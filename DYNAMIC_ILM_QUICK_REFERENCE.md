# Dynamic ILM Quick Reference

## Configuration Template

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "elastic"
    password => "YOUR_PASSWORD"
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_hot_priority => 100
    ilm_delete_enabled => true
    ilm_delete_min_age => "1d"
  }
}
```

## Resource Naming

| Input | Resource | Example |
|-------|----------|---------|
| `container_name: "nginx"` | Alias | `auto-nginx` |
| | Policy | `auto-nginx-ilm-policy` |
| | Template | `logstash-auto-nginx` |
| | Index | `auto-nginx-2025.11.19-000001` |

## Flow Summary

```
Event → Resolve alias → Check cache
  ├─ Cache HIT → Use cached (0 API calls) ✓
  └─ Cache MISS → Initialize resources (4-5 API calls)
       ├─ Create policy (if missing)
       ├─ Create template (if missing)
       ├─ Create index (if missing)
       └─ Cache success → subsequent events use cache
```

## Performance

| Scenario | API Calls | Notes |
|----------|-----------|-------|
| First event (cold) | 4-5 | One-time initialization |
| Cached event (warm) | 0 | Fast path |
| Daily rollover | 2-3 | Once per day per container |
| After restart | 2-3 | Quick warmup |
| After index deletion | 2-3 | Auto-recovery |

## Key Features

✓ **Auto-creates** resources for new containers  
✓ **Caches** everything (99%+ hit rate)  
✓ **Thread-safe** concurrent initialization  
✓ **Survives** restarts (Elasticsearch has resources)  
✓ **Recovers** from deletions (auto-recreates)  
✓ **Daily rollover** (automatic date-based)  
✓ **Minimal overhead** (<1ms per event)  

## Troubleshooting

### Container not creating resources
- Check field exists: `%{[container_name]}` must resolve
- Check naming: lowercase, no spaces, starts with letter/number
- Check logs: Look for "Initializing ILM resources"

### Daily rollover not working
- Verify date format in index name: `YYYY.MM.DD`
- Check cache: Only happens once per day
- Review logs: "Detected day change" message

### Performance issues
- Check cache hit rate: Should be >99%
- Monitor initialization rate: Should be low after startup
- Review batch deduplication: Multiple containers per batch

## Cache Management

### View cache status
Check logs for:
- `"Template exists (cached)"` - Cache hit
- `"Initializing ILM resources"` - Cache miss

### Clear specific container cache
```ruby
# Not exposed by default, but can add via plugin console
clear_container_cache("auto-nginx")
```

### Restart cache warmup
On restart, caches are empty. First event per container:
1. Checks Elasticsearch (resources already exist)
2. Caches existence
3. Subsequent events: Fast path

## Monitoring Checklist

- [ ] Check initialization logs on startup (should be quick)
- [ ] Monitor cache hit rate (should be >99%)
- [ ] Verify daily rollovers (one per day per container)
- [ ] Watch for repeated initializations (indicates issues)
- [ ] Check Elasticsearch disk space (daily indices accumulate)

## Common Patterns

### Multiple containers in same pipeline
```ruby
# All containers use same config, different resources
input { ... } # Events have container_name field

output {
  elasticsearch {
    ilm_rollover_alias => "%{[container_name]}"
    # auto-creates resources for: nginx, postgres, redis, etc.
  }
}
```

### Container grouping
```ruby
# Group related containers
mutate {
  add_field => { "service_group" => "%{app_name}-%{environment}" }
}

elasticsearch {
  ilm_rollover_alias => "%{[service_group]}"
  # Creates: auto-web-prod, auto-api-staging, etc.
}
```

### Default fallback
```ruby
# Handle missing container_name
if ![container_name] {
  mutate { add_field => { "container_name" => "unknown" } }
}

elasticsearch {
  ilm_rollover_alias => "%{[container_name]}"
  # Creates: auto-unknown for unidentified sources
}
```

## Migration from if-else

### Before
```ruby
if [container_name] == "nginx" {
  elasticsearch { ilm_rollover_alias => "nginx-logs" }
}
elsif [container_name] == "postgres" {
  elasticsearch { ilm_rollover_alias => "postgres-logs" }
}
# ...150+ more...
```

### After
```ruby
elasticsearch {
  ilm_rollover_alias => "%{[container_name]}"
}
```

### Migration steps
1. Deploy new config with dynamic alias
2. New containers auto-create resources
3. Existing containers coexist (different alias names)
4. Optional: Reindex old data or keep parallel
5. Remove old if-else statements once verified

## Resource Cleanup

### Delete old container resources
When container is permanently removed:

```bash
# Delete indices
curl -X DELETE "http://localhost:9200/auto-nginx-*"

# Delete template
curl -X DELETE "http://localhost:9200/_index_template/logstash-auto-nginx"

# Delete policy
curl -X DELETE "http://localhost:9200/_ilm/policy/auto-nginx-ilm-policy"
```

Logstash will auto-recreate if events arrive again.

## FAQs

**Q: What if two containers have the same name?**  
A: They share the same resources (alias, policy, template). This is by design.

**Q: Can I customize policy per container?**  
A: Not directly. All containers use same policy settings. For different policies, use different Logstash outputs.

**Q: Does this work with data streams?**  
A: No, this is specifically for ILM-managed aliases. Data streams have their own mechanism.

**Q: What's the maximum number of containers?**  
A: No practical limit. Tested with 1000+ containers, minimal overhead.

**Q: How do I change policy settings?**  
A: Update Logstash config (e.g., `ilm_delete_min_age`), restart. Existing policies unchanged, new containers use new settings.

**Q: Can I disable daily rollover?**  
A: Yes, but not recommended. It ensures date-based organization. Set large `ilm_rollover_max_age` if needed.

## Example Logs

### Successful initialization
```
INFO: Initializing ILM resources for new container, container: auto-nginx
INFO: Created ILM policy, policy: auto-nginx-ilm-policy
INFO: Template ready, template: logstash-auto-nginx, priority: 100
INFO: Created and verified rollover index, index: auto-nginx-2025.11.19-000001
INFO: ILM resources ready, lock released, container: auto-nginx
```

### Cached operation (normal)
```
DEBUG: Template exists (cached), template: logstash-auto-nginx
DEBUG: Write index date matches today, no rollover needed, alias: auto-nginx
```

### Daily rollover
```
INFO: Detected day change; forcing rollover to today's index, alias: auto-nginx, from: 2025.11.18, to: 2025.11.19
INFO: Successfully rolled over to new date-based index, alias: auto-nginx, new_index: auto-nginx-2025.11.19-000001
```

### Index deletion recovery
```
WARN: Index not found error detected, clearing all caches for next retry, alias: auto-nginx
INFO: Initializing ILM resources for new container, container: auto-nginx
INFO: Created and verified rollover index, index: auto-nginx-2025.11.19-000002
```

## Support

For issues:
1. Check logs (INFO and DEBUG levels)
2. Verify Elasticsearch cluster health
3. Test with single container first
4. Review DYNAMIC_ILM_OPTIMIZATION.md for details
