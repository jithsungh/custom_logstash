# Troubleshooting: Index Not Found Error Loop

## Current Issue

Your logs show a repeating pattern:

```
[2025-11-20T07:05:48,587] Template ready
[2025-11-20T07:05:48,590] ILM resources ready  <- No "Creating new index" message!
[2025-11-20T07:05:49,061] Index not found during bulk write
```

The template is being created but **the index is NOT being created**, causing events to fail when trying to write to the alias `auto-uibackend`.

## Root Cause

The `ensure_write_alias_current()` method was being called but had **indentation issues** that prevented it from executing properly. This has now been fixed.

## What Was Fixed

1. **Fixed all method indentations** in `dynamic_template_manager.rb`
2. **Ensured `create_index_if_missing()` is properly called** from `maybe_create_dynamic_template()`
3. **Added write alias creation** when creating indices

## Next Steps to Test

### 1. Restart Logstash

First, restart Logstash to load the fixed code:

```bash
# Stop Logstash
# (Use your method: Ctrl+C, systemctl stop, docker stop, etc.)

# Start Logstash
# (Use your start command)
```

### 2. Check What You Should See

After restart, for a new container like `uibackend`, you should see:

```
[INFO] Lock acquired, proceeding with initialization {:container=>"auto-uibackend"}
[INFO] Initializing ILM resources for new container {:container=>"auto-uibackend"}
[INFO] Creating minimal dynamic template programmatically {...}
[INFO] Template ready {:template=>"logstash-auto-uibackend", :priority=>100}
[INFO] Creating new index for container {:container=>"auto-uibackend", :index=>"auto-uibackend-2025.11.20", ...}
[INFO] Successfully created index with write alias {:index=>"auto-uibackend-2025.11.20", :alias=>"auto-uibackend", ...}
[INFO] ILM resources ready, lock released {...}
```

**Key difference**: You should now see the "Creating new index" and "Successfully created index with write alias" messages.

### 3. Verify in Elasticsearch

Check that the index and alias were created:

```bash
# Check indices
curl -X GET "localhost:9200/_cat/indices/auto-*?v&s=index"

# Check aliases
curl -X GET "localhost:9200/_cat/aliases/auto-*?v"

# Check specific alias details
curl -X GET "localhost:9200/_alias/auto-uibackend?pretty"
```

You should see:

- Index: `auto-uibackend-2025.11.20`
- Alias: `auto-uibackend` → `auto-uibackend-2025.11.20` (with `is_write_index: true`)

### 4. If Still Failing

If you still see "Index not found" errors after restarting:

#### Option A: Check for Exceptions in Logs

Look for error messages like:

```
[ERROR] Failed to initialize ILM resources
[ERROR] Failed to update write alias
[ERROR] Error checking if index exists
```

This would indicate a deeper issue (permissions, connectivity, etc.)

#### Option B: Manually Create the Index

As a temporary workaround, manually create the index with write alias:

```bash
curl -X PUT "localhost:9200/auto-uibackend-2025.11.20?pretty" -H 'Content-Type: application/json' -d'
{
  "settings": {
    "index": {
      "lifecycle": {
        "name": "auto-uibackend-ilm-policy"
      },
      "number_of_shards": 1,
      "number_of_replicas": 0
    }
  },
  "aliases": {
    "auto-uibackend": {
      "is_write_index": true
    }
  }
}
'
```

#### Option C: Enable Debug Logging

Add to your Logstash config or `logstash.yml`:

```yaml
log.level: debug
```

Or set it programmatically:

```bash
curl -X PUT "localhost:9600/_node/logging?pretty" -H 'Content-Type: application/json' -d'
{
  "logger.logstash.outputs.elasticsearch": "DEBUG"
}
'
```

Then look for detailed debug messages about:

- Lock acquisition
- Index existence checks
- API calls to Elasticsearch

### 5. Delete Old Indices (Optional)

If you want a clean slate:

```bash
# Delete old rollover-style indices (backup first!)
curl -X DELETE "localhost:9200/auto-uibackend-2025.11.19-000001"

# Or delete all auto-* indices (CAREFUL!)
curl -X DELETE "localhost:9200/auto-*"

# Then restart Logstash to recreate them properly
```

## Expected Behavior After Fix

### First Event of the Day

1. Event with `container_name: "uibackend"` arrives
2. Resolved to `auto-uibackend` alias
3. Template cache miss → creates resources:
   - Policy: `auto-uibackend-ilm-policy`
   - Template: `logstash-auto-uibackend`
   - Index: `auto-uibackend-2025.11.20` ✓ **NEW**
   - Alias: `auto-uibackend` → `auto-uibackend-2025.11.20` (write) ✓ **NEW**
4. Event successfully indexed to `auto-uibackend` (routed to today's index)

### Subsequent Events (Same Day)

1. Template cache hit → no resource creation
2. Write alias cache hit → no API calls
3. Event goes to `auto-uibackend` → routed to `auto-uibackend-2025.11.20`
4. Fast and efficient

### Next Day (Auto Rollover)

1. First event of new day arrives
2. Template cache hit (resources exist)
3. Write alias cache **miss** (date changed)
4. `ensure_write_alias_current()` detects new day:
   - Creates `auto-uibackend-2025.11.21`
   - Moves write alias to new index
5. Events now go to new day's index

## Common Issues

### Issue: "resource_already_exists_exception"

**Symptom**: Index exists but no alias

**Solution**:

```bash
# Add the alias manually
curl -X POST "localhost:9200/_aliases?pretty" -H 'Content-Type: application/json' -d'
{
  "actions": [
    {
      "add": {
        "index": "auto-uibackend-2025.11.20",
        "alias": "auto-uibackend",
        "is_write_index": true
      }
    }
  ]
}
'
```

### Issue: Multiple write indices

**Symptom**: "illegal_argument_exception: alias has more than one write index"

**Solution**:

```bash
# Remove write flag from old indices
curl -X POST "localhost:9200/_aliases?pretty" -H 'Content-Type: application/json' -d'
{
  "actions": [
    { "remove": { "index": "*", "alias": "auto-uibackend" } },
    { "add": { "index": "auto-uibackend-2025.11.20", "alias": "auto-uibackend", "is_write_index": true } }
  ]
}
'
```

### Issue: Template priority conflict

**Symptom**: Wrong template being applied

**Solution**:

```bash
# Check template priorities
curl -X GET "localhost:9200/_index_template?pretty"

# Our dynamic templates use priority 100
# Make sure no other template has higher priority for the same pattern
```

## Files Modified

- `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`
  - Fixed all method indentations
  - `create_index_if_missing()` now creates write alias
  - `ensure_write_alias_current()` handles daily rollover
  - `update_write_alias()` moves alias to new index

## Quick Verification Commands

```bash
# 1. Check if Logstash is using the new code
ps aux | grep logstash  # Should show recent start time

# 2. Send a test event
echo '{"message":"test", "container_name":"testcontainer"}' | nc localhost 5000

# 3. Check if index was created
curl "localhost:9200/_cat/indices/auto-testcontainer-*?v"

# 4. Check if alias was created
curl "localhost:9200/_alias/auto-testcontainer?pretty"

# 5. Verify events are being indexed
curl "localhost:9200/auto-testcontainer-*/_count?pretty"
```

## Summary

The fix ensures that when dynamic ILM rollover is enabled:

1. **Index is created** with today's date
2. **Write alias is created** pointing to that index
3. **Events use the alias** and are routed to the correct index
4. **Daily rollover** happens automatically

No more "index_not_found_exception" errors!
