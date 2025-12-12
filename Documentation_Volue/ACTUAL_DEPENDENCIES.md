# ProductionForecast Service - Actual Dependencies

**Analysis Date**: December 10, 2025
**Based on**: Code inspection of SmartPulse.Services.ProductionForecast

---

## Summary

ProductionForecast service uses **IMemoryCache** for in-memory caching, **NOT Redis**. It uses Electric.Core library ONLY for CDC (Change Data Capture) functionality, NOT for Pulsar messaging.

---

## NuGet Packages Used

### Main Web Service (SmartPulse.Web.Services.csproj)
```xml
- Microsoft.AspNetCore.Mvc.Versioning (5.1.0)
- Microsoft.AspNetCore.OpenApi (9.0.3)
- SmartPulse.Infrastructure.Data (7.0.9)
- Swashbuckle.AspNetCore (8.0.0)
```

### Application Layer (SmartPulse.Application.csproj)
```xml
- Electric.Core (7.0.158) - Used ONLY for CDC tracking
- SmartPulse.Infrastructure.Core (7.0.4)
- SmartPulse.Contract.Services.Presentation.GraphQL.Client (1.4.16)
- SmartPulse.Services.NotificationService (7.0.0)
```

---

## Caching Strategy

### 1. IMemoryCache (Primary Cache)
**Location**: `SmartPulse.Application/CacheManager.cs`
**Implementation**:
```csharp
private readonly IMemoryCache _memoryCache = new MemoryCache(
    new MemoryCacheOptions { ExpirationScanFrequency = SystemVariables.ExpirationScanFrequency }
);
```

**What is cached**:
- AllPowerPlantGipConfig
- PowerPlantHierarchies
- PowerPlantTimeZones
- UserRoles
- UserAccessibleUnits
- CompanyProviderSettings
- CompanyLimitSettings
- GroupIntradaySettings
- GroupActiveContracts

### 2. OutputCache Middleware
**Location**: `SmartPulse.Web.Services/Extensions/IServiceCollectionExtensions.cs:56-65`
**Implementation**:
```csharp
services.AddOutputCache(options =>
{
    options.AddPolicy("Forecast", builder =>
    {
        builder
            .AddPolicy<ForecastPolicy>()
            .SetVaryByHost(false)
            .Expire(TimeSpan.FromMinutes(appSettings.CacheSettings.OutputCache.Duration));
    });
});
```

**Purpose**: HTTP response caching at API level

---

## Database Access

### Entity Framework Core
**DbContext**: `SmartPulse.Entities.Sql.ForecastDbContext`
**Configuration**: Via `SmartPulse.Infrastructure.Data` package

**Key Entities**:
- T004Forecast (main forecast table)
- T004ForecastBatchInfo
- T004ForecastLock
- PowerPlant
- CompanyPowerPlant
- SysUserRole
- T000EntityPermission

---

## Change Data Capture (CDC)

### Electric.Core Usage
**Purpose**: ONLY for CDC table change tracking
**NOT used for**: Pulsar messaging, distributed messaging, event bus

**Tracked Tables**:
```csharp
// From IServiceCollectionExtensions.cs:80-91
services.AddSmartpulseTableChangeTracker<T000EntityPermissionsTracker>();
services.AddSmartpulseTableChangeTracker<T000EntityPropertyTracker>();
services.AddSmartpulseTableChangeTracker<T000EntitySystemHierarchyTracker>();
services.AddSmartpulseTableChangeTracker<SysUserRolesTracker>();
services.AddSmartpulseTableChangeTracker<PowerPlantTracker>();
services.AddSmartpulseTableChangeTracker<T004ForecastLatestTracker>(); // Optional
```

**How it works**:
1. Electric.Core monitors database change tables
2. When changes detected → triggers cache invalidation
3. CacheManager.ExpireCacheByKey() called
4. Local IMemoryCache entries removed

---

## Background Services

### 1. CacheInvalidationService
**Purpose**: Alternative to CDC for cache invalidation
**When used**: If `UseCacheInvalidationService = true` in config

### 2. SystemVariableRefresher
**Purpose**: Periodically refresh system variables
**Always active**: Yes

---

## What ProductionForecast DOES NOT Use

❌ **Redis** - No Redis connection, no distributed cache
❌ **Apache Pulsar** - No message bus, no event streaming
❌ **Electric.Core Pulsar features** - Only uses CDC tracking
❌ **Distributed caching** - Only local IMemoryCache
❌ **Message queues** - No async messaging

---

## Architecture Pattern

**Cache Pattern**: Cache-Aside with local in-memory storage
**Invalidation**: CDC-based or background polling
**Data Flow**:
```
1. API Request → Check IMemoryCache
2. Cache Miss → Query EF Core → Store in IMemoryCache
3. Cache Hit → Return from IMemoryCache
4. Data Change → CDC detects → Invalidate cache key
```

---

## Key Takeaways

1. **Simple caching**: Just IMemoryCache, no distributed cache needed
2. **Electric.Core is a helper**: Only used for CDC tracking feature
3. **No messaging**: No Pulsar, no message bus, no events
4. **Single-instance friendly**: Each instance has its own cache
5. **CDC for consistency**: Changes detected via database CDC, not messaging

---

## Documentation Updates Needed

### Notes Folder
- Remove all Redis references for ProductionForecast
- Clarify Electric.Core is only for CDC, not messaging
- Remove Pulsar references from ProductionForecast context
- Update caching documentation to focus on IMemoryCache

### Docs Folder
- Remove Redis from ProductionForecast architecture diagrams
- Remove Pulsar from ProductionForecast data flow
- Update caching patterns to show IMemoryCache only
- Clarify Electric.Core usage (CDC only, not full feature set)

---

**Conclusion**: ProductionForecast is a simpler service than documented. It uses local IMemoryCache and ASP.NET Core OutputCache, with Electric.Core providing only CDC functionality for cache invalidation.
