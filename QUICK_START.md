# Quick Start: Dynamic ILM Rollover Alias

## What Was Implemented

✅ Dynamic event-based substitution for `ilm_rollover_alias` (like `%{container_name}`)  
✅ Thread-safe alias creation  
✅ Automatic caching to avoid repeated API calls  
✅ Comprehensive documentation and examples

---

## Files Modified

### Core Changes

- **`lib/logstash/outputs/elasticsearch.rb`** (4 changes)
  - Added template storage and mutex initialization
  - Modified `resolve_index!` to check for dynamic aliases
  - Added `resolve_dynamic_rollover_alias` method
  - Added `ensure_rollover_alias_exists` method

### Documentation

- **`DYNAMIC_ILM_ROLLOVER_ALIAS.md`** - Full feature documentation
- **`IMPLEMENTATION_SUMMARY.md`** - Technical implementation details
- **`examples/dynamic_ilm_config.conf`** - Sample Logstash config
- **`examples/test_events.json`** - Test data
- **`examples/README.md`** - Testing guide

---

## Quick Test

### 1. Build and Install

```bash
cd /path/to/logstash-output-elasticsearch

# Build the gem
gem build logstash-output-elasticsearch.gemspec

# Install in Logstash
/path/to/logstash/bin/logstash-plugin install logstash-output-elasticsearch-*.gem
```

### 2. Create Test Config

Save as `test-dynamic-ilm.conf`:

```ruby
input {
  stdin { codec => json }
}

output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{container_name}"
  }
  stdout { codec => rubydebug }
}
```

### 3. Test

```bash
# Start Logstash
/path/to/logstash/bin/logstash -f test-dynamic-ilm.conf

# Paste test events:
{"message": "test 1", "container_name": "nginx"}
{"message": "test 2", "container_name": "app"}
{"message": "test 3", "container_name": "postgres"}
```

### 4. Verify in Elasticsearch

```bash
# Check aliases created
curl "localhost:9200/_cat/aliases/logs-*?v"

# Should show:
# logs-nginx      logs-nginx-2025.11.12-000001      ...
# logs-app        logs-app-2025.11.12-000001        ...
# logs-postgres   logs-postgres-2025.11.12-000001   ...
```

---

## Configuration Example

```ruby
output {
  elasticsearch {
    hosts => ["http://localhost:9200"]

    # Enable ILM
    ilm_enabled => true

    # 🎯 NEW: Dynamic alias per container
    ilm_rollover_alias => "logs-%{container_name}"

    # Optional: custom pattern
    ilm_pattern => "{now/d}-000001"

    # Optional: custom policy
    ilm_policy => "7-days-retention"
  }
}
```

---

## How It Works

```
Event: {"container_name": "nginx"}
           ↓
Logstash applies sprintf: "logs-%{container_name}"
           ↓
Result: "logs-nginx"
           ↓
Check if alias exists in cache? NO
           ↓
Check if alias exists in ES? NO
           ↓
Create alias: logs-nginx → logs-nginx-2025.11.12-000001
           ↓
Add to cache
           ↓
Write event to logs-nginx
```

**Next event with same container_name:**

- Cache hit → immediate write
- No ES API calls
- Fast path

---

## Use Cases

### Multi-Container Logging

```ruby
ilm_rollover_alias => "logs-%{container_name}"
# Creates: logs-nginx, logs-app, logs-db, etc.
```

### Multi-Tenant Application

```ruby
ilm_rollover_alias => "%{tenant_id}-logs"
# Creates: customer1-logs, customer2-logs, etc.
```

### Environment Separation

```ruby
ilm_rollover_alias => "%{environment}-%{service}"
# Creates: prod-api, staging-web, dev-worker, etc.
```

---

## Important Notes

### ⚠️ Warnings

1. **Not officially supported** - This is a custom modification
2. **Maintenance required** - May break on Logstash upgrades
3. **Test thoroughly** - Don't use in production without extensive testing
4. **Monitor cluster metadata** - Many aliases = more cluster overhead

### ✅ Best Practices

1. **Limit cardinality** - Keep unique aliases < 100
2. **Validate fields** - Ensure fields exist before output
3. **Set defaults** - Use filters to add default values
4. **Monitor performance** - Track alias creation and cache hits
5. **Have fallback** - Consider data streams as alternative

---

## Troubleshooting

### Alias not created

```bash
# Check Logstash logs
tail -f /path/to/logstash/logs/logstash-plain.log

# Verify ES is reachable
curl localhost:9200

# Check ILM enabled
curl localhost:9200/_ilm/status
```

### Field not substituted

```bash
# Verify event has field
{"container_name": "nginx"}  # ✅ Good
{"message": "test"}          # ❌ Missing container_name

# Add filter to set default
filter {
  if ![container_name] {
    mutate { add_field => {"container_name" => "default"} }
  }
}
```

### Performance issues

```bash
# Check number of unique aliases
curl "localhost:9200/_cat/aliases/logs-*?v" | wc -l

# If > 100, consider:
# - Using data streams instead
# - Reducing field cardinality
# - Static aliases
```

---

## Next Steps

1. ✅ **Implementation complete** - Code is ready
2. 🧪 **Test locally** - Use examples provided
3. 📊 **Benchmark** - Compare performance with static aliases
4. 🔍 **Review logs** - Watch for errors or warnings
5. 🚀 **Gradual rollout** - Test with small subset first

---

## Rollback Plan

If issues occur:

```bash
# Uninstall modified plugin
/path/to/logstash/bin/logstash-plugin uninstall logstash-output-elasticsearch

# Install official version
/path/to/logstash/bin/logstash-plugin install logstash-output-elasticsearch

# Revert config to static alias
ilm_rollover_alias => "logs-static"
```

---

## Getting Help

1. Check `DYNAMIC_ILM_ROLLOVER_ALIAS.md` for detailed docs
2. Check `IMPLEMENTATION_SUMMARY.md` for technical details
3. Check `examples/README.md` for testing guide
4. Review Logstash and Elasticsearch logs
5. Test with simplified config to isolate issues

---

## Summary

You now have:

- ✅ Dynamic `ilm_rollover_alias` support
- ✅ Event-based sprintf substitution
- ✅ Thread-safe alias creation
- ✅ Automatic caching
- ✅ Complete documentation
- ✅ Working examples
- ✅ Testing guide

**Ready to test!** 🚀
