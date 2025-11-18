# TROUBLESHOOTING: No Dynamic ILM Logs

## Symptoms

- No "Starting dynamic ILM resource creation" logs
- No indices/templates/policies created in Elasticsearch
- Events are being indexed to wrong indices

## Root Cause Analysis

### Most Likely Issues (in order of probability):

1. **Plugin not rebuilt/reinstalled after code changes**
2. **ILM not enabled in configuration**
3. **No sprintf placeholder in ilm_rollover_alias**
4. **Events missing the required field**
5. **Logstash using old cached gem**

---

## Step-by-Step Diagnosis

### STEP 1: Verify Plugin Was Rebuilt

```bash
# In the plugin directory
cd /path/to/logstash-output-elasticsearch

# Build the gem
gem build logstash-output-elasticsearch.gemspec

# You should see output like:
# Successfully built RubyGem
# Name: logstash-output-elasticsearch
# Version: X.X.X
# File: logstash-output-elasticsearch-X.X.X-java.gem

# Note the gem file name!
```

### STEP 2: Install the New Gem in Logstash

```bash
# In your Logstash directory (where Logstash is installed)
cd /usr/share/logstash  # or wherever Logstash is installed

# Remove old plugin
bin/logstash-plugin remove logstash-output-elasticsearch

# Install new plugin
bin/logstash-plugin install /path/to/logstash-output-elasticsearch-X.X.X-java.gem

# Verify installation
bin/logstash-plugin list | grep elasticsearch
```

**CRITICAL**: If you're using Docker/Kubernetes, you need to:

1. Build a new Docker image with the updated plugin
2. Restart/redeploy the Logstash pod

### STEP 3: Check Logstash Configuration

Your config MUST have ALL of these:

```ruby
output {
  elasticsearch {
    # ... connection settings ...

    # 1. ILM MUST be enabled
    ilm_enabled => true

    # 2. Rollover alias MUST contain sprintf placeholder %{...}
    ilm_rollover_alias => "%{[container_name]}"

    # 3. Optional but recommended
    ilm_policy => "logstash-policy"
    ilm_rollover_max_age => "1d"
  }
}
```

**Common Mistakes:**

- ❌ `ilm_enabled => "true"` (string instead of boolean)
- ❌ `ilm_rollover_alias => "container_name"` (no sprintf placeholder)
- ❌ `ilm_rollover_alias => "%{container_name}"` (wrong syntax - needs brackets)
- ✅ `ilm_rollover_alias => "%{[container_name]}"` (CORRECT)

### STEP 4: Verify Events Have the Field

Your events MUST contain the field referenced in `ilm_rollover_alias`.

Test with this filter:

```ruby
filter {
  # Debug: print the container_name
  ruby {
    code => '
      container = event.get("[container_name]")
      puts "DEBUG: container_name = #{container.inspect}"
    '
  }

  # If missing, add a default
  if ![container_name] {
    mutate {
      add_field => { "container_name" => "default" }
    }
  }
}
```

### STEP 5: Check Logstash Startup Logs

Look for these messages when Logstash starts:

**Good signs:**

```
[INFO ][logstash.outputs.elasticsearch] New Elasticsearch output
[INFO ][logstash.outputs.elasticsearch] Elasticsearch pool URLs updated
[INFO ][logstash.outputs.elasticsearch] Connected to ES instance
[INFO ][logstash.outputs.elasticsearch] Elasticsearch version determined (8.8.0)
[INFO ][logstash.outputs.elasticsearch] Skipping static template installation for dynamic ILM rollover alias
```

**Bad signs:**

```
[ERROR][logstash.outputs.elasticsearch] Failed to bootstrap
[ERROR][logstash.agent] Failed to execute action
SyntaxError: ...
```

### STEP 6: Check Runtime Logs

When events flow through, you should see:

```
[DEBUG][logstash.outputs.elasticsearch] maybe_create_dynamic_template called
[INFO ][logstash.outputs.elasticsearch] Starting dynamic ILM resource creation
[INFO ][logstash.outputs.elasticsearch] Created dynamic ILM policy
[INFO ][logstash.outputs.elasticsearch] Created rollover alias and index
[INFO ][logstash.outputs.elasticsearch] Initialized and verified dynamic ILM resources for container
```

**If you don't see these logs:**

- ILM is not enabled → Check config
- No sprintf placeholder → Check `ilm_rollover_alias`
- Field is missing → Check events

### STEP 7: Enable Debug Logging

Edit `config/log4j2.properties`:

```properties
# Add these lines
logger.elasticsearchoutput.name = logstash.outputs.elasticsearch
logger.elasticsearchoutput.level = debug

logger.dynamictemplate.name = logstash.outputs.elasticsearch.dynamic_template_manager
logger.dynamictemplate.level = debug
```

Restart Logstash and check logs again.

### STEP 8: Test with Minimal Config

Create `test-minimal.conf`:

```ruby
input {
  generator {
    lines => ['{"container_name": "testapp", "message": "test"}']
    count => 1
    codec => json
  }
}

output {
  stdout { codec => rubydebug }

  elasticsearch {
    hosts => ["http://localhost:9200"]
    user => "elastic"
    password => "changeme"

    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"

    ssl_verification_mode => "none"
  }
}
```

Run:

```bash
bin/logstash -f test-minimal.conf --log.level=debug
```

Watch for logs!

### STEP 9: Verify in Elasticsearch

After running Logstash, check Elasticsearch:

```bash
# Check indices
curl -X GET "localhost:9200/_cat/indices?v"

# Check aliases
curl -X GET "localhost:9200/_cat/aliases?v"

# Check ILM policies
curl -X GET "localhost:9200/_ilm/policy?pretty"

# Check templates
curl -X GET "localhost:9200/_index_template?pretty"
```

**Expected results:**

- Index: `testapp-2025.11.17-000001` (or similar)
- Alias: `testapp` (write index)
- Policy: `testapp-ilm-policy`
- Template: `logstash-testapp`

### STEP 10: Check for Errors in Elasticsearch

```bash
# Check Elasticsearch logs
docker logs elasticsearch-container-name

# Or
tail -f /var/log/elasticsearch/elasticsearch.log
```

Look for errors like:

- "illegal_argument_exception"
- "index_not_found_exception"
- "resource_already_exists_exception"

---

## Quick Verification Checklist

- [ ] Plugin rebuilt with `gem build`
- [ ] Plugin installed with `logstash-plugin install`
- [ ] Logstash restarted/pod redeployed
- [ ] Config has `ilm_enabled => true`
- [ ] Config has `ilm_rollover_alias => "%{[field_name]}"`
- [ ] Events contain the field referenced in rollover alias
- [ ] Logstash connected to Elasticsearch
- [ ] No syntax errors in logs
- [ ] Debug logging enabled
- [ ] Tested with minimal config

---

## Still Not Working?

### Check the Code Was Actually Loaded

Add this to your config temporarily:

```ruby
filter {
  ruby {
    code => '
      # This will print the method list
      puts "ES output methods: #{LogStash::Outputs::ElasticSearch.instance_methods(false).grep(/dynamic/).inspect}"
    '
  }
}
```

You should see `maybe_create_dynamic_template` in the output.

### Force Rebuild Everything

```bash
# Clean everything
rm -rf vendor/ .bundle/ Gemfile.lock
rm *.gem

# Rebuild
bundle install
gem build logstash-output-elasticsearch.gemspec

# Reinstall in Logstash
bin/logstash-plugin remove logstash-output-elasticsearch
bin/logstash-plugin install /full/path/to/new.gem

# Restart Logstash
bin/logstash restart
```

### Docker/Kubernetes Specific

If running in Docker/K8s:

```bash
# Rebuild Docker image
docker build -t my-logstash:latest .

# Force pull new image
kubectl delete pod logstash-pod-name
kubectl rollout restart deployment/logstash

# Check if new image is running
kubectl describe pod logstash-pod-name | grep Image
```

---

## Success Indicators

You know it's working when you see:

1. **Startup logs:**

   ```
   [INFO] Skipping static template installation for dynamic ILM rollover alias
   ```

2. **First event logs:**

   ```
   [INFO] Starting dynamic ILM resource creation container=testapp
   [INFO] Created dynamic ILM policy policy_name=testapp-ilm-policy
   [INFO] Created rollover alias and index alias=testapp
   ```

3. **Elasticsearch has resources:**

   - Policy: `testapp-ilm-policy`
   - Template: `logstash-testapp`
   - Alias: `testapp`
   - Index: `testapp-{date}-000001`

4. **Events are indexed correctly**

---

## Need More Help?

If still not working, provide:

1. Full Logstash configuration
2. Sample event JSON
3. Logstash startup logs (first 50 lines)
4. Logstash runtime logs (when event processed)
5. Elasticsearch version
6. Logstash version
7. Output of `logstash-plugin list | grep elasticsearch`
