module LogStash
  module Outputs
    class ElasticSearch
      module DynamicTemplateManager
    
        # Thread-safe cache to track which containers have been initialized
        def initialize_dynamic_template_cache
          @dynamic_templates_created ||= java.util.concurrent.ConcurrentHashMap.new
        end
          # Create ILM resources (policy, template, index) for a container
        # Called ONLY ONCE per container (first event), then cached
        def maybe_create_dynamic_template(index_name)
      unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
        return
      end
        # NOTE: index_name already has "auto-" prefix added by resolve_dynamic_rollover_alias
      # in lib/logstash/outputs/elasticsearch.rb (line 656)
      # So we use it directly without adding another prefix
      container_name = index_name
      
      # Fast path: If already created, skip entirely (no checks, no API calls)
      current_value = @dynamic_templates_created.get(container_name)
      if current_value == true
        return
      end
      
      # Build resource names early (needed for both success and error paths)
      policy_name = "#{container_name}-ilm-policy"
      template_name = "logstash-#{container_name}"
      
      # Thread-safe: Use putIfAbsent to ensure only ONE thread creates resources
      # putIfAbsent returns nil if key was absent (we won the race), 
      # or the previous value if key already existed (another thread has it)
      previous_value = @dynamic_templates_created.putIfAbsent(container_name, "initializing")        
      if previous_value.nil?
        # We won the race! Key was absent, we now hold the lock with "initializing"
        logger.info("Lock acquired, proceeding with initialization", :container => container_name)
        # Continue to resource creation below
      else
        # Another thread already grabbed the lock (previous_value is "initializing" or true)
        logger.debug("Another thread holds lock, waiting", 
                     :container => container_name, 
                     :lock_value => previous_value)
        
        # If it's already fully created, return immediately
        return if previous_value == true
        
        # Otherwise wait for initialization to complete (another thread is working on it)
        50.times do
          sleep 0.1
          current = @dynamic_templates_created.get(container_name)
          if current == true
            logger.debug("Initialization complete by other thread", :container => container_name)
            return
          end
        end
        
        logger.error("Timeout waiting for ILM initialization - will retry", :container => container_name)
        raise StandardError.new("Timeout waiting for container #{container_name} ILM initialization")
      end
      
      logger.info("Initializing ILM resources for new container", :container => container_name)
      
      # Create resources in order: policy → template → index
      # Each method is idempotent (safe to call multiple times)
      create_policy_if_missing(policy_name)
      create_template_if_missing(template_name, container_name, policy_name)
      create_index_if_missing(container_name, policy_name)
      
      # Mark as successfully created
      @dynamic_templates_created.put(container_name, true)
      
      logger.info("ILM resources ready, lock released", 
                  :container => container_name,
                  :policy => policy_name,
                  :template => template_name,
                  :index_pattern => "#{container_name}-*")
    rescue => e
      # Don't cache on failure - will retry on next event
      @dynamic_templates_created.remove(container_name)
      logger.error("Failed to initialize ILM resources - will retry on next event", 
                   :container => container_name, 
                   :error => e.message,                   :backtrace => e.backtrace.first(3))
    end
      # Handle indexing errors - recreate if index is missing
    def handle_dynamic_ilm_error(container_name, error)
      return unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
      
      error_message = error.message.to_s.downcase
      
      # Handle index-related errors only
      index_missing = error_message.include?('index_not_found') ||
                      error_message.include?('no such index') ||
                      error_message.include?('indexnotfound')
      
      if index_missing
        logger.warn("Index missing, recreating", 
                    :container => container_name,
                    :error => error.message)
        
        # Clear cache and recreate
        @dynamic_templates_created.remove(container_name)
        maybe_create_dynamic_template(container_name)
      end
    end    
    # Called from common.rb when bulk indexing encounters index_not_found error
    def handle_index_not_found_error(action)
      return unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
      
      if action && action[1] && action[1][:_index]
        container_name = action[1][:_index]
        logger.warn("Index not found error detected, clearing cache for next retry", 
                    :container => container_name)
        @dynamic_templates_created.remove(container_name)
      end
    end
    
    private
    
    # Check if an index exists (simple and reliable)
    def index_exists?(index_name)
      begin
        response = @client.pool.head(index_name)
        return true
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
        return false if e.response_code == 404
        logger.warn("Error checking if index exists", :index => index_name, :error => e.message)
        return false
      rescue => e
        logger.warn("Error checking if index exists", :index => index_name, :error => e.message)
        return false
      end
    end
    
    # Create ILM policy (idempotent - only creates if missing)
    def create_policy_if_missing(policy_name)
      # Check if exists first
      if @client.ilm_policy_exists?(policy_name)
        logger.debug("Policy already exists", :policy => policy_name)
        return
      end
      
      # Create policy
      policy_payload = build_dynamic_ilm_policy
      @client.ilm_policy_put(policy_name, policy_payload)      
      logger.info("Created ILM policy", :policy => policy_name)
    end
    
    # Create template (idempotent - only creates if missing)
    def create_template_if_missing(template_name, base_name, policy_name)
      index_pattern = "#{base_name}-*"
      
      # All dynamic templates use priority 100 for simplicity
      # Elasticsearch will match the most specific pattern automatically
      priority = 100
      
      template = build_dynamic_template(index_pattern, policy_name, priority)
      endpoint = TemplateManager.send(:template_endpoint, self)
      
      # template_install is idempotent (won't overwrite existing)
      @client.template_install(endpoint, template_name, template, false)      
      logger.info("Template ready", :template => template_name, :priority => priority)
    end    
    # Create first index with date-based naming (idempotent)
    def create_index_if_missing(container_name, policy_name)
      today = current_date_str
      index_name = "#{container_name}-#{today}"
      
      # Check if today's index already exists
      if index_exists?(index_name)
        logger.debug("Index already exists for today", :index => index_name)
        return
      end
      
      # Create today's index with ILM policy
      logger.info("Creating new index for container", 
                  :container => container_name,
                  :index => index_name,
                  :policy => policy_name)
      
      index_payload = {
        'settings' => {
          'index' => {
            'lifecycle' => {
              'name' => policy_name
            },
            'number_of_shards' => (@number_of_shards || 1).to_s,
            'number_of_replicas' => (@number_of_replicas || 0).to_s
          }
        }
      }
      
      begin
        @client.pool.put(index_name, {}, LogStash::Json.dump(index_payload))
        logger.info("Successfully created index", 
                    :index => index_name,
                    :container => container_name,
                    :policy => policy_name)
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
        # 400 with "resource_already_exists_exception" means index was created by another thread - that's OK
        if e.response_code == 400 && e.message.to_s.include?('resource_already_exists')
          logger.debug("Index already created by another thread", :index => index_name)
        else          raise e
        end
      end
    end
    
    # Build ILM policy payload based on configuration
    def build_dynamic_ilm_policy
      policy = {
        "policy" => {
          "phases" => {}
        }
      }
      
      # Hot phase configuration
      hot_phase = {
        "min_age" => "0ms",
        "actions" => {}
      }
      
      # Set priority
      hot_phase["actions"]["set_priority"] = {
        "priority" => @ilm_hot_priority
      }
      
      policy["policy"]["phases"]["hot"] = hot_phase
      
      # Delete phase configuration (if enabled)
      if @ilm_delete_enabled
        delete_phase = {
          "min_age" => @ilm_delete_min_age,
          "actions" => {
            "delete" => {
              "delete_searchable_snapshot" => true
            }
          }
        }        
        policy["policy"]["phases"]["delete"] = delete_phase
      end
      
      policy
    end
    
    # Build a template for dynamic ILM indices
    def build_dynamic_template(index_pattern, policy_name, priority = 100)
      logger.debug("Building dynamic template", 
                   :index_pattern => index_pattern, 
                   :policy_name => policy_name,
                   :priority => priority)
      
      # Try to load a custom or default template if available
      template = nil
      begin
        if @template
          logger.debug("Loading custom template file", :template => @template)
          template = TemplateManager.send(:read_template_file, @template)
        else
          logger.debug("Attempting to load default template", :es_version => maximum_seen_major_version, :ecs_compatibility => ecs_compatibility)
          template = TemplateManager.send(:load_default_template, maximum_seen_major_version, ecs_compatibility)
        end
      rescue => e
        logger.warn("Could not load template file - will create minimal template", :error => e.message)
        template = nil
      end
      
      # Use loaded template or create minimal one
      if template && !template.empty?
        # Modify loaded template with dynamic settings
        template['index_patterns'] = [index_pattern]
        template['priority'] = priority
        
        # Remove legacy template key if present
        template.delete('template') if template.include?('template') && maximum_seen_major_version == 7
        
        # Add ILM settings
        settings = TemplateManager.send(:resolve_template_settings, self, template)
        settings.update({ 'index.lifecycle.name' => policy_name })
      else
        # Create minimal template programmatically
        logger.info("Creating minimal dynamic template programmatically", 
                    :index_pattern => index_pattern, 
                    :policy_name => policy_name,
                    :priority => priority)
        template = create_minimal_template(index_pattern, policy_name, priority)
      end      
      template
    end
    
    # Create a minimal index template programmatically when template files are unavailable
    def create_minimal_template(index_pattern, policy_name, priority = 100)      es_major_version = maximum_seen_major_version
      
      # Base settings with ILM configuration
      base_settings = {
        "index" => {
          "lifecycle" => {
            "name" => policy_name
          },
          "routing" => {
            "allocation" => {
              "include" => {
                "_tier_preference" => "data_content"
              }
            }
          },
          "refresh_interval" => "5s",
          "number_of_shards" => (@number_of_shards || 1).to_s,
          "number_of_replicas" => (@number_of_replicas || 0).to_s
        }
      }
      
      # Common mappings structure for both ES 7 and 8
      common_mappings = {
        "dynamic_templates" => [
          {
            "message_field" => {
              "path_match" => "message",
              "match_mapping_type" => "string",
              "mapping" => {
                "norms" => false,
                "type" => "text"
              }
            }
          },
          {
            "string_fields" => {
              "match" => "*",
              "match_mapping_type" => "string",
              "mapping" => {
                "fields" => {
                  "keyword" => {
                    "ignore_above" => 256,
                    "type" => "keyword"
                  }
                },
                "norms" => false,
                "type" => "text"
              }
            }
          }
        ],
        "properties" => {
          "@timestamp" => { "type" => "date" },
          "@version" => { "type" => "keyword" },
          "geoip" => {
            "dynamic" => "true",
            "properties" => {
              "ip" => { "type" => "ip" },
              "latitude" => { "type" => "half_float" },
              "location" => { "type" => "geo_point" },
              "longitude" => { "type" => "half_float" }
            }
          }
        }
      }
        # Elasticsearch 8+ uses composable index templates
      if es_major_version >= 8
        {
          "index_patterns" => [index_pattern],
          "priority" => priority,
          "template" => {
            "settings" => base_settings,
            "mappings" => common_mappings,
            "aliases" => {}
          },
          "_meta" => {
            "description" => "Dynamically created template for ILM-managed index",
            "created_by" => "logstash-output-elasticsearch"
          }
        }
      # Elasticsearch 7 uses legacy templates with flat structure
      else
        {
          "index_patterns" => [index_pattern],
          "order" => priority,
          "settings" => base_settings,
          "mappings" => common_mappings,
          "aliases" => {},
          "_meta" => {
            "description" => "Dynamically created template for ILM-managed index",
            "created_by" => "logstash-output-elasticsearch"          }
        }
      end
    end
    
    # Helper to provide consistent date formatting for index names
    def current_date_str
      Time.now.strftime("%Y.%m.%d")
    end
    
      end
    end
  end
end
