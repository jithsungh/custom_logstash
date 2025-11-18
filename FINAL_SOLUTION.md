# FINAL SOLUTION: Fix Elasticsearch Auto-Index Creation Issue

## Problem Summary

When Logstash restarts or you delete indices, Elasticsearch **auto-creates** simple indices (e.g., `uibackend-betrisks`) **BEFORE** Logstash can create the proper rollover index (e.g., `uibackend-betrisks-2025.11.18-000001`).

This creates an infinite loop:
1. Delete `uibackend-betrisks`
2. Logstash writes data
3. Elasticsearch auto-creates `uibackend-betrisks` (simple index, no alias)
4. Logstash tries to create rollover index → **FAILS**
5. Repeat...

## ✅ SOLUTION APPLIED: Auto-Prefix

**What Changed:**
- Modified `dynamic_template_manager.rb` to use `auto-{container}` as the alias name
- Example: Instead of `uibackend-betrisks`, it now creates `auto-uibackend-betrisks`

**Why This Works:**
- Elasticsearch auto-creates indices matching the exact write target (`uibackend-betrisks`)
- By using `auto-uibackend-betrisks` as the alias, Logstash writes to a different name
- The auto-creation pattern doesn't match, so ES won't create conflicts

## What You'll See Now

### Before (BROKEN):
```
uibackend-betrisks                          # ❌ Simple index (auto-created by ES)
```

### After (FIXED):
```
auto-uibackend-betrisks                     # ✅ Alias
  └── auto-uibackend-betrisks-2025.11.18-000001   # ✅ Actual rollover index
```

## Code Change

**File:** `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`

```ruby
def maybe_create_dynamic_template(index_name)
  unless ilm_in_use? && @ilm_rollover_alias&.include?('%{')
    return
  end
  
  # IMPORTANT: Add "auto-" prefix to prevent Elasticsearch auto-creation conflicts
  # Without this, ES creates "uibackend-betrisks" before we can create "uibackend-betrisks-2025.11.18-000001"
  # With this, we create "auto-uibackend-betrisks" alias pointing to "auto-uibackend-betrisks-2025.11.18-000001"
  alias_name = "auto-#{index_name}"
  
  # ...rest of the code
end
```

## Deployment Steps

### 1. Build the Gem
```bash
cd /path/to/logstash-output-elasticsearch
gem build logstash-output-elasticsearch.gemspec
```

### 2. Build Docker Image
```bash
docker build -t your-registry/logstash-custom:latest .
docker push your-registry/logstash-custom:latest
```

### 3. Update Kubernetes Deployment
```yaml
spec:
  containers:
    - name: logstash
      image: your-registry/logstash-custom:latest
      imagePullPolicy: Always  # Force pull of new image
```

### 4. Deploy
```bash
kubectl rollout restart deployment/logstash -n your-namespace
```

### 5. Clean Up Old Indices (OPTIONAL)
```bash
# Delete old simple indices (do this AFTER new Logstash is running)
curl -X DELETE "http://elasticsearch:9200/uibackend-betrisks"
curl -X DELETE "http://elasticsearch:9200/uibackend-promotion"
# etc...
```

## Testing

### Check Indices
```bash
curl -X GET "http://elasticsearch:9200/_cat/indices/auto-*?v"
```

**Expected Output:**
```
health status index                                   pri rep docs.count
green  open   auto-uibackend-betrisks-2025.11.18-000001  1   0      12345
green  open   auto-uibackend-promotion-2025.11.18-000001 1   0       6789
```

### Check Aliases
```bash
curl -X GET "http://elasticsearch:9200/_cat/aliases/auto-*?v"
```

**Expected Output:**
```
alias                     index                                      is_write_index
auto-uibackend-betrisks   auto-uibackend-betrisks-2025.11.18-000001  true
auto-uibackend-promotion  auto-uibackend-promotion-2025.11.18-000001 true
```

### Verify Logstash Logs
```bash
kubectl logs -f deployment/logstash -n your-namespace | grep "ILM resources ready"
```

**Expected:**
```
ILM resources ready {:container=>"auto-uibackend-betrisks", 
                     :policy=>"auto-uibackend-betrisks-ilm-policy", 
                     :template=>"logstash-auto-uibackend-betrisks", 
                     :alias=>"auto-uibackend-betrisks"}
```

## Querying Data

### Query via Alias (RECOMMENDED)
```bash
curl -X GET "http://elasticsearch:9200/auto-uibackend-betrisks/_search?size=10"
```

### Kibana Index Pattern
```
auto-uibackend-betrisks-*
```

Or use the alias directly:
```
auto-uibackend-betrisks
```

## Rollback Plan

If something goes wrong:

### Option A: Use Git to Revert
```bash
git checkout HEAD~1 lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb
gem build logstash-output-elasticsearch.gemspec
# Rebuild and redeploy
```

### Option B: Emergency Fix
Manually delete the `auto-` prefix from line 15 in `dynamic_template_manager.rb`:

```ruby
alias_name = index_name  # Instead of: alias_name = "auto-#{index_name}"
```

## Alternative Solution (If Auto-Prefix Doesn't Work)

See `ELASTICSEARCH_CONFIG_FIX.md` for instructions on disabling Elasticsearch auto-creation:

```bash
curl -X PUT "http://elasticsearch:9200/_cluster/settings" \
  -H 'Content-Type: application/json' \
  -d '{
  "persistent": {
    "action.auto_create_index": "+*-*-*,-.monitoring*,-.security*"
  }
}'
```

## FAQ

**Q: Will this break existing indices?**  
A: No. Old indices (like `uibackend-betrisks-2025.11.17-000001`) will continue working. New data will go to `auto-` prefixed indices.

**Q: Can I migrate old data to new indices?**  
A: Yes, use Elasticsearch Reindex API or create an alias pointing to both old and new indices.

**Q: Will queries break?**  
A: If you query by alias name, update your queries from `uibackend-betrisks` to `auto-uibackend-betrisks`.

**Q: Can I remove the "auto-" prefix later?**  
A: Yes, but only if you configure Elasticsearch to prevent auto-creation first (see `ELASTICSEARCH_CONFIG_FIX.md`).

## Success Criteria

✅ No more `index exists with same name as alias` errors  
✅ Indices created as `auto-{container}-YYYY.MM.DD-000001`  
✅ Aliases work correctly (`auto-{container}`)  
✅ Data flows normally to Elasticsearch  
✅ ILM policies apply correctly  
✅ No infinite retry loops  

## Support

If you encounter issues:
1. Check Logstash logs for errors
2. Check Elasticsearch indices: `curl -X GET "http://elasticsearch:9200/_cat/indices?v"`
3. Check if simple indices exist: `curl -X GET "http://elasticsearch:9200/uibackend-*"`
4. Verify template exists: `curl -X GET "http://elasticsearch:9200/_index_template/logstash-auto-*"`

---

**Version:** 12.1.6  
**Last Updated:** November 18, 2025  
**Status:** ✅ READY FOR PRODUCTION
