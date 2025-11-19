# Daily Rollover Fix - November 19, 2025

## Problem Identified

The existing indices had aliases from previous days, but **new daily indices were NOT being created** for November 19, 2025.

### What Was Happening

```
Day 1 (Nov 18):
✅ auto-e3fbrandmapperbetgenius-2025.11.18-000001 created
✅ Alias "auto-e3fbrandmapperbetgenius" → points to above index

Day 2 (Nov 19):
❌ Check: Does alias exist? YES (from yesterday)
❌ Action: Return immediately (skip index creation)
❌ Result: No new index for today!
```

### Affected Containers

These containers had aliases from previous days but no Nov 19 indices:

- `auto-e3fbrandmapperbetgenius`
- `auto-init-e3fcabgdb`
- `auto-uibackend-betrisks`
- `auto-e3fcontentadapterbg`
- `auto-uibackend`
- `auto-uibackend-promotion`

---

## Root Cause

The `create_index_if_missing` method had this logic:

```ruby
# OLD CODE - BUG
if @client.rollover_alias_exists?(alias_name)
  logger.debug("Index/alias already exists", :alias => alias_name)
  return  # ← STOPS HERE - Never checks if date changed!
end
```

**Problem:** It assumed if alias exists, nothing more needs to be done. It didn't account for **date-based rollovers**.

---

## Solution Implemented

### Code Changes

Added **3 new methods** to `dynamic_template_manager.rb`:

#### 1. Enhanced `create_index_if_missing`

```ruby
# NEW CODE - FIXED
if @client.rollover_alias_exists?(alias_name)
  logger.debug("Alias already exists - checking if rollover needed", :alias => alias_name)

  # NEW: Check if current write index has today's date
  check_and_rollover_if_needed(alias_name)
  return
end
```

#### 2. New Method: `check_and_rollover_if_needed`

- Queries Elasticsearch to find the current **write index**
- Extracts the date from the index name
- Compares with today's date
- If dates don't match → triggers manual rollover

```ruby
# Example:
Current write index: auto-app-2025.11.18-000001
Today's date:        2025.11.19
Result:              Trigger rollover → creates auto-app-2025.11.19-000001
```

#### 3. New Method: `trigger_manual_rollover`

- Calls Elasticsearch `_rollover` API
- Forces creation of new index with today's date
- Updates write alias to point to new index

---

## How It Works Now

### Flow Diagram

```
Event arrives for container "auto-e3fbrandmapperbetgenius"
    ↓
Check: Does alias exist?
    ↓
YES → Check current write index date
    ↓
    ├─ Has today's date (2025.11.19)?
    │    ↓
    │    YES → Nothing to do (already correct)
    │
    └─ Has old date (2025.11.18)?
         ↓
         YES → Call _rollover API
              ↓
              Create: auto-e3fbrandmapperbetgenius-2025.11.19-000001
              ↓
              Update write alias → new index
```

### Example Execution

```
[INFO] Alias already exists - checking if rollover needed {:alias=>"auto-e3fbrandmapperbetgenius"}
[INFO] Write index has old date - triggering rollover for new day
       {:alias=>"auto-e3fbrandmapperbetgenius",
        :current_write_index=>"auto-e3fbrandmapperbetgenius-2025.11.18-000001",
        :expected_date=>"2025.11.19"}
[INFO] Successfully triggered manual rollover for new day {:alias=>"auto-e3fbrandmapperbetgenius"}
```

---

## Expected Behavior After Fix

### First Event of the Day

When the **first event** for a container arrives on a new day:

1. ✅ Check alias exists → **YES**
2. ✅ Get current write index → `auto-app-2025.11.18-000001`
3. ✅ Compare dates → `2025.11.18` ≠ `2025.11.19`
4. ✅ Trigger rollover → Creates `auto-app-2025.11.19-000001`
5. ✅ Update alias → Points to new index

### Subsequent Events

All subsequent events on the same day:

1. ✅ Check alias exists → **YES**
2. ✅ Get current write index → `auto-app-2025.11.19-000001`
3. ✅ Compare dates → `2025.11.19` = `2025.11.19`
4. ✅ No rollover needed → Continue normally

---

## Testing the Fix

### Before Restarting Logstash

**Expected State:**

- Aliases exist (pointing to old indices)
- No Nov 19 indices for affected containers

### After Restarting Logstash

**Expected Logs:**

```
[INFO] Alias already exists - checking if rollover needed
[INFO] Write index has old date - triggering rollover for new day
[INFO] Successfully triggered manual rollover for new day
```

**Expected Indices Created:**

```
auto-e3fbrandmapperbetgenius-2025.11.19-000001
auto-init-e3fcabgdb-2025.11.19-000001
auto-uibackend-betrisks-2025.11.19-000001
auto-e3fcontentadapterbg-2025.11.19-000001
auto-uibackend-2025.11.19-000001
auto-uibackend-promotion-2025.11.19-000001
```

### Verification Commands

```bash
# Check if new indices were created
curl -X GET "localhost:9200/_cat/indices/auto-*-2025.11.19-*?v"

# Check alias mappings
curl -X GET "localhost:9200/_cat/aliases/auto-*?v"

# Verify write index for a specific alias
curl -X GET "localhost:9200/auto-e3fbrandmapperbetgenius/_alias?pretty"
```

---

## Rollback Plan

If issues occur, the rollover can be manually triggered:

```bash
# Manual rollover for a specific alias
curl -X POST "localhost:9200/auto-e3fbrandmapperbetgenius/_rollover?pretty"
```

Or revert to the previous version (but indices won't auto-create daily).

---

## Long-Term Behavior

### Daily Index Pattern

With this fix, indices follow this pattern:

```
Day 1: auto-app-2025.11.18-000001
Day 2: auto-app-2025.11.19-000001  ← Triggered by first event
Day 3: auto-app-2025.11.20-000001  ← Triggered by first event
...
```

### ILM Lifecycle

Each daily index still follows the ILM policy:

- **Hot phase:** Immediate priority, rollover after 1 day
- **Delete phase:** Deleted after 1 day from rollover

So by Nov 21, the Nov 19 indices will be automatically deleted.

---

## Notes

- **Performance:** The date check adds minimal overhead (1 API call per container per day)
- **Thread Safety:** The existing `putIfAbsent` lock ensures only one thread triggers rollover
- **Failsafe:** If manual rollover fails, ILM will still handle it automatically
- **Backward Compatible:** Doesn't affect containers created today (they still work normally)

---

## Files Changed

- `lib/logstash/outputs/elasticsearch/dynamic_template_manager.rb`
  - Modified: `create_index_if_missing` (added date check)
  - Added: `check_and_rollover_if_needed` (date comparison logic)
  - Added: `trigger_manual_rollover` (manual rollover API call)

---

## Status

✅ **FIXED** - Code changes applied  
⏳ **PENDING** - Logstash restart required to test  
📋 **TODO** - Monitor logs for successful rollovers
