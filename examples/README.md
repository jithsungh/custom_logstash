# Testing Dynamic ILM Rollover Alias

This directory contains example configuration and test data for the dynamic ILM rollover alias feature.

## Prerequisites

1. Elasticsearch running on `http://localhost:9200`
2. Logstash installed with the modified plugin

## Files

- `dynamic_ilm_config.conf` - Logstash configuration with dynamic ILM rollover alias
- `test_events.json` - Sample events with different container names

## Quick Test

### Option 1: Using test data file

```bash
# Navigate to your Logstash installation
cd /path/to/logstash

# Run with the example config
bin/logstash -f /path/to/logstash-output-elasticsearch/examples/dynamic_ilm_config.conf < /path/to/logstash-output-elasticsearch/examples/test_events.json
```

### Option 2: Interactive testing

```bash
# Run Logstash with the config
bin/logstash -f /path/to/logstash-output-elasticsearch/examples/dynamic_ilm_config.conf

# Then paste JSON events one at a time:
{"message": "test nginx", "container_name": "nginx"}
{"message": "test app", "container_name": "app"}
{"message": "test postgres", "container_name": "postgres"}
```

## Verify Results in Elasticsearch

### Check created aliases

```bash
curl -X GET "localhost:9200/_cat/aliases/logs-*?v&s=alias"
```

Expected output showing multiple aliases:

```
alias           index                           filter routing.index routing.search is_write_index
logs-app        logs-app-2025.11.12-000001      -      -             -              true
logs-nginx      logs-nginx-2025.11.12-000001    -      -             -              true
logs-postgres   logs-postgres-2025.11.12-000001 -      -             -              true
logs-redis      logs-redis-2025.11.12-000001    -      -             -              true
```

### Check created indices

```bash
curl -X GET "localhost:9200/_cat/indices/logs-*?v&s=index"
```

### Check alias details

```bash
# Get details for a specific alias
curl -X GET "localhost:9200/logs-nginx?pretty"

# Should show the alias configuration and associated index
```

### Search logs by container

```bash
# Search all nginx logs
curl -X GET "localhost:9200/logs-nginx/_search?pretty"

# Search all app logs
curl -X GET "localhost:9200/logs-app/_search?pretty"

# Search across all containers
curl -X GET "localhost:9200/logs-*/_search?pretty"
```

### Check ILM policy association

```bash
# Get ILM policies
curl -X GET "localhost:9200/_ilm/policy?pretty"

# Check index ILM settings
curl -X GET "localhost:9200/logs-nginx-*/_ilm/explain?pretty"
```

## Expected Behavior

1. **First event for each container**:

   - Creates a new ILM rollover alias (e.g., `logs-nginx`)
   - Creates initial index (e.g., `logs-nginx-2025.11.12-000001`)
   - Associates ILM policy
   - Sets as write index

2. **Subsequent events for same container**:

   - Writes to existing alias
   - Uses cached alias (no API calls)
   - Normal ILM rollover when conditions met

3. **Concurrent events**:
   - Thread-safe alias creation
   - No duplicate aliases created

## Troubleshooting

### No indices created

- Check Elasticsearch is running: `curl localhost:9200`
- Check Logstash logs for errors
- Verify JSON events are valid

### Alias creation errors

- Check Elasticsearch user permissions
- Verify ILM is enabled on Elasticsearch
- Check cluster health: `curl localhost:9200/_cluster/health?pretty`

### Fields not substituted

- Verify JSON events contain the `container_name` field
- Check filter section in config adds default value
- Review Logstash debug output

## Cleanup

To remove test indices and aliases:

```bash
# Delete all test indices
curl -X DELETE "localhost:9200/logs-*"

# Verify deletion
curl -X GET "localhost:9200/_cat/indices/logs-*?v"
```

## Advanced Configuration Examples

### Multi-field alias template

```ruby
output {
  elasticsearch {
    ilm_rollover_alias => "%{environment}-%{service}-%{region}"
    # Creates aliases like: prod-api-us-east, staging-web-eu-west, etc.
  }
}
```

### With conditional logic

```ruby
output {
  if [container_name] {
    elasticsearch {
      ilm_rollover_alias => "logs-%{container_name}"
    }
  } else {
    elasticsearch {
      ilm_rollover_alias => "logs-default"
    }
  }
}
```

### With custom ILM policy

```ruby
output {
  elasticsearch {
    ilm_rollover_alias => "logs-%{container_name}"
    ilm_policy => "7-days-retention"
    ilm_pattern => "{now/d}-000001"
  }
}
```

## Performance Notes

- **First write to new alias**: ~100-200ms (includes alias creation)
- **Subsequent writes**: Normal performance (cached)
- **Recommended**: Limit alias cardinality (< 100 unique values)
- **Monitor**: Elasticsearch cluster metadata size

## Building the Modified Plugin

If you haven't already installed the modified plugin:

```bash
# In the plugin directory
cd /path/to/logstash-output-elasticsearch

# Build gem
gem build logstash-output-elasticsearch.gemspec

# Install in Logstash
/path/to/logstash/bin/logstash-plugin install logstash-output-elasticsearch-*.gem

# Verify installation
/path/to/logstash/bin/logstash-plugin list | grep elasticsearch
```
