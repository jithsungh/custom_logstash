module LogStash; module Outputs; class ElasticSearch
  module DynamicTemplateManager
    
    # Thread-safe cache to track which templates and policies have been created
    def initialize_dynamic_template_cache
      @dynamic_templates_created ||= java.util.concurrent.ConcurrentHashMap.new
      @dynamic_policies_created ||= java.util.concurrent.ConcurrentHashMap.new
    end
      # Create a template and ILM policy for a specific container/index pattern if ILM is enabled with dynamic alias
    def maybe_create_dynamic_template(index_name)
      return unless ilm_in_use?
      return unless @ilm_rollover_alias&.include?('%{')
      
      # When using ILM with dynamic aliases, index_name IS the alias (e.g., "nginx", not "nginx-000001")
      # because @index is set to @ilm_rollover_alias in setup_ilm
      alias_name = index_name
      
      # Check if we've already created resources for this alias
      return if @dynamic_templates_created.get(alias_name)
      
      # Create ILM policy first (if it doesn't exist)
      policy_name = "#{alias_name}-ilm-policy"
      maybe_create_dynamic_ilm_policy(policy_name, alias_name)
      
      # Create the template
      template_name = "logstash-#{alias_name}"
      create_template_for_index(template_name, alias_name, policy_name)
      
      # Create the first rollover index with write alias
      create_rollover_index(alias_name)
      
      # Mark as created
      @dynamic_templates_created.put(alias_name, true)
      logger.info("Created dynamic ILM resources for container", 
                  :container => alias_name,
                  :template_name => template_name, 
                  :index_pattern => "#{alias_name}-*",
                  :ilm_policy => policy_name,
                  :write_alias => alias_name)
    rescue => e
      logger.error("Failed to create dynamic template/policy", 
                   :alias_name => alias_name, 
                   :error => e.message,
                   :backtrace => e.backtrace.first(5))
    end
    
    private
    
    # Create the first rollover index with write alias
    def create_rollover_index(alias_name)
      # Create index name with rollover pattern: <alias>-<pattern>
      # Default pattern is "{now/d}-000001", we'll use a simpler "000001"
      index_target = "<#{alias_name}-{now/d}-000001>"
      
      rollover_payload = {
        'aliases' => {
          alias_name => {
            'is_write_index' => true
          }
        }
      }
      
      # Only create if the alias doesn't already exist
      unless @client.rollover_alias_exists?(alias_name)
        @client.rollover_alias_put(index_target, rollover_payload)
        logger.debug("Created rollover index and alias", 
                     :index_target => index_target,
                     :alias => alias_name)
      end
    end
    
    # Create an ILM policy dynamically for a container
    def maybe_create_dynamic_ilm_policy(policy_name, base_name)
      # Check if already created in this session
      return if @dynamic_policies_created.get(base_name)
      
      # Check if policy already exists in Elasticsearch
      if @client.ilm_policy_exists?(policy_name)
        logger.debug("ILM policy already exists, skipping creation", :policy_name => policy_name)
        @dynamic_policies_created.put(base_name, true)
        return
      end
      
      # Build the policy payload
      policy_payload = build_dynamic_ilm_policy
      
      # Create the policy
      @client.ilm_policy_put(policy_name, policy_payload)
      @dynamic_policies_created.put(base_name, true)
      
      logger.info("Created dynamic ILM policy", 
                  :policy_name => policy_name,
                  :container => base_name,
                  :rollover_max_age => @ilm_rollover_max_age,
                  :delete_min_age => @ilm_delete_min_age)
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
    end
    
    # Create a template for a specific index pattern
    def create_template_for_index(template_name, base_name, policy_name)
      index_pattern = "#{base_name}-*"
      
      template = build_dynamic_template(index_pattern, policy_name)
      
      # Use the appropriate endpoint based on ES version
      endpoint = TemplateManager.send(:template_endpoint, self)
      
      # Install the template
      @client.template_install(endpoint, template_name, template, false)
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
