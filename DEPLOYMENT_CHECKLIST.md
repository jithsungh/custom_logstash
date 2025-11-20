# Dynamic ILM Deployment Checklist

Use this checklist to ensure successful deployment of the dynamic ILM feature.

---

## Pre-Deployment Checklist

### Environment Verification

- [ ] **Elasticsearch version >= 8.0**
  ```bash
  curl http://localhost:9200 | jq '.version.number'
  ```

- [ ] **Logstash version >= 7.0**
  ```bash
  bin/logstash --version
  ```

- [ ] **Network connectivity**
  ```bash
  curl http://elasticsearch:9200/_cluster/health
  ```

- [ ] **Sufficient disk space**
  ```bash
  df -h | grep elasticsearch
  # Ensure >20% free space
  ```

### User Permissions

- [ ] **Test user can create ILM policies**
  ```bash
  curl -u elastic:password -X PUT \
    http://localhost:9200/_ilm/policy/test-policy \
    -H 'Content-Type: application/json' \
    -d '{"policy":{"phases":{}}}'
  ```

- [ ] **Test user can create templates**
  ```bash
  curl -u elastic:password -X PUT \
    http://localhost:9200/_index_template/test-template \
    -H 'Content-Type: application/json' \
    -d '{"index_patterns":["test-*"]}'
  ```

- [ ] **Test user can create indices**
  ```bash
  curl -u elastic:password -X PUT \
    http://localhost:9200/test-index
  ```

- [ ] **Clean up test resources**
  ```bash
  curl -X DELETE http://localhost:9200/test-index
  curl -X DELETE http://localhost:9200/_index_template/test-template
  curl -X DELETE http://localhost:9200/_ilm/policy/test-policy
  ```

### Plugin Installation

- [ ] **Plugin installed**
  ```bash
  bin/logstash-plugin list | grep logstash-output-elasticsearch
  ```

- [ ] **Plugin version correct**
  ```bash
  bin/logstash-plugin list --verbose | grep logstash-output-elasticsearch
  # Should show version with dynamic ILM support
  ```

- [ ] **Dependencies installed**
  ```bash
  gem list | grep elasticsearch
  ```

---

## Configuration Checklist

### Logstash Configuration

- [ ] **ilm_enabled set to true**
  ```ruby
  ilm_enabled => true
  ```

- [ ] **ilm_rollover_alias uses sprintf**
  ```ruby
  ilm_rollover_alias => "%{[container_name]}"
  # Must contain %{ } for dynamic behavior
  ```

- [ ] **index pattern includes field**
  ```ruby
  index => "auto-%{[container_name]}-%{+YYYY.MM.dd}"
  ```

- [ ] **ILM settings configured**
  ```ruby
  ilm_rollover_max_age => "1d"
  ilm_delete_min_age => "7d"
  ilm_delete_enabled => true
  ```

- [ ] **Connection settings correct**
  ```ruby
  hosts => ["https://elasticsearch:9200"]
  user => "logstash_writer"
  password => "${ELASTIC_PASSWORD}"
  ssl => true
  cacert => "/path/to/ca.crt"
  ```

### Input Configuration

- [ ] **Events include required field**
  ```ruby
  # Verify events have container_name field
  # Add filter if needed:
  filter {
    if ![container_name] {
      mutate { add_field => { "container_name" => "default" } }
    }
  }
  ```

- [ ] **Field is sanitized**
  ```ruby
  mutate {
    lowercase => ["container_name"]
    gsub => ["container_name", "[^a-z0-9-]", "-"]
  }
  ```

---

## Testing Checklist

### Unit Tests

- [ ] **Syntax validation**
  ```bash
  ruby -c lib/logstash/outputs/elasticsearch.rb
  ruby -c lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb
  ```

- [ ] **Configuration validation**
  ```bash
  bin/logstash -f config/pipeline.conf --config.test_and_exit
  ```

### Integration Tests

- [ ] **Single container test**
  ```bash
  echo '{"message":"Test","container_name":"test1"}' | \
    bin/logstash -f config/pipeline.conf
  
  # Verify:
  curl http://localhost:9200/_ilm/policy/auto-test1-ilm-policy
  curl http://localhost:9200/_index_template/logstash-auto-test1
  curl http://localhost:9200/_cat/indices/auto-test1-*
  ```

- [ ] **Multiple containers test**
  ```bash
  for i in {1..5}; do
    echo "{\"message\":\"Test $i\",\"container_name\":\"test$i\"}"
  done | bin/logstash -f config/pipeline.conf
  
  # Verify 5 policies, templates, indices created
  curl http://localhost:9200/_ilm/policy | jq 'keys | map(select(contains("auto-test")))'
  ```

- [ ] **Concurrent events test**
  ```bash
  # Send 1000 events for same container with multiple workers
  for i in {1..1000}; do
    echo '{"message":"Stress","container_name":"stress"}'
  done | bin/logstash -f config/pipeline.conf
  
  # Verify only 1 policy created (no duplicates)
  curl http://localhost:9200/_ilm/policy/auto-stress-ilm-policy
  ```

- [ ] **Missing field test**
  ```bash
  echo '{"message":"No container field"}' | \
    bin/logstash -f config/pipeline.conf
  
  # Check logs for fallback behavior
  grep "Field not found" /var/log/logstash/logstash-plain.log
  ```

- [ ] **Invalid characters test**
  ```bash
  echo '{"message":"Test","container_name":"HAS SPACES/SLASHES*"}' | \
    bin/logstash -f config/pipeline.conf
  
  # Verify sanitization occurred
  grep "Invalid characters" /var/log/logstash/logstash-plain.log
  ```

### Performance Tests

- [ ] **Throughput test (baseline)**
  ```bash
  # Measure events/second
  time (for i in {1..10000}; do echo '{"message":"'$i'","container_name":"perf"}'; done | \
    bin/logstash -f config/pipeline.conf)
  ```

- [ ] **Resource usage monitoring**
  ```bash
  # Monitor during test
  top -p $(pgrep -f logstash)
  ```

---

## Monitoring Setup Checklist

### Elasticsearch Monitoring

- [ ] **ILM status monitoring**
  ```bash
  # Add to monitoring script
  watch -n 60 'curl -s http://localhost:9200/_ilm/status'
  ```

- [ ] **Index count monitoring**
  ```bash
  # Alert if too many indices
  curl -s http://localhost:9200/_cat/indices/auto-*?h=index | wc -l
  ```

- [ ] **Policy count monitoring**
  ```bash
  # Alert if unexpected growth
  curl -s http://localhost:9200/_ilm/policy | jq 'keys | length'
  ```

### Logstash Monitoring

- [ ] **Log monitoring configured**
  ```bash
  # Monitor for errors
  tail -f /var/log/logstash/logstash-plain.log | \
    grep -i "error\|warn\|anomaly"
  ```

- [ ] **Metrics collection enabled**
  ```yaml
  # logstash.yml
  monitoring.enabled: true
  monitoring.elasticsearch.hosts: ["http://localhost:9200"]
  ```

### Alerting

- [ ] **Alert on repeated errors**
  ```
  Rule: ERROR count > 10 in 5 minutes
  Action: Notify ops team
  ```

- [ ] **Alert on anomaly detection**
  ```
  Rule: "ANOMALY DETECTED" in logs
  Action: Notify ops team
  ```

- [ ] **Alert on failed resource creation**
  ```
  Rule: "Failed to initialize ILM resources" count > 5
  Action: Notify ops team
  ```

---

## Security Checklist

### Connection Security

- [ ] **SSL/TLS enabled**
  ```ruby
  ssl => true
  cacert => "/path/to/ca.crt"
  ssl_certificate_verification => true
  ```

- [ ] **Authentication configured**
  ```ruby
  user => "logstash_writer"
  password => "${ELASTIC_PASSWORD}"
  # Use environment variable, not plaintext
  ```

- [ ] **Certificate validation enabled**
  ```ruby
  ssl_certificate_verification => true
  ```

### Access Control

- [ ] **Dedicated user created**
  ```bash
  # Create user with minimal permissions
  POST /_security/user/logstash_writer
  {
    "password": "...",
    "roles": ["logstash_dynamic_ilm"]
  }
  ```

- [ ] **Role has minimal privileges**
  ```json
  {
    "cluster": ["manage_ilm", "manage_index_templates"],
    "indices": [
      {"names": ["auto-*"], "privileges": ["create_index", "write", "manage"]}
    ]
  }
  ```

- [ ] **API key usage (optional)**
  ```ruby
  api_key => "${ELASTIC_API_KEY}"
  # More secure than password
  ```

### Audit Trail

- [ ] **Audit logging enabled in Elasticsearch**
  ```yaml
  # elasticsearch.yml
  xpack.security.audit.enabled: true
  ```

- [ ] **Monitor audit logs**
  ```bash
  tail -f /var/log/elasticsearch/elasticsearch_audit.json | \
    grep "auto-"
  ```

---

## Documentation Checklist

### Team Documentation

- [ ] **Operations runbook created**
  - How to monitor
  - How to troubleshoot
  - How to clean up resources
  - Emergency contacts

- [ ] **Configuration examples documented**
  - Sample configurations
  - Common patterns
  - Edge cases

- [ ] **Troubleshooting guide accessible**
  - Common errors
  - Solutions
  - Escalation path

### Knowledge Transfer

- [ ] **Team training completed**
  - How dynamic ILM works
  - How to configure
  - How to monitor
  - How to troubleshoot

- [ ] **Documentation reviewed**
  - `DYNAMIC_ILM_IMPLEMENTATION.md`
  - `DYNAMIC_ILM_TESTING_GUIDE.md`
  - `QUICK_REFERENCE.md`

---

## Deployment Checklist

### Pre-Production

- [ ] **Staging environment tested**
  - All tests passed
  - Performance acceptable
  - No errors in logs

- [ ] **Rollback plan prepared**
  - Previous configuration saved
  - Rollback procedure documented
  - Team knows how to rollback

- [ ] **Monitoring dashboards created**
  - Elasticsearch health
  - Logstash metrics
  - ILM policy status
  - Index counts

### Production Deployment

- [ ] **Change request approved**
- [ ] **Maintenance window scheduled**
- [ ] **Team on standby**
- [ ] **Backup configuration saved**

#### Deployment Steps

1. - [ ] Stop Logstash
   ```bash
   systemctl stop logstash
   ```

2. - [ ] Update configuration
   ```bash
   cp config/pipeline.conf.new config/pipeline.conf
   ```

3. - [ ] Validate configuration
   ```bash
   bin/logstash -f config/pipeline.conf --config.test_and_exit
   ```

4. - [ ] Start Logstash
   ```bash
   systemctl start logstash
   ```

5. - [ ] Monitor startup
   ```bash
   tail -f /var/log/logstash/logstash-plain.log
   ```

6. - [ ] Verify first events indexed
   ```bash
   # Check logs for resource creation
   grep "ILM resources ready" /var/log/logstash/logstash-plain.log
   ```

7. - [ ] Check Elasticsearch resources
   ```bash
   curl http://localhost:9200/_ilm/policy | jq 'keys'
   curl http://localhost:9200/_cat/indices/auto-*?v
   ```

### Post-Deployment

- [ ] **Monitor for 1 hour**
  - No errors in logs
  - Events being indexed
  - Resources created correctly

- [ ] **Verify expected containers**
  ```bash
  # List all dynamic aliases
  curl http://localhost:9200/_cat/aliases/auto-*?v
  ```

- [ ] **Check performance metrics**
  - Throughput normal
  - Latency acceptable
  - Resource usage reasonable

- [ ] **Document actual results**
  - Containers created
  - Performance observed
  - Issues encountered

---

## Post-Deployment Monitoring (First 7 Days)

### Day 1

- [ ] **Hourly checks**
  - Error count
  - Resource count
  - Event throughput

### Day 2-3

- [ ] **Check daily rollover**
  ```bash
  # Verify new indices created with new date
  curl http://localhost:9200/_cat/indices/auto-*?v | grep $(date +%Y.%m.%d)
  ```

### Day 7

- [ ] **Check deletion phase**
  ```bash
  # Verify old indices deleted (if ilm_delete_min_age="7d")
  # Should NOT see indices older than 7 days
  curl http://localhost:9200/_cat/indices/auto-*?h=index,creation.date.string
  ```

- [ ] **Performance review**
  - Average throughput
  - Peak throughput
  - Resource usage trends

- [ ] **Issue review**
  - Errors encountered
  - Workarounds applied
  - Improvements needed

---

## Success Criteria

Deployment is successful if:

- ✅ All events indexed without errors
- ✅ Resources created automatically per container
- ✅ No duplicate resources
- ✅ Performance meets requirements
- ✅ Monitoring working correctly
- ✅ Team confident in operations

---

## Rollback Procedure

If issues occur:

1. **Stop Logstash**
   ```bash
   systemctl stop logstash
   ```

2. **Restore previous configuration**
   ```bash
   cp config/pipeline.conf.backup config/pipeline.conf
   ```

3. **Restart Logstash**
   ```bash
   systemctl start logstash
   ```

4. **Verify rollback successful**
   ```bash
   tail -f /var/log/logstash/logstash-plain.log
   ```

5. **Document issues for review**

---

## Emergency Contacts

- **Primary Contact:** ______________________
- **Secondary Contact:** ______________________
- **Elasticsearch Team:** ______________________
- **On-Call:** ______________________

---

## Sign-Off

- [ ] **Pre-deployment checks complete** _____________________ Date: _____
- [ ] **Testing complete** _____________________ Date: _____
- [ ] **Security review complete** _____________________ Date: _____
- [ ] **Documentation complete** _____________________ Date: _____
- [ ] **Deployment successful** _____________________ Date: _____
- [ ] **Post-deployment review complete** _____________________ Date: _____

---

**Keep this checklist with deployment documentation!**

*Deployment Checklist v1.0 - November 2025*
