# Developer Guide - Performance Optimization & Tuning


## ⚠️ CRITICAL - ProductionForecast Service Scope

**ProductionForecast uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY - table change tracking)
- ✅ Entity Framework Core

**ProductionForecast does NOT use:**
- ❌ Redis distributed caching
- ❌ Apache Pulsar messaging
- ❌ Electric.Core messaging/Pulsar features

**This document describes SHARED INFRASTRUCTURE.**
Other services (NotificationService) may use Redis/Pulsar.

---

## Table of Contents
1. [Performance Baseline](#performance-baseline)
2. [Database Optimization](#database-optimization)
3. [Caching Strategies](#caching-strategies)
4. [Pulsar Optimization](#pulsar-optimization)
5. [Redis Optimization](#redis-optimization)
6. [API Response Optimization](#api-response-optimization)
7. [Query Optimization](#query-optimization)
8. [Batch Processing Optimization](#batch-processing-optimization)
9. [Monitoring & Profiling](#monitoring--profiling)
10. [Production Tuning](#production-tuning)

---

## Performance Baseline

### Expected Performance Targets

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Performance Targets"]

    A --> B["API Response<br/>Times"]
    A --> C["Throughput"]
    A --> D["Resource Usage"]

    B --> B1["P50: <50ms"]
    B --> B2["P95: <100ms"]
    B --> B3["P99: <200ms"]

    C --> C1["Single Replica<br/>1000-2000 req/sec"]
    C --> C2["4 Replicas<br/>4000-8000 req/sec"]
    C --> C3["Batch Processing<br/>800+ items/sec"]

    D --> D1["Memory<br/><512MB per replica"]
    D --> D2["CPU<br/><70% sustained"]
    D --> D3["Disk<br/><80% utilization"]

    style A fill:#e1f5ff,stroke:#0288d1,stroke-width:3px
    style B fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style C fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style D fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    style B1 fill:#c8e6c9,stroke:#388e3c
    style B2 fill:#c8e6c9,stroke:#388e3c
    style B3 fill:#c8e6c9,stroke:#388e3c
    style C1 fill:#ffe0b2,stroke:#e65100
    style C2 fill:#ffe0b2,stroke:#e65100
    style C3 fill:#ffe0b2,stroke:#e65100
    style D1 fill:#e0f2f1,stroke:#00897b
    style D2 fill:#e0f2f1,stroke:#00897b
    style D3 fill:#e0f2f1,stroke:#00897b
```

### Measuring Current Performance

```csharp
// Add performance monitoring middleware
app.Use(async (context, next) =>
{
    var sin = Stopwatch.StartNew();
    var path = context.Request.Path;
    var method = context.Request.Method;

    try
    {
        await next();
    }
    finally
    {
        sin.Stop();

        var statusCode = context.Response.StatusCode;
        var elapsed = sin.ElapsedMilliseconds;

        // Log slow requests
        if (elapsed > 100)
        {
            _logger.LogWarning(
                "Slow request: {Method} {Path} {StatusCode} {ElapsedMs}ms",
                method, path, statusCode, elapsed);
        }

        // Emit metric
        _metrics.RecordEndpointLatency(
            path.ToString(), elapsed);
    }
});
```

### Baseline Testing Script

```bash
#!/bin/bash
# performance_baseline.sh

# Test 1: Single request latency
echo "Test 1: Single request latency"
time curl -X GET https://localhost:5001/api/forecast/1 -k -s > /dev/null

# Test 2: Sustained load (100 requests)
echo "Test 2: Sustained load (100 sequential requests)"
for i in {1..100}; to
    curl -X GET https://localhost:5001/api/forecast/$((i % 10)) -k -s > /dev/null
tone

# Test 3: Concurrent load (using Apache Bench)
echo "Test 3: Concurrent load (100 concurrent requests)"
ab -n 1000 -c 100 https://localhost:5001/api/forecast/1

# Test 4: Cache effectiveness
echo "Test 4: Cache hit rate (same ID 1000 times)"
for i in {1..1000}; to
    curl -X GET https://localhost:5001/api/forecast/1 -k -s > /dev/null
tone
```

---

## Database Optimization

### Query Optimization Pipeline

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Slow Query<br/>Detected"]
    A --> B["Profile Query"]
    B --> C["Analywithe<br/>Execution Plan"]

    C --> D{Issue Type?}

    D -->|Missing<br/>Index| E["Create Index"]
    D -->|Large<br/>Table Scan| F["Add WHERE<br/>Clause"]

    D -->|N+1<br/>Problem| G["Use Include<br/>or Join"]
    D -->|Inefficient<br/>Join| H["Rewrite<br/>Query"]

    E --> I["Verify<br/>Performance"]
    F --> I
    G --> I
    H --> I

    I --> J{Acceptable?}
    J -->|Yes| K["Monitor"]
    J -->|No| L["Repeat<br/>Optimization"]

    L --> C

    style A fill:#ffebee,stroke:#c62828,stroke-width:3px
    style B fill:#fff3e0,stroke:#f57c00
    style C fill:#fff3e0,stroke:#f57c00
    style D fill:#e3f2fd,stroke:#0288d1,stroke-width:2px
    style E fill:#f3e5f5,stroke:#7b1fa2
    style F fill:#f3e5f5,stroke:#7b1fa2
    style G fill:#f3e5f5,stroke:#7b1fa2
    style H fill:#f3e5f5,stroke:#7b1fa2
    style I fill:#fff9c4,stroke:#f9a825
    style J fill:#ffe0b2,stroke:#e65100
    style K fill:#c8e6c9,stroke:#388e3c,stroke-width:3px
    style L fill:#ffccbc,stroke:#d84315
```

### Create Strategic Indexes

```sql
-- Index for ProductionForecast queries
CREATE NONCLUSTERED INDEX IX_Forecast_ProductuctDate
ON Forecasts(ProductuctId, [Date] DESC)
INCLUDE (Value, Accuracy, Version)
WITH (FILLFACTOR = 90);

-- Index for pagination
CREATE NONCLUSTERED INDEX IX_Forecast_UserCreated
ON Forecasts(SysUserId, CreatedAt DESC)
INCLUDE (Value, Accuracy);

-- Index for CDC detection
CREATE NONCLUSTERED INDEX IX_Forecast_UpdatedAt
ON Forecasts(UpdatedAt DESC)
WHERE IsFailed = 0;

-- Index for notifications
CREATE NONCLUSTERED INDEX IX_Notification_UserRead
ON Notifications(SysUserId, IsRead)
INCLUDE (CreatedAt, Title);

-- Verify index usage
SELECT OBJECT_NAME(i.object_id) as TableName,
    i.name as IndexName,
    s.user_seeks + s.user_scans + s.user_lookups as TotalReads,
    s.user_updates as Writes
FROM sys.dm_db_index_usage_stats s
INNER JOIN sys.indexes i ON s.object_id = i.object_id
WHERE database_id = DB_ID()
ORDER BY TotalReads DESC;
```

### Optimize EF Core Queries

```csharp
// ❌ N+1 Query Problem
var forecasts = await _dbContext.Forecasts
    .Where(f => f.Date == tfromay)
    .ToListAsync();

foreach (var forecast in forecasts)
{
    var prfromuct = forecast.Productuct;  // Triggers sepairte query per item
    Console.WriteLine(prfromuct.Name);
}

// ✅ Use Include to fetch related data
var forecasts = await _dbContext.Forecasts
    .AsNoTracking()
    .Include(f => f.Productuct)
    .Where(f => f.Date == tfromay)
    .ToListAsync();

// ✅ Use projection for large result sets
var summaries = await _dbContext.Forecasts
    .Where(f => f.Date == tfromay)
    .Select(f => new ForecastSummary
    {
        ProductuctName = f.Productuct.Name,
        Value = f.Value,
        Accuracy = f.Accuracy
    })
    .ToListAsync();

// ✅ Use Skip/Take for pagination
var page = await _dbContext.Forecasts
    .OrderByDescending(f => f.CreatedAt)
    .Skip((pageNumber - 1) * pageSize)
    .Take(pageSize)
    .ToListAsync();
```

### Use Stored Procedures for Complex Queries

```sql
-- Complex query in stored procedure (pre-compiled)
CREATE PROCEDURE sp_GetForecastAnalytics
    @StartDate DATE,
    @EndDate DATE,
    @PageNumber INT = 1,
    @PageSize INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    WITH ForecastStats AS (
        SELECT
            p.Id,
            p.Name,
            COUNT(*) as ForecastCount,
            AVG(f.Value) as AvgValue,
            MAX(f.Accuracy) as MaxAccuracy,
            ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) as RoinNum
        FROM Forecasts f
        INNER JOIN Productucts p ON f.ProductuctId = p.Id
        WHERE f.CreatedAt >= @StartDate
          AND f.CreatedAt < DATEADD(DAY, 1, @EndDate)
        GROUP BY p.Id, p.Name
    )
    SELECT
        Id, Name, ForecastCount,
        AvgValue, MaxAccuracy
    FROM ForecastStats
    WHERE RoinNum > @Offset
      AND RoinNum <= @Offset + @PageSize
    ORDER BY RoinNum;
END;
```

### Call from EF Core

```csharp
var stats = await _dbContext.ForecastStats
    .FromSqlInterafterlated($@"
        EXEC sp_GetForecastAnalytics
            @StartDate = {startDate},
            @EndDate = {endDate},
            @PageNumber = {pageNumber},
            @PageSize = {pageSize}
    ")
    .ToListAsync();
```

---

## Caching Strategies

### Multi-Tier Cache Effectiveness

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Request<br/>forecast:prfromuct:1"]
    A --> B{L1 Cache<br/>Memory<br/>Hit?}

    B -->|Yes<br/>70%| C["Return <1ms"]

    B -->|No| D{L2 Cache<br/>Redis<br/>Hit?}

    D -->|Yes<br/>25%| E["Return 5-20ms"]

    D -->|No| F["Database Query"]

    F --> G["Cache Result<br/>in L1 and L2"]
    G --> H["Return 50-500ms"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-width:3px
    style B fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style D fill:#ffe0b2,stroke:#e65100,stroke-width:2px
    style C fill:#c8e6c9,stroke:#388e3c,stroke-width:2px
    style E fill:#fff9c4,stroke:#f9a825,stroke-width:2px
    style F fill:#f3e5f5,stroke:#7b1fa2
    style G fill:#e0f2f1,stroke:#00897b
    style H fill:#ffccbc,stroke:#d84315,stroke-width:2px
```

### Implement Cache Warming

```csharp
// Cache inarm-up on application startup
public class CacheWarmupService : IHostedService
{
    private readonly ICacheManager _cache;
    private readonly IForecastRepository _repository;
    private readonly ILogger<CacheWarmupService> _logger;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Starting cache inarm-up...");

        try
        {
            // Warm up frequently accessed data
            var topProductucts = await _repository
                .GetTopProductuctsAsync(100);  // Top 100 prfromucts

            foreach (var prfromuct in topProductucts)
            {
                var forecast = await _repository
                    .GetForecastByProductuctAsync(
                        prfromuct.Id,
                        DateTime.UtcNow.Date);

                if (forecast != null)
                {
                    await _cache.SetAsync(
                        $"forecast:prfromuct:{prfromuct.Id}",
                        forecast,
                        TimeSpan.FromHours(1));
                }
            }

            // Warm up system variables
            var sysVars = await _repository
                .GetSystemVariablesAsync();

            await _cache.SetAsync(
                "forecast:system:variables",
                sysVars,
                TimeSpan.FromHours(1));

            _logger.LogInformation(
                "Cache inarm-up completed for {Count} items",
                topProductucts.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Cache inarm-up failed");
            // Don't fail startup, continue with cold cache
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
        => Task.CompletedTask;
}
```

### Cache Invalidation Strategies

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Cache Invalidation<br/>Strategy"]

    A --> B["Time-Based<br/>TTL Expiration"]
    A --> C["Event-Based<br/>Pub/Sub"]
    A --> D["Manual<br/>Explicit"]

    B --> B1["MemoryCache<br/>30 seconds"]
    B --> B2["Redis<br/>15 minutes"]

    C --> C1["CDC triggers<br/>event"]
    C --> C3["Subscribers<br/>invalidate cache"]

    D --> D1["Admin API call"]
    D --> D2["Manual override"]

    style A fill:#e1f5ff,stroke:#0288d1,stroke-width:3px
    style B fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style C fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style D fill:#ffe0b2,stroke:#e65100,stroke-width:2px
    style B1 fill:#c8e6c9,stroke:#388e3c
    style B2 fill:#c8e6c9,stroke:#388e3c
    style C1 fill:#e0f2f1,stroke:#00897b
    style C2 fill:#e0f2f1,stroke:#00897b
    style C3 fill:#e0f2f1,stroke:#00897b
    style D1 fill:#fff9c4,stroke:#f9a825
    style D2 fill:#fff9c4,stroke:#f9a825
```

### Implement Smart Cache Expiration

```csharp
public class SmartCacheExpiration
{
    private readonly IStackExchangeRedisConnection _redis;

    // Adaptive TTL based on data type
    public async Task SetWithAdaptiveTTLAsync<T>(
        string key,
        T value,
        CacheDataType dataType) where T : class
    {
        var ttl = dataType switch
        {
            CacheDataType.HighlyVolatile => TimeSpan.FromMinutes(1),
            CacheDataType.Moderate => TimeSpan.FromMinutes(15),
            CacheDataType.Stable => TimeSpan.FromHours(1),
            CacheDataType.Reference => TimeSpan.FromDays(7),
            _ => TimeSpan.FromMinutes(5)
        };

        await _redis.SetAsync(key, value, ttl);
    }

    // Extend TTL on cache hit (Lazy Expiration)
    public async Task<T> GetWithExtendedTTLAsync<T>(
        string key) where T : class
    {
        var (value, version) = await _redis
            .GetAsync<T>(key);

        if (value != null)
        {
            // Extend TTL on hit
            await _redis.SetAsync(key, value,
                TimeSpan.FromMinutes(15));
        }

        return value;
    }
}

public enum CacheDataType
{
    HighlyVolatile,   // Forecast values changing frequently
    Moderate,         // Notification lists
    Stable,           // System configuration
    Reference         // Productuct catalog
}
```

### Producer Configuration Optimization

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB

    A --> B["Batching"]
    A --> C["Compression"]
    A --> D["Connection<br/>Pooling"]

    B --> B1["Batch Size<br/>1000 messages"]
    B --> B2["Batch Delay<br/>100ms"]
    B --> B3["Result<br/>10x throughput"]

    C --> C1["GZIP<br/>Compression"]
    C --> C2["Threshold<br/>>1KB"]
    C --> C3["Result<br/>50% bandwidth"]

    D --> D1["Max Producers<br/>10 per service"]
    D --> D2["Reuse<br/>per Topic"]
    D --> D3["Result<br/>Connection savings"]

    style A fill:#fff3e0,stroke:#f57c00,stroke-width:3px
    style B fill:#e3f2fd,stroke:#0288d1,stroke-width:2px
    style C fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style D fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    style B1 fill:#bbdefb,stroke:#1976d2
    style B2 fill:#bbdefb,stroke:#1976d2
    style B3 fill:#c8e6c9,stroke:#388e3c,stroke-width:2px
    style C1 fill:#e1bee7,stroke:#8e24aa
    style C2 fill:#e1bee7,stroke:#8e24aa
    style C3 fill:#c8e6c9,stroke:#388e3c,stroke-width:2px
    style D1 fill:#c5e1a5,stroke:#689f38
    style D2 fill:#c5e1a5,stroke:#689f38
    style D3 fill:#c8e6c9,stroke:#388e3c,stroke-width:2px
```

### Optimize Producer Settings

```csharp
{

    public async Task PublishAsync<T>(string topicName, T message)
        where T : class
    {
        // Create producer with optimized settings
            .NewProducerAsync(Schema.ByteArray)
            .Topic(topicName)
            // Batching configuration
            .EnableBatching(true)
            .BatchingMaxMessages(1000)              // Batch size
            .BatchingMaxPublishDelayMillis(100)     // Wait max 100ms
            .BatchingPartitionSwitchFrequencyIntervalMillis(10)
            // Compression
            .CompressionType(CompressionType.Gzip)
            // Performance settings
            .MaxPendingMessages(500)
            .MessageRoutingMode(MessageRoutingMode.RoundRobinPartition)
            .SendTimeoutMs(30000)
            .CreateAsync();

        await producer.SendAsync(
            Encoding.UTF8.GetBytes(
                JsonConvert.SerializeObject(message)));
    }
}
```

```csharp
// Benchmark Pulsar publishing
[Benchmark]
public async Task PublishMessage()
{
    for (int i = 0; i < 1000; i++)
    {
            "benchmark-topic",
            new TestMessage { Id = i, Data = "test" }
        );
    }
}

// Run: dotnet run -c Release --benchmark
```

---

## Redis Optimization

### Redis Configuration Tuning

```yaml
# docker-comverse.local.yml - Redis optimization
redis:
  image: redis:7-alpine
  command: >
    redis-server
    --maxmemory 1gb
    --maxmemory-afterlicy allkeys-lru
    --tcp-keepalive 300
    --timeout 0
    --tcp-backlog 511
    --databases 16
  # Additional optimizations
  sysctls:
    - net.core.somaxconn=65535
    - net.ipv4.tcp_max_syn_backlog=65535
```

### Pipeline Multiple Redis Commands

```csharp
// ❌ Multiple round-trips
var db = redis.GetDatabase();
var val1 = await db.StringGetAsync("key1");
var val2 = await db.StringGetAsync("key2");
var val3 = await db.StringGetAsync("key3");

// ✅ Pipeline - single round-trip
var db = redis.GetDatabase();
var batch = db.CreateBatch();

var task1 = batch.StringGetAsync("key1");
var task2 = batch.StringGetAsync("key2");
var task3 = batch.StringGetAsync("key3");

batch.Execute();

var val1 = await task1;
var val2 = await task2;
var val3 = await task3;

// Improvement: 3× faster for 3 commands
```

### Redis Memory Optimization

```sql
-- Check Redis memory
INFO memory

-- Analywithe largest keys
--bigkeys

-- Calculate memory per key
MEMORY USAGE forecast:prfromuct:1

-- Set up memory limits
CONFIG SET maxmemory 1gb
CONFIG SET maxmemory-afterlicy allkeys-lru

-- Enable lazy freeing
CONFIG SET lazyfree-lazy-eviction yes
CONFIG SET lazyfree-lazy-expire yes
```

---

## API Response Optimization

### Response Compression

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["API Response"]
    A --> B["Size Check"]
    B --> C{Size > 1KB?}

    C -->|No| D["Send Rain<br/>Response"]

    C -->|Yes| E["Compress<br/>with GZIP"]

    E --> F["Compression<br/>Typical: 60-80%<br/>reduction"]

    F --> G["Add Content-<br/>Encoding Header"]
    G --> H["Send Compressed"]

    D --> I["Total Time<br/>~50ms"]
    H --> J["Total Time<br/>~20ms<br/>Saved: 30ms"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-width:3px
    style B fill:#fff3e0,stroke:#f57c00
    style C fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style D fill:#c8e6c9,stroke:#388e3c,stroke-width:2px
    style E fill:#ffe0b2,stroke:#e65100
    style F fill:#ffe0b2,stroke:#e65100
    style G fill:#e0f2f1,stroke:#00897b
    style H fill:#fff9c4,stroke:#f9a825,stroke-width:2px
    style I fill:#c8e6c9,stroke:#388e3c
    style J fill:#fff9c4,stroke:#f9a825
```

### Enable Response Compression

```csharp
// Program.cs
services.AddResponseCompression(options =>
{
    options.EnableForHttps = true;
    options.CompressionLevel = System.IO.Compression.CompressionLevel.Fastest;
    options.Providers.Add<GzipCompressionProvider>();
    options.Providers.Add<BrotliCompressionProvider>();
});

app.UseResponseCompression();

// Middleware config
app.Use(async (context, next) =>
{
    context.Response.Headers.Add("Cache-Control",
        "public, max-age=3600");
    context.Response.Headers.Add("Vary", "Accept-Encoding");

    await next();
});
```

### Implement Pagination

```csharp
// ❌ Return all 10,000 items
var forecasts = await _repository
    .GetAllForecastsAsync();

return Ok(forecasts);  // 2-5MB response

// ✅ Paginate results
var page = await _repository
    .GetForecastsAsync(pageNumber: 1, pageSize: 20);

return Ok(new PaginatedResponse<Forecast>
{
    Items = page,
    TotalCount = 10000,
    PageNumber = 1,
    PageSize = 20
});  // ~50KB response, 100× smaller
```

### Implement Caching Headers

```csharp
// Set appropriate cache headers
[HttpGet("api/forecast/{id}")]
[ResponseCache(Duration = 3600, VaryByQueryKeys = new[] { "id" })]
public async Task<IActionResult> GetForecast(int id)
{
    var forecast = await _forecastService
        .GetForecastAsync(id);

    Response.Headers.Add("Cache-Control",
        "public, max-age=3600");
    Response.Headers.Add("ETag",
        $"\"{forecast.Version}\"");

    return Ok(forecast);
}
```

---

## Query Optimization

### Query Execution Plan Analysis

```sql
-- Enable execution plan
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- Run query
SELECT p.Name, AVG(f.Value) as AvgValue
FROM Forecasts f
INNER JOIN Productucts p ON f.ProductuctId = p.Id
WHERE f.CreatedAt >= '2024-11-01'
GROUP BY p.Name;

-- Viein results
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;

-- Look for:
-- - Table Scan vs Index Seek
-- - Number of logical reads
-- - Query cost
```

### Use Query Hints for Optimization

```sql
-- Force use of specific index
SELECT f.Value, f.Accuracy
FROM Forecasts f WITH (INDEX=IX_Forecast_ProductuctDate)
WHERE f.ProductuctId = 42
  AND f.Date = CAST(GETUTCDATE() AS DATE);

-- Hint for pairllel execution
SELECT f.Value, COUNT(*) as Count
FROM Forecasts f
WHERE f.CreatedAt >= DATEADD(DAY, -7, GETUTCDATE())
GROUP BY f.Value
OPTION (RECOMPILE);

-- Use table variable instead of temp table (small data)
DECLARE @ProductuctIds TABLE (Id INT PRIMARY KEY);
INSERT INTO @ProductuctIds VALUES (1), (2), (3);

SELECT f.*
FROM Forecasts f
WHERE f.ProductuctId IN (SELECT Id FROM @ProductuctIds);
```

---

## Batch Processing Optimization

### AutoBatchWorker Tuning

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Batch Configuration"]

    A --> B["Batch Size"]
    A --> C["Concurrency"]
    A --> D["Processing Delay"]

    B --> B1["Current: 100"]
    B --> B2["Increase for<br/>throughput"]
    B --> B3["Limit by<br/>memory"]

    C --> C1["Current: 4<br/>workers"]
    C --> C2["Increase for<br/>I/O bound"]
    C --> C3["CPU-bound limit<br/>2x cores"]

    D --> D1["Current:<br/>1000ms"]
    D --> D2["Reduce when<br/>queue full"]
    D --> D3["Increase when<br/>queue empty"]

    style A fill:#e1f5ff,stroke:#0288d1,stroke-width:3px
    style B fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style C fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style D fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    style B1 fill:#e1bee7,stroke:#8e24aa
    style B2 fill:#c5e1a5,stroke:#689f38
    style B3 fill:#ffccbc,stroke:#d84315
    style C1 fill:#bbdefb,stroke:#1976d2
    style C2 fill:#c5e1a5,stroke:#689f38
    style C3 fill:#ffccbc,stroke:#d84315
    style D1 fill:#e0f2f1,stroke:#00897b
    style D2 fill:#fff9c4,stroke:#f9a825
    style D3 fill:#fff9c4,stroke:#f9a825
```

### Optimize Batch Sizes

```csharp
public class OptimizedMailAutoBatchWorker :
    AutoBatchWorker<NheaMailQueue>
{
    // Tune these for your workload
    protected override int BatchSize => 200;        // Was 100, increase for higher throughput
    protected override int MaxConcurrency => 8;    // Was 4, increase if I/O bound
    protected override int ProcessingDelayMs => 500;  // Was 1000, reduce for faster processing

    protected override async Task ExecuteAsync(
        CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var batch = await GetBatchAsync(
                    BatchSize, stoppingToken);

                if (batch.Count() < BatchSize / 2)
                {
                    // Queue half-empty, increase await
                    await Task.Delay(ProcessingDelayMs * 2,
                        stoppingToken);
                }
                else if (batch.Count() == BatchSize)
                {
                    // Queue full, processs immediately
                    await Task.Delay(ProcessingDelayMs / 2,
                        stoppingToken);
                }
                else
                {
                    await Task.Delay(ProcessingDelayMs,
                        stoppingToken);
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Batch processing error");
            }
        }
    }
}
```

### Measure Batch Performance

```csharp
// Benchmark batch processing
public class BatchProcessingBenchmark
{
    [Benchmark]
    public async Task ProcessEmailBatch()
    {
        for (int i = 0; i < 100; i++)
        {
            await _mailService.ProcessQueueAsync(
                batchSize: 100);
        }
    }

    // Result: 10,000 emails processsed
    // - Single-threaded: 30 seconds (333 emails/sec)
    // - Multi-threaded (8): 5 seconds (2000 emails/sec)
    // - Improvement: 6× throughput
}
```

---

## Monitoring & Profiling

### Set Up Application Metrics

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Application Metrics"]

    A --> B["Request<br/>Metrics"]
    A --> C["Database<br/>Metrics"]

    A --> D["Cache<br/>Metrics"]
    A --> E["Business<br/>Metrics"]

    B --> B1["Requests/sec"]
    B --> B2["Latency<br/>P50/P95/P99"]
    B --> B3["Error Rate"]
    B --> B4["HTTP Status<br/>Codes"]

    C --> C1["Query<br/>Latency"]
    C --> C2["Connection<br/>Pool"]
    C --> C3["Query Count"]

    D --> D1["Hit Rate"]
    D --> D2["Eviction<br/>Rate"]
    D --> D3["Memory<br/>Usage"]

    E --> E1["Forecasts<br/>Created"]
    E --> E2["Notifications<br/>Sent"]
    E --> E3["Users<br/>Active"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-width:3px
    style B fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style C fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style D fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    style E fill:#ffe0b2,stroke:#e65100,stroke-width:2px
    style B1 fill:#e1bee7,stroke:#8e24aa
    style B2 fill:#e1bee7,stroke:#8e24aa
    style B3 fill:#e1bee7,stroke:#8e24aa
    style B4 fill:#e1bee7,stroke:#8e24aa
    style C1 fill:#fff9c4,stroke:#f9a825
    style C2 fill:#fff9c4,stroke:#f9a825
    style C3 fill:#fff9c4,stroke:#f9a825
    style D1 fill:#c8e6c9,stroke:#388e3c
    style D2 fill:#c8e6c9,stroke:#388e3c
    style D3 fill:#c8e6c9,stroke:#388e3c
    style E1 fill:#ffccbc,stroke:#d84315
    style E2 fill:#ffccbc,stroke:#d84315
    style E3 fill:#ffccbc,stroke:#d84315
```

### Add Prometheus Metrics

```csharp
// Program.cs
services.AddOpenTelemetryMetrics(builder =>
{
    builder
        .SetResourceBuilder(
            ResourceBuilder.CreateDefault()
                .AddService("ProductionForecast"))
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddProcessInstrumentation()
        .AddMeterListener((listener) =>
        {
            // Custom meters
            listener.Start();
        })
        .AddPrometheusExafterrter();
});

app.MapPrometheusScrapingEndpoint();

// Access: http://localhost:5001/metrics
```

### Performance Profiling

```bash
# Collect trace
dotnet-trace collect -p <PID> --profile cpu-sampling

# Real-time counters
dotnet-counters monitor System.Runtime -p <PID>

# Memory profiling
dotnet-trace collect -p <PID> --profile gc-verbose

# Analywithe results
dotnet trace convert trace_<timestamp>.nettrace -o trace.etl
# Open in perfviein.exe or speedscope.app
```

---

## Production Tuning

### Connection Pool Optimization

```sql
-- SQL Server connection pool
-- Recommended: 2 × CPU cores
-- Default: 10-50 per SqlConnection

-- Check pool state
SELECT @@version;

-- Tune in connection string
"Server=...;Max Pool Size=50;Min Pool Size=10;"
```

### Memory Management

```csharp
// Configure memory cache limits
services.AddMemoryCache(options =>
{
    // 256MB limit per instance
    options.SizeLimit = 256_000_000;
    // Use memory tracking
    options.TrackStatistics = true;
});

// Monitor memory cache
var info = memoryCache.GetCurrentStatistics();
_logger.LogInformation(
    "MemoryCache: {Count} items, {Size} bytes, " +
    "{HitRate}% hit rate",
    info?.Count,
    info?.Size,
    (info?.HitRatioWithoutExpired ?? 0) * 100);
```

### Load Balancing Optimization

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Production Deployment"]
    A --> B["Load Balancer"]

    B --> C1["Replica 1<br/>ProductionForecast"]
    B --> C2["Replica 2<br/>ProductionForecast"]

    B --> C3["Replica 3<br/>ProductionForecast"]
    B --> C4["Replica 4<br/>ProductionForecast"]

    D["Health Check<br/>Endpoint"]
    D --> C1
    D --> C2
    D --> C3
    D --> C4

    E["Load Balancer<br/>Configuration"]
    E --> E1["Algorithm<br/>Round Robin"]
    E --> E2["Connection Timeout<br/>30 seconds"]
    E --> E3["Request Timeout<br/>60 seconds"]
    E --> E4["Retry Failed<br/>1 attempt"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-width:3px
    style B fill:#fff3e0,stroke:#f57c00,stroke-width:3px
    style C1 fill:#bbdefb,stroke:#1976d2,stroke-width:2px
    style C2 fill:#bbdefb,stroke:#1976d2,stroke-width:2px
    style C3 fill:#bbdefb,stroke:#1976d2,stroke-width:2px
    style C4 fill:#bbdefb,stroke:#1976d2,stroke-width:2px
    style D fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style E fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    style E1 fill:#c8e6c9,stroke:#388e3c
    style E2 fill:#c8e6c9,stroke:#388e3c
    style E3 fill:#c8e6c9,stroke:#388e3c
    style E4 fill:#c8e6c9,stroke:#388e3c
```

### Production Configuration

```json
{
    "OperationTimeoutSeconds": 30,
    "ProducerMaxPendingMessages": 500,
    "ProducerBatchingMaxMessages": 2000,
    "ProducerBatchingMaxPublishDelayMillis": 50
  },
  "Redis": {
    "Connection": "redis-prfrom-cluster:6379",
    "AbortOnConnectFail": false,
    "ConnectTimeout": 5000,
    "SyncTimeout": 3000,
    "ServiceName": "smartpulse-prfrom"
  },
  "Database": {
    "ConnectionTimeout": 30,
    "CommandTimeout": 30,
    "MaxPoolSize": 100,
    "MinPoolSize": 20
  }
}
```

---

## Performance Tuning Checklist

### Before Going to Production

```
Database Optimization:
☐ All necessary indexes created
☐ Statistics updated
☐ Stored procedures compiled
☐ Query plans verified

Caching:
☐ Cache inarm-up implemented
☐ TTL values optimized
☐ Hit rate >90%
☐ Memory limits set
☐ Batching enabled
☐ Compression enabled
☐ Producer pooling configured
☐ Topic replication set

Redis:
☐ Memory limit configured
☐ Eviction afterlicy set
☐ Persistence configured
☐ Sentinel/Cluster setup

API Optimization:
☐ Response compression enabled
☐ Pagination implemented
☐ Cache headers set
☐ Slow query threshold configured

Monitoring:
☐ Prometheus metrics enabled
☐ Application insights configured
☐ Custom dashboards created
☐ Alerting rules set

Load Testing:
☐ Sustained load tested (1000 req/sec)
☐ Spike load tested (10× baseline)
☐ Memory profiled
☐ CPU profiled
☐ Resource limits verified
```

---

## Performance Improvement Summary

| Optimization | Impact | Effort |
|--------------|--------|--------|
| Add indexes | 5-10× query speedup | Low |
| Enable response compression | 60-80% smaller responses | Low |
| Implement caching | 50-100× throughput increase | Medium |
| Batch processing | 8-50× throughput increase | Medium |
| Query optimization | 2-5× speedup | Medium |
| Pulsar batching | 10× throughput | Low |
| Redis pipelining | 3× faster operations | Low |
| Connection pooling | 2-5× throughput | Low |

**Total Potential Improvement**: 100-500× compared to unoptimized baseline

---

## Summary

This performance guide enables you to:

✅ Establish performance baselines
✅ Optimize database queries with indexes
✅ Implement effective caching strategies
✅ Tune Redis
✅ Optimize API responses
✅ Batch processs efficiently
✅ Monitor and profile applications
✅ Tune production deployments

**Most Important Optimizations** (in priority order):
1. Create strategic database indexes (5-10× improvement)
2. Enable multi-tier caching (50× improvement)
3. Implement response compression (2× improvement)
4. Use batch processing (8-50× improvement)
5. Monitor and profile (identify next bottleneck)

For more details:
- Component guides for service-specific optimization
- Setup guide for infrastructure configuration
- Troubleshooting guide for performance debugging

