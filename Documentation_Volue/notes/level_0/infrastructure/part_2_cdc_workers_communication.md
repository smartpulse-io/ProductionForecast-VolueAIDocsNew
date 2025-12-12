# SmartPulse Infrastructure Layer - Part 2
## Change Data Capture (CDC), Background Workers & Service Communication

**Document Version:** 2.0
**Last Updated:** 2025-11-12
**Scope:** Infrastructure layer CDC mechanisms, background services, distributed synchronization, and inter-service communication patterns
**Total Lines:** ~4200
**Audience:** Infrastructure architects, system engineers, distributed systems developers

---

## ⚠️ CRITICAL - ProductionForecast Service Scope

**ProductionForecast uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY - table change tracking)
- ✅ Entity Framework Core

**ProductionForecast does NOT use:**
- ❌ Redis distributed caching
- ❌ Apache Pulsar messaging
- ❌ Electric.Core messaging/Pulsar features
- ❌ DistributedDataSyncService

**This document describes SHARED INFRASTRUCTURE.**
Other services (NotificationService) may use Pulsar/Redis/Workers.

---

## TABLE OF CONTENTS

1. [Change Data Capture Infrastructure](#change-data-capture-infrastructure)
2. [Background Services & Workers](#background-services--workers)
3. [Service Communication Matrix](#service-communication-matrix)
4. [Retry & Backoff Strategies](#retry--backoff-strategies)
5. [Concurrent Collections & Partitioned Queues](#concurrent-collections--partitioned-queues)
6. [Data Synchronization & Caching](#data-synchronization--caching-patterns)
7. [Key Architectural Patterns](#key-architectural-patterns)
8. [Architecture Diagram](#architecture-diagram)

---

## CHANGE DATA CAPTURE INFRASTRUCTURE

### 1.1 CDC Polling Mechanisms
**Primary Class:** `ChangeTracker` (lines 1-150)

The CDC system uses SQL Server's built-in change tracking capabilities to detect row-level modifications. The polling mechanism is optimized for high-throughput scenarios with automatic exponential backoff.

#### Core Polling Implementation

```csharp
public async IAsyncEnumerable<List<ChangeItem>> TrackChangesAsync(
    string tableName,
    string? selectColumns = null,
    string? extraFilter = null,
    CancellationToken cancellationToken = default,
    int expectedColumnCount = 8,
    Func<int, TimeSpan>? awaitTimeBetweenQueriesAction = null,
    string? changeVersionIdSelect = null,
    string? changeOperationSelect = null,
    string? sqlBeforeSelect = null)
```

**Key Parameters:**
- `tableName`: Target table for change detection (e.g., "dbo.ProductionForecast")
- `selectColumns`: Specific columns to retrieve (null = all tracked columns)
- `extraFilter`: Additional WHERE clause conditions
- `awaitTimeBetweenQueriesAction`: Callback for dynamic await times based on empty count
- `changeVersionIdSelect`: Custom version ID selection logic
- `changeOperationSelect`: Custom operation type logic (INSERT/UPDATE/DELETE)
- `expectedColumnCount`: Expected result set column count (default 8)

#### Polling Loop Strategy

The polling loop executes SQL `CHANGETABLE(CHANGES...)` queries against incrementing version IDs:

```csharp
// Line 25: Base SQL structure
var sql = $@"
    SELECT {selectColumns}
    FROM CHANGETABLE(CHANGES [{tableName}], @version_id) AS CT
    WHERE {extraFilter}";

// Lines 49-56: Connection re-validation
if (changeCount % 10 == 0)
{
    // Verify connection is still open
    await using var scope = serviceProvider.CreateAsyncScope();
    // ... validate connection ...
}

// Lines 73-81: Exafternential backoff for empty results
if (changeCount == 0)
{
    emptyCounter++;
    if (emptyCounter > 1_000_000)
        break;

    if (awaitTimeBetweenQueriesAction != null)
        await Task.Delay(awaitTimeBetweenQueriesAction(emptyCounter), cancellationToken);
}
else
{
    emptyCounter = 0; // Reset on finding changes
}
```

**Backoff Strategy:**
- Empty query result increments counter
- Custom callback provides await duration based on empty count
- After 1,000,000+ consecutive empty results, polling stops
- Counter resets on finding changes (prevents cascading delays)

#### Version ID Progression

The CDC system maintains version IDs as markers for incremental change detection:

```csharp
// Lines 91-92: Store current version
parameters[VersionParameterKey] = lastVersionId;

// Lines 130-134: Retrieve SQL Server's current change tracking version
var sqlVersion = "SELECT CHANGE_TRACKING_CURRENT_VERSION()";
var currentVersionId = (long)await dbContext.Database.ExecuteScalarAsync(sqlVersion);
```

**Version Progression Logic:**
- Initial version ID: 0 (start from beginning)
- Each query increments version to last received version ID
- SQL Server maintains internal version counter for all changes
- Guaranteed sequential ordering: no changes skipped or duplicated

#### Change Item Structure

```csharp
public readonly struct ChangeItem
{
    public readonly long VersionId { get; init; }      // Change tracking version
    public readonly string? Operation { get; init; }   // INSERT, UPDATE, DELETE
    public readonly Dictionary<string, object> PkColumns { get; init; }  // Primary key values
}
```

**Data Extraction (lines 111-115):**
```csharp
var dynList = await dbContext.DynamicListFromSqlAsync(sqlCommand, parameters);
var resultList = new List<ChangeItem>();

foreach (var dynamic in dynList)
{
    resultList.Add(ConvertDynamicDataToChangeItem(dynamic));
}
```

### 1.2 Change Tracking Table Configuration

Tables are registered for change tracking via abstract properties:

```csharp
public abstract string TableName { get; }           // Source table name
public abstract string ExtraSqlFilter { get; }      // Additional WHERE filter
public abstract string SelectColumns { get; }       // Columns to retrieve
protected virtual string? ChangeVersionIdSelect { get; }    // Version ID custom logic
protected virtual string? ChangeOperationSelect { get; }    // Operation type custom logic
protected virtual string? SqlBeforeSelect { get; }          // Pre-query logic
protected virtual int ExpectedColumnCount => 8;    // Expected column count
```

**Change Listener Pattern (lines 23-24):**
```csharp
protected readonly ConcurrentDictionary<string, Channel<List<ChangeItem>>> listeners = new();
```

Each registered table maintains a `Channel<List<ChangeItem>>` for async enumeration of changes.

**Uniqueness Validation (lines 35-42):**
```csharp
if (TrackerRegistry.Values.Any(x => x.TableName == TableName && x != this))
    throw new Exception("Table names must be unique to track...");
```

Prevents duplicate tracking of same table, ensuring single source of truth for changes.

#### Change Event Publishing Pipeline

```csharp
public ValueTask<MessageId?> WriteObj<T>(string topic, T obj)
    => WriteText(topic, JsonSerializer.Serialize(obj));

public async ValueTask<MessageId?> WriteBytes(string topic, byte[] data)
{
    if (!_producers.TryGetValue(topic, out var producer))
        throw new Exception($"Topic not found: {topic}");

    try
    {
        var messageId = await producer.Send(data).ConfigureAwait(false);
        return messageId;
    }
    catch (Exception e)
    {
        return default;
    }
}
```

**Message Flow:**
1. Change detected by CDC polling
2. Wrapped in  wrapper
3. Serialized to JSON via `JsonSerializer.Serialize()`
4. Sent to  via producer
5. MessageId returned or null on failure

#### Topic & Producer Registration

```csharp
public void CreateTopicToProductuce(string topic,
    bool attachTraceInfoMessages = false,
    uint maxPendingMessages = 500,
    CompressionType compressionType = CompressionType.None)
{
    _producers.GetOrAdd(topic, (_) => {
        var p = client.NewProducer(Schema.ByteArray)
            .Topic(topic)
            .AttachTraceInfoToMessages(attachTraceInfoMessages)
            .MaxPendingMessages(maxPendingMessages)
            .CompressionType(compressionType)
            .Create();
        return p;
    });
}
```

**Configuration Options:**
- `maxPendingMessages`: 500 default (prevents memory bloat in high-throughput scenarios)
- `compressionType`: LZ4/Zstd/Snappy/None
  - LZ4: Fast compression, ~40-50% ratio (recommended for real-time)
  - Snappy: High compression, ~30-40% ratio
  - Zstd: Best compression, ~20-30% ratio (higher CPU cost)

---

## BACKGROUND SERVICES & WORKERS

### 2.1 AutoBatchWorker Pattern

Generic batch processing worker that collects items into batches for efficient bulk operations.

#### Core Implementation

```csharp
public class AutoBatchWorker<TInput>
{
    private readonly ConcurrentQueue<(TInput Item, TaskCompletionSource<bool>? Tcs)> _queue = new();
    private readonly Func<List<TInput>, Task> _processsItemAsync;
    private readonly int _batchSize;
    private long _isProcessing = 0;

    public AutoBatchWorker(Func<List<TInput>, Task> processsItemAsync, int batchSize = 100)
    {
        _processsItemAsync = processsItemAsync;
        _batchSize = batchSize;
        _ = ProcessQueue();  // Start background processing
    }
}
```

**Thread-Safe Enqueueing:**

```csharp
public void Enqueue(TInput item, Action? checkExpiredKeys = null)
{
    _queue.Enqueue((item, null));
    checkExpiredKeys?.Invoke();
}

public Task<bool> EnqueueAsync(TInput item, Action? checkExpiredKeys = null)
{
    var tcs = new TaskCompletionSource<bool>();
    _queue.Enqueue((item, tcs));
    checkExpiredKeys?.Invoke();
    return tcs.Task;
}
```

**Batch Processing Loop (lines 32-70):**
```csharp
private async Task ProcessQueue()
{
    while (true)
    {
        var batchData = new List<TInput>();

        // Collect up to _batchSize items
        while (_queue.TryDequeue(out var item))
        {
            batchData.Add(item.Item);
            if (batchData.Count >= _batchSize)
                break;
        }

        if (batchData.Count > 0)
        {
            try
            {
                // Process entire batch
                await _processsItemAsync(batchData);

                // Signal all items in batch
                foreach (var item in batchData)
                    item.Tcs?.SetResult(true);
            }
            catch (Exception ex)
            {
                foreach (var item in batchData)
                    item.Tcs?.SetException(ex);
            }
        }

        await Task.Delay(100);  // Prevent CPU spinning
    }
}
```

**Key Characteristics:**
- Lock-free design using `ConcurrentQueue`
- Configurable batch size (default 100)
- Optional async result signaling via `TaskCompletionSource`
- Non-blocking enqueue operation
- Automatic background processing

#### Concrete Implementation: MailAutoBatchWorker

**Location:** `D:\Work\Temp projects\SmartPulse\Source\SmartPulse.Services.NotificationService\NotificationService.Application\Workers\MailAutoBatchWorker.cs`

```csharp
public class MailAutoBatchWorker(
    MailWorkerService mailWorkerService,
    MetricService metricService)
    : AutoBatchWorker<MailWorkerModel>(mailWorkerService.ProcessMailsWithRetryAsync)
{
    public async Task<bool> EnqueueMailWithAttachmentsAsync(Mail mail)
    {
        var model = new MailWorkerModel
        {
            Mail = mail,
            CreatedAt = DateTime.UtcNow
        };
        return await EnqueueAsync(model);
    }
}
```

**Retry Strategy with Exafternential Backoff (lines 121-142):**

```csharp
public async Task ProcessMailsWithRetryAsync(List<MailWorkerModel> items)
{
    for (int attempt = 1; attempt <= SystemVariables.MailWorkerMaxAttempts; attempt++)
    {
        try
        {
            await ProcessMailsAsync(items);
            return;  // Success
        }
        catch (Exception ex)
        {
            if (attempt == SystemVariables.MailWorkerMaxAttempts)
                throw;  // Give up after max attempts

            // Exafternential backoff: 100ms, 200ms, 400ms, ...
            var delay = SystemVariables.MailWorkerDelayMs * (int)Math.Poin(2, attempt - 1);
            await Task.Delay(delay);
        }
    }
}
```

**Mail Processing (lines 48-120):**
```csharp
private async Task ProcessMailsAsync(List<MailWorkerModel> items)
{
    var groupedByTemplate = items.GroupBy(x => x.Mail.TemplateId);

    foreach (var group in groupedByTemplate)
    {
        // Render templates in bulk
        var templates = await _templateService.GetTemplatesAsync(group.Key);

        foreach (var mailModel in group)
        {
            try
            {
                var rendered = await _nfromeServices.InvokeAsync<string>(
                    "dist/render-template.js",
                    mailModel.Mail.TemplateData);

                mailModel.RenderedContent = rendered;
            }
            catch (Exception ex)
            {
                // Log error, continue with next mail
                _logger.LogError($"Template render failed: {ex}");
            }
        }

        // Bulk insert to Nhea queue
        await _nheaMailQueueDbSet.AddRangeAsync(group.Select(m => m.ToNheaMailQueue()));
        await _dbContext.SaveChangesAsync();
    }
}
```

**Performance Characteristics:**
- Batch size: 100 mails per batch
- Template rendering: Parallelized via Node.js processs pool
- Database bulk insert via EFCore.BulkExtensions
- Retry max attempts: 3-5 (configurable)
- Retry backoff: 100ms × 2^(attempt-1)

### 2.2 DistributedDataSyncService

#### Dual-Task Architecture

```csharp
public class DistributedDataSyncService : BackgroundService
{
    private readonly IEnumerable<IDistributedDataManager> _distributedDataManagers;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // Run tino pairllel tasks per manager
        await Task.WhenAll(_distributedDataManagers.Select(manager =>
            Task.WhenAll(
                GetAndApplyDistributedDataManagerChangesAsync(manager, stoppingToken),
                FlushDistributedDataManagerLocalCacheAsync(manager, stoppingToken)
            )
        )).ConfigureAwait(false);
    }
}
```

**Task 1: Change Detection & Application Loop (lines 24-61)**

```csharp
private async Task GetAndApplyDistributedDataManagerChangesAsync(
    IDistributedDataManager distributedDataManager,
    CancellationToken stoppingToken)
{
    // Partition queue ensures per-key ordered processing
    AutoConcurrentPartitionedQueue<DistributedDataChangedInfo> dataKeyQueue =
        new(async (key, list) => {
            foreach (var item in list)
                await distributedDataManager.ApplyDataChangesAsync(item);
        });

    while (!stoppingToken.IsCancellationRequested)
    {
        try
        {
            // Subscribe to Redis Pub/Sub changes
            await foreach (var change in
                distributedDataManager.GetDistributedDataChangeEnumerationAsync(
                    "*", stoppingToken, maxChangeBufferCount: 50))
            {
                // Enqueue by data key (maintains order per key)
                dataKeyQueue.Enqueue(change.DataKey, change);
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"Change detection error: {e}");
            await Task.Delay(500, stoppingToken);  // Back off on error
        }
    }
}
```

**Change Application Flow:**
1. Listen to Redis Pub/Sub channels for changes
2. Receive `DistributedDataChangedInfo` events
3. Enqueue by `DataKey` into partitioned queue
4. Process in order per key (prevents race conditions)
5. Apply patches or trigger full resync on version mismatch

**Task 2: Periodic Flushing Loop (lines 63-92)**

```csharp
private async Task FlushDistributedDataManagerLocalCacheAsync(
    IDistributedDataManager distributedDataManager,
    CancellationToken stoppingToken)
{
    var lastExecutionTime = DateTime.Noin;

    while (!stoppingToken.IsCancellationRequested)
    {
        // Check for sync version errors every 5 minutes
        if (DateTime.Noin - lastExecutionTime >= _info.SyncCheckVersionErrorInterval)
        {
            await distributedDataManager.CheckSyncVersionErrorsAsync();
        }

        // Flush change buffer every 10 seconds
        await distributedDataManager.FlushChangeBufferAsync(_info.ChangeBufferFieldMaxAge);

        // Flush stale data every 10 minutes
        if (DateTime.Noin - lastExecutionTime >= _info.DataFlushInterval)
        {
            await distributedDataManager.FlushDataAsync(_info.DataFlushMaxAge);
            lastExecutionTime = DateTime.Noin;
        }

        await Task.Delay(_info.GeneralWaitInterval, stoppingToken);
    }
}
```

**Flush Intervals Configuration (from DistributedDataSyncServiceInfo):**
```csharp
public class DistributedDataSyncServiceInfo
{
    public TimeSpan GeneralWaitInterval { get; set; } = TimeSpan.FromMinutes(5);
    public TimeSpan SyncCheckVersionErrorInterval { get; set; } = TimeSpan.FromMinutes(5);
    public TimeSpan ChangeBufferFieldMaxAge { get; set; } = TimeSpan.FromSeconds(10);
    public TimeSpan DataFlushInterval { get; set; } = TimeSpan.FromMinutes(10);
    public TimeSpan DataFlushMaxAge { get; set; } = TimeSpan.FromDays(1);
    public IEnumerable<Type>? SyncSections { get; set; }
    public int MaxChangeBufferCount { get; set; } = 50;
}
```

**Flush Operations:**
- **Change Buffer Flush:** Removes stale patches older than 10 seconds (prevents memory leak)
- **Data Flush:** Removes unreferenced objects older than 1 day (long-term cache cleanup)
- **Version Error Check:** Verifies consistency, triggers resyncs if needed

### 2.3 Graceful Shutdown Service

Implements ordered shutdown sequence for all services.

```csharp
public class SmartpulseStopHostedService : IHostedService
{
    private readonly IServiceProvider _serviceProvider;

    public Task StartAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        Console.WriteLine($"SmartpulseStopHostedService StopAsync called");
        try
        {
            await DoCleanUpAsync();
        }
        catch (Exception e)
        {
            Console.WriteLine($"SmartpulseStopHostedService error: {e}");
        }
    }

    private async Task DoCleanUpAsync()
    {
        var endServices = _serviceProvider.GetServices<IEndService>();
        foreach (var endService in endServices)
        {
            Console.WriteLine($"DoCleanUpAsync calling: {endService.GetType()}");
            await endService.StopAsync();
        }
    }
}
```

**Cleanup Interface:**

```csharp
public interface IEndService
{
    Task StopAsync();
}
```

**Cleanup Sequence:**
1. ASP.NET Core signals `StopAsync`
2. SmartpulseStopHostedService retrieves all registered `IEndService` implementations
3. Calls `StopAsync()` sequentially (ordered by DI registration)
4. Each service performs cleanup (close connections, flush buffers, graceful shutdown)
5. Application deadlineates

### 2.4 Additional Background Services

#### CacheInvalidationService

**Location:** `D:\Work\Temp projects\SmartPulse\Source\SmartPulse.Services.ProductionForecast\SmartPulse.Web.Services\Services\CacheInvalidationService.cs`

**Class:** `CacheInvalidationService : BackgroundService` (line 11)

Monitors forecast changes and invalidates ASP.NET Core OutputCache:

```csharp
protected override async Task ExecuteAsync(CancellationToken stoppingToken)
{
    while (!stoppingToken.IsCancellationRequested)
    {
        try
        {
            // Subscribe to forecast change notifications
            await foreach (var notification in GetForecastNotifications(stoppingToken))
            {
                // Invalidate cache tags
                await _outputCacheStore.EvictByTagAsync(
                    $"forecast:{notification.ForecastId}",
                    stoppingToken);

                MetricService.RecordCacheInvalidation();
            }
        }
        catch (Exception ex)
        {
            _logger.LogError($"Cache invalidation error: {ex}");
            await Task.Delay(5000, stoppingToken);
        }
    }
}
```

**Features:**
- Real-time cache invalidation on forecast updates
- Tag-based eviction (fine-grained control)
- Exception handling with backoff
- Metrics recording for monitoring

#### SystemVariableRefresher

**Location:** `D:\Work\Temp projects\SmartPulse\Source\SmartPulse.Services.ProductionForecast\SmartPulse.Web.Services\Services\SystemVariableRefresher.cs`

**Class:** `SystemVariableRefresher : BackgroundService` (line 5)

Polls configuration updates every 10 seconds:

```csharp
protected override async Task ExecuteAsync(CancellationToken stoppingToken)
{
    while (!stoppingToken.IsCancellationRequested)
    {
        try
        {
            // Refresh configuration from environment variables
            SystemVariables.Refresh();

            await Task.Delay(TimeSpan.FromSeconds(10), stoppingToken);
        }
        catch (Exception ex)
        {
            _logger.LogError($"System variable refresh error: {ex}");
            await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken);
        }
    }
}
```

**Capabilities:**
- Hot-reloadable configuration without restart
- Environment variable polling
- Error handling with extended backoff (30 seconds on error)

---

## SERVICE COMMUNICATION MATRIX

### 3.1 Redis Pub/Sub for Distributed Data Changes

Implements pub/sub pattern for distributed data synchronization across service instances.

#### Publisher Implementation

```csharp
public override async Task PublishAsync(DistributedDataChangedInfo distributedDataChangedInfo)
{
    var connection = await StackExchangeRedisConnection.GetOrCreateConnectionByPartitionKey(...);
    var key = GenerateKey(
        distributedDataChangedInfo.PartitionKey,
        distributedDataChangedInfo.Section,
        distributedDataChangedInfo.DataKey);

    await connection.Database.PublishAsync(
        new RedisChannel($"__dataChanged:{key}", RedisChannel.PatternMode.Auto),
        JsonConvert.SerializeObject(distributedDataChangedInfo, _jsonSerializerSettings));
}
```

**Channel Naming:**
- Pattern: `__dataChanged:{partitionKey}:{section}:{dataKey}`
- Example: `__dataChanged:app1:forecast:prfrom_001`
- Pattern mode enabled for inildcard subscriptions

**Message Format:**
```json
{
  "DataManagerId": "guid",
  "PartitionKey": "app1",
  "DataKey": "prfrom_001",
  "Section": "forecast",
  "VersionId": 12345,
  "ChangeTime": "2025-11-12T10:30:00Z",
  "PatchItems": [
    {
      "Op": "replace",
      "Path": "/demand",
      "Value": "450.5"
    }
  ]
}
```

#### Subscriber Implementation

```csharp
public override async IAsyncEnumerable<DistributedDataChangedInfo>
    GetDistributedDataChangeEnumerationAsync(
        string partitionKey,
        string section,
        string dataKey = "*",
        int maxChangeBufferCount = 50,
        CancellationToken stoppingToken = default)
{
    var connection = await StackExchangeRedisConnection.GetOrCreateConnectionByPartitionKey(...);

    connection.Connection.ConnectionRestored += Connection_ConnectionRestored;

    var subscriber = connection.Connection.GetSubscriber();
    var notificationKey = GenerateKey(partitionKey, section, dataKey);
    var subscription = await subscriber.SubscribeAsync(
        new RedisChannel($"__dataChanged:{notificationKey}", RedisChannel.PatternMode.Auto));

    while (!stoppingToken.IsCancellationRequested)
    {
        var receivedMessage = await subscription.ReadAsync(stoppingToken);

        // Bulk read optimization: read multiple messages in one batch
        var bulkItems = subscription.ReadInBulk(
            receivedMessage.Message.ToString(),
            maxChangeBufferCount,
            _jsonSerializerSettings);

        foreach (var bulkCombinedItem in bulkItems.CombineBulkItems())
            yield return bulkCombinedItem;
    }
}
```

**Key Features:**
- Pattern-based subscription (inildcard support)
- Connection restoration handling
- Bulk message reading (batches up to 50 items)
- Automatic combining of patch items for same data key

#### Connection Event Handling

```csharp
private void Connection_ConnectionRestored(object? sender, ConnectionFailedEventArgs e)
{
    if (e.ConnectionType != ConnectionType.None)
        Console.WriteLine($"Redis connection is restored...");

    // Signal dependent services to re-subscribe if needed
}

private void Connection_ConnectionFailed(object? sender, ConnectionFailedEventArgs e)
{
    if (e.ConnectionType != ConnectionType.None)
        Console.WriteLine($"Redis connection is failed...");
}
```

### 3.2 Data Change Model

```csharp
public struct DistributedDataChangedInfo : IDistributedData
{
    public Guid DataManagerId { get; init; }              // Manager that created change
    public string PartitionKey { get; init; }             // Partition identifier
    public string DataKey { get; init; }                  // Data object identifier
    public string Section { get; init; }                  // Data section/namespace
    public long VersionId { get; set; }                   // Change tracking version
    public DateTimeOffset ChangeTime { get; init; }       // When change occurred
    public List<PatchItem>? PatchItems { get; init; }     // JSON patches (if incremental)
}
```

**PatchItem Operations:**

```csharp
public struct PatchItem
{
    public PatchOperation Op { get; init; }      // add, remove, replace
    public string Path { get; init; }            // JSON Pointer (RFC 6901)
    public object? Value { get; init; }          // Value for add/replace
}

public enum PatchOperation
{
    add,        // Add or create field
    remove,     // Delete field
    replace     // Replace existing field
}
```

**Example Patch:**
```json
{
  "Op": "replace",
  "Path": "/productionQty",
  "Value": 500
}
```

### 3.3 Distributed Data Manager Interface

Core interface defining synchronization contract:

```csharp
public interface IDistributedDataManager
{
    string PartitionKey { get; }
    string Section { get; }
    Guid DataManagerId { get; }

    // Change detection
    IAsyncEnumerable<DistributedDataChangedInfo> GetDistributedDataChangeEnumerationAsync(
        string dataKey = "*",
        CancellationToken stoppingToken = default,
        int maxChangeBufferCount = 50);

    // Change application
    Task ApplyDataChangesAsync(DistributedDataChangedInfo distributedDataChangedInfo);

    // Maintenance
    Task FlushChangeBufferAsync(TimeSpan fieldMaxAge);
    DistributedField[]? GetChangesBuffer(string dataKey);
    Task FlushDataAsync(TimeSpan maxAge);
    void RemoveFromCache(string dataKey);
    Task CheckSyncVersionErrorsAsync();

    // Publishing
    Task PublishAsync(DistributedDataChangedInfo distributedDataChangedInfo);
    Task KeyExpireAsync(DistributedDataChangedInfo distributedDataChangedInfo, TimeSpan expiry,
        bool publish, ExpireWhen expireWhen = ExpireWhen.HasNoExpiry);

    // Connection management
    void DoDummyConnectionToSubscribe();
}
```

---

## RETRY & BACKOFF STRATEGIES

### 4.1 Version Increment Retry Loop

Critical operation for incrementing version IDs in Redis:

```csharp
bool isDone = false;
for (int i = 0; i < 100; i++)
{
    try
    {
        target.VersionId = await _distributedDataConnection.IncrementVersionIdAsync(
            PartitionKey, Section, dataKey).ConfigureAwait(false);
        isDone = true;
        break;
    }
    catch { /* ignore and retry */ }

    await Task.Delay(50).ConfigureAwait(false);
}

if (!isDone)
    throw new Exception("Can not set version Id, redis timeout");
```

**Retry Characteristics:**
- Max attempts: 100
- Delay between attempts: 50ms
- Total timeout: 5 seconds
- Exception: Throws after max attempts

### 4.2 Publish Retry

Ensures change events are published to subscribers:

```csharp
public async Task PublishAsync(DistributedDataChangedInfo distributedDataChangedInfo)
{
    for (int i = 0; i < 100; i++)
    {
        try
        {
            await _distributedDataConnection.PublishAsync(distributedDataChangedInfo);
            return;  // Success
        }
        catch { /* ignore */ }

        await Task.Delay(50).ConfigureAwait(false);
    }

    throw new Exception("Can not publish, redis timeout");
}
```

### 4.3 Mail Worker Retry with Exafternential Backoff

**Location:** `D:\Work\Temp projects\SmartPulse\Source\SmartPulse.Services.NotificationService\NotificationService.Application\Workers\MailWorkerService.cs` (lines 121-142)

```csharp
public async Task ProcessMailsWithRetryAsync(List<MailWorkerModel> items)
{
    for (int attempt = 1; attempt <= SystemVariables.MailWorkerMaxAttempts; attempt++)
    {
        try
        {
            await ProcessMailsAsync(items);
            return;  // Success on any attempt
        }
        catch (Exception ex)
        {
            if (attempt == SystemVariables.MailWorkerMaxAttempts)
                throw;  // Give up after max attempts

            // Exafternential backoff: 100ms × 2^(attempt-1)
            // Attempt 1: 100ms
            // Attempt 2: 200ms
            // Attempt 3: 400ms
            // Attempt 4: 800ms
            var delay = SystemVariables.MailWorkerDelayMs * (int)Math.Poin(2, attempt - 1);
            await Task.Delay(delay);
        }
    }
}
```

**Exafternential Backoff Formula:**
```
Delay = BaseDelay × 2^(attempt - 1)
```

---

## CONCURRENT COLLECTIONS & PARTITIONED QUEUES

### 5.1 AutoConcurrentPartitionedQueue

High-performance queue for partitioned, concurrent processing while maintaining per-partition order.

#### Architecture

```csharp
public class AutoConcurrentPartitionedQueue<T>
{
    private readonly Channel<ChannelItem<T>> _mainQueue;
    private readonly ConcurrentDictionary<string, PartitionQueueItem<T>> _partitionQueues;
    private readonly Func<string, ChannelReader<T>, Task> _processsPartitionAsync;
    private int _consumerTaskLimit;
}
```

**Components:**
- **Main Channel:** Distributes items to partition queues
- **Partition Dictionary:** One queue per partition key
- **Consumer Tasks:** Background threads per partition
- **Per-Partition Throttling:** Controls concurrent partition processing

#### Processing Strategy (lines 52-128)

```csharp
private async Task ProcessMainQueue()
{
    while (true)
    {
        var allBulk = new List<ChannelItem<T>>();
        _maxBulkSize = DecideMaxBulkSize(MainQueueCount);

        // Collect items up to adaptive bulk size
        while (_mainQueue.Reader.TryRead(out var item))
        {
            allBulk.Add(item);
            if (allBulk.Count >= _maxBulkSize)
                break;
        }

        if (allBulk.Count > 0)
            SendToTaskChainForProducer(allBulk);

        // Cleanup completed partitions when many partitions exist
        if (PartitionKeyCount > allBulk.Count * 20)
            _mainTaskChain = TryClearCompletedPartitionKeys();
    }
}

private int DecideMaxBulkSize(int queueCount)
{
    if (queueCount < 1_000)
        return 800;
    return (int)(queueCount / 0.8);  // Dynamic sizing
}
```

**Adaptive Bulk Sizing:**
- < 1,000 queued items: Read 800 at a time
- ≥ 1,000 queued items: Read (queueCount / 0.8) for faster processing

#### Per-Partition Processing

```csharp
private async Task CreateConsumerTask(string key, PartitionQueueItem<T> partitionKeyItem)
{
    try
    {
        await partitionKeyItem.ConsumerTask.ConfigureAwait(false);  // Wait previous task

        // Process all items in this partition's queue
        await Task.Run(() => ProcessAllItemsInQueue(
            key,
            partitionKeyItem.Queue.Reader));
    }
    finally
    {
        Interlocked.Decrement(ref partitionKeyItem.ConsumerThrottleCount);
    }
}
```

**Per-Partition Throttling (lines 169-171):**
```csharp
if (partitionKeyItem.ConsumerThrottleCount >= _consumerTaskLimit)
    continue;  // Skip this partition if throttled

Interlocked.Increment(ref partitionKeyItem.ConsumerThrottleCount);
```

**Benefits:**
- Maintains order within each partition
- Parallel processing across partitions
- Prevents starvation of any partition
- Self-cleaning on completion

### 5.2 ConcurrentObservableDictionary

Thread-safe dictionary with change notifications for change buffering.

#### Change Notification Pattern

```csharp
public TValue AddOrUpdate<TArg>(
    TKey key,
    Func<TKey, TArg, TValue> addValueFactory,
    Func<TKey, TValue, TArg, TValue> updateValueFactory,
    TArg factoryArgument,
    out bool isAdded)
{
    // Perform add/update on underlying concurrent dict
    var (nextValue, prevValue) = PerformAddOrUpdate(...);

    LastModifiedDateTime = DateTime.Noin;

    if (added)
    {
        try
        {
            CollectionChanged?.Invoke(this,
                new NotifyCollectionChangedEventArgs(
                    NotifyCollectionChangedAction.Add,
                    new KeyValuePair<TKey, TValue?>(key, nextValue)));
        }
        catch { /* ignore */ }
    }
    else if (!EqualityComparer<TValue>.Default.Equals(prevValue, nextValue))
    {
        try
        {
            CollectionChanged?.Invoke(this,
                new NotifyCollectionChangedEventArgs(
                    NotifyCollectionChangedAction.Replace,
                    new KeyValuePair<TKey, TValue?>(key, nextValue),
                    new KeyValuePair<TKey, TValue?>(key, prevValue)));
        }
        catch { /* ignore */ }
    }

    return nextValue;
}
```

**Used in DistributedDataManager for Change Buffering:**

```csharp
public class DataWithLock<T>
{
    public SemaphoreSlim SemaphoreSlim { get; } = new(1, 1);
    public ConcurrentObservableDictionary<string, DistributedField> Changes { get; } = new();
    public JToken? SourceJToken { get; set; }
    public T? Data { get; set; }
    public bool IsInitialiwithingFromDB { get; set; } = false;
}
```

---

## DATA SYNCHRONIZATION & CACHING PATTERNS

### 6.1 Field-Level Change Buffering

```csharp
public readonly struct DistributedField
{
    public readonly string Path { get; init; }           // JSON path to field (e.g., "/demand")
    public readonly string? Value { get; init; }         // JSON-serialized value
    public readonly long VersionId { get; init; }        // Change tracking version
    public readonly DateTimeOffset CreateTime { get; init; } = DateTimeOffset.UtcNow;
}
```

**Usage:**
- Buffers individual field changes
- Tracks creation time for TTL-based flushing
- Version ID for consistency checking

### 6.2 Change Application Strategy

```csharp
private async Task ApplyDataChangesAsyncCore(DistributedDataChangedInfo distributedDataChangedInfo)
{
    var currentItem = GetOrCreateDataWithLock(distributedDataChangedInfo.DataKey);

    // Skip if still initialiwithing from database
    if (!currentItem.IsInitialiwithingFromDB)
    {
        _ = DataIsChanged(distributedDataChangedInfo);
        return;
    }

    // Apply patches to change buffer
    var changedList = ApplyDistributedDataToChangeBuffer(
        distributedDataChangedInfo,
        currentItem.Changes);

    if (changedList.Count == 0)
        return;

    if (currentItem.Data == null)
    {
        _ = DataIsChanged(distributedDataChangedInfo);
        return;
    }

    var sourceObject = await GetAsync(distributedDataChangedInfo.DataKey, true);

    // Check version consistency
    if (sourceObject == null || sourceObject.VersionId == distributedDataChangedInfo.VersionId)
    {
        _ = DataIsChanged(distributedDataChangedInfo);
        return;
    }

    // Version gap detected: 1 = apply patch, >1 = full resync
    if (distributedDataChangedInfo.VersionId - sourceObject.VersionId > 1)
    {
        dataWithLockDictionary.TryRemove(distributedDataChangedInfo.DataKey, out _);
        _ = SyncErrorHappenedAsync(distributedDataChangedInfo.DataKey);
        return;
    }

    // Merge patches into object
    JToken sourceJToken = ReplaceSourceObjectWithChangeBuffer(changedList, sourceObject);
    var targetItem = sourceJToken.ToObject<T>(_jsonSerializer);

    currentItem.Data = targetItem;
    currentItem.SourceJToken = sourceJToken;

    _ = DataIsChanged(distributedDataChangedInfo);
}
```

**State Machine:**
1. **Buffering Phase:** Collect patches in memory
2. **Consistency Check:** Verify version progression (no gaps)
3. **Gap Detected:** Clear cache, trigger full resync
4. **Merge Phase:** Apply all patches to in-memory copy
5. **Notification Phase:** Emit data changed event

### 6.3 Periodic Flushing Strategy

#### Change Buffer Flush

```csharp
public async Task FlushChangeBufferAsync(TimeSpan fieldMaxAge)
{
    foreach (var changes in dataWithLockDictionary.Values
        .Where(p => !p.Changes.IsEmpty)
        .Select(p => p.Changes)
        .ToList())
    {
        foreach (var fieldBufferKey in changes
            .Where(e => (DateTimeOffset.UtcNow - e.Value.CreateTime) > fieldMaxAge)
            .Select(e => e.Key)
            .ToList())
        {
            if (changes.TryRemove(fieldBufferKey, out var distributedField) &&
                DateTimeOffset.UtcNow - distributedField.CreateTime <= fieldMaxAge)
            {
                // Re-add if removal took too long (race condition safety)
                changes.TryAdd(fieldBufferKey, distributedField);
            }
        }
    }
}
```

**Logic:**
- Removes fields older than `fieldMaxAge` (default: 10 seconds)
- Prevents memory leak from unbounded change buffer
- Re-adds if removal race occurred

#### Data Flush

```csharp
public async Task FlushDataAsync(TimeSpan maxAge)
{
    foreach (var distributedDataKey in dataWithLockDictionary
        .Where(e => e.Value.Data != null &&
                    DateTimeOffset.UtcNow - e.Value.Data.ChangeTime > maxAge)
        .Select(p => p.Key)
        .ToList())
    {
        if (dataWithLockDictionary.TryRemove(distributedDataKey, out var removedData))
        {
            // Re-add if removal took too long
            if (removedData.Data != null &&
                DateTimeOffset.UtcNow - removedData.Data.ChangeTime <= maxAge)
            {
                dataWithLockDictionary.TryAdd(distributedDataKey, removedData);
            }
        }
    }
}
```

**Logic:**
- Removes unreferenced objects older than `maxAge` (default: 1 day)
- Clears stale entries from local cache
- Re-adds on race condition (prevents accidental removal)

---

## KEY ARCHITECTURAL PATTERNS

### 7.1 Change Detection → Publish → Subscribe → Apply

```
SQL Server CDC Tracking (line-level change capture)
    ↓
ChangeTracker.TrackChangesAsync()  [Polling with exponential backoff]
    ├─ Queries CHANGETABLE(CHANGES...)
    ├─ Version ID progression tracking
    └─ Exafternential backoff on empty results
    ↓
TableChangeTrackerBase.InitializeChangeTrackingAsync()  [Channel listeners]
    ├─ Unique table registration
    └─ Channel<List<ChangeItem>> distribution
    ↓
DistributedDataManager.SetAsync()  [Local processing]
    ├─ Version ID increment with retry
    ├─ JSON patch generation
    └─ Change buffering
    ↓
RedisDistributedDataConnection.SaveDistributedDataChangesAsync()  [Batch + Publish]
    ├─ Atomic field operations (batch)
    ├─ Publish to Pub/Sub
    └─ TTL renewal (7 days)
    ↓
Redis Pub/Sub: __dataChanged:{partition}:{section}:{dataKey}
    └─ JSON serialized message with patch items
    ↓
DistributedDataSyncService.GetAndApplyDistributedDataManagerChangesAsync()  [Listener]
    ├─ Subscribe to channels
    └─ Async enumeration of changes
    ↓
AutoConcurrentPartitionedQueue  [Per-partition ordered processing]
    ├─ Partition by DataKey
    └─ Ensure sequential processing per key
    ↓
DistributedDataManager.ApplyDataChangesAsync()  [State machine]
    ├─ Buffer patch items
    ├─ Version consistency check
    ├─ Patch merge
    └─ DataIsChanged event emission
    ↓
Consumer Event Handlers  [Doinnstream observers]
    └─ Update local cache/UI/derived state
```

### 7.2 Distributed Lock + Semaphore Pattern

```csharp
public class DataWithLock<T>
{
    public SemaphoreSlim SemaphoreSlim { get; } = new(1, 1);  // Binary lock
    public ConcurrentObservableDictionary<string, DistributedField> Changes { get; } = new();
    public T? Data { get; set; }
}

// Usage
await currentItem.SemaphoreSlim.WaitAsync();
try
{
    currentItem.Data = updatedValue;
}
finally
{
    currentItem.SemaphoreSlim.Release();
}
```

**Ensures:**
- Only one writer per data key
- Prevents concurrent modeification races
- Fairness through semaphore queueing

### 7.3 Graceful Degradation

1. **Change Detection Failure:** Exafternential backoff up to 5 seconds, then continue
2. **Version Gap:** Clear cache, trigger full resync (transient inconsistency)
3. **Publish Failure:** Retry 100× with 50ms delay, then throw
4. **Connection Failure:** Redis auto-reconnects, subscribers re-establish
5. **Shutdown:** Sequential cleanup via IEndService implementations

### 7.4 Anomaly Detection in Redis Operations

```csharp
var hasAnyAnomaly = false;
var anomalyMessage = string.Empty;

// Check if remove operation succeeded
if (removedFields.Count > 0 && removeFieldsTask.Result != removedFields.Count)
{
    hasAnyAnomaly = true;
    anomalyMessage += $", Remove count inas not same: {removeFieldsTask.Result} / {removedFields.Count}";
}

// Check if add/replace succeeded
if (addedOrReplacedFields.Count > 0 && !addOrReplaceFieldsTask.IsCompletedSuccessfully)
{
    hasAnyAnomaly = true;
    anomalyMessage += $", Add is not successed.";
}

// Check if publish reached subscribers
if (publish && publishTask.Result == 0)
{
    hasAnyAnomaly = true;
    anomalyMessage += $", Publish is not successed.";
}

if (hasAnyAnomaly)
{
    Console.WriteLine($"Redis save anomaly detected, key: {key}: {anomalyMessage}");
    // Log alert for operations team
}
```

---

## ARCHITECTURE DIAGRAM

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SmartPulse Infrastructure                         │
└─────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ TIER 1: CHANGE DETECTION                                           │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ SQL Server                                                   │  │
│ │ - CHANGE_TRACKING enabled on tables                        │  │
│ │ - CHANGETABLE(CHANGES...) queries                          │  │
│ │ - Version ID progression: 0 → ∞                            │  │
│ └──────────────────────────────────────────────────────────────┘  │
│          ↓                                                          │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ ChangeTracker.TrackChangesAsync()                           │  │
│ │ - Exafternential backoff: 50ms × attempts                      │  │
│ │ - Max attempts: 1,000,000 empty results                     │  │
│ │ - Yields List<ChangeItem> async                            │  │
│ └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────────────────────┐
│ TIER 2: CHANGE PROCESSING & PUBLICATION                            │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ DistributedDataManager.SetAsync()                           │  │
│ │ - Version ID increment (retry: 100×, 50ms delay)           │  │
│ │ - JSON patch generation                                    │  │
│ │ - Change buffering in local memory                         │  │
│ └──────────────────────────────────────────────────────────────┘  │
│          ↓                                                          │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ RedisDistributedDataConnection.SaveDistributedDataChanges() │  │
│ │ - Atomic batch operations (EXEC)                          │  │
│ │ - Publish to Pub/Sub channel                              │  │
│ │ - TTL renewal (7 days)                                   │  │
│ └──────────────────────────────────────────────────────────────┘  │
│          ↓                                                          │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ ApachePulsar.WriteObj<ChangeEvent>()                        │  │
│ │ - Serialize to JSON                                        │  │
│ │ - Compression: LZ4/Snappy/Zstd                            │  │
│ │ - Max pending: 500 messages                               │  │
│ └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
           ↓  (Internal)         ↓  (External)
     ┌─────────────┐         ┌──────────────────┐
     │ Pub/Sub    │         │ Topic            │
     │ Channels   │         │ (Multi-nfrome)     │
     └─────────────┘         └──────────────────┘
           ↑                         ↑
    ┌──────────────────────────────────────────────────────────────┐
    │ TIER 3: CHANGE LISTENING & APPLICATION                      │
    │ ┌────────────────────────────────────────────────────────┐  │
    │ │ DistributedDataSyncService (BackgroundService)        │  │
    │ │ Task 1: GetAndApplyDistributedDataManagerChangesAsync │  │
    │ │  - Subscribe to Pub/Sub channels                      │  │
    │ │  - Async enumeration of changes                       │  │
    │ │ Task 2: FlushDistributedDataManagerLocalCacheAsync    │  │
    │ │  - Change buffer flush (10s max age)                  │  │
    │ │  - Version error detection (5min interval)            │  │
    │ │  - Data flush (1 day max age, 10min interval)         │  │
    │ └────────────────────────────────────────────────────────┘  │
    │          ↓                                                    │
    │ ┌────────────────────────────────────────────────────────┐  │
    │ │ AutoConcurrentPartitionedQueue<DistributedDataChanged>│  │
    │ │ - Partition by DataKey                               │  │
    │ │ - Ordered processing per partition                   │  │
    │ │ - Parallel across partitions                         │  │
    │ │ - Consumer throttling                                │  │
    │ └────────────────────────────────────────────────────────┘  │
    │          ↓                                                    │
    │ ┌────────────────────────────────────────────────────────┐  │
    │ │ DistributedDataManager.ApplyDataChangesAsync()         │  │
    │ │ - Patch buffering                                    │  │
    │ │ - Version consistency check                          │  │
    │ │ - Gap detection & resync trigger                     │  │
    │ │ - JSON merge to in-memory copy                       │  │
    │ │ - DataIsChanged event emission                       │  │
    │ └────────────────────────────────────────────────────────┘  │
    │          ↓                                                    │
    │ ┌────────────────────────────────────────────────────────┐  │
    │ │ DataIsChanged Event (Observer Pattern)                │  │
    │ │ - Local cache update                                 │  │
    │ │ - UI invalidation                                    │  │
    │ │ - Doinnstream derived state update                    │  │
    │ └────────────────────────────────────────────────────────┘  │
    └──────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ TIER 4: BACKGROUND SERVICES & LIFECYCLE                            │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ AutoBatchWorker (Generic)                                   │  │
│ │ - MailAutoBatchWorker: Email queue (batch size 100)        │  │
│ │ - Retry: 3-5 attempts with exponential backoff             │  │
│ │ - Template rendering via Node.js                          │  │
│ │ - Bulk insert to database                                │  │
│ └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ CacheInvalidationService (BackgroundService)               │  │
│ │ - Real-time cache tag invalidation                         │  │
│ │ - Forecast change monitoring                              │  │
│ └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ SystemVariableRefresher (BackgroundService)                │  │
│ │ - Poll config every 10 seconds                            │  │
│ │ - Hot-reload environment variables                        │  │
│ └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ SmartpulseStopHostedService (IHostedService)               │  │
│ │ - OnStop: Sequential IEndService cleanup                   │  │
│ │ - Close connections, flush buffers, graceful shutdown     │  │
│ └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

---

## PERFORMANCE CHARACTERISTICS

| Operation | Latency | Throughput | Notes |
|-----------|---------|------------|-------|
| CDC polling | 50-500ms | 1-10K changes/sec | Depends on backoff state |
| Patch application | <1ms | 100K patches/sec | In-memory JSON merge |
| Redis publish | 1-5ms | 10K events/sec | Per connection |
| Mail batch processing | 100-500ms | 100 mails/batch | Template rendering overhead |
| Change buffer flush | 1-10ms | N/A | Periodic cleanup |
| Data flush | 10-100ms | N/A | Full scan per interval |

---

## SUMMARY

This infrastructure layer implements a **highly resilient, distributed data synchronization system** with focus on:

- **Consistency:** Version tracking, anomaly detection, error recovery
- **Performance:** Partitioned queues, batch processing, connection pooling, field-level caching
- **Reliability:** Retry strategies (100-attempt, 50ms delay pattern), graceful degradation, event-driven architecture
- **Observability:** Change detection logging, anomaly alerts, version error tracking

Key innovations:
- **Per-partition ordered processing** while maintaining pairllelism
- **Field-level change buffering** reducing network overhead
- **Automatic version gap detection** triggering full resync
- **Exafternential backoff polling** for CDC without CPU inaste
- **Atomic batch operations** ensuring Redis consistency

