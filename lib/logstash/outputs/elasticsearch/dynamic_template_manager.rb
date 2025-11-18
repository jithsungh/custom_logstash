module LogStash; module Outputs; class ElasticSearch  module DynamicTemplateManager
    
    # Thread-safe cache to track which containers have been initialized
    def initialize_dynamic_template_cache
      @dynamic_templates_created ||= java.util.concurrent.ConcurrentHashMap.new
    end
    
    # SIMPLIFIED: Create ILM resources (policy, template, index) for a container
    # Called ONLY ONCE per container (first event), then cached
    # Auto-recovers ONLY on index-related errors (not policy/template errors)
    def maybe_create_dynamic_template(index_name)
      unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
        return
      end
      
      alias_name = index_name
      
      # FAST PATH: If already created, skip entirely (no checks, no API calls)
      if @dynamic_templates_created.get(alias_name)
        return
      end
      
      logger.info("Initializing ILM resources for new container", :container => alias_name)
      
      # Build resource names
      policy_name = "#{alias_name}-ilm-policy"
      template_name = "logstash-#{alias_name}"
      
      # Create resources in order: policy → template → index
      # Each method is idempotent (safe to call multiple times)
      create_policy_if_missing(policy_name)
      create_template_if_missing(template_name, alias_name, policy_name)
      create_index_if_missing(alias_name, policy_name)
      
      # Cache to avoid future checks
      @dynamic_templates_created.put(alias_name, true)
      
      logger.info("ILM resources ready", 
                  :container => alias_name,
                  :policy => policy_name,
                  :template => template_name,
                  :alias => alias_name)
    rescue => e
      # Don't cache on failure - will retry on next event
      logger.error("Failed to initialize ILM resources - will retry on next event", 
                   :container => alias_name, 
                   :error => e.message,
                   :backtrace => e.backtrace.first(3))
    end
    
    # Handle indexing errors - ONLY recreate if index is missing
    # This is called by the bulk indexer when an error occurs
    def handle_dynamic_ilm_error(alias_name, error)
      return unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
      
      error_message = error.message.to_s.downcase
      
      # ONLY handle index-related errors (not policy/template errors)
      # Elasticsearch errors for missing index:
      # - "index_not_found_exception"
      # - "no such index"
      # - "IndexNotFoundException"
      index_missing = error_message.include?('index_not_found') ||
                      error_message.include?('no such index') ||
                      error_message.include?('indexnotfound')
      
      if index_missing
        logger.warn("Index missing, recreating", 
                    :container => alias_name,
                    :error => error.message)
        
        # Clear cache and recreate
        @dynamic_templates_created.remove(alias_name)
        maybe_create_dynamic_template(alias_name)
      end
    end    
    private
    
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
      
      # Determine priority: parent=50, child=100
      has_children = has_child_templates?(base_name)
      priority = has_children ? 50 : 100
      
      template = build_dynamic_template(index_pattern, policy_name, priority)
      endpoint = TemplateManager.send(:template_endpoint, self)
      
      # template_install is idempotent (won't overwrite existing)
      @client.template_install(endpoint, template_name, template, false)
      
      logger.info("Template ready", :template => template_name, :priority => priority)
    end
    
    # Create first index with write alias (idempotent - only creates if missing)
    def create_index_if_missing(alias_name, policy_name)
      # Check if alias exists
      if @client.rollover_alias_exists?(alias_name)
        logger.debug("Index/alias already exists", :alias => alias_name)
        return
      end
      
      # Create first rollover index with date pattern
      today = Time.now.strftime("%Y.%m.%d")
      first_index_name = "#{alias_name}-#{today}-000001"
      
      index_payload = {
        'aliases' => {
          alias_name => {
            'is_write_index' => true
          }
        },
        'settings' => {
          'index' => {
            'lifecycle' => {
              'name' => policy_name,
              'rollover_alias' => alias_name
            }
          }
        }
      }
      
      @client.rollover_alias_put(first_index_name, index_payload)
      
      logger.info("Created rollover index", 
                  :index => first_index_name, 
                  :alias => alias_name,
                  :policy => policy_name)
    end    
    # Check if child templates exist for a base name (simple version)
    def has_child_templates?(base_name)
      begin
        endpoint = TemplateManager.send(:template_endpoint, self)
        all_templates = @client.get_template(endpoint, "logstash-#{base_name}-*")
        
        !all_templates.nil? && !all_templates.empty?
      rescue => e
        logger.debug("Could not check for child templates", :error => e.message)
        false
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
      
      # Rollover action
      rollover_conditions = {}
      rollover_conditions["max_age"] = @ilm_rollover_max_age if @ilm_rollover_max_age
      rollover_conditions["max_size"] = @ilm_rollover_max_size if @ilm_rollover_max_size
      rollover_conditions["max_docs"] = @ilm_rollover_max_docs if @ilm_rollover_max_docs
      
      hot_phase["actions"]["rollover"] = rollover_conditions unless rollover_conditions.empty?
      
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
    end      # Build a template for dynamic ILM indices
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
        logger.warn("Could not load template file, creating minimal template programmatically", :error => e.message)
        template = nil
      end
      
      # If template loading failed, create a minimal template programmatically
      if template.nil?
        logger.info("Creating minimal dynamic template programmatically", 
                    :index_pattern => index_pattern, 
                    :policy_name => policy_name,
                    :priority => priority)
        template = create_minimal_template(index_pattern, policy_name, priority)
      else        # Set the index pattern
        template['index_patterns'] = [index_pattern]
        
        # Set priority
        template['priority'] = priority
        
        # Remove legacy template key if present
        template.delete('template') if template.include?('template') && maximum_seen_major_version == 7
        
        # Add ILM settings
        settings = TemplateManager.send(:resolve_template_settings, self, template)
        
        # Set the dynamically created policy name (not the default policy)
        settings.update({ 'index.lifecycle.name' => policy_name })
      end
      
      template
    end      # Create a minimal index template programmatically when template files are unavailable
    def create_minimal_template(index_pattern, policy_name, priority = 100)
      es_major_version = maximum_seen_major_version
      
      # Extract alias name from pattern (remove the -* suffix)
      alias_name = index_pattern.gsub('*', '').chomp('-')
        # Base settings with ILM configuration
      # NOTE: We don't set rollover_alias in the template because it requires the alias to exist
      # Instead, the alias is set when we create the first index
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
            "created_by" => "logstash-output-elasticsearch"
          }
        }
      end
    end
  end
end; end; end
