# Edit #1.5 Dynamic Per-Container Template Creation - Complete Solution

## 🎯 Problem Statement

You need **one ILM template per container** to avoid field mapping conflicts, but want to use a **single shared ILM policy** (`common-ilm-policy`) and **dynamic rollover aliases** based on `%{[container_name]}`.

## ✅ Solution Implemented

The plugin now **automatically creates one template per container** when the first event for that container arrives.

### What Changed:

1. **New Module: `DynamicTemplateManager`**

   - Tracks which templates have been created (thread-safe cache)
   - Creates templates on-the-fly per container
   - Extracts base name from rollover indices (e.g., `nginx-000001` → `nginx`)

2. **Modified: `template_manager.rb`**

   - Skips static template creation during initialization if using dynamic aliases
   - Logs that templates will be created per-container automatically

3. **Modified: `elasticsearch.rb`**
   - Includes the `DynamicTemplateManager` module
   - Initializes template cache during registration
   - Calls `maybe_create_dynamic_template()` for each event with dynamic ILM

## 📋 How It Works

### Initialization Phase:

```
Logstash starts
  ↓
Register phase: Detects dynamic alias `%{[container_name]}`
  ↓
Skips creating static template
  ↓
Logs: "Templates will be created automatically per container on first event"
  ↓
Initializes empty template cache
```

### Runtime Phase (Per Event):

```
Event arrives with container_name = "nginx"
  ↓
Index resolved to: "nginx-000001"
  ↓
Check: Has template "logstash-nginx" been created? NO
  ↓
Create template:
  - Name: "logstash-nginx"
  - Pattern: "nginx-*"
  - ILM Policy: "common-ilm-policy"
  ↓
Cache: Mark "nginx" as created
  ↓
Index the event
```

```
Next event with container_name = "nginx"
  ↓
Index resolved to: "nginx-000001"
  ↓
Check: Has template "logstash-nginx" been created? YES
  ↓
Skip template creation (already exists)
  ↓
Index the event
```

```
Event arrives with container_name = "app1"
  ↓
Index resolved to: "app1-000001"
  ↓
Check: Has template "logstash-app1" been created? NO
  ↓
Create template:
  - Name: "logstash-app1"
  - Pattern: "app1-*"
  - ILM Policy: "common-ilm-policy"
  ↓
Cache: Mark "app1" as created
  ↓
Index the event
```

## 🔧 Configuration

Your Logstash output configuration remains simple:

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "password"
    ssl_enabled => false              # ✅ Changed from 'ssl'
    ecs_compatibility => "disabled"

    ilm_enabled => true
    ilm_policy => "common-ilm-policy"          # ✅ Single shared policy
    ilm_rollover_alias => "%{[container_name]}" # ✅ Dynamic per container
  }
}
```

## 📊 Result

### Templates Created Automatically:

- `logstash-nginx` with pattern `nginx-*` and ILM policy `common-ilm-policy`
- `logstash-app1` with pattern `app1-*` and ILM policy `common-ilm-policy`
- `logstash-dotcms` with pattern `dotcms-*` and ILM policy `common-ilm-policy`
- ... one per unique container

### Indices Created:

- `nginx-000001`, `nginx-000002`, ...
- `app1-000001`, `app1-000002`, ...
- `dotcms-000001`, `dotcms-000002`, ...

### Benefits:

✅ **No field conflicts** - Each container has its own template  
✅ **Shared ILM policy** - All use `common-ilm-policy`  
✅ **Automatic** - No manual template creation needed  
✅ **Efficient** - Template created only once per container  
✅ **Thread-safe** - Concurrent events handled properly

## 🚀 Deployment Steps

1. **Build the Docker image:**

   ```bash
   cd /c/Users/jithsungh.v/logstash-output-elasticsearch
   docker build -t your-registry/logstash-custom:8.4.0 .
   ```

2. **Push to your registry:**

   ```bash
   docker push your-registry/logstash-custom:8.4.0
   ```

3. **Update Kubernetes StatefulSet:**

   ```bash
   kubectl set image statefulset/logstash-logstash \
     logstash=your-registry/logstash-custom:8.4.0 \
     -n elastic-search
   ```

4. **Update ConfigMap with corrected config:**

   ```bash
   kubectl edit configmap logstash-logstash-pipeline -n elastic-search
   # Change: ssl => false  TO  ssl_enabled => false
   ```

5. **Verify:**

   ```bash
   # Watch logs
   kubectl logs -f logstash-logstash-0 -n elastic-search

   # Check templates in Elasticsearch
   kubectl exec -it <es-pod> -n elastic-search -- \
     curl "localhost:9200/_cat/templates/logstash-*?v"
   ```

## 🔍 Verification

### Check Logstash Logs:

```
[INFO] Skipping static template installation for dynamic ILM rollover alias.
       Templates will be created automatically per container on first event.
[INFO] Created dynamic template for index pattern
       template_name=logstash-nginx, index_pattern=nginx-*, ilm_policy=common-ilm-policy
[INFO] Created dynamic template for index pattern
       template_name=logstash-app1, index_pattern=app1-*, ilm_policy=common-ilm-policy
```

### Check Elasticsearch Templates:

```bash
GET _cat/templates/logstash-*?v

# Expected output:
name              index_patterns order version
logstash-nginx    [nginx-*]      1
logstash-app1     [app1-*]       1
logstash-dotcms   [dotcms-*]     1
```

### Check Template Details:

```bash
GET _index_template/logstash-nginx

# Expected response:
{
  "index_patterns": ["nginx-*"],
  "template": {
    "settings": {
      "index.lifecycle.name": "common-ilm-policy"
    }
  }
}
```

## 🎉 Summary

Your plugin now:

1. ✅ Creates **one template per container** automatically
2. ✅ Attaches your **shared ILM policy** to each template
3. ✅ Handles **dynamic rollover aliases** correctly
4. ✅ Avoids **field mapping conflicts**
5. ✅ Works exactly like your old static config, but dynamically!

No manual template creation needed - it all happens automatically on first event per container! 🚀
