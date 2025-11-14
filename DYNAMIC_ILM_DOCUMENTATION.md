# Edit #2 Dynamic ILM with Per-Container Policies

## 🎯 What This Feature Does

This modified Logstash Elasticsearch output plugin creates **separate ILM policies, templates, and indices for each container** automatically.

### For Each Unique Container:

When an event with `container_name: "nginx"` arrives, the plugin automatically creates:

1. **ILM Policy**: `nginx-ilm-policy`
2. **Index Template**: `logstash-nginx` (matches `nginx-*`)
3. **Rollover Alias**: `nginx` (writes to `nginx-000001`, `nginx-000002`, etc.)

## 📋 Configuration Options

### Required Settings

```ruby
ilm_enabled => true                        # Enable ILM
ilm_rollover_alias => "%{[container_name]}" # Dynamic alias using event field
```

### ILM Policy Customization (Optional)

All settings below apply to **every dynamically created policy**:

#### Hot Phase - Rollover Conditions

```ruby
# Rollover when index reaches 1 day old (default)
ilm_rollover_max_age => "1d"

# Optional: Rollover when index reaches size limit
ilm_rollover_max_size => "50gb"

# Optional: Rollover when index reaches document count
ilm_rollover_max_docs => 1000000
```

#### Hot Phase - Priority

```ruby
# Index priority for recovery (higher = recovered first)
# Default: 50
ilm_hot_priority => 100
```

#### Delete Phase

```ruby
# Delete indices after this age (default: 1d)
ilm_delete_min_age => "7d"

# Enable/disable automatic deletion (default: true)
ilm_delete_enabled => true
```

## 💡 Complete Example

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "password"
    ssl_enabled => false
    ecs_compatibility => "disabled"

    # Dynamic ILM configuration
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"

    # Policy defaults for ALL containers
    ilm_rollover_max_age => "1d"
    ilm_rollover_max_size => "50gb"
    ilm_delete_min_age => "7d"
    ilm_hot_priority => 50
    ilm_delete_enabled => true
  }
}
```

## 🔄 What Happens at Runtime

### First Event from Container "uibackend"

1. ✅ Plugin creates ILM policy `uibackend-ilm-policy` with the configured settings
2. ✅ Plugin creates index template `logstash-uibackend` matching `uibackend-*`
3. ✅ Plugin creates index `uibackend-000001` with write alias `uibackend`
4. ✅ Event is indexed to `uibackend-000001`

### Subsequent Events from "uibackend"

1. ✅ Plugin detects resources already exist (cached)
2. ✅ Event is indexed directly (no overhead)

### First Event from Container "app1"

1. ✅ Plugin creates ILM policy `app1-ilm-policy` with same settings
2. ✅ Plugin creates index template `logstash-app1` matching `app1-*`
3. ✅ Plugin creates index `app1-000001` with write alias `app1`
4. ✅ Event is indexed to `app1-000001`

## 🛠️ Manual Override in Kibana

### Scenario: Extend Retention for Audit Logs

If you want to keep `audit` container logs for 90 days instead of 7:

1. **After the first audit event**, the policy `audit-ilm-policy` is created
2. **Go to Kibana** → Management → Index Lifecycle Policies
3. **Edit** `audit-ilm-policy`
4. **Change** delete phase `min_age` from `7d` to `90d`
5. **Save** the policy

**The plugin will NEVER overwrite this policy!** Your manual changes are preserved.

### Scenario: Disable Deletion for Compliance Data

For `compliance` container that must never be deleted:

1. Edit `compliance-ilm-policy` in Kibana
2. Remove the entire `delete` phase
3. Save

## 📊 Policy Structure

Each dynamically created policy looks like this:

```json
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "set_priority": {
            "priority": 50
          },
          "rollover": {
            "max_age": "1d",
            "max_size": "50gb"
          }
        }
      },
      "delete": {
        "min_age": "7d",
        "actions": {
          "delete": {
            "delete_searchable_snapshot": true
          }
        }
      }
    }
  }
}
```

## 🔍 Verification

### Check Created Policies

```bash
curl -X GET "eck-es-http:9200/_ilm/policy?pretty"
```

You should see:

- `uibackend-ilm-policy`
- `app1-ilm-policy`
- `dotcms-ilm-policy`
- etc.

### Check Created Templates

```bash
curl -X GET "eck-es-http:9200/_index_template?pretty"
```

You should see:

- `logstash-uibackend`
- `logstash-app1`
- `logstash-dotcms`
- etc.

### Check Created Indices

```bash
curl -X GET "eck-es-http:9200/_cat/indices?v"
```

You should see:

- `uibackend-000001`, `uibackend-000002`, ...
- `app1-000001`, `app1-000002`, ...
- `dotcms-000001`, `dotcms-000002`, ...

## ⚠️ Important Notes

### One-Time Creation

- Policies are created **once** when the first event for a container arrives
- Subsequent events use the existing policy
- **Manual changes in Kibana are preserved** - the plugin never overwrites

### Naming Rules

Container names are normalized for Elasticsearch compatibility:

- Converted to lowercase
- Invalid characters replaced with `_`
- Leading/trailing hyphens removed

Example: `My-Service_v2` → `my-service_v2`

### Performance

- Very low overhead: template/policy creation happens once per container
- Subsequent events have no additional processing
- Thread-safe caching ensures no duplicate creations

## 🚀 Migration from Static ILM

### Before (Static Alias)

```ruby
ilm_rollover_alias => "logs"
ilm_policy => "my-policy"
```

All containers → same index → `logs-000001`, `logs-000002`

### After (Dynamic Alias)

```ruby
ilm_rollover_alias => "%{[container_name]}"
ilm_rollover_max_age => "1d"
ilm_delete_min_age => "7d"
```

Each container → separate index:

- nginx → `nginx-000001`, `nginx-000002`
- app1 → `app1-000001`, `app1-000002`

## 🐛 Troubleshooting

### Policy Not Created

**Check Logstash logs:**

```
kubectl logs -f logstash-logstash-0 -n elastic-search | grep "dynamic"
```

Look for:

```
[INFO] Created dynamic ILM policy {:policy_name=>"nginx-ilm-policy", :container=>"nginx"}
[INFO] Created dynamic template {:template_name=>"logstash-nginx", :index_pattern=>"nginx-*"}
```

### Permission Errors

Ensure the Elasticsearch user has these permissions:

- `manage_ilm` - to create ILM policies
- `manage_index_templates` - to create index templates
- `create_index` - to create indices

### Field Mapping Conflicts

This is why we create **separate templates per container**! Each container can have different field mappings without conflict.

## 📈 Best Practices

### 1. Set Reasonable Defaults

```ruby
ilm_rollover_max_age => "1d"      # Daily rollover
ilm_rollover_max_size => "50gb"   # Size limit for high-volume services
ilm_delete_min_age => "7d"        # Keep for 1 week by default
```

### 2. Customize High-Value Data

For critical services, manually increase retention in Kibana after the policy is created.

### 3. Monitor Disk Usage

```bash
curl -X GET "eck-es-http:9200/_cat/allocation?v"
```

### 4. Use Descriptive Container Names

Good: `api-gateway`, `payment-service`, `user-auth`
Bad: `app1`, `svc2`, `temp`

## 🎓 Advanced Usage

### Different Retention Per Environment

```ruby
filter {
  if [kubernetes][namespace] == "production" {
    mutate {
      add_field => { "retention" => "30d" }
    }
  } else {
    mutate {
      add_field => { "retention" => "7d" }
    }
  }
}

# Then manually adjust policies in Kibana based on container environment
```

### Custom Policy Names

The format `<container-name>-ilm-policy` is fixed in the code. To customize, modify:

```ruby
# In dynamic_template_manager.rb line 23
policy_name = "custom-prefix-#{base_name}-ilm"
```

## 📝 Summary

| Feature               | Value                                         |
| --------------------- | --------------------------------------------- |
| **Policies Created**  | One per unique container_name                 |
| **Templates Created** | One per unique container_name                 |
| **Indices Created**   | Separate rollover series per container        |
| **Configuration**     | Set defaults in Logstash, customize in Kibana |
| **Overhead**          | Minimal - one-time creation per container     |
| **Field Conflicts**   | Eliminated - each container has own template  |
| **Manual Changes**    | Preserved - never overwritten                 |

🎉 **You now have complete per-container ILM management with minimal configuration!**
