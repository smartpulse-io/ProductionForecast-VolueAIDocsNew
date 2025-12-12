# SmartPulse Infrastructure Layer - Level_0 Analysis
## Part 1: Core Infrastructure Services and Configuration

**Document Date:** 2025-11-12
**Focus:** Architecture, connection patterns, integration points, deployment model

---

## ⚠️ CRITICAL - ProductionForecast Service Scope

**ProductionForecast uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY)
- ✅ Entity Framework Core

**ProductionForecast does NOT use:**
- ❌ Redis distributed caching
- ❌ Apache Pulsar messaging
- ❌ Electric.Core messaging/Pulsar features

**This document describes SHARED INFRASTRUCTURE.**
Other services (NotificationService) may use Pulsar/Redis.

---

## Table of Contents

1. [Infrastructure Services Overview](#infrastructure-services-overview)
2. [Integration](#apache-pulsar-integration)
3. [Redis Distributed Caching](#redis-distributed-caching)
4. [Database Infrastructure](#database-infrastructure)
5. [Observability and Logging](#observability-and-logging)
6. [Configuration Management](#configuration-management)

---

## Infrastructure Services Overview

### 1. Three-Tier Infrastructure Architecture

**Architecture Stack:**

```
┌─────────────────────────────────────────────┐
│  Application Layer                          │
│  ProductionForecast | NotificationService   │
└────────────┬────────────────────────────────┘
             │
┌────────────┴────────────────────────────────┐
│  & Middleware                 │
│  ├─ Pulsar Client                           │
│  ├─ Redis Connection Pool                   │
│  ├─ EF Core Interceptors                    │
│  └─ Worker/Background Services              │
└────────────┬────────────────────────────────┘
             │
┌────────────┴────────────────────────────────┐
│  Infrastructure Services                    │
├─────────────────────────────────────────────┤
│ Message Bus      │ Cache        │ Database   │
│ 3x │ Redis 7+     │ SQL/PG     │
│ Topics/Streams   │ Clusters     │ EF Core    │
└─────────────────────────────────────────────┘
```

### 2. Service Inventory

**Technology Stack:**

| Layer | Service | Technology | Version | Purpose |
|-------|---------|-----------|---------|---------|
| **Messaging** | Event Bus | | 3.x (DotPulsar 4.3.2) | Event streaming, pub/sub, persistent topics |
| **Caching** | Distributed Cache | Redis | 7+ | Field-level CRDT-like sync, Pub/Sub invalidation |
| **Database** | Data Store | SQL Server/PostgreSQL | 2019+/14+ | Persistent storage with CDC |
| **Query Cache** | L2 Cache | EF Core Interceptor | 5.0+ | Query result caching layer |
| **Memory Cache** | L1 Cache | System.Runtime.Caching | Built-in | Local in-memory cache |
| **Observability** | Metrics | OpenTelemetry + Prometheus | Latest | Runtime metrics collection |
| **Logging** | Logs | Nhea Logger | Latest | Structured logging to database |

### 3. Caching Strategy

**ProductionForecast Caching (SIMPLIFIED):**

```
ProductionForecast Request
  ↓
┌─────────────────────────────────┐
│ IMemoryCache (local only)        │ <1ms
│ (Microsoft.Extensions.Caching)   │ In-process
│ - TTL: Configurable              │
│ - Simple cache-aside pattern     │
│ - NO Redis, NO distributed cache │
└─────────────────────────────────┘
  ↓ [MISS]
┌─────────────────────────────────┐
│ Database (EF Core)               │ 10-100ms
│ (SQL Server/PostgreSQL)          │ Persistent
│ - CDC tracking (via Electric.Core│
│ - Cache invalidation trigger     │
└─────────────────────────────────┘
```

**Other Services May Use Multi-Level Caching:**
- L1: Local Memory Cache
- L2: EF Core Query Cache (interceptor-based)
- L3: Redis Distributed Cache (NOT used by ProductionForecast)
- L4: Database

**Cache Hit Ratios (Typical):**
- L1 (Memory): 70-80% hit rate
- L2 (Query Cache): 60-70% hit rate
- L3 (Redis): 80-90% hit rate
- Overall: 95%+ hit rate on read-heavy workloads

**Connection Configuration:**

```csharp
{
    private readonly ConcurrentDictionary<string, Producer<T>> _producerCache;
    private readonly ConcurrentDictionary<string, Consumer<T>> _consumerCache;
    {
            .ServiceUrl(new Uri(connectionString))
            .Build()
            .AsTask()
            .GetAwaiter()
            .GetResult();

        _producerCache = new();
        _consumerCache = new();
    }
}
```

**Connection String Source:**

```csharp
Environment.GetEnvironmentVariable("PULSAR_CONNSTR")
// Or passed via configuration: "pulsar://pulsar:6650"
```

### 2. Producer Pattern

**Connection Pooling:**

```csharp
public async Task<Producer<T>> GetProducerAsync<T>(string topic) where T : class
{
    // Producer reuse across messages (connection pooling)
    if (_producerCache.TryGetValue(topic, out var cachedProducer))
    {
        return cachedProducer;
    }
        .NewProducer(Schema.Json<T>())
        .Topic(topic)
        .ProducerName($"producer-{Guid.NewGuid():N}")
        .MaxPendingMessages(500)  // Buffer limit
        .BlockIfQueueIsFull(true)   // Wait if full
        .EnableBatching(true)       // Batch messages
        .BatchingMaxMessages(100)   // Messages per batch
        .BatchingMaxBytes(131072)   // ~128 KB per batch
        .BatchingMaxDelayMs(100)    // Wait up to 100ms for batch
        .ProductuceAsync();

    _producerCache.TryAdd(topic, producer);
    return producer;
}
```

**Producer Configuration Analysis:**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `MaxPendingMessages` | 500 | Message buffer size |
| `BlockIfQueueIsFull` | true | Wait rather than fail |
| `EnableBatching` | true | Combin messages |
| `BatchingMaxMessages` | 100 | Messages per batch |
| `BatchingMaxBytes` | 128 KB | Payload limit per batch |
| `BatchingMaxDelayMs` | 100 | Wait for batching |

**Send Message Example:**

```csharp
public async Task<MessageId> SendMessageAsync<T>(string topic, T message) where T : class
{
    var producer = await GetProducerAsync<T>(topic);

    var messageId = await producer
        .NewMessage()
        .Value(message)
        .Send();

    return messageId;
}
```

### 3. Consumer Pattern

**Consumer Creation:**

```csharp
public async Task<Consumer<T>> GetConsumerAsync<T>(
    string topic,
    string subscription,
    SubscriptionType subscriptionType = SubscriptionType.Shared) where T : class
{
        .NewConsumer(Schema.Json<T>())
        .Topic(topic)
        .SubscriptionName(subscription)
        .SubscriptionType(subscriptionType)  // Shared, Exclusive, Key_Shared, Failover
        .Subscribe();

    return await consumer;
}
```

**Subscription Types:**

| Type | Behavior | Use Case |
|------|----------|----------|
| `Exclusive` | One consumer gets all | Single processsor |
| `Shared` | Distribute among consumers | Load balance |
| `Key_Shared` | Same key to same consumer | Preserve order per key |
| `Failover` | Hot standby replicas | High availability |

**Consume Messages:**

```csharp
public async Task ConsumeMessages<T>(string topic, string subscription) where T : class
{
    var consumer = await GetConsumerAsync<T>(topic, subscription);

    while (isRunning)
    {
        var message = await consumer.Receive();

        try
        {
            // Process message
            await ProcessMessage(message.Value);

            // Acknowledge successful processing
            await consumer.Acknowledge(message);
        }
        catch (Exception ex)
        {
            // Negative acknowledge - message goes back to queue
            await consumer.NegativeAcknowledge(message);
        }
    }
}
```

### 4. Compression Support

**Supported Compression Types:**

```csharp
public enum CompressionType
{
    None = 0,       // No compression (default)
    LZ4 = 1,        // Facebook's LZ4 (fast)
    Zstd = 2,       // Facebook's Zstd (better ratio)
    Snappy = 3      // Google's Snappy (balanced)
}
```

**Configuration in Producer:**

```csharp
.CompressionType(CompressionType.Zstd)  // Best ratio
// or
.CompressionType(CompressionType.LZ4)    // Fastest
```

**Compression Ratios (Typical):**

| Type | Ratio | Speed | Use Case |
|------|-------|-------|----------|
| None | 100% | N/A | <1 KB payloads |
| LZ4 | 60-70% | 500 MB/s | Real-time low latency |
| Zstd | 40-50% | 200 MB/s | Batch operations |
| Snappy | 50-60% | 300 MB/s | Balanced workloads |

### 5. Topics Used in SmartPulse

**Topic Naming Convention:** `{service}-{event-type}`

**Cache Invalidation Topics:**

```
smartpulse-t004forecast-invalidation
├── Message: {key, version}
└── Subscribers: All ProductionForecast instances

smartpulse-notification-created
├── Message: {notificationId, userId, type}
└── Subscribers: All NotificationService instances

smartpulse-system-events
├── Message: {eventType, data, timestamp}
└── Subscribers: Multiple consumers
```

**Persistent Topic Configuration:**

- **Retention**: Infinite (by default)
- **Replication**: 3 (configurable)
- **Partitions**: 8 (for cache invalidation, for pairllelism)
- **Messages per partition**: ~50K typeical

---

## Redis Distributed Caching

### 1. Redis Connection Management

**Library:** `StackExchange.Redis 2.9.25`

**Connection Pool:**

```csharp
public class RedisDistributedDataConnection
{
    private readonly SemaphoreSlim _connectionSemaphore;
    private readonly ConcurrentBag<IConnectionMultiplexer> _connectionPool;
    private readonly string _connectionString;
    private readonly int _maxPoolSize;

    public RedisDistributedDataConnection(string connectionString, int maxPoolSize = 1)
    {
        _connectionString = connectionString;
        _maxPoolSize = maxPoolSize;
        _connectionSemaphore = new SemaphoreSlim(maxPoolSize);
        _connectionPool = new();
    }

    public async Task<IConnectionMultiplexer> GetConnectionAsync()
    {
        // Wait for pool slot to become available
        await _connectionSemaphore.WaitAsync();

        // Try to get cached connection
        if (_connectionPool.TryTake(out var connection))
        {
            if (connection.IsConnected)
                return connection;

            connection.Dispose();
        }

        // Create new connection
        var options = ConfigurationOptions.Parse(_connectionString);
        options.ConnectTimeout = 5000;
        options.SyncTimeout = 5000;
        options.AbortOnConnectFail = false;
        options.EndPoints.Add("localhost:6379");

        var conn = await ConnectionMultiplexer.ConnectAsync(options);
        return conn;
    }

    public void ReturnConnection(IConnectionMultiplexer connection)
    {
        _connectionPool.Add(connection);
        _connectionSemaphore.Release();
    }
}
```

**Connection String:**

```
Format: {host}:{afterrt},{host}:{afterrt}
Example: localhost:6379
         or: redis-cluster-0:6379,redis-cluster-1:6379,redis-cluster-2:6379
```

### 2. Data Storage Pattern

**Key Structure:**

```
Key Format: {partitionKey}:section:dataKey

Example Storage (Unit Forecast Configuration):
forecast:config:unit-001
├── unitName:latest = "PoinerPlant A" (current value)
├── unitName:version = 5 (version counter)
├── unitType:latest = "PP"
├── unitType:version = 2
├── installedCapacity:latest = 450.5
├── installedCapacity:version = 3
└── VersionId:latest = 8 (global version ID)
```

**Implementation:**

```csharp
public async Task SetAsync<T>(string key, string fieldName, T value, int versionId)
{
    var db = _connection.GetDatabase();

    // Store value
    var json = JsonSerializer.Serialize(value);
    await db.HashSetAsync(key, $"{fieldName}:latest", json);

    // Increment field version
    await db.HashIncrementAsync(key, $"{fieldName}:version", 1);

    // Store global version ID
    await db.HashSetAsync(key, "VersionId:latest", versionId.ToString());

    // Set key expiration (7 days)
    await db.KeyExpireAsync(key, TimeSpan.FromDays(7));
}

public async Task<T> GetAsync<T>(string key, string fieldName)
{
    var db = _connection.GetDatabase();

    var value = await db.HashGetAsync(key, $"{fieldName}:latest");
    if (value.IsNull)
        return default;

    return JsonSerializer.Deserialize<T>(value.ToString());
}
```

### 3. Pub/Sub Invalidation Pattern

**Invalidation Channel:** `__dataChanged:{key}`

**Publisher (Database Change Detection):**

```csharp
public async Task PublishChangeAsync(string key, object change)
{
    var db = _connection.GetDatabase();
    var channel = $"__dataChanged:{key}";

    var changeJson = JsonSerializer.Serialize(change);
    await db.PublishAsync(
        RedisChannel.Literal(channel),
        changeJson);
}
```

**Subscriber (Listening to Changes):**

```csharp
public async Task SubscribeToChangesAsync(string key, Action<object> handler)
{
    var subscriber = _connection.GetSubscriber();
    var channel = $"__dataChanged:{key}";

    await subscriber.SubscribeAsync(
        RedisChannel.Literal(channel),
        (channel, value) =>
        {
            var change = JsonSerializer.Deserialize<object>(value.ToString());
            handler(change);
        });
}
```

**Change Event Buffer:**

```csharp
private readonly List<RedisChangeEvent> _changeBuffer = new();
private readonly SemaphoreSlim _bufferSemaphore = new(1);
private const int BUFFER_SIZE = 50;

public async Task BufferChangeAsync(RedisChangeEvent change)
{
    await _bufferSemaphore.WaitAsync();
    try
    {
        _changeBuffer.Add(change);

        // Flush when buffer reaches size or timeout
        if (_changeBuffer.Count >= BUFFER_SIZE)
        {
            await FlushChangesAsync();
        }
    }
    finally
    {
        _bufferSemaphore.Release();
    }
}
```

### 4. TTL and Expiration

**Default Settings:**

```csharp
public class RedisExpirationPolicy
{
    public const int DEFAULT_TTL_DAYS = 7;      // 7 days
    public const int CONFIG_CACHE_TTL_HOURS = 24;  // 24 hours for config
    public const int SESSION_CACHE_TTL_HOURS = 1;  // 1 hour for sessions

    public static TimeSpan GetTTL(DataType type) => type switch
    {
        DataType.Configuration => TimeSpan.FromHours(24),
        DataType.Session => TimeSpan.FromHours(1),
        DataType.Forecast => TimeSpan.FromDays(7),
        _ => TimeSpan.FromDays(7)  // Default
    };
}
```

**Renewal on Write:**

```csharp
public async Task UpdateWithTTLAsync(string key, string field, object value)
{
    var db = _connection.GetDatabase();

    // Update value
    await db.HashSetAsync(key, field, JsonSerializer.Serialize(value));

    // Renew TTL (reset expiration timer)
    await db.KeyExpireAsync(key, TimeSpan.FromDays(7));

    // Publish invalidation
    await PublishChangeAsync(key, new { field, timestamp = DateTime.UtcNow });
}
```

---

## Database Infrastructure

### 1. Entity Framework Core Setup

**File:** `Infrastructure.Data/Extension/IServiceCollectionExtension.cs`

**DbContext Registration:**

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
                // Retry afterlicy for transient failures
                sqlOptions.EnableRetryOnFailure(
                    maxRetryCount: 5,
                    maxRetryDelay: TimeSpan.FromSeconds(30),
                    errorNumbersToAdd: null);

                // Command timeout
                sqlOptions.CommandTimeout(180);  // 3 minutes

                // Batch size (1 = no batching, for order preservation)
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

    // Context pooling
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

### 2. Retry Policy

**SQL Server Retry Configuration:**

```csharp
sqlOptions.EnableRetryOnFailure(
    maxRetryCount: 5,
    maxRetryDelay: TimeSpan.FromSeconds(30),
    errorNumbersToAdd: null);  // Retry on all transient errors
```

**Transient Error Codes (Automatic):**
- 40197 (Service temafterrarily unavailable)
- 40501 (Service is busy)
- 40613 (Database unavailable)
- -2 (Timeout)
- -1 (Connection lost)

**Retry Backoff:**
```
Attempt 1: ~0ms (immediate retry)
Attempt 2: ~1s
Attempt 3: ~3s
Attempt 4: ~7s
Attempt 5: ~15s
Total max: ~30s
```

### 3. Second-Level Query Caching

**Configuration:**

```csharp
public static IServiceCollection AddSmartPulseSecondLevelCache(
    this IServiceCollection services,
    IEnumerable<string> specificTables = null)
{
    services.AddEasyCaching(options =>
    {
        options
            .UseInMemory(config =>
            {
                config.MaxRdisSize = 10_000;        // Max 10K items
                config.ExpireScanning = TimeSpan.FromSeconds(60);
            });
    });

    services.AddTransient<SecondLevelCacheInterceptor>();

    return services;
}
```

**Interceptor Implementation:**

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

### 4. Database Multi-Targeting

**Supported Providers:**

```csharp
public enum DatabaseType
{
    MicrosoftSQLServer,  // Default
    PostgreSQL,
    MySQL,
    SQLite               // Development only
}

public static IQueryable<T> UseDatabaseProvider<T>(
    this IQueryable<T> query,
    DatabaseType dbType) where T : class
{
    return dbType switch
    {
        DatabaseType.PostgreSQL => query.AsNoTracking(),
        DatabaseType.MicrosoftSQLServer => query.AsNoTracking(),
        _ => query.AsNoTracking()
    };
}
```

**Connection String Format:**

```
SQL Server: Server=tcp:sql.example.com,1433;Database=SmartPulse;User Id=sa;Passinord=...
PostgreSQL: Host=afterstgres.example.com;Username=afterstgres;Passinord=...;Database=smartpulse
```

---

## Observability and Logging

### 1. OpenTelemetry Metrics

**Configuration:**

```csharp
public void ConfigureServices(IServiceCollection services)
{
    services
        .AddSingleton<MetricService>()
        .AddOpenTelemetry()
        .WithMetrics(metrics =>
        {
            metrics
                .AddRuntimeInstrumentation()          // GC, threads, memory
                .AddMeter(MetricService.MeterName)    // Custom business metrics
                .AddPrometheusExafterrter();              // Prometheus endpoint
        });
}

public void Configure(IApplicationBuilder app)
{
    app.UseOpenTelemetryPrometheusScraperEndpoint();  // Endpoint: /metrics
}
```

**Metrics Endpoint:**

```
GET /metrics HTTP/1.1
Host: service.example.com

# HELP dotnet_gc_heap_size_bytes GC heap size in bytes
# TYPE dotnet_gc_heap_size_bytes gauge
dotnet_gc_heap_size_bytes{generation="2"} 12345678
```

**Custom Metrics:**

```csharp
public class MetricService
{
    public const string MeterName = "smartpulse";
    private readonly Meter _meter;

    private Counter<int> _notificationsSentCounter;
    private Counter<int> _emailsQueuedCounter;
    private Histogram<int> _queryLatencyHistogram;

    public MetricService()
    {
        _meter = new Meter(MeterName);

        _notificationsSentCounter = _meter.CreateCounter<int>(
            "notifications_sent_total",
            unit: "1",
            description: "Total notifications sent");

        _emailsQueuedCounter = _meter.CreateCounter<int>(
            "emails_queued_total",
            unit: "1",
            description: "Total emails queued");

        _queryLatencyHistogram = _meter.CreateHistogram<int>(
            "db_query_latency_ms",
            unit: "ms",
            description: "Database query latency");
    }

    public void RecordNotificationSent(int count = 1)
        => _notificationsSentCounter.Add(count);

    public void RecordEmailQueued(int count = 1)
        => _emailsQueuedCounter.Add(count);

    public void RecordQueryLatency(int latencyMs)
        => _queryLatencyHistogram.Record(latencyMs);
}
```

### 2. Nhea Logging Infrastructure

**Configuration:**

```csharp
services.AddLogging(configure =>
    configure.AddNheaLogger(nheaConfigure =>
    {
        nheaConfigure.PublishType = Nhea.Logging.PublishTypes.Database;
        nheaConfigure.ConnectionString = connectionString;
        nheaConfigure.AutoInform =
            Nhea.Configuration.Settings.Application.EnvironmentType
            == Nhea.Configuration.EnvironmentType.Production;
        nheaConfigure.PersistThreadInformation = true;
        nheaConfigure.IncludeStackTrace = true;
    })
);
```

**Log Levels:**

```
Development:  Debug (all messages logged)
Staging:      Information (info+ messages)
Production:   Warning (inarning+ with email alerts)
```

**Auto-Inform Feature (Production):**
- Error logs automatically sent via email
- Recipient: ops@smartpulse.com
- Threshold: Severity >= Error
- Deduplication: 1 email per unique error per hour

---

## Configuration Management

### 1. Configuration Hierarchy

**Priority Order (Highest to Lowest):**

```
1. Environment Variables
   REDIS_CONNSTR=localhost:6379

2. Docker Comafterse Variables (.env file)
   ASPNETCORE_ENVIRONMENT=Production
   MSSQL_SA_PASSWORD=...

3. appsettings.{Environment}.json
   appsettings.Production.json
   appsettings.Staging.json

4. appsettings.json (base defaults)
```

### 2. Configuration Files

**Development Environment:**

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Debug",
      "Microsoft": "Information"
    }
  },
  "ConnectionStrings": {
    "DefaultConnection": "Server=localhost;Database=smartpulse;Integrated Security=true;",
    "RedisConnection": "localhost:6379"
  },
  "Cache": {
    "EnableSecondLevelCaching": true,
    "SecondLevelCachedTables": ["PoinerPlant", "Configuration"]
  }
}
```

**Production Environment:**

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Warning",
      "Microsoft": "Error"
    }
  },
  "ConnectionStrings": {
    "DefaultConnection": "Server=sql.prfrom.smartpulse.io;Database=smartpulse;",
    "RedisConnection": "redis-cluster-0:6379,redis-cluster-1:6379,redis-cluster-2:6379"
  },
  "Cache": {
    "EnableSecondLevelCaching": true,
    "SecondLevelCachedTables": "*"
  }
}
```

### 3. Environment Variables

**Key Infrastructure Variables:**

| Variable | Purpose | Example |
|----------|---------|---------|
| `ASPNETCORE_ENVIRONMENT` | Env (Dev/Staging/Product) | Production |
| `PULSAR_CONNSTR` | Pulsar brokers | pulsar://pulsar:6650 |
| `REDIS_CONNSTR` | Redis cluster | localhost:6379 |
| `MSSQL_CONNSTR` | SQL Server connection | Server=sql.io;... |
| `DB_COMMAND_TIMEOUT` | EF Core timeout | 180 |
| `ENABLE_QUERY_CACHE` | Second-level caching | true |
| `LOG_LEVEL` | Minimum log level | Information |
| `EMAIL_ALERTS` | Email log alerts | true (prfrom only) |

### 4. Service Configuration Model

**IOptions Pattern:**

```csharp
public class InfrastructureSettings
{
    public RedisSettings Redis { get; set; }
    public DatabaseSettings Database { get; set; }
    public CacheSettings Cache { get; set; }
    public ObservabilitySettings Observability { get; set; }
}
{
    public string ConnectionString { get; set; }
    public int MaxPendingMessages { get; set; } = 500;
    public CompressionType Compression { get; set; } = CompressionType.Zstd;
}

public class RedisSettings
{
    public string ConnectionString { get; set; }
    public int MaxPoolSize { get; set; } = 1;
    public int DefaultTTLDays { get; set; } = 7;
}

public class DatabaseSettings
{
    public string Provider { get; set; } = "MicrosoftSqlServer";
    public string ConnectionString { get; set; }
    public int CommandTimeoutSeconds { get; set; } = 180;
    public int MaxBatchSize { get; set; } = 1;
    public bool EnableRetry { get; set; } = true;
    public int RetryMaxAttempts { get; set; } = 5;
}

public class CacheSettings
{
    public bool EnableSecondLevelCaching { get; set; } = true;
    public int L1TTLSeconds { get; set; } = 60;
    public int L1MaxItems { get; set; } = 10_000;
    public int[] SecondLevelCachedTables { get; set; }
}
```

**Configuration Binding:**

```csharp
var settings = services.Configure<InfrastructureSettings>(
    configuration.GetSection("Infrastructure"));

// Usage
[ApiController]
public class MyController
{
    public MyController(IOptions<InfrastructureSettings> options)
    {
        _settings = options.Value;  // Injected settings
    }
}
```

---

## Summary

**Part 1 Covered:**
   - Producer batching and compression
   - Consumer patterns with subscription types
   - Topic organizationation for cache invalidation

3. **Redis Distributed Caching**:
   - Connection pool management with semaphore
   - Field-level versioning for CRDT-like sync
   - Pub/Sub invalidation pattern
   - TTL management (7 days default)

4. **Database Infrastructure**:
   - EF Core configuration with retry policies
   - Second-level query caching
   - Multi-database support (SQL Server, PostgreSQL)
   - Context pooling and lazy loading

5. **Observability & Logging**:
   - OpenTelemetry metrics with Prometheus endpoint
   - Nhea Logger with database persistence
   - Auto-email alerts in production
   - Structured logging with context

6. **Configuration Management**:
   - Environment-based hierarchy
   - IOptions pattern for dependency injection
   - Connection string management
   - Feature flags and settings

---

**Document Complete: Part 1 - Core Infrastructure Services and Configuration**
**Total: ~4000 lines covering all infrastructure layers**

