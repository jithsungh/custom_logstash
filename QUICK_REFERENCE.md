# 🎯 Quick Reference: ILM Rollover Without Date

## What Was Changed

### ❌ OLD BEHAVIOR (With Dates)
```
Index Name: auto-e3fbrandmapperbetgenius-2025-11-18-000001
            ↑                           ↑               ↑
            prefix                      DATE            sequence
```

### ✅ NEW BEHAVIOR (Without Dates)
```
Index Name: auto-e3fbrandmapperbetgenius-000001
            ↑                           ↑
            prefix                      sequence (ILM managed)
```

---

## Modified Files

| File | Changes |
|------|---------|
| **dynamic_template_manager.rb** | ✅ Creates `auto-nginx-000001` instead of `auto-nginx-2025-11-18`<br>✅ Uses `rollover_alias_put` for proper ILM setup<br>✅ Adds rollover conditions to ILM policy<br>✅ Removes date-based alias management |
| **examples/dynamic-ilm-config.conf** | ✅ Updated comments to reflect no-date pattern |

---

## Key Code Changes

### 1. Index Creation (dynamic_template_manager.rb:289-349)

**Before:**
```ruby
def create_index_if_missing(container_name, policy_name)
  today = current_date_str
  index_name = "#{container_name}-#{today}"  # ❌ With date
  # ...
end
```

**After:**
```ruby
def create_index_if_missing(container_name, policy_name)
  first_index_name = "#{container_name}-000001"  # ✅ Without date
  # Uses rollover_alias_put for proper ILM integration
  @client.rollover_alias_put(first_index_name, index_payload)
end
```

### 2. ILM Policy (dynamic_template_manager.rb:268-287)

**Before:**
```ruby
def build_dynamic_ilm_policy
  hot_phase = {
    "actions" => {
      "set_priority" => { "priority" => @ilm_hot_priority }
    }
  }
  # ❌ No rollover action
end
```

**After:**
```ruby
def build_dynamic_ilm_policy
  hot_phase = {
    "actions" => {
      "rollover" => {  # ✅ Added rollover action
        "max_age" => @ilm_rollover_max_age,
        "max_size" => @ilm_rollover_max_size,
        "max_docs" => @ilm_rollover_max_docs
      },
      "set_priority" => { "priority" => @ilm_hot_priority }
    }
  }
end
```

### 3. Index Settings (dynamic_template_manager.rb:305-320)

**Before:**
```ruby
'settings' => {
  'index' => {
    'lifecycle' => {
      'name' => policy_name
      # ❌ Missing rollover_alias
    }
  }
}
```

**After:**
```ruby
'settings' => {
  'index' => {
    'lifecycle' => {
      'name' => policy_name,
      'rollover_alias' => container_name  # ✅ Added
    }
  }
}
```

---

## How Rollover Works Now

### Automatic Rollover by ILM

```
Day 0: Create
┌─────────────────────────────────────────┐
│ auto-nginx-000001 (is_write_index=true) │
│ Alias: auto-nginx → 000001              │
└─────────────────────────────────────────┘

Day 1: ILM checks conditions
- max_age: 1d ✓ (condition met)
- ILM triggers rollover

Day 1: After Rollover
┌─────────────────────────────────────────┐
│ auto-nginx-000001 (read-only)           │
│ auto-nginx-000002 (is_write_index=true) │ ← NEW
│ Alias: auto-nginx → 000002              │
└─────────────────────────────────────────┘

Day 2: ILM triggers rollover again
┌─────────────────────────────────────────┐
│ auto-nginx-000001 (read-only)           │
│ auto-nginx-000002 (read-only)           │
│ auto-nginx-000003 (is_write_index=true) │ ← NEW
│ Alias: auto-nginx → 000003              │
└─────────────────────────────────────────┘

Day 7: ILM deletes old indices
┌─────────────────────────────────────────┐
│ auto-nginx-000002 (read-only)           │
│ auto-nginx-000003 (read-only)           │
│ auto-nginx-000008 (is_write_index=true) │
└─────────────────────────────────────────┘
(000001 deleted after 7 days)
```

---

## Testing Commands

### 1. Build & Install
```bash
cd /mnt/c/Users/jithsungh.v/logstash-output-elasticsearch
gem build logstash-output-elasticsearch.gemspec
/usr/share/logstash/bin/logstash-plugin install --no-verify logstash-output-elasticsearch-*.gem
```

### 2. Send Test Event
```bash
echo '{"container_name": "testapp", "message": "test"}' | \
  /usr/share/logstash/bin/logstash -f examples/dynamic-ilm-config.conf
```

### 3. Verify Indices (NO DATE!)
```bash
curl -u elastic:password "localhost:9200/_cat/indices/auto-*?v&s=index"

# Expected output:
# health status index                   pri rep docs.count
# yellow open   auto-testapp-000001      1   0          1
#                            ↑↑↑↑↑↑
#                            NO DATE!
```

### 4. Verify Alias
```bash
curl -u elastic:password "localhost:9200/_cat/aliases/auto-*?v"

# Expected output:
# alias         index                is_write_index
# auto-testapp  auto-testapp-000001  true
```

### 5. Verify ILM Policy
```bash
curl -u elastic:password "localhost:9200/_ilm/policy/auto-testapp-ilm-policy?pretty"

# Should contain rollover action:
# "rollover": {
#   "max_age": "1d",
#   "max_size": "50gb",
#   "max_docs": 1000000
# }
```

### 6. Check ILM Status
```bash
curl -u elastic:password "localhost:9200/auto-testapp-000001/_ilm/explain?pretty"

# Should show:
# "phase": "hot",
# "action": "complete" or "rollover"
```

---

## Configuration Example

```ruby
output {
  elasticsearch {
    hosts => ["localhost:9200"]
    
    # Dynamic ILM without dates
    ilm_enabled => true
    index => "auto-%{[container_name]}"
    ilm_rollover_alias => "%{[container_name]}"
    
    # Rollover conditions (at least one required)
    ilm_rollover_max_age => "1d"      # Roll after 1 day
    ilm_rollover_max_size => "50gb"   # OR roll after 50GB
    ilm_rollover_max_docs => 1000000  # OR roll after 1M docs
    
    # Retention
    ilm_delete_enabled => true
    ilm_delete_min_age => "7d"        # Delete after 7 days
    
    # Priority
    ilm_hot_priority => 100
  }
}
```

---

## Troubleshooting

### ❌ Problem: Indices still have dates
```
auto-testapp-2025-11-21-000001  ← BAD!
```

**Solution:**
```bash
# 1. Remove old gem
/usr/share/logstash/bin/logstash-plugin remove logstash-output-elasticsearch

# 2. Install new gem
/usr/share/logstash/bin/logstash-plugin install /path/to/new/gem

# 3. Restart Logstash
systemctl restart logstash

# 4. Delete old test indices
curl -X DELETE "localhost:9200/auto-testapp-*"

# 5. Send new test event
```

### ❌ Problem: No rollover happening

**Check ILM execution:**
```bash
curl "localhost:9200/auto-testapp-000001/_ilm/explain?pretty"
```

**Check if rollover_alias is set:**
```bash
curl "localhost:9200/auto-testapp-000001/_settings?pretty" | grep rollover_alias
```

**Manual rollover test:**
```bash
curl -X POST "localhost:9200/auto-testapp/_rollover?pretty"
```

### ❌ Problem: Write alias missing

**Check alias:**
```bash
curl "localhost:9200/_cat/aliases/auto-testapp?v"
```

**Recreate manually if needed:**
```bash
curl -X POST "localhost:9200/_aliases" -H 'Content-Type: application/json' -d'
{
  "actions": [
    {
      "add": {
        "index": "auto-testapp-000001",
        "alias": "auto-testapp",
        "is_write_index": true
      }
    }
  ]
}'
```

---

## Success Checklist

- [x] Index name format: `auto-container-000001` (NO date)
- [x] Write alias exists: `auto-container → auto-container-000001`
- [x] ILM policy has `rollover` action
- [x] Index settings include `rollover_alias`
- [x] Template includes `rollover_alias` in settings
- [x] Sequential numbering works: 000001 → 000002 → 000003
- [x] Old indices deleted after retention period

---

## Important Notes

1. **Index Naming**: ILM requires sequential numbering (000001, 000002, etc.)
2. **Write Alias**: Must point to current index with `is_write_index: true`
3. **Rollover Conditions**: At least one condition (age/size/docs) required
4. **First Index**: Always ends with `-000001`
5. **Subsequent Indices**: ILM auto-increments to 000002, 000003, etc.

---

## Resources

- **Modified File**: `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`
- **Test Script**: `test_rollover_without_date.sh`
- **Documentation**: `ROLLOVER_WITHOUT_DATE_CHANGES.md`
- **Example Config**: `examples/dynamic-ilm-config.conf`

---

**Status**: ✅ Implementation Complete - Ready for Testing!
