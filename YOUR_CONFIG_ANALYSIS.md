# ✅ FIXED: Your Config Will Now Work (With Corrections)

## 🔧 **Your Original Config (Had Issues)**

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "password"
    ssl => false
    ecs_compatibility => "disabled"

    ilm_enabled => true
    ilm_policy => "common-ilm-policy"
    ilm_pattern => "000001"                    # ❌ WRONG - Missing date math
    ilm_rollover_alias => "%{[container_name]}" # ✅ Correct syntax
  }
}
```

---

## ✅ **CORRECTED Config (Custom ILM Implementation)**

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "password"
    ssl => false
    ecs_compatibility => "disabled"

    ilm_enabled => true
    ilm_policy => "common-ilm-policy"
    ilm_pattern => "{now/d}-000001"             # ✅ FIXED - Added date math
    ilm_rollover_alias => "%{[container_name]}" # ✅ Correct
  }
}
```

### **What I Fixed in the Code:**

1. ✅ **Added ILM policy settings** to dynamic alias creation
2. ✅ **Skip literal template** alias creation at startup
3. ✅ **Added validation** for missing fields (fallback to default)
4. ✅ **Proper logging** for troubleshooting

---

## 🎯 **BETTER Config (Data Streams - RECOMMENDED)**

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "password"
    ssl => false
    ecs_compatibility => "disabled"

    # ✅ USE DATA STREAMS - Much better approach
    data_stream => true
    data_stream_type => "logs"
    data_stream_dataset => "%{[container_name]}"
    data_stream_namespace => "default"
  }
}
```

**Then create your ILM policy in Elasticsearch:**

```bash
PUT _ilm/policy/logs
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_size": "50GB",
            "max_age": "7d",
            "max_docs": 100000000
          }
        }
      },
      "warm": {
        "min_age": "7d",
        "actions": {
          "shrink": {
            "number_of_shards": 1
          },
          "forcemerge": {
            "max_num_segments": 1
          }
        }
      },
      "cold": {
        "min_age": "30d",
        "actions": {
          "freeze": {}
        }
      },
      "delete": {
        "min_age": "90d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

---

## 📊 **Comparison: Your Approach vs Data Streams**

| Feature                   | Your Config (Fixed)    | Data Streams     |
| ------------------------- | ---------------------- | ---------------- |
| **Dynamic per container** | ✅ Yes                 | ✅ Yes           |
| **ILM policy attached**   | ✅ Yes (now fixed)     | ✅ Yes (native)  |
| **Automatic rollover**    | ✅ Yes (now fixed)     | ✅ Yes (native)  |
| **Custom policy**         | ✅ `common-ilm-policy` | ✅ `logs` policy |
| **Code complexity**       | 🟡 Medium (custom)     | 🟢 Low (native)  |
| **Official support**      | ❌ No (custom hack)    | ✅ Yes           |
| **Future upgrades**       | ⚠️ May break           | ✅ Stable        |
| **Maintenance**           | 🔴 High                | 🟢 None          |

---

## 🧪 **Testing Your Config**

### **1. Prepare Test Events**

Create `test_events.json`:

```json
{"message": "nginx started", "container_name": "nginx", "level": "info"}
{"message": "app processing", "container_name": "app", "level": "debug"}
{"message": "db query", "container_name": "postgres", "level": "info"}
{"message": "cache hit", "container_name": "redis", "level": "debug"}
```

### **2. Create ILM Policy in Elasticsearch**

```bash
curl -X PUT "eck-es-http:9200/_ilm/policy/common-ilm-policy?pretty" \
  -u elastic:password \
  -H 'Content-Type: application/json' \
  -d'{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_size": "50GB",
            "max_age": "7d"
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
}'
```

### **3. Run Logstash with Your Config**

```bash
bin/logstash -f your_config.conf < test_events.json
```

### **4. Verify ILM is Attached**

```bash
# Check indices created
curl -u elastic:password "eck-es-http:9200/_cat/indices?v"

# Should show:
# nginx-2025.11.14-000001
# app-2025.11.14-000001
# postgres-2025.11.14-000001
# redis-2025.11.14-000001
```

```bash
# Verify ILM policy is attached
curl -u elastic:password "eck-es-http:9200/nginx-*/_settings?pretty" | grep -A5 lifecycle

# Should show:
# "index" : {
#   "lifecycle" : {
#     "name" : "common-ilm-policy",
#     "rollover_alias" : "nginx"
#   }
# }
```

```bash
# Check ILM explain
curl -u elastic:password "eck-es-http:9200/nginx-*/_ilm/explain?pretty"

# Should show:
# {
#   "indices" : {
#     "nginx-2025.11.14-000001" : {
#       "managed" : true,              ← ✅ MANAGED!
#       "policy" : "common-ilm-policy", ← ✅ HAS YOUR POLICY!
#       "phase" : "hot",
#       "action" : "rollover"
#     }
#   }
# }
```

---

## 🚨 **Important Notes About Your Config**

### **1. Pattern Syntax Was Wrong**

You had:

```ruby
ilm_pattern => "000001"  # ❌ WRONG
```

Should be:

```ruby
ilm_pattern => "{now/d}-000001"  # ✅ CORRECT
```

**Why?**

- `{now/d}` is Elasticsearch date math for "current day"
- Creates indices like: `nginx-2025.11.14-000001`
- Without it: `nginx-000001` (no date separation)

### **2. Field Reference Syntax**

Your syntax `%{[container_name]}` is correct for nested fields:

- `%{container_name}` - Top-level field
- `%{[container_name]}` - Also works for top-level
- `%{[kubernetes][container][name]}` - Nested field

### **3. Fallback Behavior**

If event doesn't have `container_name` field:

- **Before fix:** Created alias literally as `%{[container_name]}` ❌
- **After fix:** Falls back to default alias (`ecs-logstash`) ✅
- Logs a warning so you can fix the pipeline

---

## ✅ **What NOW Works With Your Config**

### **Startup:**

```
[INFO] Using dynamic ILM rollover alias - aliases will be created per event
      template=%{[container_name]}
[INFO] ILM policy 'common-ilm-policy' already exists
```

### **Event Processing:**

```
Event: {container_name: "nginx", message: "..."}
  ↓
Resolved alias: "nginx"
  ↓
[INFO] Created ILM rollover alias with policy
      alias=nginx
      target=<nginx-{now/d}-000001>
      policy=common-ilm-policy
  ↓
Index created: nginx-2025.11.14-000001
  ├─ Alias: nginx (is_write_index: true)
  ├─ ILM policy: common-ilm-policy ✅
  └─ Rollover alias: nginx ✅
  ↓
Event written successfully ✅
```

### **Rollover (when conditions met):**

```
Day 1-7: nginx-2025.11.14-000001 (active, is_write_index: true)
         ↓ Reaches 50GB or 7 days
Day 8:   ILM triggers rollover
         ↓
         nginx-2025.11.14-000001 (readonly, is_write_index: false)
         nginx-2025.11.14-000002 (active, is_write_index: true) ✅
```

---

## 🎯 **Final Recommendation**

### **For Quick Testing:**

Use your corrected custom ILM config. It will work now.

### **For Production:**

Switch to Data Streams. Here's why:

1. **Officially Supported** - Won't break on upgrades
2. **Better Performance** - Optimized for this use case
3. **No Maintenance** - No custom code to maintain
4. **Feature Complete** - All ILM features work perfectly

---

## 📝 **Migration Path to Data Streams**

When you're ready:

```ruby
# Your current (working) config:
output {
  elasticsearch {
    ilm_enabled => true
    ilm_policy => "common-ilm-policy"
    ilm_pattern => "{now/d}-000001"
    ilm_rollover_alias => "%{[container_name]}"
  }
}

# Migrate to (better):
output {
  elasticsearch {
    data_stream => true
    data_stream_dataset => "%{[container_name]}"
  }
}
```

Same result, less complexity, officially supported.

---

## ✅ **Summary**

### **Your Config Status:**

| Before Fixes            | After Fixes             |
| ----------------------- | ----------------------- |
| ❌ ILM not attached     | ✅ ILM attached         |
| ❌ Wrong pattern        | ✅ Correct pattern      |
| ❌ No validation        | ✅ Field validation     |
| ❌ Indices grow forever | ✅ Rollover works       |
| ❌ Not production ready | ✅ Works (with caveats) |

### **What You Should Do:**

1. ✅ **Fix your pattern**: `ilm_pattern => "{now/d}-000001"`
2. ✅ **Test thoroughly** with the verification steps above
3. 🤔 **Consider Data Streams** for production

**Your config will work now, but Data Streams are still the better long-term solution.**

---

Ready to test? Need help with anything else?
