# NotificationService Component


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

## Overview

NotificationService is a multi-channel notification platform delivering messages via in-app notifications, push notifications (Firebase Cloud Messaging, Web Push), and email. The service operates as a distributed system with batch processing for scalability and eventual consistency across channels.

## Quick Links

- **[Service Architecture](service_architecture.md)** - Core components, layered architecture, and service dependencies
- **[Data Models & Integration](data_models_integration.md)** - Entity models, database schema, Firebase/WebPush integration
- **[API Endpoints](api_endpoints.md)** - REST API specification, request/response workflows

## Key Features

### Multi-Channel Delivery
- **In-App Notifications**: Database records with read/unread status tracking
- **Push Notifications**:
  - Firebase Cloud Messaging (FCM) for iOS and Android
  - Web Push (VAPID protocol) for web browsers
- **Email**: Template-based email delivery with batch processing

### Batch Processing
- AutoBatchWorker pattern for high-throughput email delivery
- Configurable batch size (default: 2,000 items)
- 1-second processing interval
- Exponential backoff retry logic (up to 5 attempts)

### Template System
- Pug template engine via Node.js integration
- Pre-rendered table values for structured data
- Environment-aware templates (Production/Development indicators)
- Custom domain-specific templates (EAK, GOP)

### Device Management
- Automatic device token tracking
- Multi-device support per user
- Offline state handling
- Token validation and cleanup

## Architecture Characteristics

### Assembly Structure
```
NotificationService/
├── NotificationService.Web.Api           # Entry point, HTTP controllers
├── NotificationService.Application       # Business logic, orchestration
├── NotificationService.Repository        # Data access abstraction
├── NotificationService.Infrastructure.Data # EF Core, DbContext
├── SmartPulse.Services.NotificationService.Models # DTOs, request/response
└── SmartPulse.Services.NotificationService # Constants, enums
```

### Technology Stack
- **.NET 9.0** - API and Application layers
- **Entity Framework Core 9.0** - ORM with SQL Server provider
- **Firebase Admin SDK 3.1.0** - FCM integration
- **WebPush 1.0.12** - VAPID protocol for web push
- **NodeServices 3.1.32** - Pug template rendering
- **Nhea.Communication** - Email framework with queue management
- **OpenTelemetry 1.9.0** - Metrics and observability

## Key Metrics

| Metric | Value | Notes |
|--------|-------|-------|
| **Throughput** | 1,000-2,000/sec | Per replica |
| **In-App Latency** | <50ms | Database query via stored procedures |
| **Push Delivery** | 200-500ms | Async via FCM/WebPush |
| **Email Delivery** | 5-30 seconds | Batch queue processing |
| **Batch Size** | 2,000 | Configurable per worker |
| **Batch Interval** | 1 second | AutoBatchWorker timer |

## Core Services

### NotificationManagerService
Central orchestration service managing notification CRUD operations, multi-channel routing, and status tracking.

**Key Responsibilities:**
- Notification list retrieval (with stored procedures)
- Unread count calculation
- Mark as read (single and bulk)
- Multi-channel orchestration

### MailSenderService
Email composition and queueing service with Pug template rendering.

**Key Responsibilities:**
- Template rendering via Node.js
- Email queue management
- Batch processing coordination
- Attachment handling (up to 10 MB per file)

### PushNotificationSender
Push notification delivery via Firebase and Web Push protocols.

**Key Responsibilities:**
- FCM message composition (iOS/Android)
- Web Push payload construction (VAPID)
- Device token management
- Error handling and token cleanup

### NotificationOperations
Multi-channel orchestration layer coordinating database, push, and email delivery.

**Key Responsibilities:**
- Notification record creation
- Device lookup and routing
- Push notification dispatch
- Email queuing (via MailSenderService)

## Database Schema

### Core Tables

#### Notification
```sql
CREATE TABLE [dbo].[Notification]
(
    [Id] UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    [SysUserId] INT NOT NULL,
    [Type] NVARCHAR(50) NOT NULL,
    [CreateDate] DATETIME NOT NULL,
    [Status] INT NOT NULL, -- 0=New, 1=Seen
    [TargetEntityId] NVARCHAR(250),
    [WebUrl] NVARCHAR(2000),
    [Description] NVARCHAR(400),
    [SeenOn] DATETIME
);

CREATE NONCLUSTERED INDEX [IX_Notification_SysUserId_Status]
    ON [dbo].[Notification] ([SysUserId], [Status])
    INCLUDE ([CreateDate], [Description]);
```

#### SysUserDeviceInfo
```sql
CREATE TABLE [dbo].[SysUserDeviceInfo]
(
    [Id] UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    [DeviceToken] NVARCHAR(2000) NOT NULL,
    [DeviceTypeId] INT NOT NULL, -- 1=Web, 2=Android, 3=iOS
    [SysUserId] INT NOT NULL,
    [CreateDate] DATETIME NOT NULL,
    [ModifyDate] DATETIME NOT NULL,
    [DeviceUniqueId] NVARCHAR(200),
    [DeviceKey] NVARCHAR(2000), -- WebPush P-256 public key
    [DeviceAuth] NVARCHAR(2000), -- WebPush auth secret
    [IntegrationToken] NVARCHAR(5000), -- FCM token
    [IntegrationType] INT NOT NULL -- 0=WebPush, 1=FCM
);

CREATE NONCLUSTERED INDEX [IX_SysUserDeviceInfo_SysUserId]
    ON [dbo].[SysUserDeviceInfo] ([SysUserId])
    INCLUDE ([DeviceToken], [IntegrationType]);
```

#### NheaMailQueue
```sql
CREATE TABLE [dbo].[NheaMailQueue]
(
    [Id] UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    [From] NVARCHAR(256) NOT NULL,
    [To] NVARCHAR(1000) NOT NULL,
    [Cc] NVARCHAR(250),
    [Bcc] NVARCHAR(250),
    [Subject] NVARCHAR(500),
    [Body] NVARCHAR(MAX) NOT NULL,
    [MailProviderId] INT,
    [Priority] DATETIME NOT NULL, -- Sort key: 2000-01-01=High, UtcNow=Normal, 9999-12-31=Low
    [IsReadyToSend] BIT NOT NULL,
    [HasAttachment] BIT NOT NULL,
    [CreateDate] DATETIME NOT NULL
);

CREATE NONCLUSTERED INDEX [IX_NheaMailQueue_Priority]
    ON [dbo].[NheaMailQueue] ([Priority], [CreateDate])
    WHERE [IsReadyToSend] = 1;
```

## API Endpoints

### Notification Management

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/notification/list` | POST | Get user notifications (paginated) |
| `/api/notification/unread-notification-count` | POST | Count unread notifications |
| `/api/notification/read-all` | POST | Mark all as read |
| `/api/notification/read` | POST | Mark single notification as read |

### Notification Creation

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/notification/new` | POST | Multi-channel notification (DB + Push + Email) |

### Email Delivery

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/notification/send-email` | POST | Basic email with table values |
| `/api/notification/send-email-by-template` | POST | Templated email (Pug) |
| `/api/notification/send-email-with-attachments` | POST | Email with file attachments |

## Integration Examples

### Send Multi-Channel Notification

<details>
<summary>Click to expand example</summary>

```csharp
var request = new NewNotificationRequestModel
{
    Users = new List<int> { 42, 43, 44 },
    NotificationType = "ForecastUpdate",
    Description = "New forecast available for review",
    TargetEntityId = "forecast-789",
    WebUrl = "/forecast/details/789",

    // Channel control flags
    DisableNotificationRecord = false,      // Create DB record
    DisablePushNotificationSending = false, // Send push
    DisableMailSending = false,             // Send email

    // Email details
    MailSubject = "SmartPulse: New Forecast Available",
    MailMessage = "A new forecast has been generated for your review",
    ButtonText = "View Forecast"
};

// POST /api/notification/new
var response = await httpClient.PostAsJsonAsync(
    "/api/notification/new",
    request
);
```

**Response:**
```json
{
  "errorCode": 200,
  "success": true,
  "resultMessage": "Notification sent",
  "data": null
}
```

</details>

### Send Templated Email

<details>
<summary>Click to expand example</summary>

```csharp
var request = new NewMailByTemplateRequestModel
{
    To = "analyst@example.com",
    MailSubject = "EAK Forecast Report",
    Title = "EAK System Alert",
    Description = "Energy availability analysis complete",
    TemplateName = "EAK_Template",
    Data = new
    {
        ForecastId = "fcast-2025-11-12-001",
        SystemStatus = "OPTIMAL",
        ConfidenceScore = 0.97,
        NextUpdateTime = "2025-11-12T18:00:00Z"
    },
    TableValues = new Dictionary<string, string>
    {
        { "Analysis Date", "2025-11-12" },
        { "Confidence", "97%" },
        { "Status", "Green" }
    },
    HighPriority = true
};

// POST /api/notification/send-email-by-template
var response = await httpClient.PostAsJsonAsync(
    "/api/notification/send-email-by-template",
    request
);
```

</details>

### Register Device for Push Notifications

<details>
<summary>Click to expand example</summary>

```javascript
// Browser JavaScript - Service Worker Registration
navigator.serviceWorker.ready.then(registration => {
    registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY)
    }).then(subscription => {
        // Extract subscription details
        const endpoint = subscription.endpoint;
        const p256dh = btoa(String.fromCharCode.apply(null,
            new Uint8Array(subscription.getKey('p256dh'))));
        const auth = btoa(String.fromCharCode.apply(null,
            new Uint8Array(subscription.getKey('auth'))));

        // Send to backend
        fetch('/api/device/register', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                deviceToken: endpoint,
                deviceKey: p256dh,
                deviceAuth: auth,
                deviceTypeId: 1, // Web
                integrationType: 0 // WebPush
            })
        });
    });
});
```

</details>

## Performance Optimization

### Database Stored Procedures
All read-heavy operations use stored procedures for optimal performance:

- `dbo.GetNotifications` - User notification list with pagination
- `dbo.GetUnreadNotificationsCount` - Fast count query
- `dbo.ReadAllNotifications` - Bulk update for mark-as-read

### Batch Processing
Email delivery uses AutoBatchWorker pattern:

- **Aggregation**: 1-second window for batching
- **Bulk Insert**: EFCore.BulkExtensions for 50× faster inserts
- **Retry Logic**: Exponential backoff (500ms, 1s, 1.5s, 2s, 2.5s)
- **Priority Queue**: DateTime-based sorting (year 2000 = high priority)

### Connection Management
SQL Server options for reliability:

```csharp
sqlOptions.EnableRetryOnFailure(
    maxRetryCount: 10,
    maxRetryDelaySeconds: 30
);
sqlOptions.CommandTimeout(180); // 3 minutes
sqlOptions.MaxBatchSize(1);     // Safety: individual commands
```

## Error Handling

### Graceful Degradation
- If push fails → Email still sent, DB record still created
- If email fails → Push still sent, DB record still created
- Independent channel processing with partial failure tolerance

### Token Cleanup
Automatic device deactivation on:
- **FCM**: `InvalidArgument`, `NotFound` errors
- **WebPush**: HTTP 410 (Gone), 404 (Not Found), 401/403 (Auth)

### Retry Strategies

| Operation | Max Retries | Backoff | Total Time |
|-----------|-------------|---------|-----------|
| Email batch processing | 5 | Exponential (500ms base) | ~7.5 seconds |
| SQL connection | 10 | EF Core built-in | ~5 minutes |
| Push notification | 0 | N/A (mark device inactive) | Immediate |

## Monitoring and Observability

### OpenTelemetry Metrics
- `notification_created` - New notification count
- `notification_marked_read` - Read status updates
- `email_queued` - Email queue operations
- `email_sent` - Successful email delivery
- `email_failed` - Failed email attempts
- `push_sent` - Push notification delivery
- `fcm_sent` - FCM-specific delivery
- `web_push_sent` - Web Push delivery

### Logging
Structured logging with correlation IDs:
- Request/response logging at controller level
- Service-level operation logging
- Error logging with context (user ID, notification ID, device ID)

## Troubleshooting

### Common Issues

**Issue: Push notifications not delivered**
- **Cause**: Invalid device token or expired subscription
- **Solution**: Check `SysUserDeviceInfo.IsActive` flag; re-register device
- **Logs**: "Firebase token invalid" or "Web Push endpoint expired"

**Issue: Emails stuck in queue**
- **Cause**: SMTP connection failure or batch worker not running
- **Solution**: Check `NheaMailQueue.IsReadyToSend` and `IsFailed` flags
- **Logs**: "SMTP error" or "Error processing mail queue"

**Issue: High latency on notification list**
- **Cause**: Missing database indexes or large result sets
- **Solution**: Verify `IX_Notification_SysUserId_Status` index; implement pagination
- **Logs**: Query execution time >100ms

## Configuration

### Environment Variables

```bash
# Database
MSSQL_CONNSTR=Server=localhost;Database=SmartPulse;...

# Firebase
GOOGLE_FIREBASE_CREDENTIALS_FILE=smartpulse-firebase-adminsdk.json

# Web Push (VAPID)
WEBPUSH_SUBJECT=mailto:support@smartpulse.com
WEBPUSH_PUBLICKEY=BC8rN2K7...
WEBPUSH_PRIVATEKEY=abc123...

# SMTP
SMTP_HOST=smtp.sendgrid.net
SMTP_PORT=587
SMTP_USERNAME=apikey
SMTP_PASSWORD=SG.xxxx
```

### Application Settings

```json
{
  "GoogleFirebase": {
    "FileName": "smartpulse-mobile-firebase-adminsdk-v1m05-c6c7b9940c.json"
  },
  "MailWorker": {
    "BatchSize": 2000,
    "BatchIntervalMs": 1000,
    "MaxRetryAttempts": 5,
    "RetryDelayMs": 500
  },
  "ConnectionStrings": {
    "DefaultConnection": "..."
  }
}
```

## Related Documentation

- **[Service Architecture](service_architecture.md)** - Detailed component breakdown
- **[Data Models & Integration](data_models_integration.md)** - Entity relationships and external integrations
- **[API Endpoints](api_endpoints.md)** - Complete REST API specification
- **[Message Bus](../../integration/.md)** - Event-driven architecture

## Support

For issues or questions:
- Review component documentation in this folder
- Check application logs for error details
- Verify environment variables and configuration
- Test individual channels independently (DB, Push, Email)
