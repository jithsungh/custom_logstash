# 🚀 Next Steps - What To Do Now

## ✅ Solution Complete!

Your plugin now automatically creates **one template per container** while using a **single shared ILM policy**.

---

## 📋 What To Do Next

### 1️⃣ Build the Docker Image

```bash
cd /c/Users/jithsungh.v/logstash-output-elasticsearch

# Build
docker build -t logstash-custom-elasticsearch-output:8.4.0-custom .

# Or use the build script (Windows)
./build-and-push.bat
```

### 2️⃣ Test Locally (Optional but Recommended)

```bash
# Start test environment with Elasticsearch + Logstash
docker-compose -f docker-compose.test.yml up --build

# Watch for log messages:
# - "Skipping static template installation for dynamic ILM rollover alias"
# - "Created dynamic template for index pattern"
```

### 3️⃣ Tag for Your Registry

```bash
# Azure Container Registry example
docker tag logstash-custom-elasticsearch-output:8.4.0-custom \
  your-registry.azurecr.io/logstash-custom:8.4.0-custom

# Docker Hub example
docker tag logstash-custom-elasticsearch-output:8.4.0-custom \
  your-username/logstash-custom:8.4.0-custom
```

### 4️⃣ Push to Registry

```bash
# Login to ACR
az acr login --name your-registry

# Push
docker push your-registry.azurecr.io/logstash-custom:8.4.0-custom
```

### 5️⃣ Update Kubernetes ConfigMap

**CRITICAL:** Change `ssl => false` to `ssl_enabled => false`

```bash
# Edit the pipeline config
kubectl edit configmap logstash-logstash-pipeline -n elastic-search
```

Find this section:

```ruby
output {
  elasticsearch {
    # ... other settings ...
    ssl => false  # ❌ OLD - Will cause error
```

Change to:

```ruby
output {
  elasticsearch {
    # ... other settings ...
    ssl_enabled => false  # ✅ CORRECT
```

Save and exit.

### 6️⃣ Deploy to Kubernetes

```bash
# Update the StatefulSet image
kubectl set image statefulset/logstash-logstash \
  logstash=your-registry.azurecr.io/logstash-custom:8.4.0-custom \
  -n elastic-search

# Watch the rollout
kubectl rollout status statefulset/logstash-logstash -n elastic-search

# Check logs
kubectl logs -f logstash-logstash-0 -n elastic-search
```

### 7️⃣ Verify Everything Works

```bash
# Check Logstash logs for success messages
kubectl logs logstash-logstash-0 -n elastic-search | grep -E "(template|ILM)"

# You should see:
# [INFO] Skipping static template installation for dynamic ILM rollover alias
# [INFO] Created dynamic template for index pattern template_name=logstash-nginx
# [INFO] Created dynamic template for index pattern template_name=logstash-app1
```

```bash
# Check templates in Elasticsearch
kubectl exec -it <elasticsearch-pod> -n elastic-search -- \
  curl "localhost:9200/_cat/templates/logstash-*?v"

# You should see:
# logstash-nginx    [nginx-*]    1
# logstash-app1     [app1-*]     1
# logstash-dotcms   [dotcms-*]   1
```

```bash
# Check indices
kubectl exec -it <elasticsearch-pod> -n elastic-search -- \
  curl "localhost:9200/_cat/indices?v&s=index"

# You should see:
# nginx-000001    ...
# app1-000001     ...
# dotcms-000001   ...
```

```bash
# Verify ILM policy is attached
kubectl exec -it <elasticsearch-pod> -n elastic-search -- \
  curl "localhost:9200/nginx-000001/_settings?pretty" | grep lifecycle

# You should see:
# "index.lifecycle.name": "common-ilm-policy"
```

---

## 🔍 Expected Log Messages

### During Startup:

```
[INFO] Skipping static template installation for dynamic ILM rollover alias.
       Templates will be created automatically per container on first event.
       ilm_rollover_alias=%{[container_name]}
```

### When First Event Arrives Per Container:

```
[INFO] Created dynamic template for index pattern
       template_name=logstash-nginx
       index_pattern=nginx-*
       ilm_policy=common-ilm-policy

[INFO] Created dynamic template for index pattern
       template_name=logstash-app1
       index_pattern=app1-*
       ilm_policy=common-ilm-policy
```

---

## ❌ Troubleshooting

### Problem: Logstash won't start

**Error:** `The setting 'ssl' in plugin 'elasticsearch' is obsolete`

**Solution:**

```bash
kubectl edit configmap logstash-logstash-pipeline -n elastic-search
# Change: ssl => false
# To: ssl_enabled => false
```

### Problem: No templates are being created

**Check:**

1. Are events arriving with `container_name` field?
2. Check logs for errors
3. Verify `ilm_enabled => true` is set
4. Verify `ilm_rollover_alias` contains `%{[container_name]}`

### Problem: Field mapping conflicts still happening

**Check:**

1. Are multiple containers using the same template?
2. Verify each container gets unique base name
3. Check template patterns: `GET _cat/templates/logstash-*?v`

---

## 📚 Documentation Files

- `COMPLETE_SOLUTION.md` - Full technical explanation
- `DYNAMIC_TEMPLATE_SOLUTION.md` - Detailed how-it-works
- `QUICK_DEPLOY.md` - Quick reference card
- `TEST_INSTRUCTIONS.md` - Testing guide

---

## 🎉 You're Done!

Once deployed, your plugin will:

- ✅ Automatically create one template per container
- ✅ Attach your shared `common-ilm-policy` to all templates
- ✅ Prevent field mapping conflicts
- ✅ Handle new containers automatically

**No manual work required!** 🚀
