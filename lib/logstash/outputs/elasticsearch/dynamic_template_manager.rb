module LogStash
  module Outputs
    class ElasticSearch
      module DynamicTemplateManager
      # Thread-safe cache to track which containers have been initialized
    def initialize_dynamic_template_cache
      @dynamic_templates_created ||= java.util.concurrent.ConcurrentHashMap.new
      # Cache last checked day per alias to avoid repeated rollover checks
      @alias_rollover_checked_date ||= java.util.concurrent.ConcurrentHashMap.new
      # Cache resource existence to avoid redundant API calls
      @resource_exists_cache ||= java.util.concurrent.ConcurrentHashMap.new
      # Track initialization attempts to detect anomalies
      @initialization_attempts ||= java.util.concurrent.ConcurrentHashMap.new
      
      logger.debug("Initialized dynamic template caches")
    end          # SIMPLIFIED: Create ILM resources (policy, template, index) for a container
        # Called ONLY ONCE per container (first event), then cached
        # Auto-recovers ONLY on index-related errors (not policy/template errors)
        def maybe_create_dynamic_template(index_name)
      unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
        return
      end
      
      # Validate index name follows Elasticsearch naming rules
      unless valid_index_name?(index_name)
        logger.error("Invalid index name detected - skipping dynamic template creation", 
                     :index_name => index_name,
                     :reason => "Contains invalid characters or format")
        return
      end
      
      # NOTE: index_name already has "auto-" prefix added by resolve_dynamic_rollover_alias
      # in lib/logstash/outputs/elasticsearch.rb (line 656)
      # So we use it directly without adding another prefix
      alias_name = index_name
      
      # FAST PATH: If already created, skip entirely (no checks, no API calls)
      current_value = @dynamic_templates_created.get(alias_name)
      if current_value == true
        # OPTIMIZATION: Check if we need daily rollover (very lightweight, once per day per alias)
        maybe_rollover_for_new_day(alias_name)
        return
      end
      
      # Anomaly detection: Check if this container is stuck in initialization loop
      detect_initialization_anomaly(alias_name)
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
      
      # Validate resource names before proceeding
      validate_resource_names(alias_name, policy_name, template_name)
      
      # Create resources in order: policy → template → index
      # Each method is idempotent (safe to call multiple times)
      create_policy_if_missing(policy_name)
      create_template_if_missing(template_name, alias_name, policy_name)
      create_index_if_missing(alias_name, policy_name)
      
      # Verify resources were actually created
      verify_resources_created(alias_name, policy_name, template_name)
      
      # Mark as successfully created
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
        logger.warn("Index missing, clearing cache for recreation", 
                    :container => alias_name,
                    :error => error.message)
        
        # Clear all caches related to this alias
        @dynamic_templates_created.remove(alias_name)
        @resource_exists_cache.remove("policy:#{alias_name}-ilm-policy")
        @resource_exists_cache.remove("template:logstash-#{alias_name}")
        
        # Next event will recreate resources
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
        
        logger.warn("Index not found error detected, clearing all caches for next retry", 
                    :alias => alias_name)
        
        # Clear all caches - next retry will recreate resources
        @dynamic_templates_created.remove(alias_name)
        @resource_exists_cache.remove("policy:#{alias_name}-ilm-policy")
        @resource_exists_cache.remove("template:logstash-#{alias_name}")
      end    
    end
    private
    
    # Quick check if alias exists (lightweight, no exceptions)
    def verify_alias_exists(alias_name)
      begin
        @client.rollover_alias_exists?(alias_name)
      rescue => e
        logger.debug("Error checking alias existence", :alias => alias_name, :error => e.message)
        false
      end
    end      # Create ILM policy (idempotent - only creates if missing)
    def create_policy_if_missing(policy_name)
      # Check cache first to avoid API call
      cache_key = "policy:#{policy_name}"
      return if @resource_exists_cache.get(cache_key) == true
      
      max_retries = 3
      retry_count = 0
      
      begin
        # Check if exists in Elasticsearch
        if @client.ilm_policy_exists?(policy_name)
          logger.debug("Policy already exists", :policy => policy_name)
          @resource_exists_cache.put(cache_key, true)
          return
        end
        
        # Create policy
        policy_payload = build_dynamic_ilm_policy
        
        # Validate policy payload before sending
        validate_ilm_policy(policy_payload, policy_name)
        
        @client.ilm_policy_put(policy_name, policy_payload)
        @resource_exists_cache.put(cache_key, true)
        
        logger.info("Created ILM policy", :policy => policy_name)
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
        if e.response_code == 400
          # Policy might have been created by another thread/instance - check again
          if @client.ilm_policy_exists?(policy_name)
            logger.info("Policy exists (created concurrently)", :policy => policy_name)
            @resource_exists_cache.put(cache_key, true)
            return
          end
          
          logger.error("Invalid policy payload", 
                       :policy => policy_name,
                       :response_code => e.response_code,
                       :response_body => e.response_body)
          raise e
        elsif e.response_code == 429 && retry_count < max_retries
          # Rate limited - retry with exponential backoff
          retry_count += 1
          sleep_time = [2 ** retry_count, 10].min
          logger.warn("Rate limited creating policy, retrying", 
                      :policy => policy_name,
                      :retry => retry_count,
                      :sleep => sleep_time)
          sleep sleep_time
          retry
        else
          raise e
        end
      rescue => e
        logger.error("Unexpected error creating policy", 
                     :policy => policy_name,
                     :error => e.message)
        raise e
      end
    end    
    # Create template (idempotent - only creates if missing)
    def create_template_if_missing(template_name, base_name, policy_name)
      index_pattern = "#{base_name}-*"
      
      # All dynamic templates use priority 100 for simplicity
      # Elasticsearch will match the most specific pattern automatically
      priority = 100
      
      # Cache check to avoid API call
      cache_key = "template:#{template_name}"
      if @resource_exists_cache.get(cache_key) == true
        logger.debug("Template exists (cached)", :template => template_name)
        return
      end
      
      max_retries = 3
      retry_count = 0
      
      begin
        template = build_dynamic_template(index_pattern, policy_name, priority)
        endpoint = TemplateManager.send(:template_endpoint, self)
        
        # template_install is idempotent (won't overwrite existing)
        @client.template_install(endpoint, template_name, template, false)
        @resource_exists_cache.put(cache_key, true)
        
        logger.info("Template ready", :template => template_name, :priority => priority)
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
        if e.response_code == 400
          # Template might exist - check
          endpoint = TemplateManager.send(:template_endpoint, self)
          existing = @client.get_template(endpoint, template_name)
          if existing && !existing.empty?
            logger.info("Template exists (created concurrently)", :template => template_name)
            @resource_exists_cache.put(cache_key, true)
            return
          end
          
          logger.error("Invalid template payload", 
                       :template => template_name,
                       :response_code => e.response_code,
                       :response_body => e.response_body)
          raise e
        elsif e.response_code == 429 && retry_count < max_retries
          retry_count += 1
          sleep_time = [2 ** retry_count, 10].min
          logger.warn("Rate limited creating template, retrying", 
                      :template => template_name,
                      :retry => retry_count,
                      :sleep => sleep_time)
          sleep sleep_time
          retry
        else
          raise e
        end
      rescue => e
        logger.error("Unexpected error creating template", 
                     :template => template_name,
                     :error => e.message)
        raise e
      end
    end
      # Create first index with write alias (idempotent - only creates if missing)
    def create_index_if_missing(alias_name, policy_name)
      # DEFENSIVE: Loop to handle auto-creation race conditions
      max_attempts = 3
      attempts = 0
      
      while attempts < max_attempts
        attempts += 1
        
        # Check if alias exists
        if @client.rollover_alias_exists?(alias_name)
          # Alias exists - check if write index has today's date
          write_index = get_write_index_for_alias(alias_name)
          if write_index
            # Extract date from index name (format: alias-YYYY.MM.DD-NNNNNN)
            if write_index =~ /-(\d{4}\.\d{2}\.\d{2})-\d+$/
              index_date = $1
              today = current_date_str
              
              if index_date != today
                logger.info("Write index has old date, triggering rollover", 
                           :alias => alias_name,
                           :current_write_index => write_index,
                           :index_date => index_date,
                           :today => today)
                
                # Force rollover to create index with today's date
                force_rollover_with_new_date(alias_name, policy_name)
                return
              end
            end
          end
          
          logger.debug("Index/alias already exists with current date", :alias => alias_name)
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
      today = current_date_str
      first_index_name = "#{alias_name}-#{today}-000001"
      
      # Validate index name before creating
      unless valid_index_name?(first_index_name)
        logger.error("Generated index name is invalid", :index => first_index_name)
        raise LogStash::ConfigurationError, "Invalid index name: #{first_index_name}"
      end
      
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
      
      begin
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
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
        if e.response_code == 400
          # Check if it was created by another thread/instance
          if @client.rollover_alias_exists?(alias_name)
            logger.info("Index exists (created concurrently)", :alias => alias_name)
            return
          end
        end
        
        logger.error("Failed to create rollover index", 
                     :index => first_index_name,
                     :response_code => e.response_code,
                     :response_body => e.response_body)
        raise e
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

    # Get the current write index for an alias
    def get_write_index_for_alias(alias_name)
      begin
        response = @client.pool.get("_alias/#{CGI::escape(alias_name)}")
        parsed = LogStash::Json.load(response.body)
        
        # Response format: { "index-name" => { "aliases" => { "alias-name" => { "is_write_index" => true } } } }
        parsed.each do |index_name, index_data|
          aliases = index_data['aliases'] || {}
          if aliases[alias_name] && aliases[alias_name]['is_write_index']
            return index_name
          end
        end
        
        nil
      rescue => e
        logger.warn("Error getting write index for alias", :alias => alias_name, :error => e.message)
        nil
      end
    end
    
    # Force a rollover to create a new index with today's date
    def force_rollover_with_new_date(alias_name, policy_name)
      begin
        today = current_date_str
        old_write = get_write_index_for_alias(alias_name)
        new_index_name = find_next_index_name(alias_name, today)
        logger.info("Forcing rollover to new date-based index", :alias => alias_name, :old_write_index => old_write, :new_index => new_index_name)
        # Create new index WITHOUT alias to avoid multiple write_index conflict
        index_payload = {
          'settings' => {
            'index' => {
              'lifecycle' => {
                'name' => policy_name,
                'rollover_alias' => alias_name
              }
            }
          }
        }
        @client.pool.put(new_index_name, {}, LogStash::Json.dump(index_payload))
        # Atomically move alias write flag from old to new
        reassign_write_alias(alias_name, old_write, new_index_name)
        logger.info("Successfully rolled over to new date-based index", :alias => alias_name, :new_index => new_index_name)
      rescue => e
        logger.error("Failed to force rollover", :alias => alias_name, :error => e.message, :backtrace => e.backtrace.first(3))
        # Cleanup if index created but alias not moved
        begin
          unless get_write_index_for_alias(alias_name) == new_index_name
            @client.pool.delete(new_index_name)
            logger.warn("Rolled back partial rollover (deleted new index)", :index => new_index_name)
          end
        rescue => cleanup_err
          logger.warn("Failed cleanup after rollover error", :index => new_index_name, :error => cleanup_err.message)
        end
      end
    end
    
    # Atomically remove alias from old index and add to new index with write flag
    def reassign_write_alias(alias_name, old_index, new_index)
      actions = []
      actions << { 'remove' => { 'index' => old_index, 'alias' => alias_name } } if old_index
      actions << { 'add' => { 'index' => new_index, 'alias' => alias_name, 'is_write_index' => true } }
      body = { 'actions' => actions }
      @client.pool.post('/_aliases', {}, LogStash::Json.dump(body))
      logger.debug("Alias reassigned", :alias => alias_name, :old_index => old_index, :new_index => new_index)
    rescue => e
      logger.error("Failed alias reassignment", :alias => alias_name, :error => e.message)
      raise e
    end

    # Find the next available index name for a given date
    def find_next_index_name(alias_name, date_str)
      begin
        # Get all indices matching the pattern for today
        pattern = "#{alias_name}-#{date_str}-*"
        response = @client.pool.get("#{pattern}")
        parsed = LogStash::Json.load(response.body)
        
        # Find the highest number used today
        max_number = 0
        parsed.keys.each do |index_name|
          if index_name =~ /-#{Regexp.escape(date_str)}-(\d+)$/
            number = $1.to_i
            max_number = number if number > max_number
          end
        end
        
        # Return next number (or 000001 if none exist)
        next_number = max_number + 1
        "#{alias_name}-#{date_str}-#{next_number.to_s.rjust(6, '0')}"
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
        # No indices exist for today - start with 000001
        if e.response_code == 404
          "#{alias_name}-#{date_str}-000001"
        else
          raise e
        end
      end
    end    # Perform a lightweight daily check to ensure the write index matches today's date
    # If the alias points to an index with yesterday's date, force a rollover to today's index
    # OPTIMIZATION: Only called once per day per alias (cached check)
    def maybe_rollover_for_new_day(alias_name)
      return unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')

      today = current_date_str
      last_checked = @alias_rollover_checked_date.get(alias_name)
      
      # FAST PATH: Already checked today, skip
      return if last_checked == today

      # Mark as checked for today to avoid re-checking (thread-safe putIfAbsent)
      # Only one thread will win this race and perform the check
      previous = @alias_rollover_checked_date.putIfAbsent(alias_name, today)
      return unless previous.nil? || previous != today
      
      # We won the race or date changed - perform the check
      logger.debug("Performing daily rollover check", alias: alias_name, today: today, last_checked: previous)

      write_index = get_write_index_for_alias(alias_name)
      return unless write_index

      if write_index =~ /-(\d{4}\.\d{2}\.\d{2})-\d+$/
        index_date = $1
        if index_date != today
          policy_name = "#{alias_name}-ilm-policy"
          logger.info("Detected day change; forcing rollover to today's index", alias: alias_name, from: index_date, to: today)
          force_rollover_with_new_date(alias_name, policy_name)
        else
          logger.debug("Write index date matches today, no rollover needed", alias: alias_name, index_date: index_date)
        end
      end
    rescue => e
      logger.warn("Daily rollover check failed - will try again later", alias: alias_name, error: e.message)
      # Clear the date cache so it will retry later
      @alias_rollover_checked_date.remove(alias_name)
    end

    # Helper to provide consistent date formatting for index names
    def current_date_str
      Time.now.strftime("%Y.%m.%d")
    end
      end
    end    
    # UTILITY: Clear all caches for a specific container (useful for manual intervention or testing)
    # Can be called if you manually delete resources in Elasticsearch
    def clear_container_cache(alias_name)
      logger.info("Clearing all caches for container", :alias => alias_name)
      @dynamic_templates_created.remove(alias_name)
      @alias_rollover_checked_date.remove(alias_name)
      @resource_exists_cache.remove("policy:#{alias_name}-ilm-policy")
      @resource_exists_cache.remove("template:logstash-#{alias_name}")
      @initialization_attempts.remove(alias_name)
    end
    
    # Validate that index name follows Elasticsearch naming rules
    def valid_index_name?(name)
      return false if name.nil? || name.empty?
      
      # Index names must be lowercase
      return false if name != name.downcase
      
      # Cannot contain: \, /, *, ?, ", <, >, |, ` ` (space), ,, #
      return false if name =~ /[\\\/*?"<>|,# ]/
      
      # Cannot start with -, _, +
      return false if name =~ /^[-_+]/
      
      # Cannot be . or ..
      return false if name == '.' || name == '..'
      
      # Length must be <= 255 bytes
      return false if name.bytesize > 255
      
      true
    end
    
    # Validate all resource names before creating them
    def validate_resource_names(alias_name, policy_name, template_name)
      unless valid_index_name?(alias_name)
        raise LogStash::ConfigurationError, "Invalid alias name: #{alias_name}"
      end
      
      # Policy and template names have similar but slightly different rules
      # For simplicity, we use the same validation
      unless valid_index_name?(policy_name)
        raise LogStash::ConfigurationError, "Invalid policy name: #{policy_name}"
      end
      
      unless valid_index_name?(template_name)
        raise LogStash::ConfigurationError, "Invalid template name: #{template_name}"
      end
      
      logger.debug("Resource names validated", 
                   :alias => alias_name,
                   :policy => policy_name,
                   :template => template_name)
    end
    
    # Detect if a container is stuck in an initialization loop (anomaly detection)
    def detect_initialization_anomaly(alias_name)
      attempts = @initialization_attempts.get(alias_name) || 0
      
      if attempts > 10
        logger.error("ANOMALY DETECTED: Container initialization failed repeatedly", 
                     :alias => alias_name,
                     :attempts => attempts,
                     :action => "Clearing cache to force full retry")
        
        # Clear all caches to force a fresh start
        clear_container_cache(alias_name)
        @initialization_attempts.put(alias_name, 0)
      elsif attempts > 5
        logger.warn("Container initialization retrying multiple times", 
                    :alias => alias_name,
                    :attempts => attempts)
      end
      
      # Increment attempt counter
      @initialization_attempts.put(alias_name, attempts + 1)
    end
    
    # Verify that all resources were actually created successfully
    def verify_resources_created(alias_name, policy_name, template_name)
      # Verify policy exists
      unless @client.ilm_policy_exists?(policy_name)
        logger.error("VERIFICATION FAILED: Policy does not exist after creation", 
                     :policy => policy_name)
        raise StandardError.new("Policy verification failed: #{policy_name}")
      end
      
      # Verify template exists
      endpoint = TemplateManager.send(:template_endpoint, self)
      template_exists = begin
        templates = @client.get_template(endpoint, template_name)
        !templates.nil? && !templates.empty?
      rescue => e
        logger.warn("Error verifying template", :template => template_name, :error => e.message)
        false
      end
      
      unless template_exists
        logger.error("VERIFICATION FAILED: Template does not exist after creation", 
                     :template => template_name)
        raise StandardError.new("Template verification failed: #{template_name}")
      end
      
      # Verify alias/index exists
      unless @client.rollover_alias_exists?(alias_name)
        logger.error("VERIFICATION FAILED: Alias does not exist after creation", 
                     :alias => alias_name)
        raise StandardError.new("Alias verification failed: #{alias_name}")
      end
      
      logger.debug("All resources verified successfully", 
                   :alias => alias_name,
                   :policy => policy_name,
                   :template => template_name)
        # Reset attempt counter on success
      @initialization_attempts.put(alias_name, 0)
    end
    
    # Validate ILM policy structure before sending to Elasticsearch
    def validate_ilm_policy(policy, policy_name)
      unless policy && policy['policy'] && policy['policy']['phases']
        raise LogStash::ConfigurationError, "Invalid ILM policy structure for #{policy_name}"
      end
      
      phases = policy['policy']['phases']
      
      # Validate hot phase if present
      if phases['hot']
        hot = phases['hot']
        if hot['actions'] && hot['actions']['rollover']
          rollover = hot['actions']['rollover']
          
          # At least one rollover condition must be present
          if rollover.empty?
            raise LogStash::ConfigurationError, "Hot phase rollover action must have at least one condition"
          end
          
          # Validate max_age format
          if rollover['max_age'] && rollover['max_age'] !~ /^\d+[dhms]$/
            logger.warn("Invalid max_age format in ILM policy", 
                        :policy => policy_name,
                        :max_age => rollover['max_age'])
          end
          
          # Validate max_size format
          if rollover['max_size'] && rollover['max_size'] !~ /^\d+[kmgt]b$/i
            logger.warn("Invalid max_size format in ILM policy", 
                        :policy => policy_name,
                        :max_size => rollover['max_size'])
          end
        end
      end
      
      # Validate delete phase if present
      if phases['delete']
        delete = phases['delete']
        if delete['min_age'] && delete['min_age'] !~ /^\d+[dhms]$/
          logger.warn("Invalid min_age format in delete phase", 
                      :policy => policy_name,
                      :min_age => delete['min_age'])
        end
      end
      
      logger.debug("ILM policy validation passed", :policy => policy_name)
    end
    
    private
  end
end
