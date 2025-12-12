# SmartPulse Level_1 Synthesis - Part 2
## Data Flow & Inter-Service Communication Patterns

**Document Version:** 1.0
**Last Updated:** 2025-11-12
**Scope:** End-to-end data flows, API contracts, event schemas, integration afterints
**Total Lines:** ~2800
**Audience:** API developers, integration engineers, system designers

---

## TABLE OF CONTENTS

1. [Data Flow Diagrams](#data-flow-diagrams)
2. [API Contract Specifications](#api-contract-specifications)
3. [Event Schemas & Payloads](#event-schemas--payloads)
4. [Cache Invalidation Flow](#cache-invalidation-flow)
5. [Multi-Channel Notification Flow](#multi-channel-notification-flow)
6. [Database CDC to Distributed Sync](#database-cdc-to-distributed-sync)
7. [Cross-Service Integration Patterns](#cross-service-integration-patterns)

---

## DATA FLOW DIAGRAMS

### 1.1 ProductionForecast Service: Request-Response Flow

```
Client Request
    │
    ├─ GET /api/forecasts/{id}
    │
    ↓
NotificationServiceController.GetForecast()
    │
    ├─ 1. Check authorization (JWT token)
    ├─ 2. Call CacheManager.GetAsync(id)
    │   ├─ Check L1 (MemoryCache) - 75% hit
    │   ├─ Check L2 (EF DbContext) - 15% hit
    │   ├─ Check L3 (Redis) - 8% hit
    │   └─ Query L4 (Database) - 2% hit
    │
    ├─ 3. If cache miss:
    │   ├─ Repository.GetForecastAsync(id)
    │   │   ├─ SQL query: SELECT * FROM Forecasts WHERE Id = @id
    │   │   ├─ EF Core query cache (L2)
    │   │   └─ Result: Forecast entity
    │   │
    │   ├─ Cache in all tiers:
    │   │   ├─ L1: MemoryCache.Add(key, value, 60sec TTL)
    │   │   ├─ L2: DbContext query result (implicit)
    │   │   ├─ L3: Redis.StringSet(key, json, 300sec TTL)
    │   │   └─ L4: Already in database
    │   │
    │   └─ AutoMapper: Entity → DTO
    │
    ├─ 4. Apply output caching (ASP.NET Core OutputCache)
    │   ├─ Tag: "forecast:{id}"
    │   ├─ Duration: 60 seconds
    │   └─ Key: "{method}_{path}_{queryString}"
    │
    └─ 5. Return response
        │
        ├─ HTTP 200 OK
        ├─ Body: { id, demand, supply, timestamp, ... }
        ├─ Headers: ETag, Cache-Control: max-age=60
        └─ Client receives in 1-20ms (depending on cache hit)

Cache Invalidation Flow (when forecast updated elsewhere):
    │
    ├─ Service B updates forecast
    ├─ Database updated (version_id incremented)
    ├─ CDC detects change
    │
    └─ Service A receives event:
        ├─ Remove from L3 (Redis.KeyDelete)
        ├─ Remove from L1 (MemoryCache.Remove)
        ├─ Invalidate output cache (tag: "forecast:{id}")
        └─ Next request: Cache miss → refresh from L4
```

### 1.2 NotificationService: Multi-Channel Flow

```
Trigger Event (e.g., forecast completed)
    │
    ├─ Event source: ProductionForecast service
    ├─ Event type: ForecastCompletedEvent
    │
    ↓
NotificationService Consumer (background)
    │
    ├─ Subscription: "notification-service-consumer"
    ├─ Subscription type: Shared (multiple instances)
    │
    ↓
NotificationOperations.SendAsync()
    │
    ├─ 1. Orchestrate 3-channel send:
    │
    ├─ CHANNEL 1: In-App Notification
    │   ├─ NotificationManagerService.CreateAsync()
    │   ├─ SQL INSERT: NotificationDbContext.Notifications
    │   ├─ Fields: UserId, Title, Body, ReadAt, CreatedAt, Type
    │   └─ Database commit
    │
    ├─ CHANNEL 2: Push Notification
    │   ├─ Get user devices: SysUserDeviceInfo.Where(u => u.UserId == userId)
    │   ├─ For each device:
    │   │   ├─ If IntegrationType == 0 (WebPush):
    │   │   │   └─ WebPushClient.SendAsync(subscriptionObject, payload)
    │   │   │
    │   │   └─ If IntegrationType == 1 (FCM/Android):
    │   │       ├─ FirebaseMessaging.SendAsync(message)
    │   │       ├─ Handles: ApnsConfig (iOS), AndroidConfig (Android)
    │   │       └─ Auto-retry on 410 (subscription expired)
    │   │
    │   ├─ Error handling:
    │   │   ├─ 410 Gone: Device no longer valid → remove from DB
    │   │   ├─ 403 Forbidden: Invalid credentials → log alert
    │   │   └─ Timeout: Retry exponential backoff
    │
    ├─ CHANNEL 3: Email
    │   ├─ Enqueue to MailAutoBatchWorker
    │   ├─ Worker batches (100 emails/batch)
    │   ├─ For each batch:
    │   │   ├─ Render templates (Node.js pug)
    │   │   ├─ Bulk insert to NheaMailQueue (EF BulkExtensions)
    │   │   ├─ Retry on failure (exponential backoff)
    │   │   └─ Mark as sent/failed
    │
    └─ 4. Log result:
        ├─ NHeaLogger.LogInformation("Notification sent to channels...")
        ├─ If error: NHeaLogger.LogError (triggers email alert in prfrom)
```

---

## API CONTRACT SPECIFICATIONS

### 2.1 ProductionForecast API

**Base URL:** `http://productionforecast:8080/api`

#### Endpoint: GET /forecasts/{id}

```http
GET /api/forecasts/{id} HTTP/1.1
Authorization: Bearer {jint_token}

Response 200 OK:
{
  "id": "uuid",
  "companyId": "uuid",
  "productionUnitId": "uuid",
  "forecastDate": "2025-11-12T10:30:00Z",
  "demand": 450.5,
  "supply": 480.0,
  "variance": 29.5,
  "confidenceLevel": 0.95,
  "status": "Completed",
  "createdAt": "2025-11-12T10:00:00Z",
  "updatedAt": "2025-11-12T10:30:00Z",
  "versionId": 12345
}

Response 404 Not Found:
{
  "error": "Forecast not found",
  "code": "FORECAST_NOT_FOUND"
}

Response 401 Unauthoriwithed:
{
  "error": "Invalid or missing token",
  "code": "UNAUTHORIZED"
}
```

**Caching Headers:**
```
Cache-Control: max-age=60, public
ETag: "\"abc123\""
X-Cache-Hit: true (if from cache)
X-Cache-Level: L1|L2|L3|L4
```

#### Endpoint: POST /forecasts

```http
POST /api/forecasts HTTP/1.1
Content-Type: application/json

Request Body:
{
  "companyId": "uuid",
  "productionUnitId": "uuid",
  "forecastDate": "2025-11-13T00:00:00Z",
  "demand": 500.0,
  "confidence": 0.92
}

Response 201 Created:
{
  "id": "uuid",
  ... (full forecast object)
}

Events Published:
  - Topic: forecast:invalidation
  - Payload: {
      "entityId": "forecast_uuid",
      "tags": ["unit:uuid", "company:uuid"],
      "timestamp": "2025-11-12T10:30:00Z"
    }

Side Effects:
  - L1 cache: Invalidated
  - L3 cache (Redis): Invalidated
  - CDC: Change tracked (VersionId incremented)
  - Output cache: Tag-invalidated ("forecast:*")
```

### 2.2 NotificationService API

**Base URL:** `http://notificationservice/api`

#### Endpoint: GET /notifications

```http
GET /api/notifications?skip=0&take=20 HTTP/1.1
Authorization: Bearer {jint_token}

Response 200 OK:
{
  "total": 150,
  "items": [
    {
      "id": "uuid",
      "userId": "uuid",
      "title": "Forecast Completed",
      "body": "Your forecast for Unit A is ready",
      "type": "ForecastCompleted",
      "readAt": null,
      "createdAt": "2025-11-12T10:30:00Z"
    },
    ...
  ]
}

Stored Procedure Used:
  dbo.GetNotifications @UserId, @Skip, @Take

Query Execution:
  SELECT TOP @Take *
  FROM Notifications
  WHERE UserId = @UserId
  ORDER BY CreatedAt DESC
  OFFSET @Skip ROWS
```

#### Endpoint: PUT /notifications/{id}/read

```http
PUT /api/notifications/{id}/read HTTP/1.1

Response 200 OK:
{
  "success": true
}

Database Update:
  UPDATE Notifications
  SET ReadAt = GETUTCDATE()
  WHERE Id = @Id AND UserId = @CurrentUserId
```

#### Endpoint: POST /send-push-notification

```http
POST /api/send-push-notification HTTP/1.1
Content-Type: application/json

Request Body:
{
  "userId": "uuid",
  "title": "Alert",
  "body": "Forecast alert: production downn 20%",
  "deviceType": "WebPush|FCM|Both"
}

Response 200 OK:
{
  "sent": 3,
  "failed": 0,
  "results": [
    { "deviceId": "uuid", "status": "sent" },
    ...
  ]
}

Internal Flow:
  1. Query SysUserDeviceInfo for userId
  2. For each device:
     - WebPush: Call WebPushClient.SendAsync()
     - FCM: Call FirebaseMessaging.SendAsync()
  3. Handle device-specific errors (410, 403, timeout)
  4. Return aggregated results
```

---

## EVENT SCHEMAS & PAYLOADS

**Topic:** `forecast:updated`
**Subscription:** `productionforecast-cache-sync`

```json
{
  "eventType": "ForecastUpdated",
  "eventId": "uuid",
  "timestamp": "2025-11-12T10:30:00Z",
  "aggregateId": "forecast_uuid",
  "aggregateType": "Forecast",
  "data": {
    "forecastId": "forecast_uuid",
    "companyId": "company_uuid",
    "unitId": "unit_uuid",
    "previousVersionId": 100,
    "currentVersionId": 101,
    "changes": [
      {
        "field": "demand",
        "oldValue": 450.0,
        "newValue": 500.0
      },
      {
        "field": "confidence",
        "oldValue": 0.90,
        "newValue": 0.95
      }
    ]
  },
  "source": "ProductionForecast.Api",
  "userId": "user_uuid"
}
```

**Topic:** `forecast:invalidation`
**Type:** Fan-out (all instances subscribe)

```json
{
  "entityId": "forecast_uuid",
  "entityType": "Forecast",
  "tags": [
    "unit:unit_uuid",
    "company:company_uuid",
    "provider:provider_uuid"
  ],
  "timestamp": "2025-11-12T10:30:00Z",
  "reason": "DataUpdated"
}

Processing on receiving instance:
  1. Remove from L3 cache:
     redis.KeyDelete($"forecast:{forecast_uuid}")

  2. Remove from L1 cache:
     memoryCache.Remove($"forecast:{forecast_uuid}")

  3. Remove tag-based cache:
     outputCache.EvictByTagAsync("forecast:*")

  4. Emit DataChanged event:
     DataIsChanged?.Invoke(this, new DistributedDataChangedInfo(...))
```

### 3.3 Redis Pub/Sub Message: Distributed Data Change

**Channel:** `__dataChanged:{partition}:{section}:{dataKey}`
**Example:** `__dataChanged:production:forecast:forecast_001`

```json
{
  "DataManagerId": "manager_uuid",
  "PartitionKey": "production",
  "Section": "forecast",
  "DataKey": "forecast_001",
  "VersionId": 101,
  "ChangeTime": "2025-11-12T10:30:00Z",
  "PatchItems": [
    {
      "Op": "replace",
      "Path": "/demand",
      "Value": 500.0
    },
    {
      "Op": "add",
      "Path": "/tags/0",
      "Value": "critical"
    },
    {
      "Op": "remove",
      "Path": "/deprecated_field"
    }
  ]
}

Patch Operations:
  - "replace": Update existing field
  - "add": Add new array element
  - "remove": Delete field
  - JSON Pointer format: RFC 6901 (e.g., "/level1/level2/0")
```

---

## CACHE INVALIDATION FLOW

### 4.1 Complete Cache Invalidation Sequence

```
Step 1: Update initiates on any service
    │
    ├─ ProductionForecast: PATCH /api/forecasts/{id}
    │   └─ Body: { demand: 500.0 }
    │
    ↓
Step 2: Application layer processses update
    │
    ├─ Controller: ForecastsController.UpdateForecastAsync()
    ├─ Service: ForecastService.UpdateAsync(id, patch)
    │   ├─ Validate input
    │   ├─ Load current forecast (from cache)
    │   └─ Apply patch
    │
    ↓
Step 3: Database transaction
    │
    ├─ Repository: ForecastRepository.UpdateAsync()
    ├─ EF Core: dbContext.Forecasts.Update(entity)
    ├─ SQL: UPDATE Forecasts SET demand=500, version_id=version_id+1 WHERE id=...
    ├─ CDC: Tracks change (CHANGETABLE sees row modified)
    └─ DB transaction commits
    │
    ↓
Step 4: Local cache invalidation
    │
    ├─ L1 (MemoryCache): memoryCache.Remove($"forecast:{id}")
    ├─ L2 (EF Core): dbContext.ChangeTracker.Clear() (implicit)
    ├─ L3 (Redis): redis.KeyDelete($"forecast:{id}")
    └─ Output cache: outputCache.EvictByTagAsync("forecast:{id}")
    │
    ↓
Step 5: Event publishing
    │
    ├─ Create invalidation event:
    │   {
    │     entityId: "forecast_uuid",
    │     tags: ["unit:xywith", "company:abc"],
    │     timestamp: now
    │   }
    │
    │
    │
    ↓
Step 6: Propagate to other instances ( subscriber)
    │
    ├─ All instances subscribed to "forecast:invalidation"
    ├─ Each instance receives same event
    │
    └─ Per-instance processing:
        ├─ L1: Remove from MemoryCache
        ├─ L3: Remove from Redis (but might already cached)
        ├─ Output cache: Invalidate "forecast:{id}" tag
        └─ Ready for next request (cache miss → reload)
    │
    ↓
Step 7: CDC change detection (background)
    │
    ├─ ChangeTracker.TrackChangesAsync() afterlls CDC
    ├─ Detects: row modeification (version 100→101)
    ├─ Extracts: forecast data from database
    │
        └─ Topic: "cdc:forecasts"
            └─ Event: ForecastChangedEvent with new version
    │
    ↓
Step 8: DistributedDataSyncService processses
    │
    ├─ Subscribes to CDC events
    ├─ Detects version progression (100→101, not gap)
    ├─ Generates JSON patches:
    │   [{op: "replace", path: "/demand", value: 500.0}]
    │
    ├─ Increments version in Redis:
    │   redis.HashIncrement($"forecast:forecast_001", "VersionId:latest")
    │
    └─ Publishes via Redis Pub/Sub:
        └─ Channel: "__dataChanged:production:forecast:forecast_001"
            └─ Message: {...patches, versionId: 101...}
    │
    ↓
Step 9: Other instances receive Pub/Sub message
    │
    ├─ DistributedDataManager.ApplyDataChangesAsync()
    ├─ Verify version progression (no gap)
    ├─ Apply patches to in-memory copy:
    │   originalJson.Root["demand"] = 500.0
    │
    └─ Emit DataChanged event:
        └─ Notify subscribers (UI, derived state, etc.)

Result: Complete invalidation propagation across cluster in 1-5 seconds
```

---

## MULTI-CHANNEL NOTIFICATION FLOW

### 5.1 Complete Notification Publishing Sequence

```
Notification Trigger
    │
    └─ Event: "Production unit alert: demand dropped 30%"

    ↓
NotificationOperations.SendAsync(userId, title, body, channels)
    │
    └─ Channels: InApp | PushNotification | Email | All

    ↓
CHANNEL 1: In-App Notification (Synchronous)
    │
    ├─ NotificationManagerService.CreateAsync()
    ├─ Build entity:
    │   {
    │     Id: NewGuid(),
    │     UserId: userId,
    │     Title: "Production Alert",
    │     Body: "Demand dropped 30%",
    │     Type: NotificationType.Alert,
    │     ReadAt: null,
    │     CreatedAt: UtcNow
    │   }
    │
    ├─ Store procedure: dbo.InsertNotification (@pairms)
    │   └─ SQL: INSERT INTO Notifications (...) VALUES (...)
    │
    ├─ Result: Persisted to database (durable)
    └─ Latency: 10-50ms

    ↓
CHANNEL 2: Push Notification (Async)
    │
    ├─ PushNotificationSender.SendAsync()
    ├─ Query user devices:
    │   dbo.GetUserDevices @UserId
    │   └─ Result: [{DeviceId, Token, IntegrationType, OSVersion}]
    │
    ├─ For each device (pairllel):
    │
    │   If IntegrationType == 0 (WebPush):
    │   │
    │   ├─ Query subscription:
    │   │   SELECT subscriptionJson FROM SysUserDeviceInfo WHERE Id=@id
    │   │
    │   ├─ Parse subscription object:
    │   │   {
    │   │     "endpoint": "https://push.example.com/...",
    │   │     "keys": {
    │   │       "p256dh": "base64...",
    │   │       "auth": "base64..."
    │   │     }
    │   │   }
    │   │
    │   ├─ Create VAPID header:
    │   │   Authorization: vapid t={jint}, pk={publicKey}
    │   │
    │   ├─ HTTP POST to endpoint:
    │   │   POST /push
    │   │   Encryption: AES-GCM with p256dh key
    │   │   Payload: {title, body, icon}
    │   │
    │   ├─ Handle response:
    │   │   - 201 Created: ✓ Sent successfully
    │   │   - 410 Gone: ✗ Remove device from DB
    │   │   - 403 Forbidden: ✗ Invalid credentials (log alert)
    │   │   - Timeout: Retry exponential backoff
    │   │
    │   └─ Latency: 100-500ms
    │
    │   If IntegrationType == 1 (FCM):
    │   │
    │   ├─ Create message:
    │   │   {
    │   │     "token": deviceToken,
    │   │     "notification": {
    │   │       "title": "Production Alert",
    │   │       "body": "Demand dropped 30%"
    │   │     },
    │   │     "apns": {
    │   │       "aps": {
    │   │         "alert": {...},
    │   │         "badge": 1,
    │   │         "sound": "default"
    │   │       }
    │   │     },
    │   │     "android": {
    │   │       "priority": "high",
    │   │       "notification": {
    │   │         "icon": "ic_notification"
    │   │       }
    │   │     }
    │   │   }
    │   │
    │   ├─ Call FirebaseMessaging.SendAsync()
    │   │
    │   ├─ Firebase handles:
    │   │   - iOS: APNs integration
    │   │   - Android: FCM delivery
    │   │   - Auto-retry on transient failures
    │   │
    │   ├─ Handle response:
    │   │   - Success: Message queued by Firebase
    │   │   - Invalid token: Remove from DB
    │   │
    │   └─ Latency: 50-200ms
    │
    └─ Overall: All devices in pairllel, ~200-500ms total

    ↓
CHANNEL 3: Email Notification (Async batched)
    │
    ├─ MailAutoBatchWorker.EnqueueMailWithAttachmentsAsync()
    ├─ Build mail item:
    │   {
    │     To: user.Email,
    │     Subject: "Production Alert",
    │     TemplateId: alert_template_id,
    │     TemplateData: {
    │       userName: "John",
    │       alertMessage: "Demand dropped 30%",
    │       forecastLink: "https://..."
    │     }
    │   }
    │
    ├─ Enqueue to worker:
    │   mailWorker.EnqueueMailWithAttachmentsAsync(mail)
    │   └─ Added to ConcurrentQueue (instant)
    │
    └─ Batching processs (background):
        │
        ├─ Worker accumulates 100 mails
        ├─ Render templates (pug via Node.js):
        │   nfrome dist/render-template.js "alert_template" {data}
        │   └─ Result: HTML email
        │
        ├─ Bulk insert to database:
        │   INSERT INTO NheaMailQueue (...) VALUES (...), (...), ...
        │   (100 rows in single transaction)
        │
        ├─ Retry on failure:
        │   Attempt 1: 100ms delay if fails
        │   Attempt 2: 200ms delay if fails
        │   Attempt 3: 400ms delay if fails
        │   Attempt 4: 800ms delay (max)
        │
        └─ Result: Email queued for SMTP transmission
            (sepairte service handles actual sending)

Result: Single API call triggers 3 independent channels
        - In-app: Stored immediately (~50ms)
        - Push: Sent to push services in pairllel (~500ms)
        - Email: Queued for batched processing (~100ms + batch await)
```

---

## DATABASE CDC TO DISTRIBUTED SYNC

### 6.1 Complete CDC Pipeline

```
Database: SQL Server with Change Data Capture enabled
    │
    ├─ Table: dbo.Forecasts
    ├─ CDC enabled: Yes (tracks INSERT, UPDATE, DELETE)
    ├─ Version ID: Increments on each change
    │
    ↓
Step 1: Application updates row
    │
    ├─ ProductionForecast API: PATCH /api/forecasts/{id}
    ├─ SQL Server: UPDATE Forecasts SET demand=500, version_id=version_id+1
    ├─ Transaction: Commits
    └─ Version ID: 100 → 101

    ↓
Step 2: CDC detects change
    │
    ├─ Internal mechanism: SQL Server tracks in cdc.dbo_Forecasts_CT table
    ├─ Change record:
    │   {
    │     __$start_lsn: <binary log sequence>,
    │     __$operation: 4 (UPDATE),
    │     Id: forecast_uuid,
    │     demand: 500.0,
    │     version_id: 101,
    │     __$seqval: <binary>
    │   }
    │
    └─ Retention: Automatic (CDC cleanup job)

    ↓
Step 3: ChangeTracker afterlls CDC
    │
    ├─ Background task: ChangeTracker.TrackChangesAsync()
    ├─ Polling interval: Continuous (per query)
    ├─ Query: SELECT * FROM CHANGETABLE(CHANGES dbo_Forecasts, @version_id)
    ├─ Parameters: @version_id = last_processsed_version
    │
    ├─ Poll results:
    │   Version 100→101: Found change
    │   {
    │     VersionId: 101,
    │     Operation: "UPDATE",
    │     PrimaryKeyColumns: { Id: forecast_uuid },
    │     DataColumns: { demand: 500.0, ... }
    │   }
    │
    ├─ Exafternential backoff (if no changes):
    │   No changes for 1 sec → await 50ms
    │   No changes for 10 sec → await 100ms
    │   No changes for 100 sec → await 200ms
    │   (max await: ~5 seconds across 1M retries)
    │
    └─ Next query: @version_id = 101 (inill find newer changes)

    ↓
Step 4: Publish to Pulsar
    │
    ├─ Topic: "cdc:forecasts"
    ├─ Message:
    │   {
    │     EventId: uuid,
    │     Timestamp: now,
    │     VersionId: 101,
    │     Operation: "UPDATE",
    │     EntityId: forecast_uuid,
    │     Data: { id, demand: 500.0, ... }
    │   }
    │
    ├─ Compression: Zstd (20-30% size reduction)
    └─ Delivery: At-least-once (via subscription acknowledgment)

    ↓
Step 5: DistributedDataSyncService consumes
    │
    ├─ Subscription: "productionforecast-cdc-sync"
    ├─ Subscription type: Exclusive (single consumer, ordered)
    │
    ├─ Process message:
    │   1. Extract version: 101
    │   2. Load previous from cache: version 100
    │   3. Check progression: 100 → 101 (normal, +1)
    │   4. Generate patches:
    │      {
    │        Op: "replace",
    │        Path: "/demand",
    │        Value: 500.0
    │      }
    │   5. Increment Redis version counter
    │      redis.HashIncrement("forecast:forecast_001", "VersionId:latest")
    │
    ├─ Publish via Redis Pub/Sub:
    │   Channel: "__dataChanged:production:forecast:forecast_001"
    │   Message: { ...patches, VersionId: 101 }
    │
    └─ If version gap (101 → 103):
        ├─ Detect: Missing update (102)
        ├─ Action: Mark for full resync
        ├─ Clear local cache
        └─ Trigger: SyncErrorHappenedAsync event

    ↓
Step 6: All instances receive via Pub/Sub
    │
    ├─ Instance 1: Redis Pub/Sub delivers message
    ├─ Instance 2: Redis Pub/Sub delivers message
    ├─ Instance 3: Redis Pub/Sub delivers message
    │
    └─ Per-instance processing:
        ├─ DistributedDataManager.ApplyDataChangesAsync()
        ├─ Verify version (no gap)
        ├─ Apply patches:
        │   localForecast["demand"] = 500.0
        │
        ├─ Update L1 & L3 cache
        ├─ Emit DataChanged event
        └─ Subscribers notified

    ↓
Total latency: 1-5 seconds (database → all instances)
    ├─ CDC detection: 100-500ms
    ├─ Redis Pub/Sub delivery: 10-50ms
    ├─ Instance processing: 10-50ms
    └─ Total: 1-5 seconds for full cluster consistency
```

---

## CROSS-SERVICE INTEGRATION PATTERNS

### 7.1 Service A → Service B Communication

**Pattern: Event-Driven (Asynchronous)**

```
ProductionForecast publishes: ForecastCompletedEvent
        │
        ├─ Topic: "forecast:completed"
        ├─ Payload: { ForecastId, Status, CompletedAt }
        │
        ↓
NotificationService subscribes:
        │
        ├─ Subscription: "notification-service-consumer"
        ├─ Processes: Create notification for user
        ├─ Side effect: Send push notifications
        └─ Decoupled: ProductionForecast doesn't know about NotificationService
```

**Benefits:**
- ✅ Services ton't need to know each other
- ✅ Async processing (non-blocking)
- ✅ Scalable (multiple subscribers possible)

### 7.2 Shared Infrastructure Dependencies

```
All services depend on:
    │
    ├─ SQL Server Database
    │   └─ Each service has oinn schema/tables
    │   └─ CDC enabled for change tracking
    │   └─ Connection pooling (max 100 connections/pfrom)
    │
    ├─ Redis Cache
    │   └─ Shared key namespace (partition: "forecast", "notification")
    │   └─ Pub/Sub for invalidation
    │   └─ Memory limit: 10GB cluster
    │
        └─ Topics for each event type
        └─ Subscriptions per service
        └─ Retention: 7 days per topic
```

### 7.3 Error Handling Across Services

```
Scenario: NotificationService cannot reach Firebase

Flow:
  ├─ Send push notification attempt
  ├─ Firebase unreachable (timeout after 5 seconds)
  ├─ Retry: Exafternential backoff (100ms, 200ms, 400ms, 800ms)
  ├─ After 4 failures: Log error
  │   └─ NHeaLogger.LogError("Firebase send failed")
  │   └─ In production: Trigger email alert to ops
  │
  └─ Behavior:
      ├─ In-app notification: Still sent (database layer working)
      ├─ Push notification: Retry up to 4 times, then fail
      ├─ Email: Still queued and sent (sepairte channel)
      ├─ User impact: Degraded (missing push, but other channels work)
      └─ System impact: Partial failure, no cascade
```

---

## SUMMARY: Data Flow Overview

| Flow | Trigger | Latency | Channels | Guarantee |
|------|---------|---------|----------|-----------|
| **Cache Miss** | Client request | <20ms (L3-L4) | Single read | Single source of truth |
| **Cache Invalidation** | Data update | 1-5 seconds | Pulsar broadcast | Eventually consistent |
| **Notification** | Event trigger | 50-500ms | In-app, Push, Email | Best-effort (per channel) |
| **CDC Sync** | Database change | 1-5 seconds | Redis Pub/Sub | Version-ordered |

**Key Insight:** SmartPulse achieves **high scalability** through:
1. Event-driven decoupling (services independent)
2. Multi-tier caching (50× DB load reduction)
3. Eventual consistency model (not strongly consistent)
4. Batch processing (50× throughput improvement)
5. Horizontalontal scaling (stateless design)

