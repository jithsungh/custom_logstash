# Problem Statement & Requirements

## Executive Summary

This document outlines the business problem, technical challenges, and requirements that led to the development of a dynamic ILM (Index Lifecycle Management) solution for Logstash's Elasticsearch output plugin.

---

## 1. Business Problem

### Current Situation

Organizations running containerized microservices in Kubernetes generate logs from multiple containers. These logs need to be:

- Stored in Elasticsearch for analysis
- Managed with different retention policies per service
- Organized to prevent field mapping conflicts between services
- Automatically cleaned up based on service-specific requirements

### Pain Points

#### A. Field Mapping Conflicts

When all containers write to a single index pattern (e.g., `logstash-*`), different services may use the same field name with different data types, causing conflicts:

- Service A: `status` → string ("running", "stopped")
- Service B: `status` → integer (200, 404)
- **Result:** Index mapping conflicts, failed ingestion

#### B. One-Size-Fits-All Retention

Using a single ILM policy for all services means:

- Critical audit logs deleted too soon
- Test/debug logs kept too long (wasting storage)
- No flexibility for compliance requirements per service

#### C. Manual Management Overhead

Creating and managing:

- Separate index templates for each service
- Individual ILM policies for each service
- Rollover aliases for each service

**Result:** Significant operational burden at scale (dozens to hundreds of services)

---

## 2. Technical Challenges

### Challenge 1: Static ILM Configuration

**Current Logstash Limitation:**

```ruby
output {
  elasticsearch {
    ilm_enabled => true
    ilm_rollover_alias => "logs"      # Static - same for all events
    ilm_policy => "standard-policy"   # Static - same for all events
  }
}
```

**Problem:** All containers write to the same index pattern with the same policy.

### Challenge 2: No Per-Event ILM Support

Logstash's ILM implementation creates resources at **startup**, not per-event:

- Template created once at startup
- ILM policy must exist before Logstash starts
- Rollover alias created once at startup

**Problem:** Cannot dynamically create resources based on event data.

### Challenge 3: Field Mapping Conflicts

**Scenario:**

```
uibackend container logs:           {"response_time": 0.123}    # float
e3fbrandmapperbetgenius logs:       {"response_time": "123ms"}  # string
betplacement logs:                  {"response_time": 123}      # integer
```

**Result:** All three cannot coexist in the same index template.

---

## 3. Requirements

### Functional Requirements

#### FR1: Dynamic ILM Policy Creation

- **Requirement:** Automatically create one ILM policy per container
- **Naming:** `<container-name>-ilm-policy`
- **Trigger:** When first event from a container arrives
- **Behavior:** Policy created once, never overwritten

**Example:** First event from `uibackend` creates `uibackend-ilm-policy`

#### FR2: Dynamic Template Creation

- **Requirement:** Automatically create one index template per container
- **Naming:** `logstash-<container-name>`
- **Pattern:** Matches `<container-name>-*` indices
- **Behavior:** Template created once, never overwritten

**Example:** First event from `betplacement` creates `logstash-betplacement` template

#### FR3: Dynamic Index Creation

- **Requirement:** Automatically create rollover indices per container
- **Naming:** `<container-name>-YYYY.MM.DD-000001`
- **Alias:** `<container-name>` (write alias)
- **Behavior:** Managed by ILM policy

**Example:** First event from `e3fbrandmapperbetgenius` creates `e3fbrandmapperbetgenius-2025.11.15-000001`

#### FR4: Configurable Policy Defaults

Users must be able to set default ILM policy settings in Logstash config:

- Rollover conditions (age, size, doc count)
- Hot phase priority
- Delete phase timing
- Delete phase enable/disable

**Example:**

```ruby
ilm_rollover_max_age => "1d"
ilm_rollover_max_size => "50gb"
ilm_delete_min_age => "7d"
ilm_delete_enabled => true
```

#### FR5: Manual Policy Customization

- Users can edit policies in Kibana after creation
- Manual changes must be preserved (no overwriting)
- Per-service customization without code changes

#### FR6: Backward Compatibility

- Existing static ILM configurations must continue to work
- No breaking changes to current Logstash configurations
- Dynamic mode activated only when using sprintf placeholders

### Non-Functional Requirements

#### NFR1: Performance

- **Overhead:** Minimal performance impact (< 5% CPU increase)
- **Caching:** Thread-safe caching to prevent duplicate resource creation
- **Scalability:** Support hundreds of unique containers without degradation

#### NFR2: Reliability

- **Error Handling:** Graceful failure if policy/template creation fails
- **Idempotency:** Safe to restart Logstash without resource duplication
- **Thread Safety:** Concurrent event processing without race conditions

#### NFR3: Observability

- **Logging:** Clear logs when resources are created
- **Debugging:** Easy to verify which policies/templates exist
- **Monitoring:** No silent failures

#### NFR4: Maintainability

- **Code Quality:** Follow existing Logstash plugin patterns
- **Documentation:** Comprehensive user documentation
- **Testing:** Verifiable through integration tests

---

## 4. Use Cases

### Use Case 1: Microservices Platform

**Scenario:** 50 microservices, each with different retention needs

**Services:**

- `betplacement` → 90 days retention (compliance)
- `uibackend` → 30 days retention (security)
- `e3fbrandmapperbetgenius` → 7 days retention (standard)
- `test-service` → 1 day retention (cleanup)

**Solution:**

- Each gets its own ILM policy
- Each gets its own template (no field conflicts)
- Set defaults in Logstash, customize in Kibana

### Use Case 2: Multi-Tenant Logging

**Scenario:** Multiple customers, isolated indices per customer

**Requirements:**

- Customer A data isolated from Customer B
- Different retention per customer
- Separate templates to allow custom fields

**Solution:**

- `container_name` field contains: `customer-a`, `customer-b`, etc.
- Each customer gets separate indices, templates, policies

### Use Case 3: Environment Separation

**Scenario:** Dev, staging, production logs need different handling

**Requirements:**

- Production: Long retention, high priority
- Staging: Medium retention
- Dev: Short retention, low priority

**Solution:**

- `container_name` includes environment: `betplacement-prod`, `betplacement-staging`, `betplacement-dev`
- Each gets appropriate ILM policy

---

## 5. Success Criteria

### Metric 1: Automation

- **Target:** 100% automated resource creation
- **Measure:** Zero manual template/policy creation needed
- **Benefit:** Reduced operational overhead

### Metric 2: Field Conflict Elimination

- **Target:** Zero field mapping conflicts between services
- **Measure:** All events successfully indexed
- **Benefit:** No data loss, no failed ingestion

### Metric 3: Storage Optimization

- **Target:** 30% reduction in storage costs
- **Measure:** Shorter retention for non-critical services
- **Benefit:** Lower Elasticsearch cluster costs

### Metric 4: Flexibility

- **Target:** Per-service policy customization in < 5 minutes
- **Measure:** Time from requirement to implementation
- **Benefit:** Faster compliance/regulatory adaptation

### Metric 5: Performance

- **Target:** < 5% overhead vs. static ILM
- **Measure:** Events/second throughput comparison
- **Benefit:** No significant resource increase

---

## 6. Constraints & Assumptions

### Constraints

1. **Elasticsearch Version:** Requires Elasticsearch 7.x or 8.x (ILM support)
2. **Logstash Version:** Based on Logstash 8.4.0
3. **Event Field Required:** Events must have a `container_name` field (or equivalent)
4. **Permissions:** Elasticsearch user needs `manage_ilm`, `manage_index_templates`, `create_index`

### Assumptions

1. **Container Names Are Stable:** Container names don't change frequently
2. **Reasonable Container Count:** < 1000 unique containers per cluster
3. **Network Connectivity:** Logstash can reliably communicate with Elasticsearch
4. **Event Volume:** Steady event flow (not extreme bursts)

---

## 7. Out of Scope

The following are **NOT** included in this solution:

1. **Data Streams:** This solution uses traditional indices with ILM, not data streams
2. **Cross-Cluster Replication:** No support for CCR configurations
3. **Searchable Snapshots:** Not automatically configured in ILM policies
4. **Custom Mapping Templates:** Uses default Logstash templates only
5. **Hot-Warm-Cold Architecture:** Only hot and delete phases implemented

---

## 8. Solution Approach

### High-Level Design

```
Event Flow:
┌─────────────┐
│   Event     │ container_name: "uibackend"
│  Arrives    │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────┐
│  Check Cache                │
│  "uibackend" created?       │
└──────┬──────────────────────┘
       │
       ├─ YES → Index Event (fast path)
       │
       └─ NO  → Create Resources:
              ┌─────────────────────┐
              │ 1. ILM Policy       │ uibackend-ilm-policy
              │ 2. Template         │ logstash-uibackend
              │ 3. Rollover Index   │ uibackend-2025.11.15-000001
              └─────────────────────┘
              │
              ▼
         Cache Result → Index Event
```

### Key Innovation

**Dynamic Resource Creation at Event Processing Time**

- Leverage existing Logstash HTTP client methods
- Create resources on-demand when first event arrives
- Cache results to prevent overhead on subsequent events
- Use thread-safe data structures for concurrent access

---

## 9. Expected Benefits

### Operational Benefits

- ✅ **Zero Manual Configuration:** No need to pre-create policies/templates
- ✅ **Auto-Scaling:** New services automatically get resources
- ✅ **Reduced Complexity:** Single Logstash config for all services

### Technical Benefits

- ✅ **No Field Conflicts:** Isolated templates per service
- ✅ **Flexible Retention:** Customize per service needs
- ✅ **Better Organization:** Clear index naming (`uibackend-*`, `api-*`)

### Business Benefits

- ✅ **Cost Savings:** Optimized retention reduces storage costs
- ✅ **Faster Compliance:** Easy per-service retention policies
- ✅ **Improved Reliability:** No ingestion failures from field conflicts

---

## 10. Next Steps

Upon approval, the implementation will:

1. ✅ Modify Logstash Elasticsearch output plugin
2. ✅ Add dynamic resource creation logic
3. ✅ Implement thread-safe caching
4. ✅ Add configuration options for policy defaults
5. ✅ Create comprehensive documentation
6. ✅ Build Docker image for deployment
7. ✅ Test in staging environment
8. ✅ Deploy to production

---

## Document Control

| Version | Date       | Author           | Changes                       |
| ------- | ---------- | ---------------- | ----------------------------- |
| 1.0     | 2025-11-15 | Engineering Team | Initial requirements document |

---

**Status:** ✅ Requirements Approved - Implementation Complete
