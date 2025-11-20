# Dynamic ILM Quick Reference

> **One-page reference for dynamic ILM configuration and troubleshooting**

---

## 🚀 Quick Start (30 seconds)

```ruby
output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    ilm_enabled => true
    index => "auto-%{[container_name]}-%{+YYYY.MM.dd}"
    ilm_rollover_alias => "%{[container_name]}"  # ← KEY: triggers dynamic behavior
  }
}
```

**Event must have:**
```json
{"message": "...", "container_name": "nginx"}
```

**Creates automatically:**
- Policy: `auto-nginx-ilm-policy`
- Template: `logstash-auto-nginx`
- Index: `auto-nginx-2025.11.20-000001`

---

## ⚙️ Configuration Cheat Sheet

| Setting | Default | Example | Description |
|---------|---------|---------|-------------|
| `ilm_rollover_alias` | - | `"%{[container_name]}"` | **REQUIRED** for dynamic ILM |
| `ilm_rollover_max_age` | `"1d"` | `"7d"` | Rollover after age |
| `ilm_rollover_max_size` | - | `"50gb"` | Rollover after size |
| `ilm_rollover_max_docs` | - | `1000000` | Rollover after docs |
| `ilm_hot_priority` | `50` | `100` | Index recovery priority |
| `ilm_delete_enabled` | `true` | `false` | Enable auto-deletion |
| `ilm_delete_min_age` | `"1d"` | `"30d"` | Delete after age |

---

## 🔍 Troubleshooting (90 seconds)

### Problem: No indices created

```bash
# Check if field exists
grep "container_name" /var/log/logstash/logstash-plain.log

# Check Elasticsearch connectivity
curl http://localhost:9200

# Check permissions
GET /_security/user/logstash_writer/_privileges
```

### Problem: Field not resolving

```ruby
# Add debug filter
filter {
  ruby { code => 'logger.info("Container: #{event.get(\"container_name\")}")' }
}
```

### Problem: Resources exist but not working

```bash
# Check policy
GET /_ilm/policy/auto-nginx-ilm-policy

# Check template
GET /_index_template/logstash-auto-nginx

# Check alias
GET /_alias/auto-nginx

# Check ILM status
GET /_ilm/status
```

---

## 📊 Monitoring One-Liners

```bash
# Count containers
GET /_cat/aliases?h=alias | grep "^auto-" | wc -l

# List all dynamic indices
GET /_cat/indices/auto-*?v

# Check write indices
GET /_alias/auto-* | jq 'to_entries[] | select(.value.aliases[].is_write_index == true)'

# Check ILM phase
GET /auto-*/_ilm/explain | jq '.indices[] | {index: .index, phase: .phase}'

# Find old indices
GET /_cat/indices/auto-*?h=index,creation.date.string&s=creation.date | head -20
```

---

## 🧹 Cleanup Commands

```bash
# Delete all resources for one container
DELETE /auto-nginx-*
DELETE /_index_template/logstash-auto-nginx
DELETE /_ilm/policy/auto-nginx-ilm-policy

# Delete all auto-* resources (DANGER!)
DELETE /auto-*
DELETE /_index_template/logstash-auto-*
for p in $(curl -s localhost:9200/_ilm/policy | jq -r 'keys[]' | grep auto-); do
  curl -X DELETE localhost:9200/_ilm/policy/$p
done
```

---

## 🎯 Performance Tuning

| Setting | Low Volume | High Volume | Notes |
|---------|------------|-------------|-------|
| `workers` | 2 | 8 | CPU cores × 2 |
| `flush_size` | 500 | 2000 | Events per bulk |
| `idle_flush_time` | 5 | 1 | Seconds |
| `ilm_rollover_max_age` | `"1d"` | `"1h"` | Faster rollover |
| `ilm_rollover_max_size` | `"50gb"` | `"10gb"` | Smaller indices |

---

## 🔐 Minimal Required Permissions

```json
{
  "cluster": ["manage_ilm", "manage_index_templates"],
  "indices": [
    {
      "names": ["auto-*"],
      "privileges": ["create_index", "write", "manage", "view_index_metadata"]
    }
  ]
}
```

---

## 🐛 Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Field not found` | Missing `container_name` | Add field in filter |
| `Invalid index name` | Special chars | Sanitized automatically |
| `resource_already_exists` | Race condition | Ignored (normal) |
| `index_not_found` | Deleted externally | Recreated automatically |
| `ANOMALY DETECTED` | Repeated failures | Check ES health/permissions |

---

## 📈 Expected Log Messages

```
✅ INFO  Initializing ILM resources for new container
✅ INFO  Created ILM policy
✅ INFO  Template ready
✅ INFO  Created and verified rollover index
✅ INFO  ILM resources ready, lock released

⚠️  WARN  Field not found in event for ILM rollover alias
⚠️  WARN  Invalid characters in resolved alias name
⚠️  WARN  Rate limited creating policy, retrying

❌ ERROR Failed to initialize ILM resources - will retry on next event
❌ ERROR ANOMALY DETECTED: Container initialization failed repeatedly
```

---

## 🎓 Architecture (10 second version)

```
Event → Resolve %{field} → Check cache → Create if missing → Index
                              ↓
                          Cached? ✅ Skip everything
                              ↓
                          Not cached? Create: Policy → Template → Index
                              ↓
                          Cache ✅ Future events instant
```

---

## 📞 Getting Help

1. Check logs: `tail -f /var/log/logstash/logstash-plain.log | grep -i "ilm\|dynamic"`
2. Enable debug: Add `log.level: debug` to `logstash.yml`
3. Review docs: `DYNAMIC_ILM_IMPLEMENTATION.md`
4. Run tests: `DYNAMIC_ILM_TESTING_GUIDE.md`

---

## 🎁 Bonus: Test Event Generator

```bash
# Generate test events
for i in {1..100}; do
  echo "{\"message\":\"Test $i\",\"container_name\":\"nginx\",\"@timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
done | bin/logstash -f test.conf
```

---

**Print this page and keep it handy!** 📄

*Quick Reference v1.0 - November 2025*
