# Dynamic ILM Rollover Alias Support

## Overview

This enhancement allows `ilm_rollover_alias` to support dynamic event-based substitution using Logstash's sprintf syntax (e.g., `%{container_name}`), similar to how the `index` field currently works.

## Usage

### Configuration Example

```ruby
output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{container_name}"
    ilm_pattern => "{now/d}-000001"
    ilm_policy => "custom-policy"
  }
}
```

### How It Works

1. **Per-Event Resolution**: The `ilm_rollover_alias` template is resolved for each event using `event.sprintf()`, allowing field references like `%{container_name}`, `%{application}`, etc.

2. **Thread-Safe Alias Creation**: When a new alias is encountered, the plugin automatically:

   - Checks if the alias exists in Elasticsearch
   - Creates the alias with an initial index (following the ILM pattern) if it doesn't exist
   - Marks it as a write index for ILM rollover
   - Caches the alias name to avoid repeated checks

3. **Automatic Index Management**: Each unique resolved alias gets its own:
   - Initial index (e.g., `logs-nginx-2025.11.12-000001`)
   - ILM policy association
   - Rollover configuration

## Example Scenarios

### Scenario 1: Multi-Container Logging

**Input Events:**

```json
{"message": "Error occurred", "container_name": "nginx"}
{"message": "Request processed", "container_name": "app"}
{"message": "Database query", "container_name": "postgres"}
```

**Configuration:**

```ruby
ilm_rollover_alias => "logs-%{container_name}"
```

**Result:**

- Creates aliases: `logs-nginx`, `logs-app`, `logs-postgres`
- Each gets its own index series:
  - `logs-nginx-2025.11.12-000001`, `logs-nginx-2025.11.12-000002`, ...
  - `logs-app-2025.11.12-000001`, `logs-app-2025.11.12-000002`, ...
  - `logs-postgres-2025.11.12-000001`, ...

### Scenario 2: Multi-Tenant Application

**Configuration:**

```ruby
ilm_rollover_alias => "%{tenant_id}-logs"
```

**Result:**

- Each tenant gets isolated ILM-managed indices
- Automatic creation of new tenant aliases on first event

### Scenario 3: Combined Fields

**Configuration:**

```ruby
ilm_rollover_alias => "%{environment}-%{service_name}"
```

**Result:**

- Creates aliases like: `prod-api`, `staging-web`, `dev-worker`

## Implementation Details

### Key Changes

1. **Template Storage**: The original `ilm_rollover_alias` config value is stored in `@ilm_rollover_alias_template`

2. **Resolution Method**: New `resolve_dynamic_rollover_alias(event)` method performs sprintf substitution per event

3. **Thread Safety**: A mutex (`@dynamic_alias_mutex`) ensures concurrent events don't create duplicate aliases

4. **Alias Caching**: A Set (`@created_aliases`) tracks aliases that have been verified/created

5. **Modified Index Resolution**: The `resolve_index!` method checks for dynamic aliases before standard index resolution

### Code Flow

```
Event arrives
    ↓
resolve_index!(event) called
    ↓
Check if ILM enabled & template has placeholders
    ↓
resolve_dynamic_rollover_alias(event)
    ↓
event.sprintf(@ilm_rollover_alias_template)
    ↓
ensure_rollover_alias_exists(resolved_alias)
    ↓
Create alias if needed (thread-safe)
    ↓
Return resolved alias as index name
```

## Important Caveats

### ⚠️ Production Considerations

1. **Not Officially Supported**: Elasticsearch ILM was designed for static aliases, not dynamic per-event aliases

2. **Maintenance Required**: Custom modifications may break on Logstash upgrades

3. **Performance Impact**: Each new alias requires Elasticsearch API calls (cached after first creation)

4. **Rollover Guarantees**: Dynamic aliases may not behave exactly like static ILM configurations

5. **Cluster Load**: Many unique field values = many aliases = increased cluster metadata

### Recommended Alternatives

For production use, consider these officially supported approaches:

- **Data Streams**: Use Elasticsearch data streams with dynamic naming
- **Dynamic Index Patterns**: Use `index => "logs-%{container_name}-%{+yyyy.MM.dd}"` without ILM
- **Index Templates**: Configure templates with appropriate patterns

## Testing

### Unit Test Example

```bash
# Build the gem
rake build

# Install locally
bin/logstash-plugin install logstash-output-elasticsearch-*.gem

# Test with sample config
```

### Sample Logstash Config for Testing

```ruby
input {
  stdin {
    codec => json
  }
}

filter {
  # Ensure container_name field exists
  if ![container_name] {
    mutate {
      add_field => { "container_name" => "default" }
    }
  }
}

output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{container_name}"
    ilm_pattern => "{now/d}-000001"
  }

  stdout {
    codec => rubydebug
  }
}
```

### Test Events

```json
{"message": "test 1", "container_name": "nginx"}
{"message": "test 2", "container_name": "app"}
{"message": "test 3", "container_name": "nginx"}
```

### Verify in Elasticsearch

```bash
# Check created aliases
curl -X GET "localhost:9200/_cat/aliases/logs-*?v"

# Check indices
curl -X GET "localhost:9200/_cat/indices/logs-*?v"

# Check alias details
curl -X GET "localhost:9200/logs-nginx"
```

## Troubleshooting

### Alias Creation Fails

**Symptom**: Errors about alias not existing or creation failing

**Solutions**:

- Check Elasticsearch permissions
- Verify ILM policy exists
- Check cluster health
- Review Logstash logs for detailed errors

### Undefined Field References

**Symptom**: Aliases created with literal `%{field_name}` in the name

**Solutions**:

- Ensure the field exists in events before reaching output
- Add filters to set default values
- Use conditional output blocks

### Performance Issues

**Symptom**: Slow indexing with many dynamic aliases

**Solutions**:

- Limit cardinality of fields used in alias template
- Consider static aliases or data streams
- Increase Elasticsearch cluster resources

## Building and Installation

```bash
# Navigate to plugin directory
cd logstash-output-elasticsearch

# Build the gem
gem build logstash-output-elasticsearch.gemspec

# Install in Logstash
/path/to/logstash/bin/logstash-plugin install logstash-output-elasticsearch-*.gem

# Restart Logstash
```

## Compatibility

- Tested with Logstash 7.x and 8.x
- Requires Elasticsearch with ILM support (6.6+)
- Ruby 2.5+

## License

Same as parent project (Apache 2.0)
