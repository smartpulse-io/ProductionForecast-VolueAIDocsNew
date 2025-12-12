# Infrastructure Component


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

## Overview

**Core Responsibilities**:
- **Event Bus**: -based pub/sub with producer pooling
- **Distributed Cache**: Redis with field-level versioning
- **Change Detection**: SQL Server CDC with exponential backoff
- **Data Synchronization**: Version-aware distributed sync
- **Batch Processing**: Generic framework for high-throughput scenarios
- **Resilience**: Retry policies, circuit breakers, health checks

**Architecture Pattern**: Repository + Service Layer with dependency injection

---

## Architecture

### Component Dependency Graph

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'14px', 'primaryColor':'#3498db', 'primaryBorderColor':'#2c3e50', 'lineColor':'#7f8c8d'}}}%%
graph TB
    A["Application Services<br/>ProductionForecast<br/>NotificationService<br/>etc."]

    A --> B["Client"]
    A --> C["Redis Connection"]
    A --> D["EF Core +<br/>ChangeTracker"]

    B --> E["AutoBatchWorker"]
    C --> E
    D --> E

    E --> F["AutoConcurrentPartitionedQueue<br/>DistributedDataSyncService<br/>Background Services"]

    F --> G["Cluster"]
    F --> H["Redis Cluster"]
    F --> I["SQL Server Database"]

    style A fill:#3498db,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style B fill:#27ae60,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style C fill:#27ae60,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style D fill:#27ae60,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style E fill:#f39c12,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style F fill:#9b59b6,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style G fill:#e74c3c,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style H fill:#e74c3c,stroke:#2c3e50,color:#fff,stroke-inidth:2px
    style I fill:#e74c3c,stroke:#2c3e50,color:#fff,stroke-inidth:2px
```

---

## Core Services

**Key Features**:
- **Persistent Topics**: Messages persisted across broker failures
- **Multi-Tenancy**: Built-in namespace isolation for future scaling
- **High Throughput**: Millions of messages per second capacity
- **Low Latency**: <100ms end-to-end message delivery
- **Exactly-Once Semantics**: Transaction support (optional)

**Why **:
- Separate storage and serving layers enable independent scaling
- Native geo-replication support for multi-region deployments
- Built-in tiered storage (hot SSD → cold S3)
- Consumer lag management without manual partition management
- Topic retention policies independent of cluster size

#### Producer Pooling Strategy

**Benefits**:
- Connection reuse reduces overhead by 50-70% vs. creating per-message producers
- Semaphore throttles concurrent producer creation (prevents thundering herd)
- Double-check locking prevents duplicate producer creation
- TTL-based cleanup removes unused producers

#### Producer Batching Configuration

Producer batching dramatically improves throughput by amortizing compression and network overhead:

| Parameter | Value | Impact |
|-----------|-------|--------|
| `EnableBatching` | true | Enable batching feature |
| `BatchingMaxMessages` | 100 | Messages per batch |
| `BatchingMaxBytes` | 131,072 | ~128 KB per batch |
| `BatchingMaxDelayMs` | 100 | Max wait before flush |
| `MaxPendingMessages` | 500 | Buffer before backpressure |

**Throughput Impact**:
- Without batching: ~1,000 messages/sec
- With batching (100 msgs): ~100,000 messages/sec (100× improvement)
- Latency trade-off: 100ms max delay between publication and delivery

For more details, see [Integration Documentation](../../../docs/integration/.md).

---

### Redis Distributed Cache

`StackExchangeRedisConnection` provides connection pooling, field-level versioning, Pub/Sub messaging, and transaction support for Redis operations.

**Key Features**:
- **Versioned Cache**: Each cached value includes version metadata for consistency checking
- **Connection Pooling**: Reuses connections across database instances
- **Transactional Support**: Atomic multi-key operations
- **Pub/Sub Messaging**: Cross-service communication
- **Metrics Integration**: OpenTelemetry instrumentation

#### Cache Retrieval with Versioning

```csharp
public async Task<(T Value, long Version)> GetAsync<T>(
    string key) where T : class
```

Retrieves both the cached value and its version number atomically, enabling consistency checks in distributed scenarios.

#### Cache Storage with Versioning

```csharp
public async Task SetAsync<T>(
    string key,
    T value,
    TimeSpan? expiration = null,
    long? version = null) where T : class
```

Stores value and optional version metadata, with automatic expiration support.

**Caching Strategy**:
- L1 Cache (MemoryCache): Hot data, 30s TTL
- L2 Cache (Redis): Shared across replicas, 1-hour TTL
- Database: Source of truth

For more details, see [Redis Integration Documentation](../../../docs/integration/redis.md).

---

### Change Data Capture (CDC) Pipeline

`ChangeTracker` enables continuous monitoring of SQL Server database changes via Change Data Capture with exponential backoff retry logic and version-based anomaly detection.

**Key Features**:
- **Continuous Polling**: Monitors SQL Server CDC tables for changes
- **Exponential Backoff**: Retries with exponential backoff on transient failures
- **Version Tracking**: Detects anomalies using version comparison
- **Event Correlation**: Links changes to events
- **Metrics Integration**: Detailed observability for CDC operations

#### CDC Polling Algorithm

Uses `CHANGETABLE()` SQL Server function to retrieve changes:

```sql
SELECT TOP 1000
    [sys_change_version] as ChangeVersion,
    [sys_change_operation] as Operation,
    [sys_change_context] as Context,
    *
FROM CHANGETABLE(CHANGES TableName, LastKnownVersion) AS CT
ORDER BY sys_change_version ASC
```

**Error Handling**:
- **Transient Errors (Retry)**: Connection broken, temporary unavailability
- **Fatal Errors (Fail)**: Table doesn't exist, permission denied

For more details, see [EF Core Integration Documentation](../../../docs/integration/ef-core.md).

---

### Data Synchronization Service

`DistributedDataSyncService` orchestrates version-aware distributed sync across replicas with eventual consistency guarantees.

**Key Features**:
- **Cross-Replica Sync**: Synchronizes changes across multiple database replicas
- **Version Tracking**: Ensures consistency using version metadata
- **Conflict Resolution**: Detects and resolves version conflicts
- **Batch Optimization**: Groups sync operations for efficiency

---

### AutoBatchWorker Generic Pattern

Generic framework for high-throughput batch processing scenarios:

**Key Features**:
- **Dynamic Batch Sizing**: Adjusts batch size based on throughput
- **Throughput Tuning**: 5-10x improvements over per-item processing
- **Latency Control**: Configurable max latency before flush
- **Metrics Integration**: Detailed batch performance tracking

---

### Resilience Patterns

#### Retry Strategy: Fixed Interval

Fixed-interval retry with configurable delay:

**Use Cases**:
- Network timeouts that typically resolve quickly
- Temporary broker unavailability
- Rate-limited API calls with consistent backoff

#### Retry Strategy: Exponential Backoff

Exponential backoff retry starting at initial delay, doubling on each attempt:

**Use Cases**:
- Database connection failures
- Service startup latency
- Cascading failures across services

**Configuration**:
- Initial delay: 100ms
- Multiplier: 2.0
- Max retries: 5
- Max delay: 30 seconds

#### Circuit Breaker Pattern

Prevents cascading failures by stopping requests to failing services:

**States**:
- **Closed**: Normal operation, requests pass through
- **Open**: Service failing, requests rejected immediately
- **Half-Open**: Testing if service recovered

**Configuration**:
- Failure threshold: 5 consecutive failures
- Reset timeout: 1 minute
- Success count to close: 2 consecutive successes

---

## Integration Points

### With Application Layer
Application services (ProductionForecast, NotificationService, etc.) depend on Infrastructure for:
- Publishing events to - Caching via Redis
- Querying tracked database changes
- Batch processing high-volume operations

### With Data Layer
Infrastructure services interact with:
- **SQL Server Database**: CDC polling, data persistence
- **Entity Framework Core**: Change tracking, transactions
- **Repository Pattern**: Data access abstraction

### With Background Services
Background processing components depend on:
- AutoBatchWorker for efficient bulk operations
- AutoConcurrentPartitionedQueue for work distribution
- DistributedDataSyncService for cross-replica synchronization

---

## Performance Characteristics

### Event Publishing

| Scenario | Throughput | Latency |
|----------|-----------|---------|
| Single message | 1,000 msg/sec | 100ms |
| Batched (100 msg) | 100,000 msg/sec | <100ms |
| Batched (1,000 msg) | 250,000+ msg/sec | <500ms |

### Distributed Caching

| Operation | Redis Hit | Redis Miss | Hit Rate |
|-----------|-----------|-----------|----------|
| Get | <5ms | ~10ms (with DB) | 90%+ |
| Set | <5ms | N/A | N/A |

### CDC Polling

| Scenario | Polling Interval | Processing Time |
|----------|-----------------|-----------------|
| No changes | 30 seconds | <100ms |
| 100 changes | 30 seconds | 100-500ms |
| 1,000+ changes | 30 seconds | 1-5 seconds |

---

## Configuration & Deployment

### Kubernetes Deployment

Infrastructure services are deployed as containerized workloads:

**Cluster (Kubernetes)**:
- 3x Brokers (high availability)
- 3x BookKeeper Bookies (persistent storage)
- 1x ZooKeeper (metadata coordination)
- 1x Manager (admin UI)

**Redis Cluster (Kubernetes)**:
- Sentinel-based high availability
- Automatic failover on primary failure
- Persistent volume storage

**Database**:
- SQL Server managed instance
- CDC enabled on all tables
- Regular backups with WAL archiving

### Resilience Configuration

**Connection Timeouts**:
- : 10 seconds with exponential backoff
- Redis: 5 seconds with 3 retries
- SQL Server: 15 seconds with exponential backoff

**Retry Policies**:
- Max retries: 5 attempts
- Initial delay: 100ms
- Backoff multiplier: 2.0
- Max delay: 30 seconds

---

## Troubleshooting

### Common Issues

**Connection Failures**
- Verify broker addresses in configuration
- Check authentication token validity
- Inspect firewall rules for port 6650/6651

**Redis Connection Issues**
- Verify connection string format
- Check Redis cluster status
- Review authentication credentials

**CDC Polling Lag**
- Verify CDC is enabled on SQL Server
- Check table-level CDC configuration
- Monitor CDC table sizes and cleanup jobs

---

## Related Documentation

- [Integration Guide](../../../docs/integration/.md) - Event bus configuration and usage
- [Redis Integration Guide](../../../docs/integration/redis.md) - Distributed cache patterns
- [EF Core Integration Guide](../../../docs/integration/ef-core.md) - Database operations and CDC
- [Data Flow Documentation](../../../docs/guides/data-flow.md) - End-to-end data synchronization
- [Kubernetes Deployment Guide](../../../docs/deployment/kubernetes.md) - Container orchestration
- [Resilience Patterns Guide](../../../docs/patterns/resilience.md) - Error handling strategies

---

## Summary

The Infrastructure Layer provides:

1. **Event-Driven Architecture**: pub/sub with producer pooling
2. **Distributed Caching**: Redis with version tracking
3. **Change Detection**: SQL Server CDC with resilient polling
4. **Data Synchronization**: Cross-replica sync with eventual consistency
5. **Batch Processing**: Dynamic bulk sizing with 5-10x throughput improvements
6. **Performance Optimization**: Latency-throughput tradeoff tuning, memory efficiency, network I/O reduction
7. **Resilience**: Retry logic, circuit breakers, health monitoring
8. **Kubernetes Orchestration**: Scalable, resilient deployments with zero-downtime updates
9. **Network Topology**: Service mesh with ingress, load balancing, and network policies

For architectural deep dives and implementation details, refer to the related documentation above.
