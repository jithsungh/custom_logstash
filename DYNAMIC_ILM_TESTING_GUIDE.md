# Dynamic ILM Testing Guide

This guide provides comprehensive testing procedures for the dynamic ILM feature in the Logstash Elasticsearch output plugin.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Basic Functionality Tests](#basic-functionality-tests)
3. [Thread Safety Tests](#thread-safety-tests)
4. [Validation Tests](#validation-tests)
5. [Anomaly Detection Tests](#anomaly-detection-tests)
6. [Recovery Tests](#recovery-tests)
7. [Performance Tests](#performance-tests)

---

## Prerequisites

### Elasticsearch 8.x Setup

```bash
# Start Elasticsearch 8.x (Docker)
docker run -d \
  --name elasticsearch \
  -p 9200:9200 \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=false" \
  docker.elastic.co/elasticsearch/elasticsearch:8.11.0

# Verify Elasticsearch is running
curl http://localhost:9200
```

### Logstash Setup

```bash
# Install the plugin (from gem or local build)
bin/logstash-plugin install logstash-output-elasticsearch

# Or install from local gem
bin/logstash-plugin install /path/to/logstash-output-elasticsearch-*.gem
```

---

## Basic Functionality Tests

### Test 1: Single Container Dynamic Index Creation

**Objective:** Verify that resources are created for a single container.

**Input Events:**
```json
{"message": "Test log 1", "container_name": "nginx", "@timestamp": "2025-11-20T10:00:00Z"}
{"message": "Test log 2", "container_name": "nginx", "@timestamp": "2025-11-20T10:01:00Z"}
{"message": "Test log 3", "container_name": "nginx", "@timestamp": "2025-11-20T10:02:00Z"}
```

**Configuration:**
```ruby
output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    ilm_enabled => true
    index => "auto-%{[container_name]}-%{+YYYY.MM.dd}"
    ilm_rollover_alias => "%{[container_name]}"
    ilm_rollover_max_age => "1d"
    ilm_delete_min_age => "7d"
  }
}
```

**Expected Results:**
```bash
# Check ILM policy created
curl http://localhost:9200/_ilm/policy/auto-nginx-ilm-policy | jq

# Check index template created
curl http://localhost:9200/_index_template/logstash-auto-nginx | jq

# Check index and alias created
curl http://localhost:9200/_cat/aliases?v | grep auto-nginx
curl http://localhost:9200/_cat/indices?v | grep auto-nginx

# Verify write index
curl http://localhost:9200/_alias/auto-nginx | jq
# Should show: "auto-nginx-2025.11.20-000001" with "is_write_index": true
```

**Validation:**
- [ ] ILM policy exists with correct settings
- [ ] Index template exists with correct pattern
- [ ] Write index created with today's date
- [ ] Alias points to write index
- [ ] All 3 events indexed successfully

---

### Test 2: Multiple Containers

**Objective:** Verify that separate resources are created for each container.

**Input Events:**
```json
{"message": "Nginx log", "container_name": "nginx"}
{"message": "Apache log", "container_name": "apache"}
{"message": "MySQL log", "container_name": "mysql"}
{"message": "Redis log", "container_name": "redis"}
```

**Expected Results:**
```bash
# Should have 4 ILM policies
curl http://localhost:9200/_ilm/policy | jq 'keys' | grep auto-

# Should have 4 templates
curl http://localhost:9200/_index_template | jq '.index_templates[].name' | grep logstash-auto-

# Should have 4 indices
curl http://localhost:9200/_cat/indices?v | grep auto-
```

**Validation:**
- [ ] 4 separate ILM policies created
- [ ] 4 separate templates created
- [ ] 4 separate indices created
- [ ] Each alias points to correct write index

---

### Test 3: Missing container_name Field

**Objective:** Verify fallback behavior when container_name is missing.

**Input Events:**
```json
{"message": "Log without container", "@timestamp": "2025-11-20T10:00:00Z"}
```

**Expected Results:**
- Event should be indexed to default/fallback index
- Warning logged about missing container_name field
- No error, event not lost

**Validation:**
- [ ] Event indexed successfully
- [ ] Warning logged in Logstash logs
- [ ] Fallback alias used (check configuration)

---

## Thread Safety Tests

### Test 4: Concurrent Events for Same Container

**Objective:** Verify thread safety when multiple workers process events for the same container simultaneously.

**Configuration:**
```ruby
output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    workers => 8  # Multiple workers
    ilm_enabled => true
    index => "auto-%{[container_name]}-%{+YYYY.MM.dd}"
    ilm_rollover_alias => "%{[container_name]}"
  }
}
```

**Test Script:**
```bash
# Send 1000 events rapidly for the same container
for i in {1..1000}; do
  echo "{\"message\": \"Test $i\", \"container_name\": \"stress-test\"}" >> test_input.log
done

# Run Logstash
bin/logstash -f test-config.conf
```

**Expected Results:**
```bash
# Verify only ONE policy created (no duplicates)
curl http://localhost:9200/_ilm/policy/auto-stress-test-ilm-policy | jq

# Verify only ONE template created
curl http://localhost:9200/_index_template/logstash-auto-stress-test | jq

# Verify only ONE write index exists
curl http://localhost:9200/_alias/auto-stress-test | jq

# Verify all 1000 events indexed
curl http://localhost:9200/auto-stress-test-*/_count | jq
# Should show: "count": 1000
```

**Validation:**
- [ ] No duplicate policies created
- [ ] No duplicate templates created
- [ ] No race condition errors in logs
- [ ] All events indexed exactly once

---

### Test 5: Multiple Containers Concurrent

**Objective:** Verify concurrent creation of resources for multiple containers.

**Test Script:**
```bash
# Send events for 10 different containers simultaneously
for container in nginx apache mysql redis mongodb postgres kafka rabbitmq elasticsearch logstash; do
  for i in {1..100}; do
    echo "{\"message\": \"Test $i\", \"container_name\": \"$container\"}" >> test_input_multi.log
  done
done

# Shuffle to randomize order
shuf test_input_multi.log > test_input_shuffled.log

# Run with multiple workers
bin/logstash -f test-config.conf
```

**Expected Results:**
- 10 separate policies created
- 10 separate templates created
- 10 separate write indices created
- 1000 total events indexed (100 per container)

**Validation:**
- [ ] All resources created without conflicts
- [ ] No errors in Logstash logs
- [ ] Event counts correct per container

---

## Validation Tests

### Test 6: Invalid Container Names

**Objective:** Verify validation and sanitization of invalid container names.

**Input Events:**
```json
{"message": "Test", "container_name": "UPPERCASE"}
{"message": "Test", "container_name": "has spaces"}
{"message": "Test", "container_name": "has/slash"}
{"message": "Test", "container_name": "has\\backslash"}
{"message": "Test", "container_name": "has*asterisk"}
{"message": "Test", "container_name": "_starts_underscore"}
{"message": "Test", "container_name": "-starts-dash"}
```

**Expected Results:**
- Invalid characters sanitized (replaced with `-`)
- Uppercase converted to lowercase
- Invalid prefixes handled
- Events indexed successfully

**Check Logstash logs for warnings:**
```
Invalid characters in resolved alias name - using sanitized version
```

**Validation:**
- [ ] All events indexed (no failures)
- [ ] Index names follow Elasticsearch rules
- [ ] Warnings logged for sanitized names

---

### Test 7: ILM Policy Validation

**Objective:** Verify ILM policy structure validation.

**Configuration with Invalid Settings:**
```ruby
output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_rollover_max_age => "invalid"  # Invalid format
    ilm_rollover_max_size => "999"     # Invalid format
  }
}
```

**Expected Results:**
- Warnings logged about invalid formats
- Plugin attempts to create policy anyway
- Elasticsearch rejects invalid policy (400 error)
- Error logged with details

**Validation:**
- [ ] Warnings logged for invalid values
- [ ] Error captured and logged
- [ ] Plugin doesn't crash

---

## Anomaly Detection Tests

### Test 8: Initialization Loop Detection

**Objective:** Verify that repeated initialization failures are detected.

**Simulation:**
```bash
# Manually delete resources repeatedly while Logstash tries to create them
# This simulates external interference

# In one terminal: Run Logstash
bin/logstash -f test-config.conf

# In another terminal: Delete resources repeatedly
for i in {1..15}; do
  curl -X DELETE http://localhost:9200/auto-test-*
  curl -X DELETE http://localhost:9200/_index_template/logstash-auto-test
  curl -X DELETE http://localhost:9200/_ilm/policy/auto-test-ilm-policy
  sleep 2
done
```

**Expected Results:**
- After 5-10 attempts, anomaly detection triggers
- Cache cleared and full retry attempted
- Warning/error logged about anomaly
- Eventually succeeds when deletions stop

**Check logs for:**
```
ANOMALY DETECTED: Container initialization failed repeatedly
```

**Validation:**
- [ ] Anomaly detected after threshold
- [ ] Cache cleared automatically
- [ ] Recovery attempted
- [ ] No infinite loop

---

### Test 9: Resource Verification

**Objective:** Verify that created resources are validated.

**Simulation:**
```bash
# Manually create a policy with wrong name
curl -X PUT http://localhost:9200/_ilm/policy/wrong-policy-name \
  -H 'Content-Type: application/json' \
  -d '{"policy": {"phases": {}}}'

# Send event expecting different policy
echo '{"message": "Test", "container_name": "verification-test"}' | \
  bin/logstash -f test-config.conf
```

**Expected Results:**
- Plugin creates correct policy (auto-verification-test-ilm-policy)
- Verification step ensures policy exists
- If verification fails, error logged

**Validation:**
- [ ] Verification performed after creation
- [ ] Errors logged if verification fails
- [ ] Correct resources created

---

## Recovery Tests

### Test 10: Logstash Restart Recovery

**Objective:** Verify cache recovery after Logstash restart.

**Steps:**
1. Start Logstash and send events for multiple containers
2. Stop Logstash
3. Verify resources still exist in Elasticsearch
4. Start Logstash again
5. Send more events for same containers

**Expected Results:**
- On restart, plugin checks Elasticsearch
- Existing resources detected and reused
- No duplicate resources created
- Events continue indexing normally

**Validation:**
- [ ] No duplicate resources after restart
- [ ] Events indexed successfully
- [ ] Logs show "already exists" messages

---

### Test 11: External Resource Deletion Recovery

**Objective:** Verify recovery when resources are deleted externally.

**Steps:**
1. Start Logstash and send events (creates resources)
2. Externally delete index (keep policy/template)
3. Send more events

**Expected Results:**
- Plugin detects missing index
- Cache cleared for that container
- Resources recreated on next event
- Events indexed successfully

**Commands:**
```bash
# Delete index but keep policy/template
curl -X DELETE http://localhost:9200/auto-nginx-*

# Send more events
echo '{"message": "After deletion", "container_name": "nginx"}' | \
  bin/logstash -f test-config.conf

# Verify new index created
curl http://localhost:9200/_cat/indices?v | grep auto-nginx
```

**Validation:**
- [ ] Index recreated automatically
- [ ] New write index has correct date
- [ ] Events indexed successfully
- [ ] No errors (automatic recovery)

---

### Test 12: Daily Rollover

**Objective:** Verify automatic rollover to new date-based index.

**Simulation:**
```bash
# Create index with yesterday's date
curl -X PUT "http://localhost:9200/auto-daily-2025.11.19-000001" \
  -H 'Content-Type: application/json' \
  -d '{
    "aliases": {
      "auto-daily": {"is_write_index": true}
    }
  }'

# Send event today
echo '{"message": "Today", "container_name": "daily"}' | \
  bin/logstash -f test-config.conf

# Check if rollover occurred
curl http://localhost:9200/_alias/auto-daily | jq
```

**Expected Results:**
- Plugin detects old date
- Triggers rollover to today's date
- New index: auto-daily-2025.11.20-000001
- Old index kept but no longer write index

**Validation:**
- [ ] New index created with today's date
- [ ] Alias moved to new index
- [ ] Old index still exists (no data loss)
- [ ] Event indexed to new index

---

## Performance Tests

### Test 13: Throughput Test

**Objective:** Measure event processing throughput.

**Test Script:**
```bash
# Generate 100,000 events for 10 containers
for container in {1..10}; do
  for i in {1..10000}; do
    echo "{\"message\": \"Event $i\", \"container_name\": \"perf-test-$container\"}" \
      >> perf_test.log
  done
done

# Measure time
time bin/logstash -f test-config.conf < perf_test.log
```

**Measure:**
- Events per second
- CPU usage
- Memory usage
- API calls to Elasticsearch

**Expected:**
- First event per container: ~100-200ms (creates resources)
- Subsequent events: <10ms (cached)
- Throughput: >1000 events/second

**Validation:**
- [ ] All events indexed
- [ ] No memory leaks
- [ ] Consistent performance

---

### Test 14: Cache Efficiency

**Objective:** Verify cache prevents redundant API calls.

**Steps:**
1. Enable Elasticsearch slow log
2. Send 10,000 events for same container
3. Count API calls

**Expected:**
- First event: 3-5 API calls (check + create policy/template/index)
- Remaining 9,999 events: 0 API calls (cached)
- Only bulk indexing requests

**Validation:**
- [ ] Cache hit rate > 99.9%
- [ ] Minimal API overhead
- [ ] Fast event processing

---

## Automated Test Suite

Create a comprehensive test script:

```bash
#!/bin/bash
# run_all_tests.sh

set -e

echo "=== Dynamic ILM Test Suite ==="

# Start Elasticsearch
docker-compose up -d elasticsearch
sleep 30

# Run each test
./test_basic_single_container.sh
./test_multiple_containers.sh
./test_concurrent_events.sh
./test_invalid_names.sh
./test_restart_recovery.sh
./test_daily_rollover.sh
./test_performance.sh

# Cleanup
docker-compose down -v

echo "=== All Tests Passed ==="
```

---

## Troubleshooting Test Failures

### Check Logstash Logs
```bash
tail -f /var/log/logstash/logstash-plain.log | grep -i "dynamic\|ilm\|template"
```

### Check Elasticsearch Logs
```bash
docker logs elasticsearch | grep -i "ilm\|template\|index"
```

### Verify Resources
```bash
# List all policies
curl http://localhost:9200/_ilm/policy?pretty

# List all templates
curl http://localhost:9200/_index_template?pretty

# List all indices
curl http://localhost:9200/_cat/indices?v

# List all aliases
curl http://localhost:9200/_cat/aliases?v
```

### Clean Up Test Resources
```bash
# Delete all auto-* indices
curl -X DELETE "http://localhost:9200/auto-*"

# Delete all logstash-auto-* templates
curl -X DELETE "http://localhost:9200/_index_template/logstash-auto-*"

# Delete all auto-*-ilm-policy policies
for policy in $(curl -s http://localhost:9200/_ilm/policy | jq -r 'keys[]' | grep auto-); do
  curl -X DELETE "http://localhost:9200/_ilm/policy/$policy"
done
```

---

## Success Criteria

All tests should pass with:
- ✅ 0 errors in Logstash logs
- ✅ All events indexed successfully
- ✅ Correct resources created
- ✅ No duplicate resources
- ✅ No race conditions
- ✅ Automatic recovery from failures
- ✅ Performance within acceptable limits

---

## Next Steps

After successful testing:
1. Performance tuning for production workload
2. Security hardening (SSL, authentication)
3. Monitoring and alerting setup
4. Documentation for operations team
5. Production deployment plan
