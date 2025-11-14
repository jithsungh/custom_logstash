# Quick Deploy Guide - Dynamic Per-Container Templates

## 📦 Build & Deploy

```bash
# 1. Build Docker image
cd /c/Users/jithsungh.v/logstash-output-elasticsearch
docker build -t your-registry.azurecr.io/logstash-custom:8.4.0 .

# 2. Push to registry
docker push your-registry.azurecr.io/logstash-custom:8.4.0

# 3. Update Kubernetes
kubectl set image statefulset/logstash-logstash \
  logstash=your-registry.azurecr.io/logstash-custom:8.4.0 \
  -n elastic-search

# 4. Fix config (ssl => ssl_enabled)
kubectl edit configmap logstash-logstash-pipeline -n elastic-search
```

## ⚙️ Configuration

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "password"
    ssl_enabled => false              # ⚠️ NOT 'ssl'
    ecs_compatibility => "disabled"

    ilm_enabled => true
    ilm_policy => "common-ilm-policy"          # Shared policy
    ilm_rollover_alias => "%{[container_name]}" # Dynamic alias
  }
}
```

## ✅ What Happens

1. **Logstash starts** → Skips creating static template
2. **First nginx event** → Creates `logstash-nginx` template for `nginx-*`
3. **First app1 event** → Creates `logstash-app1` template for `app1-*`
4. **Subsequent events** → Use existing templates

## 🔍 Verify

```bash
# Check Logstash logs
kubectl logs -f logstash-logstash-0 -n elastic-search | grep "dynamic template"

# Check templates in Elasticsearch
kubectl exec -it <es-pod> -n elastic-search -- \
  curl "localhost:9200/_cat/templates/logstash-*?v"

# Check specific template
kubectl exec -it <es-pod> -n elastic-search -- \
  curl "localhost:9200/_index_template/logstash-nginx?pretty"
```

## 📊 Expected Results

### Templates:

- ✅ `logstash-nginx` → `nginx-*` → `common-ilm-policy`
- ✅ `logstash-app1` → `app1-*` → `common-ilm-policy`
- ✅ `logstash-dotcms` → `dotcms-*` → `common-ilm-policy`

### Indices:

- ✅ `nginx-000001`, `nginx-000002`, ...
- ✅ `app1-000001`, `app1-000002`, ...
- ✅ Each with proper ILM policy attached

## 🎯 Benefits

✅ **One template per container** - No field conflicts  
✅ **Automatic creation** - No manual work  
✅ **Shared ILM policy** - Easy management  
✅ **Backward compatible** - Static aliases still work

## 🚨 Troubleshooting

**Logstash won't start:**

- Check: Changed `ssl => false` to `ssl_enabled => false`?

**Templates not created:**

- Check logs for "Created dynamic template" messages
- Verify events have `container_name` field populated

**Field conflicts still happening:**

- Verify each container gets unique template
- Check template patterns don't overlap
