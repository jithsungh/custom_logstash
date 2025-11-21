# ✅ QUICK CHECKLIST - ILM Rollover Without Date

## 📋 Pre-Deployment Checklist

- [ ] **1. Verify Code Changes**
  - [ ] Open `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`
  - [ ] Verify `create_index_if_missing()` creates `#{container_name}-000001` (NO DATE)
  - [ ] Verify `build_dynamic_ilm_policy()` includes `rollover` action
  - [ ] Verify `rollover_alias_has_write_index?()` method exists

## 🔧 Build & Install

- [ ] **2. Build the Gem**
  ```bash
  cd /mnt/c/Users/jithsungh.v/logstash-output-elasticsearch
  gem build logstash-output-elasticsearch.gemspec
  ```
  - [ ] Gem builds successfully
  - [ ] Note the gem filename: `logstash-output-elasticsearch-*.gem`

- [ ] **3. Remove Old Plugin**
  ```bash
  /usr/share/logstash/bin/logstash-plugin remove logstash-output-elasticsearch
  ```

- [ ] **4. Install New Plugin**
  ```bash
  /usr/share/logstash/bin/logstash-plugin install /path/to/logstash-output-elasticsearch-*.gem
  ```

- [ ] **5. Restart Logstash**
  ```bash
  systemctl restart logstash
  # OR
  docker-compose restart logstash
  ```

## 📝 Configuration Check

- [ ] **6. Verify Config File**
  - [ ] `index => "auto-%{[container_name]}"` (NO DATE PATTERN)
  - [ ] `ilm_rollover_alias => "%{[container_name]}"`
  - [ ] `ilm_enabled => true`
  - [ ] `ilm_rollover_max_age` configured (e.g., "1d")
  - [ ] `ilm_delete_min_age` configured (e.g., "7d")

## 🧪 Testing

- [ ] **7. Send Test Events**
  ```bash
  echo '{"container_name": "testapp", "message": "test 1"}' | \
    /usr/share/logstash/bin/logstash -f config.conf
  ```

- [ ] **8. Verify Indices (CRITICAL!)**
  ```bash
  curl -u elastic:password "http://localhost:9200/_cat/indices/auto-*?v"
  ```
  - [ ] Index name is `auto-testapp-000001` ✅
  - [ ] Index name is NOT `auto-testapp-2025-11-18-000001` ❌
  - [ ] **NO DATE IN INDEX NAME!**

- [ ] **9. Verify Alias**
  ```bash
  curl -u elastic:password "http://localhost:9200/_cat/aliases/auto-testapp?v"
  ```
  - [ ] Alias `auto-testapp` exists
  - [ ] Points to `auto-testapp-000001`
  - [ ] `is_write_index` is `true`

- [ ] **10. Verify ILM Policy**
  ```bash
  curl -u elastic:password "http://localhost:9200/_ilm/policy/auto-testapp-ilm-policy?pretty"
  ```
  - [ ] Policy exists
  - [ ] Has `hot.actions.rollover` section
  - [ ] Has `max_age`, `max_size`, or `max_docs` condition
  - [ ] Has `delete` phase (if configured)

- [ ] **11. Verify Index Settings**
  ```bash
  curl -u elastic:password "http://localhost:9200/auto-testapp-000001/_settings?pretty"
  ```
  - [ ] `index.lifecycle.name` is set to policy name
  - [ ] `index.lifecycle.rollover_alias` is set to alias name ← **CRITICAL!**

- [ ] **12. Verify ILM Execution**
  ```bash
  curl -u elastic:password "http://localhost:9200/auto-testapp-000001/_ilm/explain?pretty"
  ```
  - [ ] Shows current phase (should be "hot")
  - [ ] Shows managed: true
  - [ ] No error messages

## 🔍 Production Validation

- [ ] **13. Multiple Containers Test**
  ```bash
  # Send events for different containers
  echo '{"container_name": "nginx", "message": "test"}' | ...
  echo '{"container_name": "apache", "message": "test"}' | ...
  echo '{"container_name": "mysql", "message": "test"}' | ...
  ```
  - [ ] Each creates separate indices: `auto-nginx-000001`, `auto-apache-000001`, etc.
  - [ ] NO DATES in any index name

- [ ] **14. Check Logstash Logs**
  ```bash
  tail -f /var/log/logstash/logstash-plain.log | grep -i "ilm\|rollover"
  ```
  - [ ] See: "Created ILM policy"
  - [ ] See: "Template ready"
  - [ ] See: "Successfully created first rollover index"
  - [ ] NO errors about missing aliases or indices

- [ ] **15. Restart Test**
  - [ ] Restart Logstash
  - [ ] Send more events
  - [ ] Verify no duplicate indices created
  - [ ] Verify existing indices/aliases reused

## 📊 Monitor Rollover (After 1 Day)

- [ ] **16. Wait for Rollover Condition**
  - [ ] Wait for max_age (e.g., 1 day)
  - [ ] OR fill with max_size (e.g., 50GB)
  - [ ] OR reach max_docs (e.g., 1M documents)

- [ ] **17. Verify Automatic Rollover**
  ```bash
  curl -u elastic:password "http://localhost:9200/_cat/indices/auto-testapp-*?v&s=index"
  ```
  - [ ] See `auto-testapp-000001` (read-only)
  - [ ] See `auto-testapp-000002` (writing)
  - [ ] **BOTH WITHOUT DATES!** ✅

- [ ] **18. Verify Alias Updated**
  ```bash
  curl -u elastic:password "http://localhost:9200/_cat/aliases/auto-testapp?v"
  ```
  - [ ] Alias now points to `-000002`
  - [ ] `is_write_index: true` on `-000002`

## 🗑️ Monitor Deletion (After 7 Days)

- [ ] **19. Verify Automatic Deletion**
  ```bash
  curl -u elastic:password "http://localhost:9200/_cat/indices/auto-testapp-*?v&s=index"
  ```
  - [ ] Old indices (7+ days) are deleted
  - [ ] Recent indices still exist

## ✅ Success Criteria

- [ ] **ALL indices are created WITHOUT dates** (e.g., `auto-nginx-000001`)
- [ ] **ILM policy includes rollover action**
- [ ] **Index settings include `rollover_alias`**
- [ ] **Automatic rollover works** (creates 000002, 000003, etc.)
- [ ] **Automatic deletion works** (deletes old indices)
- [ ] **Multiple containers work independently**
- [ ] **Logstash restart reuses existing resources**

---

## 🚨 If Something Goes Wrong

### Problem: Indices still have dates
```
Wrong: auto-nginx-2025-11-18-000001
```

**Solution**:
1. Verify you installed the NEW gem (check gem build date)
2. Restart Logstash completely
3. Delete old indices and try again

### Problem: No `rollover_alias` in index settings
```bash
curl "http://localhost:9200/auto-testapp-000001/_settings?pretty"
# Missing: index.lifecycle.rollover_alias
```

**Solution**:
1. Delete the index
2. Delete the template
3. Restart Logstash
4. Send new events (will recreate with correct settings)

### Problem: ILM not rolling over
```bash
# Index is 2 days old but no rollover happened
```

**Solution**:
1. Check ILM is running: `GET /_ilm/status`
2. Check index ILM explain: `GET /index-name/_ilm/explain`
3. Verify rollover_alias is set correctly
4. Check conditions are actually met (age, size, docs)

---

## 📞 Need Help?

Check these files:
- `FINAL_IMPLEMENTATION_SUMMARY.md` - Complete details
- `ROLLOVER_WITHOUT_DATE_CHANGES.md` - All changes explained
- `FLOW_DIAGRAM.md` - Visual flow
- `QUICK_REFERENCE.md` - Quick tips
- `test_rollover_without_date.sh` - Automated test script

---

**Last Updated**: November 21, 2025  
**Status**: Ready for production ✅
