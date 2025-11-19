# Dynamic ILM Troubleshooting Guide

## Common Issues and Solutions

### 🔴 Issue 1: Resources Not Being Created

**Symptoms:**
- Events accepted but no indices created in Elasticsearch
- No log messages about "Initializing ILM resources"
- Errors about index not found

**Diagnosis:**

1. **Check field exists:**
```bash
# Verify your events have the field
# In Logstash, add this filter temporarily:
filter {
  if ![container_name] {
    mutate { add_tag => ["missing_container_name"] }
  }
  ruby {
    code => "logger.warn('Container name:', event.get('container_name'))"
  }
}
```

2. **Check Logstash logs:**
```bash
# Look for dynamic ILM initialization
grep "Using dynamic ILM rollover alias" /var/log/logstash/logstash-plain.log

# Look for container initialization
grep "Initializing ILM resources" /var/log/logstash/logstash-plain.log
```

**Solutions:**

**A. Field doesn't exist:**
```ruby
# Add default value
filter {
  if ![container_name] {
    mutate { add_field => { "container_name" => "unknown" } }
  }
}
```

**B. Field name is wrong:**
```ruby
# Verify field path
output {
  elasticsearch {
    # For nested fields, use full path
    ilm_rollover_alias => "%{[kubernetes][container][name]}"
  }
}
```

**C. ILM not enabled:**
```ruby
output {
  elasticsearch {
    ilm_enabled => true  # Must be explicitly set
    ilm_rollover_alias => "%{[container_name]}"
  }
}
```

---

### 🔴 Issue 2: Repeated Initialization (Performance Problem)

**Symptoms:**
- Logs show "Initializing ILM resources" repeatedly for same container
- High API call rate to Elasticsearch
- Slow indexing performance

**Diagnosis:**

```bash
# Count initialization attempts
grep "Initializing ILM resources" /var/log/logstash/logstash-plain.log | \
  awk -F'container:' '{print $2}' | \
  sort | uniq -c | sort -rn

# Should see low counts (1-2 per container)
# High counts indicate cache problem
```

**Possible Causes:**

**A. Initialization failing:**
```bash
# Check for errors immediately after initialization
grep -A5 "Initializing ILM resources" /var/log/logstash/logstash-plain.log | \
  grep -i error
```

**Solution:** Fix the underlying error (see error messages)

**B. Cache not persisting:**
```ruby
# Verify cache initialization in elasticsearch.rb
# Should call this in initialize or register:
initialize_dynamic_template_cache
```

**C. Multiple Logstash instances competing:**
```bash
# Check how many Logstash instances are running
ps aux | grep logstash | grep -v grep
```

**Solution:** This is normal - each instance maintains own cache. First event per instance initializes, then cached.

---

### 🔴 Issue 3: Daily Rollover Not Working

**Symptoms:**
- Indices still use previous day's date
- No new index created at midnight
- Logs don't show "Detected day change"

**Diagnosis:**

```bash
# Check current write indices
curl -X GET "localhost:9200/_cat/aliases/auto-*?v&h=alias,index,is_write_index"

# Look for rollover checks
grep "daily rollover check" /var/log/logstash/logstash-plain.log | tail -20
```

**Possible Causes:**

**A. No events after midnight:**
- Rollover only happens when first event arrives after date change
- If no events, no rollover

**Solution:** This is by design. Index will be created when first event arrives.

**B. Index name doesn't match expected pattern:**
```bash
# Verify index name format
curl -X GET "localhost:9200/_cat/indices/auto-*?v&h=index"

# Should be: auto-{container}-YYYY.MM.DD-NNNNNN
# Example: auto-nginx-2025.11.19-000001
```

**Solution:** If pattern is wrong, manually delete indices and let them recreate:
```bash
# Delete and recreate
curl -X DELETE "localhost:9200/auto-nginx-*"
# Clear cache in Logstash (send event with container_name)
```

**C. Timezone issue:**
```ruby
# Check what Logstash sees as "today"
# Add debug logging
def current_date_str
  today = Time.now.strftime("%Y.%m.%d")
  logger.info("Current date string: #{today}")
  today
end
```

**Solution:** Ensure Logstash server timezone is correct:
```bash
# Check timezone
timedatectl

# Set timezone if needed
sudo timedatectl set-timezone America/New_York
```

---

### 🔴 Issue 4: Index Deletion Not Auto-Recovering

**Symptoms:**
- Index deleted manually
- Next events fail with "index not found"
- Index NOT automatically recreated
- Events go to DLQ or fail

**Diagnosis:**

```bash
# Check error handler logs
grep "Index not found" /var/log/logstash/logstash-plain.log

# Should see:
# "Index not found error detected, clearing all caches for next retry"

# Check if handle_index_not_found_error is being called
grep "handle_index_not_found_error" /var/log/logstash/logstash-plain.log
```

**Possible Causes:**

**A. Error handler not called:**
- Check if `common.rb` has the error detection code
- Verify method `handle_index_not_found_error` exists in DynamicTemplateManager

**Solution:** Verify code in `lib/logstash/plugin_mixins/elasticsearch/common.rb`:
```ruby
if status == 404 && error && type && (type.include?('index_not_found'))
  if respond_to?(:handle_index_not_found_error)
    handle_index_not_found_error(action)
    actions_to_retry << action
    next
  end
end
```

**B. Cache not being cleared:**
```bash
# Check if cache removal is logged
grep "clearing all caches" /var/log/logstash/logstash-plain.log
```

**Solution:** Verify `handle_index_not_found_error` clears ALL caches:
```ruby
@dynamic_templates_created.remove(alias_name)
@resource_exists_cache.remove("policy:#{alias_name}-ilm-policy")
@resource_exists_cache.remove("template:logstash-#{alias_name}")
```

**C. Retry not happening:**
- Check retry queue size
- Verify events are being retried

**Solution:** Monitor retry metrics in Logstash stats:
```bash
curl -X GET "localhost:9600/_node/stats/pipelines"
```

---

### 🔴 Issue 5: Thread Deadlock or Timeout

**Symptoms:**
- Logs show "Timeout waiting for ILM initialization"
- Events stuck/blocked
- Pipeline throughput drops to zero

**Diagnosis:**

```bash
# Check for timeout messages
grep "Timeout waiting" /var/log/logstash/logstash-plain.log

# Check for lock messages
grep "Lock acquired\|holds lock" /var/log/logstash/logstash-plain.log
```

**Possible Causes:**

**A. Elasticsearch is slow/unresponsive:**
```bash
# Test Elasticsearch response time
time curl -X GET "localhost:9200/_cluster/health"

# Should be < 1 second
```

**Solution:** 
- Fix Elasticsearch performance issue
- Increase timeout in wait loop (change from 50 iterations to more)

**B. Initialization genuinely takes long:**
- Large custom template
- Slow network to Elasticsearch
- Elasticsearch under heavy load

**Solution:** Increase wait timeout:
```ruby
# In maybe_create_dynamic_template
100.times do  # Changed from 50
  sleep 0.2   # Changed from 0.1 (total: 20 seconds)
  current = @dynamic_templates_created.get(alias_name)
  if current == true
    return
  end
end
```

**C. Actual deadlock (rare):**
```bash
# Get Java thread dump
jstack <logstash_pid> > /tmp/logstash-threads.txt

# Look for BLOCKED threads
grep -A10 "BLOCKED" /tmp/logstash-threads.txt
```

**Solution:** Restart Logstash, check for code bugs

---

### 🔴 Issue 6: High Memory Usage

**Symptoms:**
- Logstash memory grows over time
- Cache sizes seem large
- OOM errors

**Diagnosis:**

```bash
# Check Logstash heap usage
curl -X GET "localhost:9600/_node/stats/jvm?pretty" | grep heap

# Estimate cache size (rough calculation)
# Each container uses ~350 bytes
# 1000 containers = ~350 KB (should be negligible)
```

**Possible Causes:**

**A. Too many unique containers:**
```bash
# Count unique containers
grep "Initializing ILM resources" /var/log/logstash/logstash-plain.log | \
  awk -F'container:' '{print $2}' | \
  sort -u | wc -l
```

**Solution:** 
- If > 10,000 containers, consider grouping
- Use container prefixes (e.g., `%{[app_name]}` instead of full container ID)

**Example:**
```ruby
filter {
  # Group containers by app instead of individual container
  grok {
    match => { "container_name" => "^(?<app_name>[^-]+)" }
  }
}

output {
  elasticsearch {
    ilm_rollover_alias => "%{[app_name]}"
  }
}
```

**B. Memory leak elsewhere:**
- Not related to dynamic ILM caching
- Check other plugins

**Solution:** Profile Logstash memory:
```bash
# Enable GC logging
LS_JAVA_OPTS="-XX:+PrintGCDetails" bin/logstash
```

---

### 🔴 Issue 7: Template/Policy Not Applied Correctly

**Symptoms:**
- Index created but mappings are wrong
- ILM policy not attached
- Rollover doesn't happen

**Diagnosis:**

```bash
# Check index settings
curl -X GET "localhost:9200/auto-nginx-*/_settings?pretty" | grep lifecycle

# Check index template
curl -X GET "localhost:9200/_index_template/logstash-auto-nginx?pretty"

# Check ILM policy
curl -X GET "localhost:9200/_ilm/policy/auto-nginx-ilm-policy?pretty"
```

**Possible Causes:**

**A. Template priority too low:**
- Another template with higher priority is matching

**Solution:** Check all templates:
```bash
# List all templates matching pattern
curl -X GET "localhost:9200/_index_template?pretty" | grep -A5 "auto-"

# Increase priority if needed (edit dynamic_template_manager.rb)
priority = 200  # Default is 100
```

**B. Policy creation failed:**
```bash
# Check policy creation logs
grep "Created ILM policy" /var/log/logstash/logstash-plain.log
```

**Solution:** Check Elasticsearch permissions:
```bash
# Test policy creation manually
curl -X PUT "localhost:9200/_ilm/policy/test-policy" -H 'Content-Type: application/json' -d'
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": { "max_age": "1d" }
        }
      }
    }
  }
}'
```

**C. Template not matching indices:**
```bash
# Check template pattern
curl -X GET "localhost:9200/_index_template/logstash-auto-nginx?pretty" | grep index_patterns

# Should be: ["auto-nginx-*"]
```

**Solution:** Verify pattern matches actual index name

---

### 🔴 Issue 8: Elasticsearch Permissions Error

**Symptoms:**
- Errors about "security_exception" or "unauthorized"
- Resources not created
- 403 errors in logs

**Diagnosis:**

```bash
# Check Elasticsearch logs for security errors
grep "security_exception\|unauthorized" /var/log/elasticsearch/*.log

# Test permissions
curl -u elastic:password -X GET "localhost:9200/_security/user/_privileges?pretty"
```

**Required Permissions:**

```json
{
  "cluster": [
    "manage_ilm",
    "manage_index_templates"
  ],
  "indices": [
    {
      "names": ["auto-*"],
      "privileges": [
        "create_index",
        "write",
        "manage",
        "manage_ilm"
      ]
    }
  ]
}
```

**Solution:** Create role with required permissions:
```bash
curl -X POST "localhost:9200/_security/role/logstash_dynamic_ilm" -H 'Content-Type: application/json' -d'
{
  "cluster": ["manage_ilm", "manage_index_templates", "monitor"],
  "indices": [
    {
      "names": ["auto-*"],
      "privileges": ["create_index", "write", "manage", "manage_ilm"]
    }
  ]
}
'

# Assign role to user
curl -X POST "localhost:9200/_security/user/logstash_writer" -H 'Content-Type: application/json' -d'
{
  "password": "secure_password",
  "roles": ["logstash_dynamic_ilm"]
}
'
```

---

## Debugging Commands

### View All Dynamic Resources

```bash
# List all auto-* aliases
curl -X GET "localhost:9200/_cat/aliases/auto-*?v"

# List all auto-* indices
curl -X GET "localhost:9200/_cat/indices/auto-*?v&s=index"

# List all ILM policies for auto-*
curl -X GET "localhost:9200/_ilm/policy/auto-*?pretty"

# List all templates for auto-*
curl -X GET "localhost:9200/_index_template/logstash-auto-*?pretty"
```

### Check Specific Container

```bash
CONTAINER="nginx"

# Check alias
curl -X GET "localhost:9200/_alias/auto-${CONTAINER}"

# Check write index
curl -X GET "localhost:9200/_cat/aliases/auto-${CONTAINER}?v&h=alias,index,is_write_index"

# Check ILM policy
curl -X GET "localhost:9200/_ilm/policy/auto-${CONTAINER}-ilm-policy?pretty"

# Check template
curl -X GET "localhost:9200/_index_template/logstash-auto-${CONTAINER}?pretty"

# Check index settings
curl -X GET "localhost:9200/auto-${CONTAINER}-*/_settings?pretty" | grep -A5 lifecycle

# Check index count
curl -X GET "localhost:9200/_cat/indices/auto-${CONTAINER}-*?v&h=index,docs.count,store.size"
```

### Force Resource Recreation

```bash
CONTAINER="nginx"

# Delete all resources (will be auto-recreated on next event)
curl -X DELETE "localhost:9200/auto-${CONTAINER}-*"
curl -X DELETE "localhost:9200/_index_template/logstash-auto-${CONTAINER}"
curl -X DELETE "localhost:9200/_ilm/policy/auto-${CONTAINER}-ilm-policy"

# Send a test event to trigger recreation
# (or wait for next real event)
```

### Monitor Performance

```bash
# Watch Logstash metrics
watch -n 2 'curl -s localhost:9600/_node/stats/pipelines | jq ".pipelines.main.events"'

# Count events per container (from indices)
curl -X GET "localhost:9200/auto-*/_search?size=0" -H 'Content-Type: application/json' -d'
{
  "aggs": {
    "containers": {
      "terms": {
        "field": "container_name.keyword",
        "size": 100
      }
    }
  }
}'

# Check ILM explain (why index hasn't rolled over)
curl -X GET "localhost:9200/auto-nginx-*/_ilm/explain?pretty"
```

### Enable Debug Logging

```ruby
# In logstash.yml or via --log.level flag
log.level: debug

# Or just for Elasticsearch output
logger.debug("Dynamic ILM", :container => alias_name, :action => "initialization")
```

```bash
# Tail logs with filter
tail -f /var/log/logstash/logstash-plain.log | grep -E "Initializing|Template|Policy|Cache|Rollover"
```

---

## Performance Optimization Tips

### 1. Reduce Container Cardinality

**Before:**
```ruby
# Using full container ID (millions of unique values)
ilm_rollover_alias => "%{[container_id]}"
```

**After:**
```ruby
# Use container name (hundreds of unique values)
ilm_rollover_alias => "%{[container_name]}"

# Or group by app/service
filter {
  mutate {
    add_field => { "service" => "%{[app_name]}-%{[environment]}" }
  }
}

output {
  elasticsearch {
    ilm_rollover_alias => "%{[service]}"
  }
}
```

### 2. Batch Size Tuning

```ruby
output {
  elasticsearch {
    # Larger batches = better deduplication
    flush_size => 1000  # Default: 500
  }
}
```

### 3. Template Caching

Use the built-in minimal template instead of loading files:
```ruby
output {
  elasticsearch {
    # Don't specify template = faster initialization
    # template => "/path/to/file.json"  # Remove this
  }
}
```

### 4. Multiple Workers

```ruby
# In pipeline config
pipeline.workers: 8  # Increase for better parallelism
```

Each worker maintains own cache, so first event per worker per container initializes.

---

## Health Check Checklist

Use this checklist to verify system health:

- [ ] **Configuration valid:**
  - `ilm_enabled => true`
  - `ilm_rollover_alias` contains `%{...}`
  - Field referenced exists in events

- [ ] **Resources created:**
  - Aliases exist: `curl localhost:9200/_cat/aliases/auto-*`
  - Policies exist: `curl localhost:9200/_ilm/policy/auto-*`
  - Templates exist: `curl localhost:9200/_index_template/logstash-auto-*`
  - Indices exist: `curl localhost:9200/_cat/indices/auto-*`

- [ ] **Caching working:**
  - "Initializing ILM resources" appears rarely in logs
  - "Template exists (cached)" appears frequently
  - No repeated initialization for same container

- [ ] **Daily rollover working:**
  - New indices created each day
  - Index names have current date
  - Write alias moves to new index

- [ ] **Error recovery working:**
  - Delete index manually
  - Send event
  - Index recreated automatically

- [ ] **Performance acceptable:**
  - Events/sec > 10,000 (steady state)
  - Latency < 10ms (cached)
  - API calls minimal (check Elasticsearch slow log)

- [ ] **Logs clean:**
  - No ERROR messages related to ILM
  - No repeated WARN messages
  - Cache hit rate > 99%

---

## Getting Help

If you're still stuck:

1. **Collect diagnostics:**
```bash
# Save all logs
tar -czf logstash-diag.tar.gz \
  /var/log/logstash/logstash-plain.log \
  /etc/logstash/conf.d/*.conf \
  /etc/logstash/logstash.yml

# Save Elasticsearch state
curl -X GET "localhost:9200/_cat/aliases/auto-*?v" > aliases.txt
curl -X GET "localhost:9200/_cat/indices/auto-*?v" > indices.txt
curl -X GET "localhost:9200/_ilm/policy/auto-*?pretty" > policies.json
curl -X GET "localhost:9200/_index_template/logstash-auto-*?pretty" > templates.json
```

2. **Check documentation:**
   - `DYNAMIC_ILM_OPTIMIZATION.md` - Full implementation guide
   - `DYNAMIC_ILM_QUICK_REFERENCE.md` - Quick reference
   - `IMPLEMENTATION_CHECKLIST.md` - Verification checklist

3. **Test minimal case:**
```ruby
# Simplest possible config
input {
  generator {
    count => 10
    message => '{"container_name":"test"}'
    codec => json
  }
}

output {
  elasticsearch {
    hosts => ["localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
  }
}
```

Run and verify resources created for "auto-test"

4. **Enable verbose logging:**
```bash
bin/logstash --log.level=debug -f config/test.conf
```

5. **Check GitHub issues:**
   - Search for similar issues in logstash-output-elasticsearch repo
   - Post detailed diagnostics if needed

---

## Emergency Rollback

If you need to revert to static configuration:

```ruby
# Disable dynamic ILM
output {
  elasticsearch {
    ilm_enabled => true
    ilm_rollover_alias => "static-logs"  # No %{...}
    # Resources created once at startup
  }
}
```

Or use traditional index pattern:
```ruby
output {
  elasticsearch {
    ilm_enabled => false
    index => "logstash-%{+YYYY.MM.dd}"  # Daily indices without ILM
  }
}
```

**Note:** Existing dynamic resources will remain in Elasticsearch and continue working.
