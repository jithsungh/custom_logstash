# Dynamic ILM Testing Scenarios

## 🧪 Complete Testing Checklist

This document provides step-by-step testing procedures to verify all functionality.

---

## Test Setup

### Prerequisites:
```bash
# 1. Elasticsearch 8.x running
curl -X GET "http://eck-es-http:9200"

# 2. Logstash with your configuration
# 3. Sample events with container_name field
```

### Sample Event:
```json
{
  "container_name": "nginx",
  "message": "Test log message",
  "@timestamp": "2025-11-20T12:00:00.000Z",
  "level": "info"
}
```

---

## Test 1: First Event for New Container

### Objective:
Verify that resources are created automatically for a new container.

### Steps:
```bash
# 1. Send first event
echo '{"container_name":"nginx","message":"First event","@timestamp":"2025-11-20T12:00:00.000Z"}' | \
  nc localhost 5000

# 2. Check Logstash logs
tail -f /var/log/logstash/logstash-plain.log | grep -i "nginx"

# Expected logs:
# - "Lock acquired, proceeding with initialization"
# - "Created ILM policy"
# - "Template ready"
# - "Created rollover index"
# - "ILM resources ready, lock released"
```

### Verification:
```bash
# Check policy created
curl -X GET "http://eck-es-http:9200/_ilm/policy/auto-nginx-ilm-policy?pretty"

# Check template created
curl -X GET "http://eck-es-http:9200/_index_template/logstash-auto-nginx?pretty"

# Check index created
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-nginx*?v"

# Check alias created
curl -X GET "http://eck-es-http:9200/_alias/auto-nginx?pretty"

# Check event indexed
curl -X GET "http://eck-es-http:9200/auto-nginx/_search?pretty"
```

### Expected Results:
- ✅ Policy exists with correct hot/delete phases
- ✅ Template exists with pattern "auto-nginx-*"
- ✅ Index named "auto-nginx-2025.11.20-000001"
- ✅ Alias "auto-nginx" points to index with is_write_index=true
- ✅ Event is searchable in index

### Performance:
- First event: 500-1000ms
- API calls: 7-9

---

## Test 2: Subsequent Events (Cached)

### Objective:
Verify that subsequent events use cached resources (no API calls).

### Steps:
```bash
# Send 100 events rapidly
for i in {1..100}; do
  echo "{\"container_name\":\"nginx\",\"message\":\"Event $i\",\"@timestamp\":\"2025-11-20T12:00:0$i.000Z\"}" | nc localhost 5000
done

# Monitor Logstash logs
tail -f /var/log/logstash/logstash-plain.log
```

### Expected Logs:
- **NO** "Lock acquired" messages
- **NO** "Created ILM policy" messages
- **NO** "Template ready" messages
- Only bulk indexing logs

### Verification:
```bash
# Check event count
curl -X GET "http://eck-es-http:9200/auto-nginx/_count?pretty"

# Should show 101 documents (1 from Test 1 + 100 new)
```

### Expected Results:
- ✅ All 100 events indexed successfully
- ✅ No new resources created
- ✅ No errors in logs

### Performance:
- Per event: 1-5ms
- API calls: 0 (fully cached)

---

## Test 3: Multiple Containers Simultaneously

### Objective:
Verify thread-safe concurrent processing of multiple containers.

### Steps:
```bash
# Send events for 3 containers simultaneously
(
  echo '{"container_name":"nginx","message":"nginx event"}' | nc localhost 5000 &
  echo '{"container_name":"apache","message":"apache event"}' | nc localhost 5000 &
  echo '{"container_name":"mysql","message":"mysql event"}' | nc localhost 5000 &
  wait
)

# Check logs
tail -f /var/log/logstash/logstash-plain.log | grep -E "(nginx|apache|mysql)"
```

### Expected Logs:
```
[nginx] Lock acquired, proceeding with initialization
[apache] Lock acquired, proceeding with initialization  
[mysql] Lock acquired, proceeding with initialization
[nginx] ILM resources ready, lock released
[apache] ILM resources ready, lock released
[mysql] ILM resources ready, lock released
```

### Verification:
```bash
# Check all policies created
curl -X GET "http://eck-es-http:9200/_ilm/policy/_all?pretty" | grep -E "(nginx|apache|mysql)"

# Check all templates created
curl -X GET "http://eck-es-http:9200/_index_template?pretty" | grep -E "(nginx|apache|mysql)"

# Check all aliases created
curl -X GET "http://eck-es-http:9200/_cat/aliases?v" | grep -E "(nginx|apache|mysql)"
```

### Expected Results:
- ✅ 3 policies created (auto-nginx-ilm-policy, auto-apache-ilm-policy, auto-mysql-ilm-policy)
- ✅ 3 templates created
- ✅ 3 indices/aliases created
- ✅ No race conditions or errors
- ✅ All events indexed

---

## Test 4: Day Change Rollover

### Objective:
Verify automatic rollover when day changes.

### Setup:
```bash
# This test requires manual time manipulation OR waiting for midnight
# Option 1: Change system time (not recommended in production)
# Option 2: Wait for actual day change
# Option 3: Modify code temporarily to use shorter intervals
```

### Simulation (for testing):
```bash
# 1. Send events on Nov 20
echo '{"container_name":"nginx","message":"Nov 20 event","@timestamp":"2025-11-20T23:59:00.000Z"}' | nc localhost 5000

# 2. Check current write index
curl -X GET "http://eck-es-http:9200/_alias/auto-nginx?pretty"
# Should show: auto-nginx-2025.11.20-000001

# 3. Send event on Nov 21 (requires actual date change or simulation)
echo '{"container_name":"nginx","message":"Nov 21 event","@timestamp":"2025-11-21T00:01:00.000Z"}' | nc localhost 5000

# 4. Check logs
tail -f /var/log/logstash/logstash-plain.log | grep -i "rollover"
```

### Expected Logs:
```
Performing daily rollover check
Detected day change; forcing rollover to today's index
Successfully rolled over to new date-based index
```

### Verification:
```bash
# Check both indices exist
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-nginx*?v&s=index"

# Should show:
# auto-nginx-2025.11.20-000001
# auto-nginx-2025.11.21-000001

# Check alias points to new index
curl -X GET "http://eck-es-http:9200/_alias/auto-nginx?pretty"
# Should show auto-nginx-2025.11.21-000001 with is_write_index: true
```

### Expected Results:
- ✅ New index created with new date
- ✅ Alias moved to new index
- ✅ Old index still exists (searchable)
- ✅ New events go to new index
- ✅ Only checked once per day

---

## Test 5: Logstash Restart

### Objective:
Verify that resources are reused after restart (no duplicate creation).

### Steps:
```bash
# 1. Send events to create resources
echo '{"container_name":"nginx","message":"Before restart"}' | nc localhost 5000

# 2. Verify resources exist
curl -X GET "http://eck-es-http:9200/_ilm/policy/auto-nginx-ilm-policy?pretty"

# 3. Restart Logstash
systemctl restart logstash
# OR
kill -HUP $(cat /var/run/logstash.pid)

# 4. Wait for startup (check logs)
tail -f /var/log/logstash/logstash-plain.log | grep -i "started"

# 5. Send event after restart
echo '{"container_name":"nginx","message":"After restart"}' | nc localhost 5000

# 6. Check logs
tail -f /var/log/logstash/logstash-plain.log | grep -i "nginx"
```

### Expected Logs:
```
Policy already exists
Template exists (created concurrently) OR Template ready
Index/alias already exists with current date
All resources verified successfully
ILM resources ready, lock released
```

### Verification:
```bash
# Check policy still the same (not recreated)
curl -X GET "http://eck-es-http:9200/_ilm/policy/auto-nginx-ilm-policy?pretty&filter_path=policy.modified_date"

# Check only one template exists
curl -X GET "http://eck-es-http:9200/_index_template?pretty" | grep -c "logstash-auto-nginx"
# Should output: 1

# Check events in index
curl -X GET "http://eck-es-http:9200/auto-nginx/_search?pretty&size=2&sort=@timestamp:desc"
```

### Expected Results:
- ✅ Resources NOT recreated
- ✅ Existing resources detected and reused
- ✅ Events indexed successfully
- ✅ No errors or warnings

### Performance:
- First event after restart: 50-100ms
- API calls: 6-7 (existence checks + verifications)

---

## Test 6: Manual Index Deletion (Auto-Recovery)

### Objective:
Verify automatic recovery when index is manually deleted.

### Steps:
```bash
# 1. Create and index events normally
echo '{"container_name":"nginx","message":"Before deletion"}' | nc localhost 5000

# 2. Verify index exists
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-nginx*?v"

# 3. Manually DELETE the index
curl -X DELETE "http://eck-es-http:9200/auto-nginx-2025.11.20-000001?pretty"

# 4. Verify deletion
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-nginx*?v"
# Should be empty

# 5. Send new event (will trigger recovery)
echo '{"container_name":"nginx","message":"After deletion - recovery test"}' | nc localhost 5000

# 6. Check logs
tail -f /var/log/logstash/logstash-plain.log | grep -E "(nginx|index_not_found|clearing cache)"
```

### Expected Logs:
```
Bulk request failed with index_not_found_exception
Index missing, clearing cache for recreation
Lock acquired, proceeding with initialization
Created and verified rollover index
ILM resources ready, lock released
```

### Verification:
```bash
# Check new index created (incremented number)
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-nginx*?v"
# Should show: auto-nginx-2025.11.20-000002 (or -000001 if first of day)

# Check event was indexed
curl -X GET "http://eck-es-http:9200/auto-nginx/_search?pretty&q=message:recovery"
```

### Expected Results:
- ✅ Error detected automatically
- ✅ Cache cleared
- ✅ New index created
- ✅ Event successfully indexed (retried)
- ✅ No data loss

### Performance:
- Recovery time: ~500ms
- Event retried automatically

---

## Test 7: Missing container_name Field

### Objective:
Verify graceful handling of missing container_name field.

### Steps:
```bash
# Send event WITHOUT container_name field
echo '{"message":"No container name","@timestamp":"2025-11-20T12:00:00.000Z"}' | nc localhost 5000

# Check logs
tail -f /var/log/logstash/logstash-plain.log | grep -i "container"
```

### Expected Logs:
```
Field not found in event for ILM rollover alias - fallback to default
```

### Verification:
```bash
# Check event indexed to default/fallback index
curl -X GET "http://eck-es-http:9200/_cat/indices?v" | grep -i logstash
```

### Expected Results:
- ✅ Warning logged
- ✅ Event NOT dropped
- ✅ Event indexed to fallback index
- ✅ No error/crash

---

## Test 8: Invalid container_name Characters

### Objective:
Verify sanitization of invalid container names.

### Steps:
```bash
# Send event with invalid characters
echo '{"container_name":"NGINX/Server_123","message":"Invalid chars test"}' | nc localhost 5000

# Check logs
tail -f /var/log/logstash/logstash-plain.log | grep -i "invalid"
```

### Expected Logs:
```
Invalid characters in resolved alias name - using sanitized version
```

### Verification:
```bash
# Check sanitized index created
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-*?v"
# Should show sanitized name like: auto-nginx-server-123-2025.11.20-000001

# Check alias created
curl -X GET "http://eck-es-http:9200/_cat/aliases?v" | grep nginx
```

### Expected Results:
- ✅ Invalid characters sanitized
- ✅ Lowercase conversion applied
- ✅ Resources created with valid names
- ✅ Event indexed successfully

---

## Test 9: High-Throughput Stress Test

### Objective:
Verify performance under high load.

### Steps:
```bash
# Send 10,000 events across 5 containers
for container in nginx apache mysql redis postgres; do
  for i in {1..2000}; do
    echo "{\"container_name\":\"$container\",\"message\":\"Event $i\",\"@timestamp\":\"2025-11-20T12:00:00.000Z\"}"
  done | nc localhost 5000 &
done
wait

# Monitor performance
tail -f /var/log/logstash/logstash-plain.log | grep -E "(bulk|events)"
```

### Verification:
```bash
# Check all events indexed
for container in nginx apache mysql redis postgres; do
  count=$(curl -s "http://eck-es-http:9200/auto-$container/_count" | jq '.count')
  echo "$container: $count events"
done

# Check no errors
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-*?v&h=index,docs.count,health"
```

### Expected Results:
- ✅ All 10,000 events indexed
- ✅ 5 containers handled simultaneously
- ✅ No race conditions
- ✅ No duplicate resource creation
- ✅ Throughput: 50,000-100,000 events/sec (after warmup)

---

## Test 10: Anomaly Detection (Initialization Loop)

### Objective:
Verify detection and recovery from stuck initialization.

### Simulation:
This requires simulating repeated failures (e.g., by temporarily making Elasticsearch unavailable during initialization).

### Steps:
```bash
# 1. Block Elasticsearch temporarily
sudo iptables -A OUTPUT -d <ES_IP> -j DROP

# 2. Send events (will fail to initialize)
for i in {1..15}; do
  echo '{"container_name":"test","message":"Loop test"}' | nc localhost 5000
  sleep 1
done

# 3. Check logs
tail -f /var/log/logstash/logstash-plain.log | grep -i "anomaly"

# 4. Unblock Elasticsearch
sudo iptables -D OUTPUT -d <ES_IP> -j DROP

# 5. Send another event
echo '{"container_name":"test","message":"After recovery"}' | nc localhost 5000
```

### Expected Logs:
```
Failed to initialize ILM resources - will retry on next event (multiple times)
ANOMALY DETECTED: Container initialization failed repeatedly
Clearing cache to force full retry
```

### Expected Results:
- ✅ Anomaly detected after 10+ failures
- ✅ Cache automatically cleared
- ✅ Fresh retry attempted
- ✅ System recovers when ES available

---

## Performance Benchmarks

### Expected Performance Metrics:

| Metric | Value |
|--------|-------|
| First event (new container) | 500-1000ms |
| Cached event (existing container) | 1-5ms |
| Daily rollover | 100-200ms |
| Post-restart first event | 50-100ms |
| Throughput (cached) | 50K-100K events/sec |
| Memory per container cache | <1KB |
| API calls (first event) | 7-9 |
| API calls (cached event) | 0 |

---

## Troubleshooting Common Issues

### Issue 1: Events not indexed
```bash
# Check Logstash logs
tail -f /var/log/logstash/logstash-plain.log | grep -i error

# Check Elasticsearch cluster health
curl -X GET "http://eck-es-http:9200/_cluster/health?pretty"

# Check index exists
curl -X GET "http://eck-es-http:9200/_cat/indices/auto-*?v"
```

### Issue 2: Resources not created
```bash
# Check ILM enabled
curl -X GET "http://eck-es-http:9200/_ilm/status?pretty"

# Check permissions
curl -u elastic:password -X GET "http://eck-es-http:9200/_security/user/elastic?pretty"

# Check Logstash config
grep -A5 "ilm_enabled" /etc/logstash/conf.d/output.conf
```

### Issue 3: Duplicate resources
```bash
# List all policies
curl -X GET "http://eck-es-http:9200/_ilm/policy?pretty"

# Delete duplicates if needed
curl -X DELETE "http://eck-es-http:9200/_ilm/policy/duplicate-policy?pretty"

# Restart Logstash
systemctl restart logstash
```

---

## Test Completion Checklist

- [ ] Test 1: First event for new container ✅
- [ ] Test 2: Subsequent events (cached) ✅
- [ ] Test 3: Multiple containers simultaneously ✅
- [ ] Test 4: Day change rollover ✅
- [ ] Test 5: Logstash restart ✅
- [ ] Test 6: Manual index deletion ✅
- [ ] Test 7: Missing container_name field ✅
- [ ] Test 8: Invalid container_name characters ✅
- [ ] Test 9: High-throughput stress test ✅
- [ ] Test 10: Anomaly detection ✅

---

## Success Criteria

All tests pass when:
- ✅ Resources created automatically
- ✅ Events indexed successfully
- ✅ No errors in logs (except expected warnings)
- ✅ Performance meets expectations
- ✅ Auto-recovery works correctly
- ✅ Thread safety maintained
- ✅ Cache working correctly

**Your implementation is ready for production!** 🚀
