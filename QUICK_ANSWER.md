# Quick Answer: Why Logs Go to Old Index

## The Problem You're Seeing

```
New index created: auto-uibackend-2025.11.20 ✓
But logs still go to: auto-uibackend-2025.11.19-000001 ✗
```

## Root Cause

The code was creating **indices** but not creating **write aliases** to route events to them.

- Events are sent to alias: `auto-uibackend`
- But this alias didn't exist or pointed to the old index
- So Elasticsearch used the old index or auto-created unwanted ones

## The Fix Applied

✅ **Write Alias Creation**: Now when an index is created, a write alias is also created
✅ **Daily Rollover**: Automatically moves the write alias to today's index each day
✅ **Caching**: Efficient caching prevents excessive API calls

## What Happens Now

### Today (After Fix)

1. New index created: `auto-uibackend-2025.11.20`
2. Write alias created: `auto-uibackend` → `auto-uibackend-2025.11.20` (write_index: true)
3. All new events → `auto-uibackend` → routed to `auto-uibackend-2025.11.20` ✓

### Tomorrow (Automatic)

1. New index created: `auto-uibackend-2025.11.21`
2. Write alias moved: `auto-uibackend` → `auto-uibackend-2025.11.21`
3. Old index `auto-uibackend-2025.11.20` remains for reading (ILM will delete based on policy)

## Should You Delete Old Indices?

### NO - Recommended Approach

- Keep old indices for historical data
- They're still readable via queries
- ILM will auto-delete based on your retention policy
- No data loss

### YES - Only If Needed

If you want clean slate:

```bash
# Delete old index (CAUTION: Data loss!)
DELETE auto-uibackend-2025.11.19-000001

# Or reindex to new format first
POST _reindex
{
  "source": {"index": "auto-uibackend-2025.11.19-000001"},
  "dest": {"index": "auto-uibackend-2025.11.19"}
}
DELETE auto-uibackend-2025.11.19-000001
```

## Verify the Fix

After restarting Logstash:

```bash
# Check aliases
GET _cat/aliases/auto-*?v

# Should show:
# alias              index                          is_write_index
# auto-uibackend     auto-uibackend-2025.11.20      true

# Check indices
GET _cat/indices/auto-*?v&s=index

# Send a test log and verify it goes to the new index
GET auto-uibackend-2025.11.20/_count
```

## Next Steps

1. **Restart Logstash** to apply the fix
2. **Send test events** to verify routing
3. **Monitor logs** for successful index creation
4. **Wait for tomorrow** to see automatic rollover
5. **Cleanup old indices** (optional, after verification)

## Files Changed

- `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`
  - Line ~190: Added write alias in `create_index_if_missing()`
  - Line ~90: Added `ensure_write_alias_current()` call
  - Line ~96: New `ensure_write_alias_current()` method
  - Line ~153: New `update_write_alias()` method
