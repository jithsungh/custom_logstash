# Fix: Disable Elasticsearch Auto-Index Creation

## The Problem

Elasticsearch is **auto-creating** simple indices (e.g., `uibackend-betrisks`) when Logstash writes data, **BEFORE** your code can create the proper rollover index (e.g., `uibackend-betrisks-2025.11.18-000001`).

This creates a race condition:
1. Logstash starts → checks if index exists → NO
2. Logstash tries to write data → Elasticsearch auto-creates `uibackend-betrisks`
3. Logstash tries to create rollover index → FAILS (index already exists)

## Solution: Configure Elasticsearch to Restrict Auto-Creation

### Option A: Allow Only Pattern-Based Index Creation (RECOMMENDED)

Add this to your Elasticsearch configuration (`elasticsearch.yml` or via API):

```yaml
# Only allow indices matching specific patterns to be auto-created
# This prevents creation of "uibackend-betrisks" but allows "uibackend-betrisks-2025.11.18-000001"
action.auto_create_index: "+*-*-*,-.monitoring*,-.security*"
```

**Explanation:**
- `+*-*-*` - Allow indices with at least 2 dashes (matches rollover pattern like `name-date-number`)
- `-.monitoring*` - Explicitly deny monitoring indices auto-creation
- `-.security*` - Explicitly deny security indices auto-creation

### Option B: Disable All Auto-Creation (STRICT)

```yaml
# Completely disable auto-creation - all indices must be created via templates/API
action.auto_create_index: false
```

### Option C: Use Elasticsearch API (No Restart Required)

```bash
# Apply dynamically via API (no Elasticsearch restart needed)
curl -X PUT "http://your-elasticsearch:9200/_cluster/settings" \
  -H 'Content-Type: application/json' \
  -d '{
  "persistent": {
    "action.auto_create_index": "+*-*-*,-.monitoring*,-.security*"
  }
}'
```

### Verify the Setting

```bash
# Check current setting
curl -X GET "http://your-elasticsearch:9200/_cluster/settings?include_defaults=true&filter_path=*.*.action.auto_create_index"
```

## After Applying the Fix

1. **Restart Logstash** (Elasticsearch restart NOT needed if using API)
2. **Delete any existing simple indices:**
   ```bash
   curl -X DELETE "http://your-elasticsearch:9200/uibackend-betrisks"
   ```
3. **Test:** New indices should be created as `uibackend-betrisks-2025.11.18-000001` with proper alias

## For Kubernetes Deployment

Add to your Elasticsearch ConfigMap or environment variables:

```yaml
env:
  - name: action.auto_create_index
    value: "+*-*-*,-.monitoring*,-.security*"
```

Or in `elasticsearch.yml` ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-config
data:
  elasticsearch.yml: |
    action.auto_create_index: "+*-*-*,-.monitoring*,-.security*"
```

## Alternative: Change Alias Pattern

If you CANNOT modify Elasticsearch config, use **Solution 2** (see next file).
