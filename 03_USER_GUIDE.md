# Dynamic ILM User Guide

## Overview

This guide explains how to use the Logstash Elasticsearch output plugin with **Dynamic Index Lifecycle Management (ILM)** capabilities. This feature automatically creates and manages ILM policies, index templates, and rollover indices per container/application without manual configuration.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [How It Works](#how-it-works)
3. [Configuration Reference](#configuration-reference)
4. [Common Use Cases](#common-use-cases)
5. [Customizing ILM Policies](#customizing-ilm-policies)
6. [Monitoring and Troubleshooting](#monitoring-and-troubleshooting)
7. [Best Practices](#best-practices)
8. [FAQ](#faq)

---

## Quick Start

### Minimal Configuration

The simplest configuration for dynamic ILM:

```ruby
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"

    # Enable dynamic ILM
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
  }
}
```

**What this does:**

- Automatically creates one ILM policy per container
- Uses default settings: rollover daily, delete after 7 days
- Creates index templates and rollover indices automatically
- No manual Elasticsearch configuration required

### Prerequisites

Before using dynamic ILM, ensure:

1. **Log events contain a container identifier field**

   ```json
   {
     "message": "Application started",
     "container_name": "betplacement",
     "timestamp": "2025-11-15T10:30:00Z"
   }
   ```

2. **Elasticsearch user has required permissions**

   - `manage_ilm` - Create and manage ILM policies
   - `manage_index_templates` - Create index templates
   - `create_index` - Create rollover indices
   - `write` - Index documents

3. **Elasticsearch version 7.x or higher**
   - ILM requires Elasticsearch 7.0+

---

## How It Works

### Automatic Resource Creation

When the first log event from a new container arrives:

```
┌─────────────────┐
│ Log Event       │
│ container_name: │──────┐
│   "nginx"       │      │
└─────────────────┘      │
                         ▼
              ┌──────────────────────┐
              │ Dynamic ILM Manager  │
              └──────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    ┌────────┐    ┌──────────┐    ┌────────────┐
    │ Policy │    │ Template │    │   Index    │
    │ nginx- │    │logstash- │    │nginx-2025. │
    │  ilm-  │    │  nginx   │    │11.15-000001│
    │ policy │    │          │    │            │
    └────────┘    └──────────┘    └────────────┘
```

**Created Resources:**

| Resource Type  | Name Pattern                | Example                   |
| -------------- | --------------------------- | ------------------------- |
| ILM Policy     | `{container}-ilm-policy`    | `nginx-ilm-policy`        |
| Index Template | `logstash-{container}`      | `logstash-nginx`          |
| Rollover Index | `{container}-{date}-000001` | `nginx-2025.11.15-000001` |
| Write Alias    | `{container}`               | `nginx`                   |

### Caching and Performance

After the first event:

- Resources are **cached in memory** (thread-safe ConcurrentHashMap)
- Subsequent events skip resource creation entirely
- **Zero overhead** for ongoing event processing
- Cache persists for the lifetime of the Logstash process

### Lifecycle Example

For container "betplacement":

```
Day 1 (Nov 15):
├─ First event arrives
├─ Creates betplacement-ilm-policy
├─ Creates logstash-betplacement template
├─ Creates betplacement-2025.11.15-000001 index
└─ Write alias: betplacement → betplacement-2025.11.15-000001

Day 2 (Nov 16, 00:00):
├─ Max age reached (1 day)
├─ ILM automatically creates betplacement-2025.11.16-000002
└─ Write alias: betplacement → betplacement-2025.11.16-000002

Day 9 (Nov 23):
├─ betplacement-2025.11.15-000001 reaches delete age (7 days)
└─ ILM automatically deletes old index
```

---

## Configuration Reference

### Required Settings

```ruby
output {
  elasticsearch {
    # Basic Elasticsearch connection
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"

    # Enable dynamic ILM (required)
    ilm_enabled => true

    # Dynamic alias pattern (required)
    ilm_rollover_alias => "%{[container_name]}"
  }
}
```

### ILM Policy Settings

Control the default ILM policy behavior for all containers:

```ruby
output {
  elasticsearch {
    # ... connection settings ...

    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"

    # Rollover conditions (any condition triggers rollover)
    ilm_rollover_max_age => "1d"      # Rollover after 1 day (default)
    ilm_rollover_max_size => "50gb"   # Rollover at 50GB (optional)
    ilm_rollover_max_docs => 10000000 # Rollover at 10M docs (optional)

    # Index priority in hot tier
    ilm_hot_priority => 100           # Higher = higher priority (default: 50)

    # Deletion settings
    ilm_delete_enabled => true        # Enable automatic deletion (default)
    ilm_delete_min_age => "30d"       # Delete after 30 days (default: 7d)
  }
}
```

### Configuration Options Explained

| Option                  | Type    | Default | Description                                                                |
| ----------------------- | ------- | ------- | -------------------------------------------------------------------------- |
| `ilm_enabled`           | boolean | false   | **Must be true** for dynamic ILM                                           |
| `ilm_rollover_alias`    | string  | -       | **Required:** Pattern with field placeholder (e.g., `%{[container_name]}`) |
| `ilm_rollover_max_age`  | string  | "1d"    | Rollover after this age (e.g., "1d", "12h", "7d")                          |
| `ilm_rollover_max_size` | string  | -       | Rollover at this size (e.g., "50gb", "100gb")                              |
| `ilm_rollover_max_docs` | number  | -       | Rollover at this document count (e.g., 10000000)                           |
| `ilm_hot_priority`      | number  | 50      | Index priority in hot tier (0-1000)                                        |
| `ilm_delete_enabled`    | boolean | true    | Enable automatic deletion of old indices                                   |
| `ilm_delete_min_age`    | string  | "7d"    | Delete indices after this age (e.g., "7d", "30d", "90d")                   |

### Field Extraction

The `ilm_rollover_alias` uses Logstash field interpolation:

```ruby
# Extract from top-level field
ilm_rollover_alias => "%{[container_name]}"

# Extract from nested field
ilm_rollover_alias => "%{[kubernetes][container][name]}"

# Extract from metadata
ilm_rollover_alias => "%{[@metadata][application]}"
```

**Example log event:**

```json
{
  "message": "Request processed",
  "kubernetes": {
    "container": {
      "name": "api-gateway"
    }
  }
}
```

**Configuration:**

```ruby
ilm_rollover_alias => "%{[kubernetes][container][name]}"
```

**Result:** Creates `api-gateway-ilm-policy`, `logstash-api-gateway`, `api-gateway-2025.11.15-000001`

---

## Common Use Cases

### Use Case 1: Multi-Tenant Application

**Scenario:** SaaS platform with separate indices per customer

```ruby
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"

    ilm_enabled => true
    ilm_rollover_alias => "customer-%{[customer_id]}"

    # Long retention for compliance
    ilm_rollover_max_age => "30d"
    ilm_delete_min_age => "365d"
  }
}
```

**Result:** Creates `customer-123-ilm-policy`, `customer-456-ilm-policy`, etc.

### Use Case 2: High-Volume Service

**Scenario:** API gateway generating 100GB logs per day

```ruby
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"

    ilm_enabled => true
    ilm_rollover_alias => "%{[service_name]}"

    # Rollover every 6 hours OR at 25GB
    ilm_rollover_max_age => "6h"
    ilm_rollover_max_size => "25gb"

    # High priority for critical service
    ilm_hot_priority => 100

    # Short retention
    ilm_delete_min_age => "3d"
  }
}
```

### Use Case 3: Microservices Architecture

**Scenario:** 50+ microservices in Kubernetes

```ruby
input {
  kafka {
    bootstrap_servers => "kafka:9092"
    topics => ["logs"]
    codec => json
  }
}

filter {
  # Extract container name from log
  mutate {
    add_field => { "container_name" => "%{[kubernetes][container][name]}" }
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"

    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"

    # Standard settings for all microservices
    ilm_rollover_max_age => "1d"
    ilm_rollover_max_size => "10gb"
    ilm_delete_min_age => "7d"
  }
}
```

**Result:** Each microservice automatically gets its own ILM policy and indices

### Use Case 4: Environment Separation

**Scenario:** Separate policies for dev/staging/prod

```ruby
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"

    ilm_enabled => true
    ilm_rollover_alias => "%{[environment]}-%{[app_name]}"

    # Adjust retention by environment
    ilm_delete_min_age => "%{[retention_days]}d"
  }
}
```

**Example events:**

```json
{"app_name": "api", "environment": "dev", "retention_days": 3}
{"app_name": "api", "environment": "prod", "retention_days": 90}
```

**Result:** Creates `dev-api-ilm-policy` (3 days) and `prod-api-ilm-policy` (90 days)

---

## Customizing ILM Policies

### When to Customize

You may want to customize ILM policies for specific containers when:

- **High-volume services** need more frequent rollover
- **Critical services** need longer retention
- **Low-priority services** can have shorter retention
- **Compliance requirements** dictate specific retention periods

### How to Customize in Kibana

1. **Open Kibana Dev Tools**

   - Navigate to: Management → Dev Tools

2. **View existing policy**

   ```json
   GET _ilm/policy/nginx-ilm-policy
   ```

3. **Update policy with custom settings**

   ```json
   PUT _ilm/policy/nginx-ilm-policy
   {
     "policy": {
       "phases": {
         "hot": {
           "min_age": "0ms",
           "actions": {
             "rollover": {
               "max_age": "6h",        // Custom: rollover every 6 hours
               "max_size": "25gb"      // Custom: rollover at 25GB
             },
             "set_priority": {
               "priority": 100         // Custom: high priority
             }
           }
         },
         "delete": {
           "min_age": "30d",           // Custom: keep for 30 days
           "actions": {
             "delete": {}
           }
         }
       }
     }
   }
   ```

4. **Verify changes**
   ```json
   GET _ilm/policy/nginx-ilm-policy
   ```

### Important Notes

✅ **Your customizations are preserved** - Logstash will never overwrite an existing policy

⚠️ **Changes apply to new indices only** - Existing indices continue with their original policy version

💡 **Default settings still apply to new containers** - Only the customized policy is affected

---

## Monitoring and Troubleshooting

### Verifying Resource Creation

**Check if ILM policy exists:**

```bash
GET _ilm/policy/nginx-ilm-policy
```

**Check if index template exists:**

```bash
GET _index_template/logstash-nginx
```

**Check if rollover alias exists:**

```bash
GET nginx
```

**List all indices for a container:**

```bash
GET nginx-*/_settings
```

### Logstash Logs

**Successful resource creation:**

```
[INFO] Creating dynamic ILM policy: nginx-ilm-policy
[INFO] Creating dynamic index template: logstash-nginx
[INFO] Creating rollover index for alias: nginx
```

**Resource already exists (cached):**

```
[DEBUG] Skipping dynamic template creation for 'nginx' (already cached)
```

**Error during creation:**

```
[WARN] Failed to create ILM policy nginx-ilm-policy:
       security_exception: action [cluster:admin/ilm/put] is unauthorized
```

### Common Issues

#### Issue: "Security exception: action unauthorized"

**Cause:** Elasticsearch user lacks required permissions

**Solution:** Grant permissions to Logstash user:

```json
POST /_security/role/logstash_dynamic_ilm
{
  "cluster": ["manage_ilm", "manage_index_templates"],
  "indices": [
    {
      "names": ["*"],
      "privileges": ["create_index", "write", "manage"]
    }
  ]
}

POST /_security/user/logstash/_password
{
  "password": "your-password"
}

PUT /_security/user/logstash
{
  "roles": ["logstash_dynamic_ilm"]
}
```

#### Issue: "Field [container_name] not found"

**Cause:** Log event missing the container name field

**Solution:** Add filter to extract container name:

```ruby
filter {
  if ![container_name] {
    mutate {
      add_field => { "container_name" => "unknown" }
    }
  }
}
```

#### Issue: "Invalid index name"

**Cause:** Container name contains invalid characters

**Solution:** Sanitize container name:

```ruby
filter {
  mutate {
    lowercase => ["container_name"]
    gsub => ["container_name", "[^a-z0-9-]", "-"]
  }
}
```

### Health Checks

**Check ILM status:**

```bash
GET _ilm/status
```

**Check index ILM explain:**

```bash
GET nginx-*/_ilm/explain
```

**Check alias status:**

```bash
GET _alias/nginx
```

---

## Best Practices

### 1. Use Meaningful Container Names

✅ **Good:**

```
payment-service
user-authentication
order-processing
```

❌ **Bad:**

```
pod-1234567890
container-xyz
temp-service
```

### 2. Configure Appropriate Retention

Consider your use case:

| Use Case                    | Retention  | Rollover             |
| --------------------------- | ---------- | -------------------- |
| Development logs            | 3-7 days   | Daily                |
| Production application logs | 30-90 days | Daily or size-based  |
| Audit logs (compliance)     | 365+ days  | Daily                |
| Debug/trace logs            | 1-3 days   | Hourly or size-based |

### 3. Monitor Index Sizes

Use Kibana or Elasticsearch APIs:

```bash
GET _cat/indices/nginx-*?v&s=index:desc&h=index,docs.count,store.size
```

### 4. Test in Non-Production First

1. Deploy to development/staging environment
2. Verify resource creation
3. Test customization workflow
4. Monitor for errors
5. Roll out to production

### 5. Document Custom Policies

Keep a record of customized policies:

```markdown
# ILM Policy Customizations

## nginx-ilm-policy

- **Reason:** High volume, frequent rollover needed
- **Settings:** Rollover every 6h, keep 14 days
- **Modified by:** ops-team
- **Date:** 2025-11-15

## payment-service-ilm-policy

- **Reason:** Compliance requirement
- **Settings:** Daily rollover, keep 365 days
- **Modified by:** compliance-team
- **Date:** 2025-11-10
```

### 6. Use Environment Variables

Don't hardcode credentials:

```ruby
output {
  elasticsearch {
    hosts => ["${ELASTICSEARCH_HOSTS}"]
    user => "${ELASTICSEARCH_USER}"
    password => "${ELASTICSEARCH_PASSWORD}"

    ilm_rollover_max_age => "${ILM_ROLLOVER_AGE:1d}"
    ilm_delete_min_age => "${ILM_DELETE_AGE:7d}"
  }
}
```

### 7. Set Up Alerts

Configure Elasticsearch Watcher or external monitoring:

- Alert when index size exceeds threshold
- Alert when deletion phase starts
- Alert on ILM policy execution failures
- Alert on Logstash indexing errors

---

## FAQ

### Q: What happens if I restart Logstash?

**A:** The in-memory cache is cleared, but resources in Elasticsearch persist. The first event from each container will trigger a check (which will find existing resources and skip creation). No duplicate resources are created.

### Q: Can I use static and dynamic ILM together?

**A:** No. The `ilm_rollover_alias` must be either static (no placeholders) or dynamic (with placeholders). Choose one approach per Logstash output.

### Q: What if two containers have the same name?

**A:** They will share the same ILM policy, template, and indices. This is usually intentional (e.g., replicas of the same service). If you need separation, include additional fields in the alias pattern:

```ruby
ilm_rollover_alias => "%{[namespace]}-%{[container_name]}"
```

### Q: How do I delete a container's resources?

**A:** Manually in Kibana:

```bash
# Delete policy
DELETE _ilm/policy/nginx-ilm-policy

# Delete template
DELETE _index_template/logstash-nginx

# Delete indices
DELETE nginx-*

# Delete alias
DELETE _alias/nginx
```

### Q: Can I change the default settings after deployment?

**A:** Yes, but changes only affect **new containers**. Existing policies are never updated. To update existing policies, customize them manually in Kibana.

### Q: What's the performance impact?

**A:** Minimal. Resource creation happens once per container. After that, there's zero overhead. The caching mechanism ensures no redundant API calls.

### Q: Does this work with Elasticsearch data streams?

**A:** No. This solution uses traditional rollover indices and write aliases, not data streams. Data streams have their own ILM integration.

### Q: What Elasticsearch version is required?

**A:** Elasticsearch 7.x or higher (ILM was introduced in 7.0).

### Q: Can I disable dynamic ILM for specific events?

**A:** Yes, use conditionals:

```ruby
output {
  if [container_name] == "special-service" {
    elasticsearch {
      hosts => ["http://elasticsearch:9200"]
      index => "special-service-%{+YYYY.MM.dd}"
      # No ILM
    }
  } else {
    elasticsearch {
      hosts => ["http://elasticsearch:9200"]
      ilm_enabled => true
      ilm_rollover_alias => "%{[container_name]}"
    }
  }
}
```

---

## Support and Resources

### Documentation

- [Elasticsearch ILM Documentation](https://www.elastic.co/guide/en/elasticsearch/reference/current/index-lifecycle-management.html)
- [Logstash Elasticsearch Output Plugin](https://www.elastic.co/guide/en/logstash/current/plugins-outputs-elasticsearch.html)

### Examples

- See `examples/complete_dynamic_ilm.conf` in this repository
- See `BUILD_AND_DEPLOY.md` for deployment examples

### Getting Help

1. Check Logstash logs for error messages
2. Verify Elasticsearch permissions
3. Test configuration with small dataset
4. Review this user guide's troubleshooting section
5. Check Elasticsearch cluster health

---

## Summary

Dynamic ILM provides:

✅ **Zero-touch operations** - New services start logging immediately
✅ **Per-container customization** - Tailor policies to specific needs
✅ **Scalability** - Supports hundreds of containers effortlessly
✅ **Flexibility** - Override defaults when necessary
✅ **Production-ready** - Battle-tested in high-volume environments

With proper configuration and monitoring, dynamic ILM eliminates manual Elasticsearch resource management while maintaining full control over ILM policies.
