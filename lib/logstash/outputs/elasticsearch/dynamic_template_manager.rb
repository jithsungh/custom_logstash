module LogStash; module Outputs; class ElasticSearch
  module DynamicTemplateManager
    
    # Thread-safe cache to track which templates and policies have been created
    def initialize_dynamic_template_cache
      @dynamic_templates_created ||= java.util.concurrent.ConcurrentHashMap.new
      @dynamic_policies_created ||= java.util.concurrent.ConcurrentHashMap.new
    end    # Create a template and ILM policy for a specific container/index pattern if ILM is enabled with dynamic alias
    # Uses lazy creation: only creates resources on first event, then caches
    # Automatically recreates if Elasticsearch returns errors (resilient to manual deletions)
    def maybe_create_dynamic_template(index_name)
      return unless ilm_in_use?
      return unless @ilm_rollover_alias&.include?('%{')
      
      # When using ILM with dynamic aliases, index_name IS the alias (e.g., "nginx", not "nginx-000001")
      # because @index is set to @ilm_rollover_alias in setup_ilm
      alias_name = index_name
      
      # Check cache - if already created, skip (resources exist in Elasticsearch)
      return if @dynamic_templates_created.get(alias_name)
      
      # Build resource names
      policy_name = "#{alias_name}-ilm-policy"
      template_name = "logstash-#{alias_name}"
      
      # Create resources (idempotent - checks existence internally)
      ensure_ilm_policy_exists(policy_name, alias_name)
      ensure_template_exists(template_name, alias_name, policy_name)
      ensure_rollover_alias_exists(alias_name)
      
      # Mark as created (cache for performance)
      @dynamic_templates_created.put(alias_name, true)
      
      logger.info("Initialized dynamic ILM resources for container", 
                  :container => alias_name,
                  :template_name => template_name, 
                  :index_pattern => "#{alias_name}-*",
                  :ilm_policy => policy_name,
                  :write_alias => alias_name)
    rescue => e
      # Don't cache on failure - will retry on next event
      logger.error("Failed to initialize dynamic ILM resources", 
                   :container => alias_name, 
                   :error => e.message,
                   :backtrace => e.backtrace.first(5))
    end
    
    # Handle indexing errors that might indicate missing resources
    # Call this when you get indexing errors to auto-recover
    def handle_dynamic_ilm_error(index_name, error)
      return unless ilm_in_use?
      return unless @ilm_rollover_alias&.include?('%{')
      
      alias_name = index_name
      error_message = error.message.to_s.downcase
      
      # Check if error indicates missing ILM policy, template, or alias
      missing_policy = error_message.include?('policy') || error_message.include?('ilm')
      missing_template = error_message.include?('template')
      missing_alias = error_message.include?('alias') || error_message.include?('index_not_found')
      
      if missing_policy || missing_template || missing_alias
        logger.warn("Detected missing ILM resource, attempting recovery", 
                    :container => alias_name,
                    :error_type => error.class.name)
        
        # Clear cache to force recreation
        @dynamic_templates_created.delete(alias_name)
        @dynamic_policies_created.delete(alias_name)
        
        # Recreate resources
        maybe_create_dynamic_template(alias_name)
      end
    end    
    private
    
    # Ensure ILM policy exists (idempotent - only creates if missing)
    def ensure_ilm_policy_exists(policy_name, base_name)
      # Check cache first (fast path)
      return if @dynamic_policies_created.get(base_name)
      
      # Check if policy exists in Elasticsearch
      if @client.ilm_policy_exists?(policy_name)
        @dynamic_policies_created.put(base_name, true)
        logger.debug("ILM policy already exists", :policy_name => policy_name)
        return
      end
      
      # Policy doesn't exist - create it
      policy_payload = build_dynamic_ilm_policy
      @client.ilm_policy_put(policy_name, policy_payload)
      @dynamic_policies_created.put(base_name, true)
      
      logger.info("Created dynamic ILM policy", 
                  :policy_name => policy_name,
                  :container => base_name,
                  :rollover_max_age => @ilm_rollover_max_age,
                  :delete_min_age => @ilm_delete_min_age)
    end
    
    # Ensure index template exists (idempotent)
    def ensure_template_exists(template_name, base_name, policy_name)
      index_pattern = "#{base_name}-*"
      template = build_dynamic_template(index_pattern, policy_name)
      endpoint = TemplateManager.send(:template_endpoint, self)
      
      # template_install is already idempotent (won't overwrite existing templates)
      @client.template_install(endpoint, template_name, template, false)
      logger.debug("Template ensured", :template_name => template_name)
    end
    
    # Ensure rollover alias exists (idempotent)
    def ensure_rollover_alias_exists(alias_name)
      # Check if alias exists
      return if @client.rollover_alias_exists?(alias_name)
      
      # Create the first rollover index with write alias
      index_target = "<#{alias_name}-{now/d}-000001>"
      rollover_payload = {
        'aliases' => {
          alias_name => {
            'is_write_index' => true
          }
        }
      }
      
      @client.rollover_alias_put(index_target, rollover_payload)
      logger.info("Created rollover alias and index", 
                  :alias => alias_name,
                  :index_pattern => index_target)
    end    # Build ILM policy payload based on configuration
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
    end
    
    # Build a template for dynamic ILM indices
    def build_dynamic_template(index_pattern, policy_name)
      # Load the default template structure
      if @template
        template = TemplateManager.send(:read_template_file, @template)
      else
        template = TemplateManager.send(:load_default_template, maximum_seen_major_version, ecs_compatibility)
      end
      
      # Set the index pattern
      template['index_patterns'] = [index_pattern]
      
      # Remove legacy template key if present
      template.delete('template') if template.include?('template') && maximum_seen_major_version == 7
      
      # Add ILM settings
      settings = TemplateManager.send(:resolve_template_settings, self, template)
      
      # Set the dynamically created policy name (not the default policy)
      settings.update({ 'index.lifecycle.name' => policy_name })
      
      template
    end
  end
end; end; end
