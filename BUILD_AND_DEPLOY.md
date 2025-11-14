# 🚀 READY TO BUILD AND DEPLOY

## ✅ Everything is Ready!

All code changes are complete. Here's exactly what to do:

## 📦 Step 1: Build the Docker Image

Open your terminal and run:

```bash
cd /c/Users/jithsungh.v/logstash-output-elasticsearch

# Option 1: Use the quick build script
./quick-build.bat

# Option 2: Build manually
docker build -t logstash-dynamic-ilm:8.4.0-custom .
```

This will:

- ✅ Install build dependencies (gcc, make, ruby-dev, dos2unix)
- ✅ Convert Windows line endings to Unix
- ✅ Build the gem with your modified code
- ✅ Install the plugin into Logstash
- ✅ Verify the installation

## 🧪 Step 2: Test Locally (Optional but Recommended)

```bash
docker-compose -f docker-compose.test.yml up
```

This starts Elasticsearch + your modified Logstash and runs test events.

## 📤 Step 3: Push to Your Registry

### For Azure Container Registry:

```bash
# Login
az acr login --name yourregistry

# Tag
docker tag logstash-dynamic-ilm:8.4.0-custom \
  yourregistry.azurecr.io/logstash-dynamic-ilm:8.4.0-custom

# Push
docker push yourregistry.azurecr.io/logstash-dynamic-ilm:8.4.0-custom
```

### For Docker Hub:

```bash
# Login
docker login

# Tag
docker tag logstash-dynamic-ilm:8.4.0-custom \
  yourusername/logstash-dynamic-ilm:8.4.0-custom

# Push
docker push yourusername/logstash-dynamic-ilm:8.4.0-custom
```

## ⚙️ Step 4: Update Your Logstash Config

Edit your Logstash pipeline configuration:

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "password"
    ssl_enabled => false  # ✅ CHANGED: was 'ssl'
    ecs_compatibility => "disabled"

    # ✅ Dynamic ILM Configuration
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"

    # ✅ NEW: Policy defaults for ALL containers
    ilm_rollover_max_age => "1d"       # Rollover daily
    ilm_rollover_max_size => "50gb"    # Optional size limit
    ilm_hot_priority => 50             # Recovery priority
    ilm_delete_min_age => "7d"         # Keep for 7 days
    ilm_delete_enabled => true         # Enable deletion
  }
}
```

Update the ConfigMap:

```bash
kubectl edit configmap logstash-logstash-pipeline -n elastic-search
```

## 🚀 Step 5: Deploy to Kubernetes

```bash
# Update the image
kubectl set image statefulset/logstash-logstash \
  logstash=yourregistry.azurecr.io/logstash-dynamic-ilm:8.4.0-custom \
  -n elastic-search

# Watch the rollout
kubectl rollout status statefulset/logstash-logstash -n elastic-search

# Check logs
kubectl logs -f logstash-logstash-0 -n elastic-search
```

## 🔍 Step 6: Verify It's Working

### Check Logstash Logs

```bash
kubectl logs -f logstash-logstash-0 -n elastic-search | grep -i "dynamic\|ilm"
```

You should see:

```
[INFO] Skipping template installation at startup for dynamic ILM rollover alias
[INFO] Using dynamic ILM rollover alias - aliases will be created per event
[INFO] Created dynamic ILM policy {:policy_name=>"nginx-ilm-policy", :container=>"nginx"}
[INFO] Created dynamic ILM resources for container {:container=>"nginx"}
```

### Check Elasticsearch

```bash
# Check ILM policies created
curl -X GET "eck-es-http:9200/_ilm/policy?pretty" | grep "ilm-policy"

# You should see:
# - nginx-ilm-policy
# - app1-ilm-policy
# - dotcms-ilm-policy
# etc.

# Check templates created
curl -X GET "eck-es-http:9200/_index_template?pretty" | grep "logstash-"

# You should see:
# - logstash-nginx
# - logstash-app1
# - logstash-dotcms
# etc.

# Check indices created
curl -X GET "eck-es-http:9200/_cat/indices?v" | grep "000001"

# You should see:
# nginx-000001
# app1-000001
# dotcms-000001
# etc.
```

## 🎯 What Happens Next

### For Each Unique Container:

When an event with `container_name: "nginx"` arrives:

1. ✅ Plugin creates ILM policy: `nginx-ilm-policy`

   ```json
   {
     "hot": {
       "rollover": { "max_age": "1d", "max_size": "50gb" }
     },
     "delete": {
       "min_age": "7d"
     }
   }
   ```

2. ✅ Plugin creates template: `logstash-nginx` (matches `nginx-*`)

3. ✅ Plugin creates index: `nginx-000001` with write alias `nginx`

4. ✅ Event is indexed

5. ✅ Resources are cached (no overhead for subsequent events)

## 🛠️ Customize Individual Policies in Kibana

After a container's policy is created, you can edit it:

1. Go to **Kibana** → **Management** → **Index Lifecycle Policies**
2. Find the policy (e.g., `nginx-ilm-policy`)
3. Click **Edit**
4. Modify settings (e.g., change delete age from 7d to 30d)
5. **Save**

**The plugin will NEVER overwrite your manual changes!**

## 📊 Example Output

After running for a while with containers: nginx, app1, dotcms

### ILM Policies

```
nginx-ilm-policy
app1-ilm-policy
dotcms-ilm-policy
```

### Templates

```
logstash-nginx → nginx-*
logstash-app1 → app1-*
logstash-dotcms → dotcms-*
```

### Indices

```
nginx-000001, nginx-000002, nginx-000003
app1-000001, app1-000002
dotcms-000001, dotcms-000002, dotcms-000003, dotcms-000004
```

## 🎉 That's It!

You now have:

- ✅ One ILM policy per container (dynamically created)
- ✅ One template per container (no field conflicts!)
- ✅ Separate rollover indices per container
- ✅ Configurable defaults in Logstash
- ✅ Manual customization preserved in Kibana

## 📚 Reference Documents

- **`COMPLETE_DYNAMIC_ILM_SOLUTION.md`** - Full technical details
- **`DYNAMIC_ILM_DOCUMENTATION.md`** - User guide
- **`examples/complete_dynamic_ilm.conf`** - Working config example

---

**Now run the build command and deploy!** 🚀
