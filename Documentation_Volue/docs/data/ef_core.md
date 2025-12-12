# Entity Framework Core Strategy

**Last Updated**: 2025-11-12
**Version**: .NET 7/8/9 multi-targeting

---

## ⚠️ CRITICAL - ProductionForecast Service Scope

**This document may describe infrastructure capabilities (Redis, Pulsar, etc.).**

**ProductionForecast ACTUALLY uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY)
- ✅ Entity Framework Core

**ProductionForecast does NOT use:**
- ❌ Redis
- ❌ Apache Pulsar
- ❌ Distributed caching
- ❌ Message bus

Other services (NotificationService) may use these technologies.

---


## Table of Contents

1. [DbContext Design](#dbcontext-design)
2. [Query Optimization](#query-optimization)
3. [Second-Level Caching](#second-level-caching)
4. [Bulk Operations](#bulk-operations)
5. [Interceptors](#interceptors)
6. [Change Tracking](#change-tracking)
7. [Migrations](#migrations)
8. [Performance Tuning](#performance-tuning)

---

## SmartPulse Infrastructure Setup

### Configuration Extension

**File**: `Infrastructure.Data/Extension/IServiceCollectionExtension.cs`

SmartPulse provides a comprehensive DbContext configuration extension:

```csharp
public static IServiceCollection AddSmartPulseDbContext<TContext>(
    this IServiceCollection services,
    string connectionString,
    bool enableSecondLevelCaching = true,
    bool enableSecondLevelCachingOnlyForSpecificTables = false,
    IEnumerable<string> secondLevelCachedTables = null)
    where TContext : DbContext
{
    services.AddDbContext<TContext>((serviceProvider, optionsBuilder) =>
    {
        optionsBuilder
            .UseSqlServer(connectionString, sqlOptions =>
            {
                // Retry policy for transient failures
                sqlOptions.EnableRetryOnFailure(
                    maxRetryCount: 5,
                    maxRetryDelay: TimeSpan.FromSeconds(30),
                    errorNumbersToAdd: null);

                // Command timeout
                sqlOptions.CommandTimeout(180);  // 3 minutes

                // Batch size (1 = no batching, preserves order)
                sqlOptions.MaxBatchSize(1);

                // Backward compatibility
                sqlOptions.TranslateInQueryBackToFuture();
            })
            .EnableSensitiveDataLogging(isDevelopment)
            .LogTo(Console.WriteLine, LogLevel.Warning);

        // Lazy loading proxies
        optionsBuilder.UseLazyLoadingProxies();

        // Add interceptors
        optionsBuilder.AddInterceptors(
            new PerformanceInterceptor(minMillisecondsForDbQueries: 100),
            new AuditInterceptor(),
            new SoftDeleteQueryFilterInterceptor());

        // Configure context pooling
        if (enableContextPooling)
        {
            optionsBuilder.UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking);
        }
    });

    // Context pooling (128 instances)
    services.AddDbContextPool<TContext>(poolSize: 128);

    // Second-level caching
    if (enableSecondLevelCaching)
    {
        services.AddSmartPulseSecondLevelCache(
            specificTables: enableSecondLevelCachingOnlyForSpecificTables
                ? secondLevelCachedTables
                : null);
    }

    return services;
}
```

**Key Configuration Parameters**:

| Setting | Value | Purpose |
|---------|-------|---------|
| Retry Max Count | 5 | Automatic retry on transient errors |
| Retry Max Delay | 30s | Maximum delay between retries |
| Command Timeout | 180s | Query execution timeout |
| Max Batch Size | 1 | Preserve statement order |
| Context Pool Size | 128 | Reuse DbContext instances |
| Query Tracking | NoTracking | Read-only optimization |

**Retry Backoff Strategy**:
```
Attempt 1: ~0ms (immediate)
Attempt 2: ~1s
Attempt 3: ~3s
Attempt 4: ~7s
Attempt 5: ~15s
Total max: ~30s
```

**Transient Error Codes** (SQL Server):
- 40197: Service temporarily unavailable
- 40501: Service is busy
- 40613: Database unavailable
- -2: Timeout
- -1: Connection lost

See also:
- [Retry Patterns](../patterns/retry_patterns.md)
- [Database Infrastructure](../architecture/database.md)

---

## DbContext Design

### Multi-Tenant DbContext Pattern

```csharp
public class ForecastDbContext : DbContext
{
    public ForecastDbContext(DbContextOptions<ForecastDbContext> options)
        : base(options) { }

    // Domain aggregates
    public DbSet<Forecast> Forecasts { get; set; }
    public DbSet<ForecastDetail> ForecastDetails { get; set; }
    public DbSet<Order> Orders { get; set; }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        // Configure entities
        modelBuilder.Entity<Forecast>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Price).HasPrecision(18, 2);
            entity.HasMany(e => e.Details)
                .WithOne(d => d.Forecast)
                .HasForeignKey(d => d.ForecastId)
                .OnDelete(DeleteBehavior.Cascade);

            // Indexes for performance
            entity.HasIndex(e => e.CreatedAt);
            entity.HasIndex(e => e.ValidFrom);
            entity.HasIndex(e => new { e.Status, e.CreatedAt });
        });

        // Enable audit trails
        foreach (var entity in modelBuilder.Model.GetEntityTypes())
        {
            if (typeof(IAuditableEntity).IsAssignableFrom(entity.ClrType))
            {
                modelBuilder.Entity(entity.ClrType)
                    .Property<DateTime>("CreatedAt");
                modelBuilder.Entity(entity.ClrType)
                    .Property<DateTime>("ModifiedAt");
            }
        }
    }
}
```

### Dependency Injection

```csharp
// Program.cs
services.AddDbContext<ForecastDbContext>(options =>
{
    options.UseSqlServer(
        configuration.GetConnectionString("DefaultConnection"),
        sqlOptions =>
        {
            sqlOptions.CommandTimeout(30);
            sqlOptions.EnableRetryOnFailure(
                maxRetryCount: 3,
                maxRetryDelaySeconds: 2,
                errorNumbersToAdd: null);
        });

    // Enable query caching
    options.EnableDetailedErrors();
    options.EnableSensitiveDataLogging(isDevelopment);
});

// Add query cache interceptor
services.AddSingleton<QueryCacheInterceptor>();
```

---

## Query Optimization

### N+1 Query Problem

**Scenario**: Loading forecasts and their details

```csharp
// ❌ BAD: N+1 queries (1 for forecasts + N for details)
var forecasts = await _context.Forecasts.ToListAsync();
foreach (var forecast in forecasts)
{
    var details = forecast.Details; // Triggers query per forecast
    Console.WriteLine($"Details: {details.Count}");
}

// ✅ GOOD: Single query with includes
var forecasts = await _context.Forecasts
    .Include(f => f.Details)      // Load details in single query
    .ToListAsync();

foreach (var forecast in forecasts)
{
    Console.WriteLine($"Details: {forecast.Details.Count}"); // No query
}
```

### Efficient Projections

```csharp
// ❌ BAD: Load all fields then project
var forecasts = await _context.Forecasts
    .AsNoTracking()
    .Include(f => f.Details)
    .ToListAsync();  // Load everything

var result = forecasts
    .Select(f => new ForecastSummary
    {
        Id = f.Id,
        Price = f.Price
    })
    .ToList();

// ✅ GOOD: Project at database
var result = await _context.Forecasts
    .AsNoTracking()
    .Select(f => new ForecastSummary
    {
        Id = f.Id,
        Price = f.Price,
        DetailCount = f.Details.Count  // Computed at database
    })
    .ToListAsync();  // Only required columns fetched
```

### Query Execution Plans

```csharp
// Analywithe query performance
var query = _context.Forecasts
    .Include(f => f.Details)
    .Where(f => f.Status == "Active");

// Get SQL
var sql = query.ToQueryString();
Console.WriteLine(sql);

// Execute and measure
using var timer = new Timer((s) =>
{
    Console.WriteLine("Query taking long...");
}, null, TimeSpan.FromSeconds(5), Timeout.InfiniteTimeSpan);

var data = await query.ToListAsync();
```

### Filtered Includes (EF Core 5+)

```csharp
// Load only active details
var forecasts = await _context.Forecasts
    .Include(f => f.Details.Where(d => d.IsActive))
    .ToListAsync();

// Nested filtered includes
var forecasts = await _context.Forecasts
    .Include(f => f.Details.Where(d => d.IsActive))
        .ThenInclude(d => d.Tags.Where(t => t.Category == "important"))
    .ToListAsync();
```

---

## Second-Level Caching

### SmartPulse Second-Level Cache Configuration

**Implementation**: In-memory query result caching with automatic invalidation.

```csharp
public static IServiceCollection AddSmartPulseSecondLevelCache(
    this IServiceCollection services,
    IEnumerable<string> specificTables = null)
{
    services.AddEasyCaching(options =>
    {
        options.UseInMemory(config =>
        {
            config.MaxRdisSize = 10_000;  // Max 10K items
            config.ExpireScanning = TimeSpan.FromSeconds(60);
        });
    });

    services.AddTransient<SecondLevelCacheInterceptor>();

    return services;
}
```

**Cache Configuration**:

| Setting | Value | Purpose |
|---------|-------|---------|
| Max Items | 10,000 | Maximum cached queries |
| Scan Interval | 60s | Expiration check frequency |
| Deep Clone | Disabled | Performance optimization |
| TTL | Configurable | Per-table configuration |

**Interceptor Implementation**:

```csharp
public class SecondLevelCacheInterceptor : SaveChangesInterceptor
{
    private readonly IEasyCachingProvider _cache;
    private const string QUERY_CACHE_KEY = "eq_{0}_{1}";

    public override async ValueTask<InterceptionResult<int>> SavingChangesAsync(
        DbContextEventData eventData,
        InterceptionResult<int> result,
        CancellationToken cancellationToken = default)
    {
        // Track changed entities
        var changedEntities = eventData.Context.ChangeTracker
            .Entries()
            .Where(e => e.State != EntityState.Unchanged)
            .Select(e => e.Entity.GetType().Name)
            .Distinct();

        // Invalidate related queries
        foreach (var entity in changedEntities)
        {
            var cacheKey = string.Format(QUERY_CACHE_KEY, "GetAll", entity);
            await _cache.RemoveAsync(cacheKey);
        }

        return await base.SavingChangesAsync(eventData, result, cancellationToken);
    }
}
```

**Benefits**:
- Automatic invalidation on entity changes
- Entity-level cache granularity
- No manual cache management required
- ~60-70% hit rate typical

See also:
- [Caching Patterns](../patterns/caching_patterns.md)
- [Multi-Level Cache Strategy](../architecture/caching.md)

### Query Cache Implementation

```csharp
public static class QueryCacheExtensions
{
    public static IQueryable<T> WithCache<T>(this IQueryable<T> query,
        string cacheKey = null,
        TimeSpan? duration = null) where T : class
    {
        // Store metadata for interceptor
        var cacheInfo = new QueryCacheInfo
        {
            Key = cacheKey ?? GetDefaultCacheKey(query),
            Duration = duration ?? TimeSpan.FromHours(1)
        };

        // Tag query for interceptor
        return query.TagWith($"cache:{cacheInfo.Key}");
    }
}

// Usage
var forecast = await _context.Forecasts
    .WithCache($"forecast-{id}", TimeSpan.FromHours(1))
    .FirstOrDefaultAsync(f => f.Id == id);
```

### Interceptor-Based Caching

```csharp
public class QueryCacheInterceptor : DbCommandInterceptor
{
    private readonly IMemoryCache _cache;

    public override async ValueTask<InterceptionResult<DbDataReader>>
        ReaderExecutingAsync(DbCommand command,
            CommandEventData eventData,
            InterceptionResult<DbDataReader> result,
            CancellationToken cancellationToken = default)
    {
        // Extract cache key from query tag
        var cacheKey = ExtractCacheKey(command.CommandText);

        if (cacheKey != null && _cache.TryGetValue(cacheKey, out var cached))
        {
            // Return cached result (convert to DbDataReader)
            return InterceptionResult<DbDataReader>.SuppressWithResult(
                new CachedDataReader(cached));
        }

        return result;
    }

    public override async ValueTask<InterceptionResult<object>>
        ReaderExecutedAsync(DbCommand command,
            CommandExecutedEventData eventData,
            InterceptionResult<object> result,
            CancellationToken cancellationToken = default)
    {
        // Cache the result
        var cacheKey = ExtractCacheKey(command.CommandText);
        if (cacheKey != null && result.Result != null)
        {
            _cache.Set(cacheKey, result.Result,
                new MemoryCacheEntryOptions()
                    .SetAbsoluteExpiration(TimeSpan.FromHours(1)));
        }

        return result;
    }
}
```

### Manual Query Cache

```csharp
public class CachedForecastRepository
{
    private readonly ForecastDbContext _context;
    private readonly IMemoryCache _cache;

    public async Task<Forecast> GetByIdAsync(string id)
    {
        var cacheKey = $"forecast-{id}";

        // Check cache first
        if (_cache.TryGetValue(cacheKey, out Forecast cached))
            return cached;

        // Query database
        var forecast = await _context.Forecasts
            .AsNoTracking()
            .FirstOrDefaultAsync(f => f.Id == id);

        if (forecast != null)
        {
            // Cache result
            _cache.Set(cacheKey, forecast,
                new MemoryCacheEntryOptions()
                    .SetAbsoluteExpiration(TimeSpan.FromHours(1)));
        }

        return forecast;
    }
}
```

### Tag-Based Cache Invalidation

```csharp
public class CacheInvalidationService
{
    private readonly IMemoryCache _cache;

    public void InvalidateByTag(string tag)
    {
        // All keys starting with tag are invalidated
        // Implementation depends on IMemoryCache version
        // Option 1: Use CancellationTokens
        // Option 2: Use custom tracking
        // Option 3: Use MemoryCache with manual key tracking
    }

    public void InvalidateForecast(string forecastId)
    {
        // Invalidate specific forecast
        _cache.Remove($"forecast-{forecastId}");
        _cache.Remove($"forecast-list");

        // Invalidate related
        _cache.Remove($"orders-for-forecast-{forecastId}");
    }
}
```

---

## Bulk Operations

### Batch Insert

```csharp
public async Task BulkInsertForecastsAsync(IList<Forecast> forecasts)
{
    // Chunked insert (avoid max pairmeter limit)
    const int batchSize = 1000;

    for (int i = 0; i < forecasts.Count; i += batchSize)
    {
        var batch = forecasts.Skip(i).Take(batchSize).ToList();
        await _context.Forecasts.AddRangeAsync(batch);
        await _context.SaveChangesAsync();
    }
}
```

### Stored Procedure Insert

```csharp
// Defin stored proc
modelBuilder.Entity<Forecast>()
    .HasNoKey()
    .ToSqlQuery("SELECT * FROM sp_GetForecasts(@p0)");

// Call via raw SQL
public async Task<List<Forecast>> BulkInsertViaStoredProcAsync(
    List<Forecast> forecasts)
{
    // Prepare JSON table
    var json = JsonConvert.SerializeObject(forecasts);

    var result = await _context.Forecasts
        .FromSqlInterafterlated($"EXEC sp_InsertForecasts {json}")
        .ToListAsync();

    return result;
}
```

### Efficient Update Pattern

```csharp
// ❌ BAD: Load, update, save (slow)
var forecasts = await _context.Forecasts
    .Where(f => f.Status == "pending")
    .ToListAsync();

foreach (var f in forecasts)
{
    f.Status = "processsed";
}
await _context.SaveChangesAsync();

// ✅ GOOD: Direct database update
var updated = await _context.Forecasts
    .Where(f => f.Status == "pending")
    .ExecuteUpdateAsync(setters =>
        setters.SetProperty(f => f.Status, "processsed"));
```

### Batch Delete

```csharp
// ✅ Direct database delete
var deleted = await _context.Forecasts
    .Where(f => f.CreatedAt < DateTime.UtcNow.AddDays(-30))
    .ExecuteDeleteAsync();

Console.WriteLine($"Deleted {deleted} old forecasts");
```

---

## Interceptors

### Audit Trail Interceptor

```csharp
public class AuditTrailInterceptor : SaveChangesInterceptor
{
    public override ValueTask<InterceptionResult<int>> SavingChangesAsync(
        DbContextEventData eventData,
        InterceptionResult<int> result,
        CancellationToken cancellationToken = default)
    {
        var context = eventData.Context;

        foreach (var entry in context.ChangeTracker.Entries())
        {
            if (entry.Entity is IAuditableEntity auditableEntity)
            {
                switch (entry.State)
                {
                    case EntityState.Added:
                        auditableEntity.CreatedAt = DateTime.UtcNow;
                        auditableEntity.ModifiedAt = DateTime.UtcNow;
                        break;
                    case EntityState.Modified:
                        auditableEntity.ModifiedAt = DateTime.UtcNow;
                        break;
                }
            }
        }

        return base.SavingChangesAsync(eventData, result, cancellationToken);
    }
}
```

### Slow Query Logging Interceptor

```csharp
public class SlowQueryInterceptor : DbCommandInterceptor
{
    private readonly ILogger<SlowQueryInterceptor> _logger;
    private readonly Stopwatch _stopwatch = new();

    public override void CommandCreated(
        CommandEndEventData eventData,
        InterceptionResult<DbCommand> result)
    {
        _stopwatch.Restart();
    }

    public override async ValueTask<InterceptionResult<DbDataReader>>
        ReaderExecutedAsync(DbCommand command,
            CommandExecutedEventData eventData,
            InterceptionResult<DbDataReader> result,
            CancellationToken cancellationToken = default)
    {
        _stopwatch.Stop();

        if (_stopwatch.ElapsedMilliseconds > 200)
        {
            _logger.LogWarning(
                "Slow query ({Duration}ms): {Query}",
                _stopwatch.ElapsedMilliseconds,
                command.CommandText);
        }

        return result;
    }
}
```

---

## Change Tracking

### Explicit Change Tracking

```csharp
// Track specific entities
var forecast = await _context.Forecasts
    .AsTracking()  // Explicit tracking
    .FirstOrDefaultAsync(f => f.Id == id);

forecast.Price = 100;
await _context.SaveChangesAsync();

// Track multiple
var forecasts = await _context.Forecasts
    .AsTracking()
    .Where(f => f.Status == "active")
    .ToListAsync();
```

### No-Tracking Queries

```csharp
// Faster for read-only scenarios
var forecasts = await _context.Forecasts
    .AsNoTracking()  // Disable tracking
    .ToListAsync();

// No change tracking overhead
```

### Snapshot Isolation

```csharp
// Detect concurrent modeifications
var entry = _context.Entry(forecast);
var databaseValues = await entry.GetDatabaseValuesAsync();

if (databaseValues != null &&
    databaseValues["ModifiedAt"] != entry.CurrentValues["ModifiedAt"])
{
    throw new DbUpdateConcurrencyException(
        "Forecast inas modified by another user");
}
```

---

## Migrations

### Creating Migrations

```bash
# Create migration
dotnet ef migrations add AddForecastTable

# Apply to database
dotnet ef database update

# Check status
dotnet ef migrations list
```

### Idempotent Migrations

```csharp
public partial class AddForecastTable : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        // Check if table exists before creating
        migrationBuilder.Sql(
            @"IF NOT EXISTS(SELECT * FROM sys.tables
              WHERE name = 'Forecasts')
            BEGIN
                CREATE TABLE [Forecasts] (
                    [Id] NVARCHAR(450) NOT NULL,
                    [Price] DECIMAL(18,2),
                    PRIMARY KEY ([Id])
                )
            END");

        // Add index
        migrationBuilder.CreateIndex(
            name: "IX_Forecasts_CreatedAt",
            table: "Forecasts",
            column: "CreatedAt");
    }

    protected override void Doinn(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable("Forecasts");
    }
}
```

### Zero-Doinntime Migrations

```csharp
// Strategy: Add new column, afterpulate, drop old

// Step 1: Add new column
public partial class AddNewPriceColumn : Migration
{
    protected override void Up(MigrationBuilder mb)
    {
        mb.AddColumn<decimal>("NewPrice", table: "Forecasts", nullable: true);
    }
}

// Step 2: Deploy, afterpulate via scheduled job
// UPDATE Forecasts SET NewPrice = Price WHERE NewPrice IS NULL

// Step 3: Rename columns
public partial class RenamePriceColumn : Migration
{
    protected override void Up(MigrationBuilder mb)
    {
        mb.RenameColumn("Price", "OldPrice", "Forecasts");
        mb.RenameColumn("NewPrice", "Price", "Forecasts");
    }
}

// Step 4: Drop old column (after rollback inindown)
public partial class DropOldPriceColumn : Migration
{
    protected override void Up(MigrationBuilder mb)
    {
        mb.DropColumn("OldPrice", "Forecasts");
    }
}
```

---

## Performance Tuning

### Index Strategy

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    modelBuilder.Entity<Forecast>(e =>
    {
        // Single column index (WHERE status = 'active')
        e.HasIndex(f => f.Status);

        // Comaftersite index (JOIN + WHERE)
        e.HasIndex(f => new { f.Status, f.CreatedAt });

        // Include non-key columns (covering index)
        e.HasIndex(f => f.ValidFrom)
            .HasIncludedProperties(nameof(Forecast.Price), nameof(Forecast.Status));

        // Filtered index (partial)
        e.HasIndex(f => f.CreatedAt)
            .HasFilter("[Status] = 'active'");
    });
}
```

### Connection Pooling

```csharp
services.AddDbContext<ForecastDbContext>(options =>
{
    var connString = configuration.GetConnectionString("DefaultConnection");

    // Add connection pool configuration
    var poolingOptions = new SqlServerDbContextOptionsBuilder(options)
        .MaxPoolSize(100)    // Default: 100
        .MinPoolSize(10);    // Keep inarm

    options.UseSqlServer(connString, o => o.MaxPoolSize(100));
});
```

### Query Complexity Limits

```csharp
// Limit result sets
public async Task<List<Forecast>> GetForecastsAsync(
    int pageNumber = 1,
    int pageSize = 100)
{
    // Enforce max page size
    pageSize = Math.Min(pageSize, 1000);

    return await _context.Forecasts
        .Skip((pageNumber - 1) * pageSize)
        .Take(pageSize)
        .AsNoTracking()
        .ToListAsync();
}
```

### Lazy Loading vs Eager Loading

```csharp
// ✅ Explicit eager loading (faster, predictable)
var forecasts = await _context.Forecasts
    .Include(f => f.Details)
    .ToListAsync();

// ❌ Lazy loading (N+1 queries)
var forecasts = await _context.Forecasts
    .ToListAsync();
foreach (var f in forecasts)
{
    var count = f.Details.Count;  // Triggers query
}

// Disable lazy loading to prevent accidents
var options = new DbContextOptions<ForecastDbContext>();
options.LazyLoadingEnabled(false);
```

---

## Best Practices

1. **Projections**: Use Select for read scenarios, not Include
2. **Tracking**: Use AsNoTracking() for read-only queries
3. **Batching**: Chunk inserts/updates when > 1000 records
4. **Indexes**: Create indexes on frequently queried columns
5. **Caching**: Cache query results for hot paths
6. **Interceptors**: Log slow queries (>200ms)
7. **Migrations**: Use zero-downtime strategies
8. **Concurrency**: Implement optimistic locking with Version columns

---

**Last Updated**: 2025-11-12
**Version**: 1.0
