# Documentation Update Plan

**Date**: December 10, 2025
**Purpose**: Correct ProductionForecast documentation to match actual code implementation

---

## Key Corrections Needed

### 1. Caching Implementation
**WRONG**: ProductionForecast uses Redis for distributed caching
**CORRECT**: ProductionForecast uses IMemoryCache (local in-memory cache only)

### 2. Cache Invalidation
**WRONG**: Uses Redis Pub/Sub for cross-instance synchronization
**CORRECT**: Uses CDC (Change Data Capture) for cache invalidation triggers

### 3. Electric.Core Usage
**WRONG**: ProductionForecast uses Electric.Core for Pulsar messaging and distributed features
**CORRECT**: ProductionForecast uses Electric.Core ONLY for CDC table change tracking

### 4. Architecture Pattern
**WRONG**: Distributed caching with Redis + Pulsar messaging
**CORRECT**: Simple cache-aside pattern with local IMemoryCache + CDC invalidation

---

## Files to Update

### High Priority (ProductionForecast-specific)

1. `notes/level_0/production_forecast/part_2_business_logic_caching.md`
   - Line 80: Remove "Redis Pub/Sub", add "CDC detection"
   - Update CacheManager section to clarify IMemoryCache usage
   - Remove distributed cache references

2. `notes/level_1/component_guide_production_forecast.md`
   - Update caching architecture section
   - Remove Redis from component dependencies
   - Add IMemoryCache + CDC explanation

3. `notes/level_1/synthesis_architectural_patterns.md`
   - Update ProductionForecast caching pattern
   - Clarify it's local-only, not distributed

4. `docs/components/production_forecast/*.md`
   - Update all caching references
   - Remove Redis dependencies
   - Add actual implementation details

### Medium Priority (Infrastructure - verify if used)

5. `notes/level_1/component_guide_infrastructure.md`
   - Check if Redis section applies to ProductionForecast
   - May apply to NotificationService instead

6. `notes/level_0/infrastructure/part_1_core_infrastructure_services.md`
   - Verify Redis usage context
   - May be NotificationService-specific

### Low Priority (General documentation)

7. README files
8. DOCUMENTATION_MAP files
9. Setup guides (if they mention ProductionForecast + Redis)

---

## Update Strategy

### Phase 1: Core ProductionForecast Files
- Update part_2_business_logic_caching.md
- Update component_guide_production_forecast.md
- Update architectural patterns for ProductionForecast

### Phase 2: Docs Folder
- Update all docs/components/production_forecast/*.md
- Update architecture diagrams

### Phase 3: Cross-references
- Update synthesis documents
- Update troubleshooting guides
- Update performance guides

---

## Specific Text Replacements

### For ProductionForecast Context Only:

| Old Text | New Text |
|----------|----------|
| "Redis distributed cache" | "IMemoryCache (in-memory cache)" |
| "Redis Pub/Sub for sync" | "CDC (Change Data Capture) for invalidation" |
| "CRDT-like distributed cache" | "Local cache with CDC invalidation" |
| "StackExchangeRedisConnection" | "(Not used by ProductionForecast)" |
| "Redis field-level versioning" | "(Infrastructure feature, not used by ProductionForecast)" |
| "Multi-instance cache sync" | "Per-instance cache with CDC invalidation" |

### Electric.Core Clarifications:

| Old Text | New Text |
|----------|----------|
| "Electric.Core provides distributed features" | "Electric.Core provides CDC tracking (change detection only)" |
| "Electric.Core Pulsar integration" | "(Not used by ProductionForecast - Electric.Core only used for CDC)" |
| "Electric.Core message bus" | "(Not used by ProductionForecast)" |

---

## Architecture Diagram Updates

### Old Diagram (Incorrect):
```
ProductionForecast → Redis → Pulsar → Other Instances
```

### New Diagram (Correct):
```
ProductionForecast → IMemoryCache (local)
                  → Database CDC → Invalidation Signal
```

---

## Next Steps

1. ✅ Created ACTUAL_DEPENDENCIES.md with findings
2. ✅ Created this UPDATE_PLAN.md
3. ⏳ Update notes/level_0/production_forecast/part_2_business_logic_caching.md
4. ⏳ Update notes/level_1/component_guide_production_forecast.md
5. ⏳ Update docs/components/production_forecast/*.md
6. ⏳ Update architecture documents
7. ⏳ Update README and index files

---

## Validation Checklist

After updates, verify:
- [ ] No mention of "ProductionForecast uses Redis"
- [ ] IMemoryCache clearly stated as cache mechanism
- [ ] CDC explained as invalidation trigger
- [ ] Electric.Core scope limited to CDC tracking
- [ ] No Pulsar references for ProductionForecast
- [ ] OutputCache middleware mentioned
- [ ] Architecture diagrams show correct flow

---

## Notes

- NotificationService MAY actually use Redis - verify before changing those references
- Infrastructure layer MAY use Redis - verify before changing those references
- Only update ProductionForecast-specific content
- Keep helper library documentation separate from service-level documentation
