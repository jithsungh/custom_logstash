# Dynamic ILM Debugging Checklist

## Why Your Dynamic ILM Might Not Be Working

### 1. Check Your Logstash Configuration

Your configuration MUST have these settings for dynamic ILM to work:

```ruby
output {
  elasticsearch {
    hosts => ["http://your-elasticsearch:9200"]
    user => "elastic"
    password => "your-password"

    # CRITICAL: ILM must be enabled
    ilm_enabled => true

    # CRITICAL: Use a dynamic rollover alias with sprintf placeholder
    ilm_rollover_alias => "%{[kubernetes][container][name]}"

    # CRITICAL: Set the ILM policy name
    ilm_policy => "logstash-policy"

    # Optional: Configure rollover conditions
    ilm_rollover_max_age => "1d"
    ilm_rollover_max_size => "50gb"
    ilm_delete_min_age => "7d"
    ilm_delete_enabled => true
  }
}
```

### 2. Verify Your Events Have the Required Field

Your events MUST contain the field referenced in `ilm_rollover_alias`.

For example, if your config has:

```ruby
ilm_rollover_alias => "%{[kubernetes][container][name]}"
```

Then your event must have:

```json
{
  "kubernetes": {
    "container": {
      "name": "my-container"
    }
  }
}
```

### 3. Check Logstash Logs for Errors

Look for these log messages in your Logstash output:

**Success Messages:**

```
[INFO ][logstash.outputs.elasticsearch] Skipping static template installation for dynamic ILM rollover alias
[INFO ][logstash.outputs.elasticsearch] Created dynamic ILM policy
[INFO ][logstash.outputs.elasticsearch] Created rollover alias and index
[INFO ][logstash.outputs.elasticsearch] Initialized and verified dynamic ILM resources for container
```

**Error Messages:**

```
[ERROR][logstash.outputs.elasticsearch] ILM policy creation failed
[ERROR][logstash.outputs.elasticsearch] Failed to initialize dynamic ILM resources
[WARN ][logstash.outputs.elasticsearch] Field not found in event for ILM rollover alias
```

### 4. Verify Elasticsearch Connection

Make sure Logstash can connect to Elasticsearch:

```
[INFO ][logstash.outputs.elasticsearch] Connected to ES instance
[INFO ][logstash.outputs.elasticsearch] Elasticsearch version determined (8.8.0)
```

### 5. Check What's Actually Created in Elasticsearch

Run these commands to verify resources were created:

```bash
# Check if policies were created
GET _ilm/policy/*-ilm-policy

# Check if templates were created
GET _index_template/logstash-*

# Check if indices were created
GET _cat/indices/*-*?v

# Check if aliases exist
GET _cat/aliases/*?v
```

### 6. Enable Debug Logging

Add this to your Logstash config to see more details:

```ruby
output {
  elasticsearch {
    # ... your config ...

    # Add this for more verbose logging
    logger => true
  }
}
```

Or modify `config/log4j2.properties`:

```properties
logger.elasticsearchoutput.name = logstash.outputs.elasticsearch
logger.elasticsearchoutput.level = debug
```

### 7. Common Issues

#### Issue: No logs at all

- **Cause**: ILM is not enabled
- **Fix**: Set `ilm_enabled => true` in your config

#### Issue: "Field not found in event"

- **Cause**: The event doesn't have the field specified in `ilm_rollover_alias`
- **Fix**: Check your event structure, adjust the field path, or add the field in a filter

#### Issue: "Skipping static template installation" but nothing created

- **Cause**: Events are not flowing through the pipeline
- **Fix**: Check your input and filter configurations

#### Issue: Resources created but data not indexed

- **Cause**: Write alias might not be set correctly
- **Fix**: Check Elasticsearch logs for indexing errors

### 8. Test with Simple Configuration

Create a test file `test-dynamic-ilm.conf`:

```ruby
input {
  stdin {
    codec => json
  }
}

filter {
  # Ensure the field exists
  if ![container_name] {
    mutate {
      add_field => { "container_name" => "test-container" }
    }
  }
}

output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    user => "elastic"
    password => "changeme"

    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_policy => "logstash-policy"
    ilm_rollover_max_age => "1d"

    # Disable SSL verification for local testing
    ssl_verification_mode => "none"
  }

  stdout {
    codec => rubydebug
  }
}
```

Test with:

```bash
echo '{"message": "test", "container_name": "myapp"}' | bin/logstash -f test-dynamic-ilm.conf
```

### 9. Verify the Plugin Was Rebuilt

After fixing syntax errors, you must rebuild the plugin:

```bash
# Rebuild the gem
gem build logstash-output-elasticsearch.gemspec

# Reinstall in Logstash
bin/logstash-plugin remove logstash-output-elasticsearch
bin/logstash-plugin install /path/to/logstash-output-elasticsearch-X.X.X-java.gem
```

### 10. Check Logstash Startup

Look for these messages during startup:

```
[INFO ][logstash.outputs.elasticsearch] New Elasticsearch output
[INFO ][logstash.outputs.elasticsearch] Elasticsearch pool URLs updated
[INFO ][logstash.outputs.elasticsearch] Connected to ES instance
[INFO ][logstash.outputs.elasticsearch] Elasticsearch version determined
```

If you see errors here, the plugin didn't load correctly.

---

## Quick Diagnosis Script

Run this in your Elasticsearch to check what was created:

```json
GET _cat/indices?v
GET _cat/aliases?v
GET _ilm/policy
GET _index_template
```

If you see indices/aliases/policies with your container names, it's working!
If you see nothing, check the steps above.
