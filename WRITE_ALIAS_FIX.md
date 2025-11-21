# Write Alias Fix for Dynamic ILM Rollover

## Problem

When using dynamic ILM rollover aliases (e.g., `ilm_rollover_alias => "auto-%{[container_name]}"`), the system was creating date-based indices (e.g., `auto-uibackend-2025.11.20`) but **logs were still being written to old indices** (e.g., `auto-uibackend-2025.11.19-000001`).

### Root Cause

The code had two critical issues:

1. **No Write Alias**: When creating new indices, no alias was configured to route writes
2. **Missing Daily Rollover**: No mechanism to automatically move the write alias when the date changes

This meant:

- Events were resolved to alias names like `auto-uibackend`
- But these aliases didn't exist or pointed to old indices
- Elasticsearch would either create unwanted auto-indices or route to the wrong index

## Solution

### 1. Create Write Alias on Index Creation

Modified `create_index_if_missing()` in `dynamic_template_manager.rb` to include an alias configuration:

```ruby
index_payload = {
  'settings' => { ... },
  'aliases' => {
    container_name => {
      'is_write_index' => true  # Mark as the current write target
    }
  }
}
```

This ensures that when `auto-uibackend-2025.11.20` is created, the alias `auto-uibackend` points to it as the write index.

### 2. Add Daily Rollover Logic

Added two new methods:

#### `ensure_write_alias_current(container_name, policy_name)`

- Checks if today's index exists
- Verifies the write alias points to today's index
- Moves the write alias if needed (handles day changes automatically)
- Uses daily caching to avoid excessive API calls

#### `update_write_alias(alias_name, target_index)`

- Atomically updates the write alias to point to a new index
- Uses the `_aliases` API with proper `is_write_index: true` flag

### 3. Daily Cache Optimization

To prevent checking the write alias on every event batch, implemented a date-based cache:

```ruby
# Cache key includes the date, so it automatically expires daily
cache_key = "#{container_name}:#{today}"
if @write_alias_last_checked.get(cache_key)
  return # Already verified today
end
```

## How It Works Now

### First Event of the Day (or Container)

1. Event arrives with `container_name: "uibackend"`
2. Resolved alias: `auto-uibackend`
3. `maybe_create_dynamic_template()` is called
4. Creates:
   - Policy: `auto-uibackend-ilm-policy`
   - Template: `logstash-auto-uibackend` (matches `auto-uibackend-*`)
   - Index: `auto-uibackend-2025.11.20`
   - **Alias: `auto-uibackend` → `auto-uibackend-2025.11.20` (write index)**
5. Cache updated: both template cache and write alias cache

### Subsequent Events (Same Day)

1. Event arrives with same container
2. Template cache hit - resources already exist
3. Write alias cache hit - already verified today
4. Event goes directly to `auto-uibackend` alias → routed to `auto-uibackend-2025.11.20`

### Next Day (Automatic Rollover)

1. First event of new day arrives
2. Template cache hit - resources exist
3. Write alias cache **miss** (date changed in cache key)
4. `ensure_write_alias_current()` detects date change
5. Creates new index: `auto-uibackend-2025.11.21`
6. Moves write alias: `auto-uibackend` → `auto-uibackend-2025.11.21`
7. Old index (`auto-uibackend-2025.11.20`) remains readable but no longer receives writes

## Benefits

✅ **No Manual Intervention**: Daily rollover happens automatically  
✅ **Write Alias Always Current**: Events always go to today's index  
✅ **Old Indices Preserved**: Previous days' data remains accessible  
✅ **ILM Compatible**: ILM policies can still manage retention/deletion  
✅ **High Performance**: Minimal API calls due to intelligent caching  
✅ **Thread-Safe**: Uses ConcurrentHashMap for safe concurrent access

## Migration from Old Indices

If you have old indices like `auto-uibackend-2025.11.19-000001`:

### Option 1: Keep Both (Recommended)

- Old indices remain readable
- New daily indices are created alongside them
- ILM will eventually delete old indices based on your retention policy

### Option 2: Reindex (If You Want Consistency)

```bash
# Reindex old data into new daily indices
POST _reindex
{
  "source": {
    "index": "auto-uibackend-2025.11.19-000001"
  },
  "dest": {
    "index": "auto-uibackend-2025.11.19"
  }
}

# Then delete old index
DELETE auto-uibackend-2025.11.19-000001
```

### Option 3: Create Alias for Old Index

```bash
# Make old index readable via the same alias
POST _aliases
{
  "actions": [
    {
      "add": {
        "index": "auto-uibackend-2025.11.19-000001",
        "alias": "auto-uibackend",
        "is_write_index": false
      }
    }
  ]
}
```

## Testing

After deploying this fix:

1. Restart Logstash
2. Send events with different container names
3. Verify in Kibana/Elasticsearch:
   ```bash
   GET _cat/aliases/auto-*?v
   ```
   You should see write aliases pointing to today's indices
4. Check index creation:

   ```bash
   GET _cat/indices/auto-*?v
   ```

   You should see indices with today's date

5. Next day, verify automatic rollover:
   - New indices created with new date
   - Write aliases moved to new indices
   - Old indices still present (for reading)

## Files Modified

- `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`
  - Added write alias creation in `create_index_if_missing()`
  - Added `ensure_write_alias_current()` method
  - Added `update_write_alias()` method
  - Added `@write_alias_last_checked` cache
