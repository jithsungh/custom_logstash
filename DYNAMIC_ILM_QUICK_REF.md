# Dynamic ILM Quick Reference

## ⚡ TL;DR

When you use `ilm_rollover_alias => "%{[field]}"`, the `ilm_policy` parameter is **IGNORED**.

Policies are auto-created as: `{field_value}-ilm-policy`

---

## 📋 Resource Naming

| **Event Field**           | **Alias** | **Policy**         | **Template**     | **Index**                 |
| ------------------------- | --------- | ------------------ | ---------------- | ------------------------- |
| `container_name: "nginx"` | `nginx`   | `nginx-ilm-policy` | `logstash-nginx` | `nginx-2025.11.17-000001` |
| `container_name: "redis"` | `redis`   | `redis-ilm-policy` | `logstash-redis` | `redis-2025.11.17-000001` |
| `app: "api"`              | `api`     | `api-ilm-policy`   | `logstash-api`   | `api-2025.11.17-000001`   |

---

## 🎯 Minimal Working Config

```ruby
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "changeme"

    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_rollover_max_age => "1d"
    ilm_delete_min_age => "30d"
    ilm_delete_enabled => true

    # ⚠️ DON'T add ilm_policy - it's ignored!
  }
}
```

---

## ✅ Verification (30 seconds)

### 1. Check policies exist

```bash
curl "http://elasticsearch:9200/_ilm/policy?pretty" | grep -E '(nginx|redis|postgres)'
```

### 2. Check indices created with rollover naming

```bash
curl "http://elasticsearch:9200/_cat/indices?v" | grep -E '\-[0-9]{4}\.[0-9]{2}\.[0-9]{2}\-[0-9]{6}'
```

**Expected:** `nginx-2025.11.17-000001` ✅  
**NOT:** `nginx` ❌

### 3. Check aliases attached

```bash
curl "http://elasticsearch:9200/_cat/aliases?v"
```

**Expected:**

```
alias  index
nginx  nginx-2025.11.17-000001
redis  redis-2025.11.17-000001
```

---

## 🔥 Common Mistakes

### ❌ Mistake 1: Adding ilm_policy in dynamic mode

```ruby
ilm_rollover_alias => "%{[container_name]}"  # Dynamic
ilm_policy => "my-policy"                     # IGNORED!
```

**Fix:** Remove `ilm_policy` line entirely.

### ❌ Mistake 2: Expecting indices named just "nginx"

**Wrong expectation:** Index will be called `nginx`  
**Reality:** Index will be `nginx-2025.11.17-000001`

### ❌ Mistake 3: Missing field in events

```ruby
ilm_rollover_alias => "%{[container_name]}"
# But events don't have container_name field!
```

**Fix:** Add filter:

```ruby
filter {
  if ![container_name] {
    mutate { add_field => { "container_name" => "unknown" } }
  }
}
```

---

## 🛠️ Debug Commands

```bash
# Show Logstash is sending data
docker logs logstash 2>&1 | grep -i "ilm"

# Show what policies were created
curl "http://elasticsearch:9200/_ilm/policy?pretty"

# Show what templates were created
curl "http://elasticsearch:9200/_index_template?pretty"

# Show what indices exist
curl "http://elasticsearch:9200/_cat/indices?v&s=index"

# Show aliases
curl "http://elasticsearch:9200/_cat/aliases?v&s=alias"

# Check if index is write index
curl "http://elasticsearch:9200/nginx?pretty" | jq '.nginx.aliases'
```

---

## 📊 Expected Log Output

When working correctly, you'll see:

```
[INFO] Created dynamic ILM policy {:policy_name=>"nginx-ilm-policy", :container=>"nginx"}
[INFO] Created dynamic template {:template_name=>"logstash-nginx", :pattern=>"nginx-*"}
[INFO] Created rollover alias {:alias=>"nginx", :index=>"nginx-2025.11.17-000001"}
```

---

## 🚀 Next Steps

1. **Verify rollover works:**

   ```bash
   curl -X POST "http://elasticsearch:9200/nginx/_rollover?pretty"
   ```

   Should create: `nginx-2025.11.17-000002`

2. **Check ILM status:**

   ```bash
   curl "http://elasticsearch:9200/_ilm/status?pretty"
   ```

3. **Monitor index lifecycle:**
   ```bash
   curl "http://elasticsearch:9200/_cat/indices?v&h=index,health,pri.store.size"
   ```

---

## 📖 Full Documentation

See: [DYNAMIC_ILM_EXPLAINED.md](./DYNAMIC_ILM_EXPLAINED.md)
