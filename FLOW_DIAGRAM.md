# 📊 ILM Rollover Flow Diagram

## Complete Event Processing Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Event Arrives at Logstash                        │
│  {"container_name": "e3fbrandmapperbetgenius", "message": "log"}    │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│              elasticsearch.rb - resolve_dynamic_rollover_alias()    │
│  • Performs sprintf: %{[container_name]} → "e3fbrandmapperbetgenius"│
│  • Adds prefix: "auto-e3fbrandmapperbetgenius"                      │
│  • Returns: "auto-e3fbrandmapperbetgenius"                          │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│       dynamic_template_manager.rb - maybe_create_dynamic_template() │
│  • Check cache: Is "auto-e3fbrandmapperbetgenius" initialized?      │
│  • If YES → Skip (use existing resources)                           │
│  • If NO  → Continue to initialization                              │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  Thread-Safe Lock Acquisition                       │
│  • Use ConcurrentHashMap.putIfAbsent()                              │
│  • Winner thread → Proceeds to create resources                     │
│  • Loser threads → Wait for completion                              │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│              STEP 1: Create ILM Policy (if missing)                 │
│                                                                      │
│  Policy Name: "auto-e3fbrandmapperbetgenius-ilm-policy"             │
│                                                                      │
│  Policy Content:                                                    │
│  {                                                                  │
│    "policy": {                                                      │
│      "phases": {                                                    │
│        "hot": {                                                     │
│          "actions": {                                               │
│            "rollover": {                    ← KEY CHANGE!           │
│              "max_age": "1d",               ← Triggers rollover     │
│              "max_size": "50gb",            ← OR this               │
│              "max_docs": 1000000            ← OR this               │
│            },                                                       │
│            "set_priority": { "priority": 100 }                      │
│          }                                                          │
│        },                                                           │
│        "delete": {                                                  │
│          "min_age": "7d",                                           │
│          "actions": { "delete": {} }                                │
│        }                                                            │
│      }                                                              │
│    }                                                                │
│  }                                                                  │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│            STEP 2: Create Index Template (if missing)               │
│                                                                      │
│  Template Name: "logstash-auto-e3fbrandmapperbetgenius"             │
│  Index Pattern: "auto-e3fbrandmapperbetgenius-*"                    │
│  Priority: 100                                                      │
│                                                                      │
│  Template Settings:                                                 │
│  {                                                                  │
│    "settings": {                                                    │
│      "index": {                                                     │
│        "lifecycle": {                                               │
│          "name": "auto-e3fbrandmapperbetgenius-ilm-policy",         │
│          "rollover_alias": "auto-e3fbrandmapperbetgenius" ← KEY!    │
│        }                                                            │
│      }                                                              │
│    },                                                               │
│    "mappings": { ... }                                              │
│  }                                                                  │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│       STEP 3: Create First Rollover Index (if missing)              │
│                                                                      │
│  Check: Does write alias exist?                                     │
│  • rollover_alias_has_write_index?("auto-e3fbrandmapperbetgenius")  │
│  • If YES → Skip (index already exists)                             │
│  • If NO  → Create first index                                      │
│                                                                      │
│  Index Name: "auto-e3fbrandmapperbetgenius-000001"  ← NO DATE!      │
│                                     ↑↑↑↑↑↑                          │
│                                     Sequential number               │
│                                                                      │
│  Index Creation Payload:                                            │
│  {                                                                  │
│    "settings": {                                                    │
│      "index": {                                                     │
│        "lifecycle": {                                               │
│          "name": "auto-e3fbrandmapperbetgenius-ilm-policy",         │
│          "rollover_alias": "auto-e3fbrandmapperbetgenius" ← KEY!    │
│        }                                                            │
│      }                                                              │
│    },                                                               │
│    "aliases": {                                                     │
│      "auto-e3fbrandmapperbetgenius": {                              │
│        "is_write_index": true        ← CRITICAL!                    │
│      }                                                              │
│    }                                                                │
│  }                                                                  │
│                                                                      │
│  Method Used: rollover_alias_put()    ← Proper ILM setup           │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Mark as Initialized                              │
│  • @dynamic_templates_created.put("auto-e3fbrandmapperbetgenius",  │
│                                    true)                            │
│  • Release lock                                                     │
│  • Subsequent events skip initialization                            │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  Event Indexed to Elasticsearch                     │
│  • Write to alias: "auto-e3fbrandmapperbetgenius"                   │
│  • Elasticsearch routes to: "auto-e3fbrandmapperbetgenius-000001"   │
│  • Document stored successfully                                     │
└─────────────────────────────────────────────────────────────────────┘


═══════════════════════════════════════════════════════════════════════
                          ILM Background Process
═══════════════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────────────┐
│                  ILM Daemon (runs every 10 minutes)                 │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│        Check Rollover Conditions for All ILM-Managed Indices        │
│                                                                      │
│  For index: "auto-e3fbrandmapperbetgenius-000001"                   │
│  • Check max_age: Is index > 1 day old?                             │
│  • Check max_size: Is index > 50GB?                                 │
│  • Check max_docs: Does index have > 1M docs?                       │
│                                                                      │
│  If ANY condition is met → Trigger Rollover                         │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                 ┌───────┴───────┐
                 │               │
          Condition       Condition
          NOT met         MET!
                 │               │
                 ▼               ▼
        ┌───────────────┐  ┌─────────────────────────────────────────┐
        │  Wait         │  │         ILM Executes Rollover           │
        │  Continue     │  │                                         │
        └───────────────┘  │  Actions:                               │
                           │  1. Create new index:                   │
                           │     "auto-e3fbrandmapperbetgenius-000002"│
                           │                              ↑↑↑↑↑↑     │
                           │                              Auto-incremented!│
                           │                                         │
                           │  2. Update alias atomically:            │
                           │     • Remove is_write_index from 000001 │
                           │     • Add is_write_index to 000002      │
                           │                                         │
                           │  3. Index 000001 becomes read-only      │
                           │  4. New events go to 000002             │
                           └────────┬────────────────────────────────┘
                                    │
                                    ▼
                ┌─────────────────────────────────────────────────────┐
                │           State After Rollover                      │
                │                                                     │
                │  auto-e3fbrandmapperbetgenius-000001 (read-only)    │
                │  auto-e3fbrandmapperbetgenius-000002 (is_write_index│
                │                                                     │
                │  Alias: auto-e3fbrandmapperbetgenius → 000002       │
                └────────────────────┬────────────────────────────────┘
                                     │
                         ┌───────────┴───────────┐
                         │                       │
                   After 1 day           After 7 days
                   (max_age met)         (delete min_age met)
                         │                       │
                         ▼                       ▼
            ┌────────────────────┐   ┌──────────────────────────────┐
            │ Rollover again     │   │ Delete Phase Executes        │
            │ Create 000003      │   │                              │
            │ Alias → 000003     │   │ Delete: 000001               │
            └────────────────────┘   │ Keep: 000002, 000003, etc.   │
                                     └──────────────────────────────┘
```

---

## Resource Naming Convention

```
Container Name in Event: "e3fbrandmapperbetgenius"
                                    ↓
              Add "auto-" prefix (in resolve_dynamic_rollover_alias)
                                    ↓
        Resolved Alias: "auto-e3fbrandmapperbetgenius"
                                    ↓
              ┌───────────────────┴──────────────────┐
              │                                      │
              ▼                                      ▼
    ILM Policy Name                         Template Name
    "auto-e3fbrandmapperbetgenius-ilm-policy"  "logstash-auto-e3fbrandmapperbetgenius"
              │                                      │
              └───────────────────┬──────────────────┘
                                  ▼
                         First Index Name
                "auto-e3fbrandmapperbetgenius-000001"
                                               ↑↑↑↑↑↑
                                        Sequential (ILM managed)
                                        NO DATE!
                                  ↓
                         Subsequent Indices
                "auto-e3fbrandmapperbetgenius-000002"
                "auto-e3fbrandmapperbetgenius-000003"
                "auto-e3fbrandmapperbetgenius-000004"
                                ...
```

---

## Index Lifecycle Timeline

```
Timeline →

Day 0                  Day 1                  Day 2                  Day 7
│                      │                      │                      │
│  [000001 Created]    │  [Rollover]          │  [Rollover]          │  [Delete 000001]
│  is_write=true       │  000001→read-only    │  000002→read-only    │
│                      │  [000002 Created]    │  [000003 Created]    │
│                      │  is_write=true       │  is_write=true       │
│                      │                      │                      │
▼                      ▼                      ▼                      ▼

[Index State]          [Index State]          [Index State]          [Index State]

000001 (WRITE)         000001 (READ)          000001 (READ)          000002 (READ)
                       000002 (WRITE)         000002 (READ)          000003 (READ)
                                              000003 (WRITE)         000004 (READ)
                                                                     000005 (READ)
                                                                     000006 (READ)
                                                                     000007 (READ)
                                                                     000008 (WRITE)

[Alias Points To]      [Alias Points To]      [Alias Points To]      [Alias Points To]
→ 000001               → 000002               → 000003               → 000008

[ILM Phase]            [ILM Phase]            [ILM Phase]            [ILM Phase]
hot: 0d old            hot: 1d old            hot: 2d old            delete: 7d old
                       ROLLOVER!              ROLLOVER!              DELETE 000001!
```

---

## Comparison: Old vs New Implementation

```
╔════════════════════════════════════════════════════════════════════╗
║                          OLD IMPLEMENTATION                        ║
║                          (Date-Based)                              ║
╚════════════════════════════════════════════════════════════════════╝

Indices Created:
  auto-nginx-2025-11-18-000001   ← Manual date insertion
  auto-nginx-2025-11-19-000001   ← New date = new sequence
  auto-nginx-2025-11-20-000001   ← Each day restarts at 000001

Problems:
  ❌ Date in index name conflicts with ILM
  ❌ Each day creates new -000001 index
  ❌ Rollover doesn't increment properly
  ❌ Manual alias management required
  ❌ Race conditions with daily alias updates

ILM Policy:
  {
    "hot": {
      "actions": {
        "set_priority": { ... }
      }
    }
  }
  ❌ No rollover action!


╔════════════════════════════════════════════════════════════════════╗
║                          NEW IMPLEMENTATION                        ║
║                          (ILM-Managed)                             ║
╚════════════════════════════════════════════════════════════════════╝

Indices Created:
  auto-nginx-000001   ← First index
  auto-nginx-000002   ← ILM rollover (auto-increment)
  auto-nginx-000003   ← ILM rollover (auto-increment)

Benefits:
  ✅ NO date in index name
  ✅ ILM controls sequence numbering
  ✅ Proper rollover based on conditions
  ✅ Automatic alias management
  ✅ Thread-safe, no race conditions

ILM Policy:
  {
    "hot": {
      "actions": {
        "rollover": {           ← NEW!
          "max_age": "1d",
          "max_size": "50gb",
          "max_docs": 1000000
        },
        "set_priority": { ... }
      }
    }
  }
  ✅ Rollover action configured!

Index Settings:
  {
    "settings": {
      "index": {
        "lifecycle": {
          "name": "...-ilm-policy",
          "rollover_alias": "auto-nginx"  ← NEW!
        }
      }
    }
  }
```

---

## Key Implementation Details

### Thread Safety
```
Event A                          Event B
(container: nginx)              (container: nginx)
        │                               │
        ├───────────────┬───────────────┤
        │   RACE!       │               │
        ▼               ▼               ▼
   Lock Attempt    Lock Attempt    Lock Attempt
        │               │               │
   putIfAbsent()   putIfAbsent()   putIfAbsent()
        │               │               │
    WINNER!         LOSER          LOSER
        │               │               │
   Create           Wait           Wait
   Resources         │               │
        │            │               │
   Mark Done  ───────┴───────────────┘
        │
   All threads continue
```

### Idempotent Operations
```
All operations are safe to call multiple times:

✅ create_policy_if_missing()
   • Checks if policy exists first
   • Only creates if missing
   • Safe if multiple threads call

✅ create_template_if_missing()
   • template_install() is idempotent
   • Won't overwrite existing template
   
✅ create_index_if_missing()
   • Checks for write alias first
   • rollover_alias_put() handles race conditions
   • Returns success if index already exists
```

---

This diagram shows the complete flow from event arrival to ILM-managed rollover! 🎉
