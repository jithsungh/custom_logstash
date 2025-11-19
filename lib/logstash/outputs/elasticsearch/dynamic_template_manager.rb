module LogStash
  module Outputs
    class ElasticSearch
      module DynamicTemplateManager
    
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
      
      # NOTE: index_name already has "auto-" prefix added by resolve_dynamic_rollover_alias
      # in lib/logstash/outputs/elasticsearch.rb (line 656)
      # So we use it directly without adding another prefix
      alias_name = index_name
      
      # FAST PATH: If already created, skip entirely (no checks, no API calls)
      current_value = @dynamic_templates_created.get(alias_name)
      if current_value == true
        return
      end
        # THREAD-SAFE: Use putIfAbsent to ensure only ONE thread creates resources
      # putIfAbsent returns nil if key was absent (we won the race), 
      # or the previous value if key already existed (another thread has it)
      previous_value = @dynamic_templates_created.putIfAbsent(alias_name, "initializing")
        if previous_value.nil?
        # We won the race! Key was absent, we now hold the lock with "initializing"
        logger.info("Lock acquired, proceeding with initialization", :container => alias_name)
        # Continue to resource creation below
      else
        # Another thread already grabbed the lock (previous_value is "initializing" or true)
        logger.debug("Another thread holds lock, waiting", 
                     :container => alias_name, 
                     :lock_value => previous_value)
        
        # If it's already fully created, return immediately
        return if previous_value == true
          # Otherwise wait for initialization to complete (another thread is working on it)
        50.times do
          sleep 0.1
          current = @dynamic_templates_created.get(alias_name)
          if current == true
            logger.debug("Initialization complete by other thread", :container => alias_name)
            return
          end
        end
        
        logger.error("Timeout waiting for ILM initialization - will retry", :container => alias_name)
        raise StandardError.new("Timeout waiting for container #{alias_name} ILM initialization")
      end
      
      logger.info("Initializing ILM resources for new container", :container => alias_name)
      
      # Build resource names
      policy_name = "#{alias_name}-ilm-policy"
      template_name = "logstash-#{alias_name}"
      
      # Create resources in order: policy → template → index
      # Each method is idempotent (safe to call multiple times)
      create_policy_if_missing(policy_name)
      create_template_if_missing(template_name, alias_name, policy_name)
      create_index_if_missing(alias_name, policy_name)      # Mark as successfully created
      @dynamic_templates_created.put(alias_name, true)
      
      logger.info("ILM resources ready, lock released", 
                  :container => alias_name,
                  :policy => policy_name,
                  :template => template_name,
                  :alias => alias_name)
    rescue => e
      # Don't cache on failure - will retry on next event
      @dynamic_templates_created.remove(alias_name)
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
    
    # Called from common.rb when bulk indexing encounters index_not_found error
    # Extracts the index name from the action and clears the cache
    def handle_index_not_found_error(action)
      return unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
      
      # Action is [action_type, params, event_data]
      # params contains :_index with the alias name
      if action && action[1] && action[1][:_index]
        alias_name = action[1][:_index]
        
        logger.warn("Index not found error detected, clearing cache for next retry", 
                    :alias => alias_name)
        
        # Clear cache - next retry will recreate resources
        @dynamic_templates_created.remove(alias_name)
      end    end
    private
    
    # Quick check if alias exists (lightweight, no exceptions)
    def verify_alias_exists(alias_name)
      begin
        @client.rollover_alias_exists?(alias_name)
      rescue => e
        logger.debug("Error checking alias existence", :alias => alias_name, :error => e.message)
        false
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
    end# Create first index with write alias (idempotent - only creates if missing)
    def create_index_if_missing(alias_name, policy_name)
      # DEFENSIVE: Loop to handle auto-creation race conditions
      max_attempts = 3
      attempts = 0
      
      while attempts < max_attempts
        attempts += 1
        
        # Check if alias exists
        if @client.rollover_alias_exists?(alias_name)
          logger.debug("Index/alias already exists", :alias => alias_name)
          return
        end
        
        # Check if a simple index exists with the same name as the alias
        # This can happen if Elasticsearch auto-created it during a brief gap
        if simple_index_exists?(alias_name)
          logger.warn("Found simple index with alias name - deleting and recreating properly (attempt #{attempts}/#{max_attempts})", 
                      :index => alias_name)
          delete_simple_index(alias_name)
          # After deletion, loop back to re-check before creating
          sleep 0.1  # Brief pause to let deletion propagate
          next
        end
        
        # Neither alias nor simple index exists - safe to create
        break
      end
      
      if attempts >= max_attempts
        logger.error("Failed to clean up auto-created index after #{max_attempts} attempts", :alias => alias_name)
        raise StandardError.new("Cannot create rollover index: auto-created index keeps reappearing")
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
      
      # Verify the alias was created correctly (not as a simple index)
      if @client.rollover_alias_exists?(alias_name)
        logger.info("Created and verified rollover index", 
                    :index => first_index_name, 
                    :alias => alias_name,
                    :policy => policy_name)
      else
        logger.error("Rollover index creation may have failed - alias not found after creation", 
                     :index => first_index_name,
                     :alias => alias_name)
      end
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
    end    # Build a template for dynamic ILM indices
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
    end# Create a minimal index template programmatically when template files are unavailable
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
    end    # Check if a simple index (not an alias) exists with the given name
    def simple_index_exists?(index_name)
      begin
        # Use GET /index_name to check if an index exists
        response = @client.pool.get(index_name)
        parsed = LogStash::Json.load(response.body)
        
        logger.debug("Simple index check response", :index => index_name, :has_data => !parsed.nil?)
        
        # If we get a 200 response with index details, it's a simple index
        # Response format: { "index_name" => { "aliases" => {...}, "mappings" => {...}, "settings" => {...} } }
        if parsed && parsed.is_a?(Hash) && parsed[index_name]
          # Check if it has aliases field - if empty or doesn't point to write alias, it's a simple index
          index_data = parsed[index_name]
          aliases = index_data['aliases'] || {}
          
          # It's a simple index if:
          # 1. It exists (we got here)
          # 2. It has no aliases, OR
          # 3. It has aliases but none with is_write_index: true
          
          if aliases.empty?
            logger.warn("Found simple index (no aliases)", :index => index_name)
            return true
          else
            # Check if any alias has is_write_index: true
            has_write_alias = aliases.values.any? { |alias_def| alias_def['is_write_index'] == true }
            if !has_write_alias
              logger.warn("Found simple index (no write alias)", :index => index_name, :aliases => aliases.keys)
              return true
            end
          end
        end
        
        return false
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
        # 404 means it doesn't exist - that's fine
        if e.response_code == 404
          logger.debug("Index does not exist (404)", :index => index_name)
          return false
        end
        # Other errors - log and assume it doesn't exist
        logger.warn("Error checking if simple index exists", :index => index_name, :code => e.response_code, :error => e.message)
        return false
      rescue => e
        logger.warn("Error checking if simple index exists", :index => index_name, :error => e.message, :backtrace => e.backtrace.first(2))
        return false
      end
    end
      # Delete a simple index (used to clean up auto-created indices)
    def delete_simple_index(index_name)
      begin
        @client.pool.delete(index_name)
        logger.info("Deleted auto-created simple index", :index => index_name)
      rescue => e
        logger.warn("Failed to delete simple index - will retry", 
                    :index => index_name, 
                    :error => e.message)
        raise e
      end
    end
      end
    end
  end
end
