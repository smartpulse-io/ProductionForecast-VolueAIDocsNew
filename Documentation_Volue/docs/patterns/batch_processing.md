# Batch Processing Patterns

**Last Updated**: 2025-11-13

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

1. [Overview](#overview)
2. [AutoBatchWorker Pattern](#autobatchworker-pattern)
3. [Channel-Based Batching](#channel-based-batching)
4. [Database Bulk Operations](#database-bulk-operations)
5. [Performance Optimization](#performance-optimization)
6. [Best Practices](#best-practices)

---

## Overview

SmartPulse implements several batch processing patterns to optimize throughput and resource utilization across database operations, message processing, and distributed data synchronization.

### Batch Processing Benefits

| Benefit | Impact | Typical Improvement |
|---------|--------|---------------------|
| Reduced network round-trips | Lower latency | 5-10x faster |
| Amortized overhead | Higher throughput | 50-100x more items/sec |
| Better resource utilization | Lower CPU usage | 30-50% reduction |
| Improved cache locality | Better performance | 2-3x throughput |

---

## AutoBatchWorker Pattern

### Architecture

The `AutoBatchWorker<T>` pattern provides automatic batching with configurable triggers.

```csharp
public class AutoBatchWorker<T>
{
    private readonly Channel<T> _channel;
    private readonly int _maxBatchSize;
    private readonly TimeSpan _maxWaitTime;
    private readonly Func<IReadOnlyCollection<T>, Task> _processor;

    public AutoBatchWorker(
        int maxBatchSize = 100,
        TimeSpan? maxWaitTime = null,
        int channelCapacity = 10000)
    {
        _maxBatchSize = maxBatchSize;
        _maxWaitTime = maxWaitTime ?? TimeSpan.FromMilliseconds(100);

        _channel = Channel.CreateBounded<T>(new BoundedChannelOptions(channelCapacity)
        {
            FullMode = BoundedChannelFullMode.Wait,  // Backpressure
            SingleReader = true,                     // Optimization
            SingleWriter = false                     // Multiple producers
        });
    }

    public async Task EnqueueAsync(T item, CancellationToken cancellationToken = default)
    {
        await _channel.Writer.WriteAsync(item, cancellationToken);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var batch = new List<T>(_maxBatchSize);
        var timer = new CancellationTokenSource();

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                // Start timeout timer
                timer.CancelAfter(_maxWaitTime);

                // Collect items until batch full or timeout
                while (batch.Count < _maxBatchSize)
                {
                    if (!await _channel.Reader.WaitToReadAsync(timer.Token))
                        break;

                    if (_channel.Reader.TryRead(out var item))
                        batch.Add(item);
                }

                // Process batch if not empty
                if (batch.Count > 0)
                {
                    await _processor(batch);
                    batch.Clear();
                }

                // Reset timer
                timer = new CancellationTokenSource();
            }
            catch (OperationCanceledException) when (timer.IsCancellationRequested)
            {
                // Timeout occurred - process what we have
                if (batch.Count > 0)
                {
                    await _processor(batch);
                    batch.Clear();
                }

                timer = new CancellationTokenSource();
            }
        }
    }
}
```

### Batching Triggers

**Two conditions trigger batch processing**:

1. **Size Threshold**: Batch reaches `maxBatchSize` items
2. **Time Threshold**: `maxWaitTime` elapses since first item

**Decision Matrix**:

```
If batch.Count >= maxBatchSize → Process immediately
Else if time_since_first_item >= maxWaitTime → Process with partial batch
Else → Continue collecting items
```

### Configuration Recommendations

| Use Case | Batch Size | Wait Time | Rationale |
|----------|------------|-----------|-----------|
| Real-time updates | 10-50 | 50-100ms | Low latency priority |
| Analytics ingestion | 500-1000 | 1-5s | High throughput priority |
| Database writes | 100-500 | 200-500ms | Balance both |
| Event publishing | 100-200 | 100ms | Network efficiency |

### Example: Batch Forecast Processing

```csharp
public class ForecastBatchProcessor : AutoBatchWorker<ForecastEvent>
{
    private readonly IForecastRepository _repository;
    private readonly ILogger<ForecastBatchProcessor> _logger;

    public ForecastBatchProcessor(IForecastRepository repository, ILogger logger)
        : base(maxBatchSize: 100, maxWaitTime: TimeSpan.FromMilliseconds(200))
    {
        _repository = repository;
        _logger = logger;
    }

    protected override async Task ProcessBatchAsync(
        IReadOnlyCollection<ForecastEvent> batch,
        CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();

        try
        {
            // Bulk insert to database
            await _repository.BulkInsertAsync(batch.Select(e => e.ToForecast()));

            _logger.LogInformation(
                "Processed batch of {Count} forecasts in {ElapsedMs}ms",
                batch.Count, sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process forecast batch");
            // Optionally: retry individual items or send to DLQ
        }
    }
}

// Usage
public class ForecastService
{
    private readonly ForecastBatchProcessor _batchProcessor;

    public async Task PublishForecastAsync(ForecastEvent forecast)
    {
        // Non-blocking enqueue
        await _batchProcessor.EnqueueAsync(forecast);
    }
}
```

---

## Channel-Based Batching

### Channel Advantages

System.Threading.Channels provides built-in backpressure and async enumeration.

```csharp
public class ChannelBatchProcessor<T>
{
    private readonly Channel<T> _channel;

    public ChannelBatchProcessor(int capacity = 10000)
    {
        _channel = Channel.CreateBounded<T>(new BoundedChannelOptions(capacity)
        {
            FullMode = BoundedChannelFullMode.Wait,  // Block producer when full
            SingleReader = true,                     // Single consumer optimization
            SingleWriter = false                     // Multiple producers allowed
        });
    }

    public async Task ProcessInBatchesAsync(
        int batchSize,
        Func<List<T>, Task> processor,
        CancellationToken cancellationToken)
    {
        var batch = new List<T>(batchSize);

        await foreach (var item in _channel.Reader.ReadAllAsync(cancellationToken))
        {
            batch.Add(item);

            if (batch.Count >= batchSize)
            {
                await processor(batch);
                batch.Clear();
            }
        }

        // Process remaining items
        if (batch.Count > 0)
            await processor(batch);
    }
}
```

### Backpressure Handling

**BoundedChannelFullMode Options**:

| Mode | Behavior | Use Case |
|------|----------|----------|
| `Wait` | Block producer until space available | **Recommended** - prevents memory overflow |
| `DropWrite` | Drop new items when full | Non-critical events |
| `DropOldest` | Drop oldest item when full | Real-time data streams |

### Multi-Producer Pattern

```csharp
public class MultiProducerBatchProcessor
{
    private readonly Channel<WorkItem> _channel;
    private readonly SemaphoreSlim _semaphore;  // Optional: rate limiting

    public async Task EnqueueFromMultipleSourcesAsync(WorkItem item)
    {
        // Optional: Rate limiting
        await _semaphore.WaitAsync();
        try
        {
            await _channel.Writer.WriteAsync(item);
        }
        finally
        {
            _semaphore.Release();
        }
    }

    public async Task StartProcessingAsync(CancellationToken cancellationToken)
    {
        // Single consumer
        await foreach (var item in _channel.Reader.ReadAllAsync(cancellationToken))
        {
            await ProcessAsync(item);
        }
    }
}
```

---

## Database Bulk Operations

### EF Core Bulk Insert

**Pattern**: Chunked insertion to avoid parameter limits.

```csharp
public async Task BulkInsertForecastsAsync(IList<Forecast> forecasts)
{
    const int batchSize = 1000;  // SQL Server parameter limit: ~2100

    for (int i = 0; i < forecasts.Count; i += batchSize)
    {
        var batch = forecasts.Skip(i).Take(batchSize).ToList();

        _context.Forecasts.AddRange(batch);
        await _context.SaveChangesAsync();

        // Clear change tracker to free memory
        _context.ChangeTracker.Clear();
    }
}
```

### Bulk Update Pattern

**EF Core 7+**: Use `ExecuteUpdateAsync` for direct database updates.

```csharp
// ❌ BAD: Load all entities, modify, save
var forecasts = await _context.Forecasts
    .Where(f => f.Status == "pending")
    .ToListAsync();

foreach (var f in forecasts)
    f.Status = "processed";

await _context.SaveChangesAsync();

// ✅ GOOD: Direct database update (no entity tracking)
var updated = await _context.Forecasts
    .Where(f => f.Status == "pending")
    .ExecuteUpdateAsync(setters =>
        setters.SetProperty(f => f.Status, "processed")
               .SetProperty(f => f.ProcessedAt, DateTime.UtcNow));

Console.WriteLine($"Updated {updated} forecasts");
```

**Performance Comparison**:

| Method | 10K Records | 100K Records |
|--------|-------------|--------------|
| Load + Modify + Save | 5-10s | 50-100s |
| ExecuteUpdateAsync | 100-200ms | 500-1000ms |
| **Speedup** | **25-100x** | **50-200x** |

### Bulk Delete Pattern

```csharp
// ✅ Direct database delete (EF Core 7+)
var deleted = await _context.Forecasts
    .Where(f => f.CreatedAt < DateTime.UtcNow.AddDays(-30))
    .ExecuteDeleteAsync();

Console.WriteLine($"Deleted {deleted} old forecasts");
```

### Stored Procedure Batching

```csharp
public async Task<int> BulkInsertViaStoredProcAsync(List<Forecast> forecasts)
{
    // Convert to JSON table parameter
    var json = JsonSerializer.Serialize(forecasts);

    var result = await _context.Database
        .ExecuteSqlInterpolatedAsync(
            $"EXEC sp_BulkInsertForecasts {json}");

    return result;
}
```

**SQL Stored Procedure**:

```sql
CREATE PROCEDURE sp_BulkInsertForecasts
    @JsonData NVARCHAR(MAX)
AS
BEGIN
    INSERT INTO Forecasts (Id, Price, CreatedAt)
    SELECT Id, Price, CreatedAt
    FROM OPENJSON(@JsonData)
    WITH (
        Id NVARCHAR(50) '$.Id',
        Price DECIMAL(18,2) '$.Price',
        CreatedAt DATETIME2 '$.CreatedAt'
    )
END
```

---

## Performance Optimization

### Memory Efficiency

**Pattern**: Clear change tracker between batches.

```csharp
for (int i = 0; i < items.Count; i += batchSize)
{
    var batch = items.Skip(i).Take(batchSize);

    await _context.AddRangeAsync(batch);
    await _context.SaveChangesAsync();

    // Free memory
    _context.ChangeTracker.Clear();

    // Optional: Force GC after large batches
    if (i % (batchSize * 10) == 0)
        GC.Collect(2, GCCollectionMode.Optimized);
}
```

### Parallel Batch Processing

**Pattern**: Process independent batches in parallel.

```csharp
public async Task ProcessBatchesInParallelAsync(List<WorkItem> items)
{
    const int batchSize = 100;
    const int maxParallelism = 4;

    var batches = items
        .Select((item, index) => new { item, index })
        .GroupBy(x => x.index / batchSize)
        .Select(g => g.Select(x => x.item).ToList())
        .ToList();

    var options = new ParallelOptions
    {
        MaxDegreeOfParallelism = maxParallelism
    };

    await Parallel.ForEachAsync(batches, options, async (batch, ct) =>
    {
        await ProcessBatchAsync(batch);
    });
}
```

### Adaptive Batch Sizing

**Pattern**: Adjust batch size based on processing time.

```csharp
public class AdaptiveBatchProcessor
{
    private int _currentBatchSize = 100;
    private const int MinBatchSize = 10;
    private const int MaxBatchSize = 1000;
    private const int TargetProcessingTimeMs = 500;

    public async Task ProcessWithAdaptiveBatchingAsync(List<WorkItem> items)
    {
        for (int i = 0; i < items.Count; i += _currentBatchSize)
        {
            var batch = items.Skip(i).Take(_currentBatchSize).ToList();
            var sw = Stopwatch.StartNew();

            await ProcessBatchAsync(batch);

            sw.Stop();

            // Adjust batch size based on processing time
            if (sw.ElapsedMilliseconds < TargetProcessingTimeMs / 2)
            {
                // Processing too fast, increase batch size
                _currentBatchSize = Math.Min(_currentBatchSize * 2, MaxBatchSize);
            }
            else if (sw.ElapsedMilliseconds > TargetProcessingTimeMs * 2)
            {
                // Processing too slow, decrease batch size
                _currentBatchSize = Math.Max(_currentBatchSize / 2, MinBatchSize);
            }

            _logger.LogDebug(
                "Processed {Count} items in {ElapsedMs}ms, next batch size: {BatchSize}",
                batch.Count, sw.ElapsedMilliseconds, _currentBatchSize);
        }
    }
}
```

---

## Best Practices

### 1. Choose Appropriate Batch Size

**Small Batches (10-50)**:
- ✅ Low latency requirements
- ✅ Real-time processing
- ❌ High overhead per batch

**Medium Batches (50-500)**:
- ✅ Balance latency and throughput
- ✅ Most common use case
- ✅ Good default choice

**Large Batches (500-5000)**:
- ✅ Maximum throughput
- ✅ Analytics workloads
- ❌ Higher latency
- ❌ More memory usage

### 2. Implement Timeout Logic

**Always set maximum wait time**:

```csharp
var batch = new List<T>();
var cancellationTokenSource = new CancellationTokenSource(TimeSpan.FromSeconds(1));

while (batch.Count < maxBatchSize)
{
    try
    {
        var item = await _channel.Reader.ReadAsync(cancellationTokenSource.Token);
        batch.Add(item);
    }
    catch (OperationCanceledException)
    {
        // Timeout - process partial batch
        break;
    }
}

if (batch.Count > 0)
    await ProcessBatchAsync(batch);
```

### 3. Handle Partial Batches

**Last batch may be incomplete**:

```csharp
// Process remaining items after main loop
if (batch.Count > 0)
{
    await ProcessBatchAsync(batch);
}
```

### 4. Error Handling Strategies

**Strategy 1: Retry entire batch**

```csharp
for (int retry = 0; retry < 3; retry++)
{
    try
    {
        await ProcessBatchAsync(batch);
        break;  // Success
    }
    catch (Exception ex) when (retry < 2)
    {
        await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, retry)));  // Exponential backoff
    }
}
```

**Strategy 2: Process items individually on batch failure**

```csharp
try
{
    await ProcessBatchAsync(batch);
}
catch (Exception ex)
{
    _logger.LogWarning(ex, "Batch processing failed, retrying individually");

    foreach (var item in batch)
    {
        try
        {
            await ProcessSingleAsync(item);
        }
        catch (Exception itemEx)
        {
            _logger.LogError(itemEx, "Failed to process item");
            await _deadLetterQueue.SendAsync(item);
        }
    }
}
```

### 5. Monitor Batch Metrics

**Key metrics to track**:

```csharp
public class BatchMetrics
{
    public long TotalBatches { get; set; }
    public long TotalItems { get; set; }
    public double AverageBatchSize => TotalItems / (double)TotalBatches;
    public TimeSpan AverageBatchProcessingTime { get; set; }
    public long FailedBatches { get; set; }
    public int CurrentQueueDepth { get; set; }
}
```

---

## Related Documentation

- [Worker Patterns](./worker_patterns.md)
- [CDC Infrastructure](../data/cdc.md)
- [Integration](../integration/.md)
- [Performance Tuning Guide](../guides/performance.md)

---

**Last Updated**: 2025-11-13
**Version**: 1.0
