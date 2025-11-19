# Dynamic ILM - How It Actually Works

## Overview

The dynamic ILM feature **automatically creates separate ILM policies, templates, and indices** for each unique value in your event fields (like `container_name`). This eliminates the need to manually create and manage these resources.

---

## Key Concept: The `ilm_policy` Parameter is IGNORED

⚠️ **IMPORTANT**: When you use a dynamic `ilm_rollover_alias` with sprintf placeholders (like `%{[container_name]}`), the `ilm_policy` parameter you specify in your Logstash config is **completely ignored**.

### Why?

Because the plugin **automatically generates unique policy names** based on the alias.

**Example:**

```ruby
ilm_rollover_alias => "%{[container_name]}"  # Dynamic alias
ilm_policy => "my-manual-policy"              # ❌ IGNORED!
```

If a log event has `container_name = "nginx"`, the plugin will:

1. ✅ Use alias: `nginx`
2. ✅ Auto-create policy: `nginx-ilm-policy` (not `my-manual-policy`)
3. ✅ Auto-create template: `logstash-nginx`
4. ✅ Create index: `nginx-2025.11.17-000001`

---

## Resource Naming Convention

The plugin follows this automatic naming pattern:

| Resource Type     | Naming Pattern                | Example                      |
| ----------------- | ----------------------------- | ---------------------------- |
| **Alias**         | `{field_value}`               | `nginx`, `redis`, `postgres` |
| **ILM Policy**    | `{alias}-ilm-policy`          | `nginx-ilm-policy`           |
| **Template**      | `logstash-{alias}`            | `logstash-nginx`             |
| **Index**         | `{alias}-{YYYY.MM.DD}-000001` | `nginx-2025.11.17-000001`    |
| **Next Rollover** | `{alias}-{YYYY.MM.DD}-000002` | `nginx-2025.11.17-000002`    |

---

## Configuration Examples

### ✅ Correct - Dynamic ILM (Recommended)

```ruby
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]

    # Enable ILM
    ilm_enabled => true

    # Dynamic alias based on container name
    ilm_rollover_alias => "%{[container_name]}"

    # Policy settings (applied to all auto-created policies)
    ilm_rollover_max_age => "1d"
    ilm_rollover_max_size => "50gb"
    ilm_delete_min_age => "30d"
    ilm_delete_enabled => true

    # ⚠️ Do NOT specify ilm_policy - it's auto-generated!
  }
}
```

**Result:**

- Event with `container_name = "uibackend-betrisks"`:

  - Policy: `uibackend-betrisks-ilm-policy`
  - Template: `logstash-uibackend-betrisks`
  - Index: `uibackend-betrisks-2025.11.17-000001`

- Event with `container_name = "e3fcontentadapterbg"`:
  - Policy: `e3fcontentadapterbg-ilm-policy`
  - Template: `logstash-e3fcontentadapterbg`
  - Index: `e3fcontentadapterbg-2025.11.17-000001`

---

### ✅ Correct - Static ILM (Single Policy for All Logs)

```ruby
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]

    ilm_enabled => true
    ilm_rollover_alias => "logs"               # Fixed alias
    ilm_policy => "my-custom-policy"           # ✅ This WILL be used
    ilm_rollover_max_age => "7d"
  }
}
```

**Result:**

- All logs go to same policy: `my-custom-policy`
- All logs go to same index pattern: `logs-2025.11.17-000001`

---

### ❌ Incorrect - Mixed Configuration (Common Mistake)

```ruby
output {
  elasticsearch {
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"  # Dynamic
    ilm_policy => "k8s-logs-policy"              # ❌ IGNORED!
  }
}
```

**Problem:** You think all containers will use `k8s-logs-policy`, but they **won't**! Each container gets its own auto-generated policy like `nginx-ilm-policy`, `redis-ilm-policy`, etc.

---

## Policy Settings - How They Work

The `ilm_rollover_*` and `ilm_delete_*` settings define the **behavior** of auto-created policies:

```ruby
ilm_rollover_max_age => "1d"        # Rollover after 1 day
ilm_rollover_max_size => "50gb"     # OR after 50GB
ilm_rollover_max_docs => 10000000   # OR after 10M docs
ilm_delete_min_age => "30d"         # Delete indices older than 30 days
ilm_delete_enabled => true          # Enable automatic deletion
```

These settings are **embedded into every auto-created policy**. You can verify by checking the policy in Elasticsearch:

```bash
curl -X GET "http://elasticsearch:9200/_ilm/policy/nginx-ilm-policy?pretty"
```

You'll see:

```json
{
  "nginx-ilm-policy": {
    "policy": {
      "phases": {
        "hot": {
          "actions": {
            "rollover": {
              "max_age": "1d",
              "max_size": "50gb"
            }
          }
        },
        "delete": {
          "min_age": "30d",
          "actions": {
            "delete": {}
          }
        }
      }
    }
  }
}
```

---

## Multi-Field Dynamic Aliases

You can combine multiple fields:

```ruby
ilm_rollover_alias => "%{[kubernetes][namespace]}-%{[container_name]}"
```

**Example event:**

```json
{
  "kubernetes": { "namespace": "production" },
  "container_name": "nginx"
}
```

**Result:**

- Alias: `production-nginx`
- Policy: `production-nginx-ilm-policy`
- Template: `logstash-production-nginx`
- Index: `production-nginx-2025.11.17-000001`

---

## Verification Commands

### 1. Check Auto-Created Policies

```bash
curl "http://elasticsearch:9200/_ilm/policy?pretty"
```

Expected output:

```json
{
  "nginx-ilm-policy": { ... },
  "redis-ilm-policy": { ... },
  "postgres-ilm-policy": { ... }
}
```

### 2. Check Auto-Created Templates

```bash
curl "http://elasticsearch:9200/_index_template?pretty"
```

Expected output:

```json
{
  "index_templates": [
    {"name": "logstash-nginx", "index_template": {...}},
    {"name": "logstash-redis", "index_template": {...}},
    {"name": "logstash-postgres", "index_template": {...}}
  ]
}
```

### 3. Check Auto-Created Indices

```bash
curl "http://elasticsearch:9200/_cat/indices?v&h=index,health,status,docs.count"
```

Expected output:

```
index                           health status docs.count
nginx-2025.11.17-000001        green  open   12345
redis-2025.11.17-000001        green  open   6789
postgres-2025.11.17-000001     green  open   3456
```

### 4. Check Aliases

```bash
curl "http://elasticsearch:9200/_cat/aliases?v&h=alias,index"
```

Expected output:

```
alias     index
nginx     nginx-2025.11.17-000001
redis     redis-2025.11.17-000001
postgres  postgres-2025.11.17-000001
```

---

## Common Questions

### Q: Can I manually create a policy and have containers use it?

**A:** No, not in dynamic mode. If you use `ilm_rollover_alias => "%{[field]}"`, policies are **always auto-created**. Use static mode if you want manual control.

### Q: What if I want different rollover settings per container?

**A:** Currently not supported. All auto-created policies use the same settings from your Logstash config. You would need to manually edit policies in Elasticsearch after they're created.

### Q: Can I pre-create templates/policies before Logstash starts?

**A:** Yes, but Logstash will **overwrite** them if they don't match the expected format. The auto-creation is idempotent - it only creates if missing.

### Q: What happens if `container_name` is missing from an event?

**A:** The event will be **dropped** or sent to a fallback index. You should add a filter to ensure the field exists:

```ruby
filter {
  if ![container_name] {
    mutate {
      add_field => { "container_name" => "unknown" }
    }
  }
}
```

### Q: How do I disable dynamic ILM?

**A:** Just use a static `ilm_rollover_alias` without sprintf:

```ruby
ilm_rollover_alias => "logs"  # No %{...} = static mode
ilm_policy => "my-policy"     # This will be used
```

---

## Troubleshooting

### Problem: Policies aren't being created

**Check Logstash logs for:**

```
[WARN] Failed to create ILM policy
```

**Solution:** Ensure Elasticsearch user has `manage_ilm` privilege.

### Problem: Indices aren't rolling over

**Verify policy exists:**

```bash
curl "http://elasticsearch:9200/_ilm/policy/{alias}-ilm-policy?pretty"
```

**Verify is_write_index is true:**

```bash
curl "http://elasticsearch:9200/{alias}?pretty"
```

**Manually trigger rollover (testing):**

```bash
curl -X POST "http://elasticsearch:9200/{alias}/_rollover?pretty"
```

### Problem: Template conflicts (priority errors)

**Symptoms:** Logs show "template priority conflict" errors.

**Solution:** The plugin automatically detects child templates and skips parent template creation. Check:

```bash
curl "http://elasticsearch:9200/_index_template?pretty" | grep -A5 "uibackend"
```

If you see both `uibackend-*` and `uibackend-betrisks-*` templates with same priority, the plugin will skip the parent.

---

## Summary

✅ **DO:**

- Use `ilm_rollover_alias => "%{[field]}"` for dynamic ILM
- Configure `ilm_rollover_max_age`, `ilm_delete_min_age`, etc.
- Let the plugin auto-create policies, templates, and indices
- Use filters to ensure dynamic fields always exist

❌ **DON'T:**

- Specify `ilm_policy` when using dynamic aliases (it's ignored)
- Manually create policies/templates (plugin will overwrite)
- Assume you can mix static and dynamic modes

---

## Code Reference

The dynamic policy name is generated here:
**File:** `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`
**Line:** 22

```ruby
policy_name = "#{alias_name}-ilm-policy"
```

This is **hardcoded** and cannot be customized via config.
