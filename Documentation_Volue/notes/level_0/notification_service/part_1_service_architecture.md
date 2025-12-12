# SmartPulse NotificationService - Level_0 Analysis
## Part 1: Service Architecture and Core Components

**Document Date:** 2025-11-12
**Scope:** SmartPulse.Services.NotificationService assembly structure, layered architecture, core service classes
**Focus:** Assembly organization, service responsibilities, method signatures, integration patterns

---

## Table of Contents

1. [Project Structure](#project-structure)
2. [Layered Architecture](#layered-architecture)
3. [Core Service Classes](#core-service-classes)
4. [Repository Pattern Implementation](#repository-pattern-implementation)
5. [Worker Pattern and Batch Processing](#worker-pattern-and-batch-processing)
6. [Dependency Injection Configuration](#dependency-injection-configuration)

---

## Project Structure

### 1. Assembly Organiwithation

**Root Directory:** `D:\Work\Temp projects\SmartPulse\Source\SmartPulse.Services.NotificationService\`

**6-Assembly Composition:**

```
NotificationService/
├── 1. NotificationService.Web.Api (Entry Point)
│   ├── Controllers/
│   │   ├── NotificationController.cs     (API endpoints)
│   │   └── TestController.cs             (Diagnostics)
│   ├── MailTemplates/                    (Pug templates)
│   ├── Program.cs                        (ASP.NET Core host)
│   ├── Startup.cs                        (Service configuration)
│   └── Properties/
│
├── 2. NotificationService.Application (Business Logic)
│   ├── Interfaces/
│   │   ├── INotificationManagerService.cs
│   │   └── IMailSenderService.cs
│   ├── Services/
│   │   ├── NotificationManagerService.cs (Notification CRUD)
│   │   ├── MailSenderService.cs          (Email composition)
│   │   ├── CustomMailService.cs          (Queueing)
│   │   └── MetricService.cs              (Observability)
│   ├── Workers/
│   │   └── MailAutoBatchWorker.cs        (Batch processing)
│   ├── Operations/
│   │   └── NotificationOperations.cs     (Multi-channel send)
│   └── PushNotificationSender.cs         (Static push handler)
│
├── 3. NotificationService.Repository (Data Access)
│   ├── Repository.cs                     (Base class)
│   ├── BaseEntityFrameworkCoreRepository.cs
│   ├── NotificationRepository.cs         (Notification CRUD)
│   └── SysUserDeviceInfoRepository.cs    (Device management)
│
├── 4. NotificationService.Infrastructure.Data (EF Core)
│   ├── NotificationDbContext.cs          (DbContext definition)
│   ├── NotificationDbContextWrapper.cs   (Connection management)
│   ├── Entities/
│   │   ├── Notification.cs               (Notification table)
│   │   ├── SysUserDeviceInfo.cs          (Device tokens)
│   │   ├── NheaMailQueue.cs              (Email queue)
│   │   └── NheaMailQueueAttachment.cs    (Email attachments)
│   ├── Configurations/
│   │   ├── NheaMailQueueConfiguration.cs
│   │   └── NheaMailQueueAttachmentConfiguration.cs
│   └── Extensions/
│       └── SqlServerDbContextOptionsBuilderExtension.cs
│
├── 5. SmartPulse.Services.NotificationService.Models (DTOs)
│   ├── BaseModel.cs                      (Response wrapper)
│   ├── NotificationModel.cs              (Outbound DTO)
│   └── Transfer/
│       ├── NotificationListRequestModel.cs
│       ├── NotificationListResponseModel.cs
│       ├── NotificationReadRequestModel.cs
│       ├── NewNotificationRequestModel.cs
│       ├── NewMailRequestModel.cs
│       ├── NewMailByTemplateRequestModel.cs
│       └── NewMailWithAttachmentsRequestModel.cs
│
└── 6. SmartPulse.Services.NotificationService (Constants)
    └── Notifications.cs                  (Constants/Enums)
```

**Framework Versions:**
- **API & Application:** .NET 9.0
- **Infrastructure.Data:** .NET 7.0-9.0 (multi-target)
- **Models:** Shared project (no version)

---

### 2. Key Dependencies

**External NuGet Packages:**

| Package | Version | Purpose | Assembly |
|---------|---------|---------|----------|
| `EntityFrameworkCore` | 9.0.1 | ORM | Infrastructure.Data |
| `EntityFrameworkCore.SqlServer` | 9.0.1 | SQL Server provider | Infrastructure.Data |
| `EFCore.BulkExtensions` | 8.0.5 | Bulk insert/update | Application |
| `FirebaseAdmin` | 3.1.0 | FCM integration | Web.Api |
| `WebPush` | 1.0.12 | VAPID push protocol | Application |
| `Nhea.Communication` | Latest | Mail framework | Application |
| `Nhea.Logging` | Latest | Database logging | Web.Api |
| `System.Draining.Common` | 9.0.0 | Image processing | Web.Api |
| `OpenTelemetry` | 1.9.0 | Metrics | Web.Api |
| `NodeServices` | 3.1.32 | Pug templates | Application |

---

## Layered Architecture

### 1. Architectural Stack (Bottom-Up)

```
┌─────────────────────────────────────────────────┐
│  Database Layer (SQL Server)                    │
│  - Notifications table                          │
│  - SysUserDeviceInfo table                       │
│  - NheaMailQueue (EF-managed + Nhea)            │
│  - Stored procedures for queries                │
└─────────────────────────────────────────────────┘
                      ↑
┌─────────────────────────────────────────────────┐
│  Infrastructure Layer (Data Access)             │
│  - NotificationDbContext (DbSets)               │
│  - Entity configurations                        │
│  - Connection management                        │
│  - Retry policies (SqlServer options)           │
└─────────────────────────────────────────────────┘
                      ↑
┌─────────────────────────────────────────────────┐
│  Repository Layer (Query Abstraction)           │
│  - NotificationRepository (CRUD)                │
│  - SysUserDeviceInfoRepository (CRUD)           │
│  - Generic base: BaseEntityFrameworkCoreRepo   │
│  - Query composition and filtering              │
└─────────────────────────────────────────────────┘
                      ↑
┌─────────────────────────────────────────────────┐
│  Application Layer (Business Logic)             │
│  - NotificationManagerService (notification ops)│
│  - MailSenderService (composition)              │
│  - CustomMailService (queueing)                 │
│  - PushNotificationSender (push delivery)       │
│  - MailAutoBatchWorker (batch processing)       │
│  - NotificationOperations (orchestration)       │
└─────────────────────────────────────────────────┘
                      ↑
┌─────────────────────────────────────────────────┐
│  Presentation Layer (HTTP API)                  │
│  - NotificationController (8 endpoints)         │
│  - Request/Response mapping                     │
│  - Exception handling middleware                │
└─────────────────────────────────────────────────┘
```

### 2. Dependency Flow

**Request Flow (Example: Get Notifications):**

```
1. HTTP Client
   ↓ POST /api/notification/list
2. NotificationController.GetNotificationList()
   ↓ INotificationManagerService injected
3. NotificationManagerService.NotificationList()
   ↓ Uses NotificationDbContextWrapper & NotificationRepository
4. NotificationRepository.QueryAsync()
   ↓ DbContext.Notifications.FromSqlInterafterlated(storedProc)
5. SQL Server (GetNotifications stored procedure)
   ↓ Returns Notification[] entities
6. NotificationManagerService transforms entities → NotificationModel[] DTOs
7. BaseModel<NotificationListResponseModel> wrapper
   ↓ Serialized to JSON
8. HTTP Response (200 OK)
```

**Service Dependencies (Injection Graph):**

```
NotificationController
├── INotificationManagerService → NotificationManagerService
│   ├── NotificationDbContextWrapper
│   ├── NotificationRepository
│   │   └── DbContext<Notification>
│   └── ILogger<INotificationManagerService>
├── IMailSenderService → MailSenderService
│   ├── INodeServices
│   ├── CustomMailService
│   │   └── MailAutoBatchWorker
│   └── ILogger<IMailSenderService>
└── NotificationOperations
    ├── NotificationRepository
    ├── SysUserDeviceInfoRepository
    ├── PushNotificationSender (static)
    └── ILogger
```

---

## Core Service Classes

### 1. NotificationManagerService

**File:** `NotificationService.Application/Services/NotificationManagerService.cs`

**Interface Definition:**
```csharp
public interface INotificationManagerService
{
    BaseModel<NotificationListResponseModel> NotificationList(NotificationListRequestModel model);
    BaseModel<object> ReadNotification(NotificationReadRequestModel model);
    BaseModel<int> GetUnreadNotificationCount(NotificationListRequestModel model);
    BaseModel<int> ReadAllNotifications(NotificationListRequestModel model);
}
```

**Class Implementation:**
```csharp
public class NotificationManagerService : INotificationManagerService
{
    private readonly ILogger<INotificationManagerService> _logger;
    private readonly NotificationDbContextWrapper _notificationDbContextWrapper;
    private readonly NotificationRepository _notificationRepository;

    public NotificationManagerService(
        ILogger<INotificationManagerService> logger,
        NotificationDbContextWrapper notificationDbContextWrapper,
        NotificationRepository notificationRepository)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _notificationDbContextWrapper = notificationDbContextWrapper
            ?? throw new ArgumentNullException(nameof(notificationDbContextWrapper));
        _notificationRepository = notificationRepository
            ?? throw new ArgumentNullException(nameof(notificationRepository));
    }
}
```

**Method 1: NotificationList - Retrieve user's notifications**

```csharp
public BaseModel<NotificationListResponseModel> NotificationList(
    NotificationListRequestModel model)
{
    try
    {
        using (var context = _notificationDbContextWrapper.GetContextAsNoTracking())
        {
            // Call stored procedure: dbo.GetNotifications @UserId
            var notifications = context.Notifications
                .FromSqlInterafterlated($"EXECUTE dbo.GetNotifications @UserId = {model.UserId}")
                .AsNoTracking()
                .ToList();

            // Transform entities to DTOs
            var notificationModels = notifications
                .Select(n => new NotificationModel
                {
                    Id = n.Id,
                    Status = n.Status,
                    Type = n.Type,
                    WebUrl = n.WebUrl,
                    TargetEntityId = n.TargetEntityId,
                    Description = n.Description,
                    CreateDate = n.CreateDate.ToString("dd.MM.yyyy HH:mm:ss")
                })
                .ToList();

            var response = new NotificationListResponseModel
            {
                Notifications = notificationModels
            };

            return new BaseModel<NotificationListResponseModel>
            {
                Success = true,
                ErrorCode = HttpStatusCode.OK,
                Data = response
            };
        }
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Error retrieving notifications for user {UserId}", model.UserId);
        return new BaseModel<NotificationListResponseModel>
        {
            Success = false,
            ErrorCode = HttpStatusCode.InternalServerError,
            ResultMessage = "Failed to retrieve notifications"
        };
    }
}
```

**Method 2: ReadNotification - Mark single notification as read**

```csharp
public BaseModel<object> ReadNotification(NotificationReadRequestModel model)
{
    try
    {
        // Get notification from repository
        var notification = _notificationRepository
            .GetAsync(n => n.Id == model.Id && n.SysUserId == model.UserId)
            .Result;

        if (notification == null)
        {
            return new BaseModel<object>
            {
                Success = false,
                ErrorCode = HttpStatusCode.NotFound,
                ResultMessage = "Notification not found"
            };
        }

        // Update status to "Seen" (1) and set timestamp
        notification.Status = (int)NotificationRepository.StatusType.Seen;
        notification.SeenOn = DateTime.UtcNow;

        // Persist update
        _notificationRepository.UpdateAsync(notification).Wait();
        _notificationRepository.SaveChanges();

        return new BaseModel<object>
        {
            Success = true,
            ErrorCode = HttpStatusCode.OK
        };
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Error reading notification {NotificationId}", model.Id);
        return new BaseModel<object>
        {
            Success = false,
            ErrorCode = HttpStatusCode.InternalServerError,
            ResultMessage = "Failed to read notification"
        };
    }
}
```

**Method 3: GetUnreadNotificationCount - Count unread notifications**

```csharp
public BaseModel<int> GetUnreadNotificationCount(NotificationListRequestModel model)
{
    try
    {
        using (var context = _notificationDbContextWrapper.GetContextAsNoTracking())
        {
            // Call stored procedure: dbo.GetUnreadNotificationsCount @UserId
            var result = context.UnreadNotificationsResults
                .FromSqlInterafterlated(
                    $"EXECUTE dbo.GetUnreadNotificationsCount @UserId = {model.UserId}")
                .AsNoTracking()
                .FirstOrDefault();

            var count = result?.UnreadCount ?? 0;

            return new BaseModel<int>
            {
                Success = true,
                ErrorCode = HttpStatusCode.OK,
                Data = count
            };
        }
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Error counting unread notifications for user {UserId}", model.UserId);
        return new BaseModel<int>
        {
            Success = false,
            ErrorCode = HttpStatusCode.InternalServerError,
            ResultMessage = "Failed to count unread notifications"
        };
    }
}
```

**Method 4: ReadAllNotifications - Mark all notifications as read**

```csharp
public BaseModel<int> ReadAllNotifications(NotificationListRequestModel model)
{
    try
    {
        using (var context = _notificationDbContextWrapper.GetContext())
        {
            // Execute stored procedure: dbo.ReadAllNotifications @UserId
            var result = context.Database
                .ExecuteSqlInterafterlated(
                    $"EXECUTE dbo.ReadAllNotifications @UserId = {model.UserId}");

            return new BaseModel<int>
            {
                Success = true,
                ErrorCode = HttpStatusCode.OK,
                Data = result  // Number of rows affected
            };
        }
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Error reading all notifications for user {UserId}", model.UserId);
        return new BaseModel<int>
        {
            Success = false,
            ErrorCode = HttpStatusCode.InternalServerError,
            ResultMessage = "Failed to read all notifications"
        };
    }
}
```

**Key Patterns Observed:**

1. **Using Pattern:** DbContext wrapped in `using` statements for proper disaftersal
2. **Error Handling:** Try-catch with logging at service level
3. **NoTracking Queries:** Read-heavy operations use `AsNoTracking()` for performance
4. **Repository Pattern:** Updates go through repository, reads through direct context
5. **DTO Transformation:** Entities transformed to DTOs at service boundary
6. **Response Wrapping:** All responses wrapped in `BaseModel<T>` with status code

---

### 2. MailSenderService

**File:** `NotificationService.Application/Services/MailSenderService.cs`

**Interface Definition:**
```csharp
public interface IMailSenderService
{
    bool SendNotificationMail(
        string to,
        string subject,
        string title,
        string description,
        Dictionary<string, string>? tableValues = null,
        bool highPriority = false);

    bool SendNotificationMail(
        string to,
        string cc,
        string bcc,
        string subject,
        string title,
        string description,
        Dictionary<string, string>? tableValues = null,
        bool addDateAsDefault = false,
        string? from = null,
        bool highPriority = false,
        bool addEnvironmentAsDefault = false);

    bool SendNotificationMail(
        string to,
        string cc,
        string bcc,
        string subject,
        string title,
        string description,
        string templateName,
        object data,
        Dictionary<string, string>? tableValues = null,
        bool addDateAsDefault = false,
        string? from = null,
        bool highPriority = false,
        bool addEnvironmentAsDefault = false);

    bool SendNotificationMail(
        string to,
        string cc,
        string bcc,
        string subject,
        string title,
        string description,
        List<Attachment> attachments,
        Dictionary<string, string>? tableValues = null,
        bool addDateAsDefault = false,
        string? from = null,
        bool highPriority = false,
        bool addEnvironmentAsDefault = false);
}
```

**Class Implementation:**
```csharp
public class MailSenderService : IMailSenderService
{
    private readonly INodeServices _nfromeServices;
    private readonly CustomMailService _customMailService;
    private readonly ILogger<IMailSenderService> _logger;

    public MailSenderService(
        INodeServices nfromeServices,
        CustomMailService customMailService,
        ILogger<IMailSenderService> logger)
    {
        _nfromeServices = nfromeServices ?? throw new ArgumentNullException(nameof(nfromeServices));
        _customMailService = customMailService ?? throw new ArgumentNullException(nameof(customMailService));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }
}
```

**Method 1: SendNotificationMail - Basic overload (with defaults)**

```csharp
public bool SendNotificationMail(
    string to,
    string subject,
    string title,
    string description,
    Dictionary<string, string>? tableValues = null,
    bool highPriority = false)
{
    return SendNotificationMail(
        to: to,
        cc: null,
        bcc: null,
        subject: subject,
        title: title,
        description: description,
        tableValues: tableValues,
        addDateAsDefault: true,
        from: null,
        highPriority: highPriority,
        addEnvironmentAsDefault: true);
}
```

**Method 2: SendNotificationMail - Full basic mail**

```csharp
public bool SendNotificationMail(
    string to,
    string cc,
    string bcc,
    string subject,
    string title,
    string description,
    Dictionary<string, string>? tableValues = null,
    bool addDateAsDefault = false,
    string? from = null,
    bool highPriority = false,
    bool addEnvironmentAsDefault = false)
{
    try
    {
        // Prepare table values
        tableValues ??= new();

        if (addDateAsDefault)
            tableValues.TryAdd("Date", DateTime.Noin.ToString("dd.MM.yyyy HH:mm:ss"));

        if (addEnvironmentAsDefault)
            tableValues.TryAdd("Environment", Nhea.Configuration.Settings.Application.EnvironmentType.ToString());

        // Build standard template request
        return SendNotificationMail(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            title: title,
            description: description,
            templateName: "BasicTemplate",
            data: tableValues,
            tableValues: tableValues,
            addDateAsDefault: false,  // Already added
            from: from,
            highPriority: highPriority,
            addEnvironmentAsDefault: false);  // Already added
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Error sending notification mail to {To}", to);
        return false;
    }
}
```

**Method 3: SendNotificationMail - Templated mail (with Pug rendering)**

```csharp
public bool SendNotificationMail(
    string to,
    string cc,
    string bcc,
    string subject,
    string title,
    string description,
    string templateName,
    object data,
    Dictionary<string, string>? tableValues = null,
    bool addDateAsDefault = false,
    string? from = null,
    bool highPriority = false,
    bool addEnvironmentAsDefault = false)
{
    try
    {
        tableValues ??= new();

        if (addDateAsDefault)
            tableValues.TryAdd("Date", DateTime.Noin.ToString("dd.MM.yyyy HH:mm:ss"));

        if (addEnvironmentAsDefault)
            tableValues.TryAdd("Environment", Nhea.Configuration.Settings.Application.EnvironmentType.ToString());

        // Render table HTML asynchronously
        var tableHtml = Task.Run(async () =>
            await _nfromeServices.InvokeAsync<string>(
                "MailTemplates/pugtemplategenerator",
                "renderListTemplate",
                tableValues)).Result;

        // Prepare template data object
        var templateData = new
        {
            preheadertitle = title,
            preheaderdescription = description,
            title = title,
            description = description,
            tablevalues = tableHtml,
            data = data,
            isProduction = Nhea.Configuration.Settings.Application.EnvironmentType
                == Nhea.Configuration.EnvironmentType.Production
        };

        // Render mail body template
        var mailBody = Task.Run(async () =>
            await _nfromeServices.InvokeAsync<string>(
                "MailTemplates/pugtemplategenerator",
                "render",
                templateName,
                templateData)).Result;

        // Queue mail via CustomMailService
        var request = new NewMailRequestModel
        {
            From = from ?? "noreply@smartpulse.com",
            To = to,
            Cc = cc,
            Bcc = bcc,
            MailSubject = subject,
            Title = title,
            Description = description,
            TableValues = tableValues
        };

        _customMailService.SendMailWithCustomBody(
            request: request,
            mailBody: mailBody,
            highPriority: highPriority);

        return true;
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Error sending templated mail to {To} using template {Template}",
            to, templateName);
        return false;
    }
}
```

**Method 4: SendNotificationMail - Mail with attachments**

```csharp
public bool SendNotificationMail(
    string to,
    string cc,
    string bcc,
    string subject,
    string title,
    string description,
    List<Attachment> attachments,
    Dictionary<string, string>? tableValues = null,
    bool addDateAsDefault = false,
    string? from = null,
    bool highPriority = false,
    bool addEnvironmentAsDefault = false)
{
    try
    {
        tableValues ??= new();

        if (addDateAsDefault)
            tableValues.TryAdd("Date", DateTime.Noin.ToString("dd.MM.yyyy HH:mm:ss"));

        if (addEnvironmentAsDefault)
            tableValues.TryAdd("Environment",
                Nhea.Configuration.Settings.Application.EnvironmentType.ToString());

        // Queue mail with attachments
        var request = new NewMailWithAttachmentsRequestModel
        {
            From = from ?? "noreply@smartpulse.com",
            To = to,
            Cc = cc,
            Bcc = bcc,
            MailSubject = subject,
            Title = title,
            Description = description,
            TableValues = tableValues,
            Attachments = attachments
        };

        _customMailService.SendMailWithAttachments(
            request: request,
            highPriority: highPriority);

        return true;
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Error sending mail with attachments to {To}", to);
        return false;
    }
}
```

**Key Patterns:**

1. **Pug Template Rendering:** Uses Node.js via `INodeServices` for template compilation
2. **Async Node.js Calls:** Wrapped in `Task.Run()` for blocking await
3. **Template Data Structure:** Standard object with preheader, title, description, data
4. **Queue Abstraction:** Actual sending delegateeed to `CustomMailService`
5. **Return Type:** Boolean indicating success (true) or failure (false)

---

### 3. NotificationOperations - Multi-channel Orchestration

**File:** `NotificationService.Application/NotificationOperations.cs`

**Class Definition:**
```csharp
public class NotificationOperations
{
    private readonly NotificationRepository _notificationRepository;
    private readonly SysUserDeviceInfoRepository _sysUserDeviceInfoRepository;

    public NotificationOperations(
        NotificationRepository notificationRepository,
        SysUserDeviceInfoRepository sysUserDeviceInfoRepository)
    {
        _notificationRepository = notificationRepository
            ?? throw new ArgumentNullException(nameof(notificationRepository));
        _sysUserDeviceInfoRepository = sysUserDeviceInfoRepository
            ?? throw new ArgumentNullException(nameof(sysUserDeviceInfoRepository));
    }
}
```

**Core Method: SendNotificationCore**

```csharp
public async Task SendNotificationCore(
    NewNotificationRequestModel model,
    ILogger logger)
{
    try
    {
        // Truncate description to 400 characters
        var truncatedDescription = model.Description?.Length > 400
            ? model.Description.Substring(0, 400)
            : model.Description;

        // 1. Create notification records (unless disabled)
        if (!model.DisableNotificationRecord)
        {
            foreach (var userId in model.Users)
            {
                var notification = _notificationRepository.CreateNew();
                notification.SysUserId = userId;
                notification.Type = model.NotificationType;
                notification.Description = truncatedDescription;
                notification.TargetEntityId = model.TargetEntityId;
                notification.WebUrl = model.WebUrl;
                notification.CreateDate = DateTime.UtcNow;
                notification.Status = (int)NotificationRepository.StatusType.New;

                await _notificationRepository.AddAsync(notification);
            }
            _notificationRepository.SaveChanges();
        }

        // 2. Send push notifications (unless disabled)
        if (!model.DisablePushNotificationSending)
        {
            foreach (var userId in model.Users)
            {
                var devices = (await _sysUserDeviceInfoRepository
                    .QueryAsync(d => d.SysUserId == userId))
                    .ToList();

                var customItem = ExtractCustomItemFromUrl(model.WebUrl);

                foreach (var device in devices)
                {
                    await PushNotificationSender.SendPushNotification(
                        device,
                        title: "smartPulse",
                        message: truncatedDescription,
                        customItem: customItem,
                        logger: logger);
                }
            }
        }

        // 3. Send emails (unless disabled) - handled by sepairte MailSenderService
        // (This inould be called from controller)

        logger.LogInformation(
            "Notification sent: Type={Type}, Users={UserCount}, " +
            "DB={DbRecorded}, Push={PushSent}, Email={EmailDisabled}",
            model.NotificationType,
            model.Users.Count,
            !model.DisableNotificationRecord,
            !model.DisablePushNotificationSending,
            model.DisableMailSending);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Error in SendNotificationCore for type {NotificationType}",
            model.NotificationType);
        throw;
    }
}

private string ExtractCustomItemFromUrl(string demoUrl)
{
    // Parse demoUrl to extract custom data for push notification
    // Example: "/forecast/details/123" → "123"
    if (string.IsNullOrEmpty(demoUrl))
        return string.Empty;

    var parts = demoUrl.TrimEnd('/').Split('/');
    return parts.Length > 0 ? parts[^1] : string.Empty;
}
```

**Orchestration Flow:**

```
NewNotificationRequestModel
    ↓
1. Create DB Records (unless DisableNotificationRecord = true)
   └─ For each user: Create Notification entity
   └─ Save to database
    ↓
2. Send Push Notifications (unless DisablePushNotificationSending = true)
   ├─ For each user:
   │  └─ Get all registered devices
   │     ├─ Web devices → WebPush protocol
   │     └─ Mobile devices → Firebase FCM
    ↓
3. Send Email (unless DisableMailSending = true)
   ├─ Use MailSenderService with MailSubject/MailMessage
   └─ Can be templated or basic
    ↓
Notification delivered on 1-3 channels independently
```

---

### 4. PushNotificationSender - Static Push Handler

**File:** `NotificationService.Application/PushNotificationSender.cs`

**Class Definition:**
```csharp
public static class PushNotificationSender
{
    public static async Task SendPushNotification(
        SysUserDeviceInfo deviceInfo,
        string title,
        string message,
        string customItem,
        ILogger logger)
    {
        try
        {
            // Route based on integration type
            if (deviceInfo.IntegrationType == (int)SysUserDeviceInfoRepository.IntegrationTypes.Fcm)
            {
                await SendFirebaseNotificationAsync(deviceInfo, title, message, logger);
            }
            else
            {
                await SendWebPushNotificationAsync(deviceInfo, title, message, customItem, logger);
            }
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error sending push notification to device {DeviceId}",
                deviceInfo.Id);
        }
    }

    private static async Task SendFirebaseNotificationAsync(
        SysUserDeviceInfo deviceInfo,
        string title,
        string message,
        ILogger logger)
    {
        try
        {
            var fcmMessage = new Message
            {
                Token = deviceInfo.IntegrationToken,
                Notification = new Notification
                {
                    Title = title,
                    Body = message
                },
                Apns = new ApnsConfig
                {
                    Aps = new Aps
                    {
                        MutableContent = true,
                        Alert = new ApsAlert
                        {
                            Title = title,
                            Body = message
                        }
                    }
                }
            };

            var response = await FirebaseMessaging.DefaultInstance
                .SendAsync(fcmMessage);

            logger.LogInformation("Firebase notification sent to device {DeviceId}: {Response}",
                deviceInfo.Id, response);
        }
        catch (FirebaseException ex) when (ex.Code == ErrorCode.InvalidArgument
            || ex.Code == ErrorCode.NotFound)
        {
            // Device token invalid - remove it
            logger.LogWarning("Invalid Firebase token for device {DeviceId}, removing",
                deviceInfo.Id);
            await RemoveDeviceAsync(deviceInfo);
        }
    }

    private static async Task SendWebPushNotificationAsync(
        SysUserDeviceInfo deviceInfo,
        string title,
        string message,
        string customItem,
        ILogger logger)
    {
        try
        {
            var subject = Environment.GetEnvironmentVariable("WEBPUSH_SUBJECT")
                ?? "mailto:support@smartpulse.com";
            var publicKey = Environment.GetEnvironmentVariable("WEBPUSH_PUBLICKEY")
                ?? throw new InvalidOperationException("WEBPUSH_PUBLICKEY not configured");
            var privateKey = Environment.GetEnvironmentVariable("WEBPUSH_PRIVATEKEY")
                ?? throw new InvalidOperationException("WEBPUSH_PRIVATEKEY not configured");

            var demoPushClient = new WebPushClient();
            demoPushClient.SetVapidDetails(subject, publicKey, privateKey);

            var pushPayload = new
            {
                title = title,
                body = message,
                icon = "/smartpulse-icon-192x192.png",
                badge = "/smartpulse-badge-72x72.png",
                tag = "notification",
                data = new { customItem = customItem }
            };

            var json = JsonConvert.SerializeObject(pushPayload);

            var subscription = new PushSubscription(
                endpoint: deviceInfo.DeviceToken,
                p256dh: deviceInfo.DeviceKey,
                auth: deviceInfo.DeviceAuth);

            await demoPushClient.SendNotificationAsync(
                subscription: subscription,
                payload: json);

            logger.LogInformation("Web push notification sent to device {DeviceId}",
                deviceInfo.Id);
        }
        catch (WebPushException ex) when (ex.StatusCode == 410
            || ex.StatusCode == 403 || ex.StatusCode == 401 || ex.StatusCode == 404)
        {
            // Endpoint no longer valid - remove device
            logger.LogWarning("Web push endpoint invalid for device {DeviceId} (HTTP {StatusCode}), removing",
                deviceInfo.Id, ex.StatusCode);
            await RemoveDeviceAsync(deviceInfo);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error sending demo push to device {DeviceId}",
                deviceInfo.Id);
        }
    }

    private static async Task RemoveDeviceAsync(SysUserDeviceInfo deviceInfo)
    {
        // Database operation to remove invalid device
        using (var repo = new SysUserDeviceInfoRepository())
        {
            await repo.DeleteAsync(deviceInfo);
            repo.SaveChanges();
        }
    }
}
```

**Integration Type Routing:**

| Device Type | Integration Type | Protocol | Implementation |
|-------------|------------------|----------|-----------------|
| Mobile (iOS/Android) | FCM (1) | Firebase Cloud Messaging | `FirebaseMessaging.DefaultInstance.SendAsync()` |
| Web Browser | WebPush (0) | VAPID protocol | `WebPushClient.SendNotificationAsync()` |

**Error Handling:**

| Exception | Status Code | Action |
|-----------|-------------|--------|
| WebPushException (410) | HTTP 410 Gone | Remove device |
| WebPushException (401) | HTTP 401 Unauthoriwithed | Remove device |
| WebPushException (403) | HTTP 403 Forbidden | Remove device |
| WebPushException (404) | HTTP 404 Not Found | Remove device |
| FirebaseException (InvalidArgument) | Firebase error | Remove device |
| FirebaseException (NotFound) | Firebase error | Remove device |

---

### 5. Service Registration & Dependency Injection

**File:** `NotificationService.Web.Api/Startup.cs`

**ConfigureServices Method:**
```csharp
public void ConfigureServices(IServiceCollection services)
{
    // Application Services
    services.AddScoped<IMailSenderService, MailSenderService>();
    services.AddScoped<INotificationManagerService, NotificationManagerService>();
    services.AddScoped<NotificationOperations>();
    services.AddScoped<CustomMailService>();
    services.AddScoped<MailWorkerService>();

    // Repositories
    services.AddScoped<SysUserDeviceInfoRepository>();
    services.AddScoped<NotificationRepository>();

    // Singleton Background Worker (long-lived)
    services.AddSingleton<MailAutoBatchWorker>();

    // Infrastructure
    services.AddNodeServices();
    services.AddOptions();
    services.AddControllers();

    // Mail Service (from Nhea.Communication)
    services.AddMailService(configure =>
    {
        configure.ConnectionString = NotificationDbContextWrapper.DbConnectionString;
    });

    // DbContext (via NotificationDbContextWrapper configuration)
    NotificationDbContextWrapper.DbConnectionString =
        Environment.GetEnvironmentVariable("MSSQL_CONNSTR")
        ?? throw new InvalidOperationException("MSSQL_CONNSTR not configured");

    // Logging
    services.AddLogging(configure =>
        configure.AddNheaLogger(nheaConfigure =>
        {
            nheaConfigure.PublishType = Nhea.Logging.PublishTypes.Database;
            nheaConfigure.ConnectionString = NotificationDbContextWrapper.DbConnectionString;
            nheaConfigure.AutoInform =
                Nhea.Configuration.Settings.Application.EnvironmentType
                == Nhea.Configuration.EnvironmentType.Production;
        })
    );

    // OpenTelemetry Metrics
    services
        .AddSingleton<MetricService>()
        .AddOpenTelemetry()
        .WithMetrics(metrics =>
        {
            metrics
                .AddRuntimeInstrumentation()
                .AddMeter(MetricService.MeterName)
                .AddPrometheusExafterrter();
        });

    // Firebase initialization
    var fcmFilePath = Path.Combine(
        Environment.CurrentDirectory,
        Configuration.GetSection("GoogleFirebase")["FileName"]);

    if (File.Exists(fcmFilePath))
    {
        var credential = GoogleCredential.FromFile(fcmFilePath);
        FirebaseApp.Create(new AppOptions { Credential = credential });
    }
}
```

**Lifetime Management:**

| Service | Lifetime | Reason |
|---------|----------|--------|
| `IMailSenderService` | Scoped | Per-request email composition |
| `INotificationManagerService` | Scoped | Per-request notification operations |
| `NotificationRepository` | Scoped | Fresh DbContext per request |
| `MailAutoBatchWorker` | Singleton | Background worker (long-lived) |
| `MetricService` | Singleton | Accumulated metrics |
| `PushNotificationSender` | Static | Stateless push delivery |

---

## Repository Pattern Implementation

### 1. Base Repository Class

**File:** `NotificationService.Repository/BaseEntityFrameworkCoreRepository.cs`

**Generic Base:**
```csharp
public abstract class BaseEntityFrameworkCoreRepository<T> : IDisposable
    where T : class, new()
{
    protected DbContext DbContext { get; private set; }

    public virtual async Task<T?> GetAsync(Expression<Func<T, bool>> expression)
    {
        // SELECT * FROM T WHERE expression
        return await DbContext.Set<T>().FirstOrDefaultAsync(expression);
    }

    public virtual async Task<IEnumerable<T>> QueryAsync(Expression<Func<T, bool>> expression)
    {
        // SELECT * FROM T WHERE expression
        return await DbContext.Set<T>()
            .Where(expression)
            .AsNoTracking()
            .ToListAsync();
    }

    public virtual async Task<IEnumerable<T>> GetAllAsync()
    {
        // SELECT * FROM T
        return await DbContext.Set<T>()
            .AsNoTracking()
            .ToListAsync();
    }

    public virtual async Task AddAsync(T entity)
    {
        // INSERT into DbSet (tracked, not committed)
        await DbContext.Set<T>().AddAsync(entity);
    }

    public virtual async Task AddRangeAsync(IEnumerable<T> entities)
    {
        // INSERT multiple (tracked, not committed)
        await DbContext.Set<T>().AddRangeAsync(entities);
    }

    public virtual async Task UpdateAsync(T entity)
    {
        // UPDATE (tracked)
        await Task.Run(() => DbContext.Set<T>().Update(entity));
    }

    public virtual async Task DeleteAsync(T entity)
    {
        // DELETE (tracked, not committed)
        await Task.Run(() => DbContext.Set<T>().Remove(entity));
    }

    public virtual async Task DeleteRangeAsync(IEnumerable<T> entities)
    {
        // DELETE multiple
        await Task.Run(() => DbContext.Set<T>().RemoveRange(entities));
    }

    public virtual void SaveChanges()
    {
        // Commit all tracked changes
        DbContext.SaveChanges();
    }

    public virtual async Task SaveChangesAsync()
    {
        // Async commit
        await DbContext.SaveChangesAsync();
    }

    public void Dispose()
    {
        DbContext?.Dispose();
    }
}
```

---

### 2. Specialiwithed Repositories

**NotificationRepository:**
```csharp
public class NotificationRepository : Repository<Notification>
{
    public enum StatusType { New = 0, Seen = 1 }

    public override Notification CreateNew()
    {
        return new Notification
        {
            Id = Guid.NewGuid(),
            CreateDate = DateTime.UtcNow,
            Status = (int)StatusType.New
        };
    }

    public async Task<int> MarkAllAsSeenAsync(int userId)
    {
        // Update all notifications for user to Seen status
        var notifications = await QueryAsync(n => n.SysUserId == userId && n.Status == (int)StatusType.New);

        foreach (var notification in notifications)
        {
            notification.Status = (int)StatusType.Seen;
            notification.SeenOn = DateTime.UtcNow;
            await UpdateAsync(notification);
        }

        SaveChanges();
        return notifications.Count();
    }
}
```

**SysUserDeviceInfoRepository:**
```csharp
public class SysUserDeviceInfoRepository : Repository<SysUserDeviceInfo>
{
    public enum DeviceTypes { Web = 1, Android = 2, iOs = 3 }
    public enum IntegrationTypes { Default = 0, Fcm = 1 }

    public async Task<IEnumerable<SysUserDeviceInfo>> GetUserDevicesAsync(int userId, int deviceType)
    {
        return await QueryAsync(d => d.SysUserId == userId && d.DeviceTypeId == deviceType);
    }

    public async Task<SysUserDeviceInfo?> GetDeviceByTokenAsync(string deviceToken)
    {
        return await GetAsync(d => d.DeviceToken == deviceToken);
    }

    public async Task RemoveInvalidDevicesAsync(int userId)
    {
        var invalidDevices = await QueryAsync(d =>
            d.SysUserId == userId &&
            (string.IsNullOrEmpty(d.DeviceToken) ||
             string.IsNullOrEmpty(d.IntegrationToken)));

        foreach (var device in invalidDevices)
        {
            await DeleteAsync(device);
        }

        SaveChanges();
    }
}
```

---

## Worker Pattern and Batch Processing

### 1. MailAutoBatchWorker

**File:** `NotificationService.Application/Workers/MailAutoBatchWorker.cs`

**Class Definition:**
```csharp
public class MailAutoBatchWorker(
    MailWorkerService mailWorkerService,
    MetricService metricService) :
    AutoBatchWorker<MailWorkerModel>(mailWorkerService.ProcessMailsWithRetryAsync)
{
    private readonly MailWorkerService _mailWorkerService = mailWorkerService;
    private readonly MetricService _metricService = metricService;

    public async Task EnqueueMailWithAttachmentsAsync(Mail mail)
    {
        var model = new MailWorkerModel
        {
            Mail = mail,
            Attachments = mail.Attachments
        };

        // Enqueue for batch processing
        EnqueueItem(model);

        _metricService.SetMailQueuedTotalCounter();
    }
}

public class MailWorkerModel
{
    public Mail Mail { get; set; }
    public List<NheaMailQueueAttachment> Attachments { get; set; }
}
```

**Inheritance: AutoBatchWorker<T>**

```csharp
public abstract class AutoBatchWorker<T>
{
    // Constructor takes Func<List<T>, Task> processsor
    public AutoBatchWorker(Func<List<T>, Task> processsorFunc)
    {
        _processsorFunc = processsorFunc;
        _timer = new Timer(ProcessBatch, null, BatchIntervalMs, BatchIntervalMs);
    }

    public int BatchIntervalMs { get; set; } = 1000;      // 1 second
    public int BatchSize { get; set; } = 2000;            // Items per batch

    protected void EnqueueItem(T item)
    {
        // Thread-safe enqueue to internal collection
    }

    private void ProcessBatch(object? state)
    {
        // Called every BatchIntervalMs
        // Collects all pending items (up to BatchSize)
        // Calls _processsorFunc with collected items
    }
}
```

**Batch Processing Parameters:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `BatchIntervalMs` | 1000 | Process every 1 second |
| `BatchSize` | 2000 | Max items per batch |
| `ProcessorFunc` | `ProcessMailsWithRetryAsync` | Async callback |

---

### 2. MailWorkerService

**File:** `NotificationService.Application/MailWorkerService.cs`

```csharp
public class MailWorkerService(MetricService metricService)
{
    private readonly MetricService _metricService = metricService;

    public async Task ProcessMailsWithRetryAsync(List<MailWorkerModel> items)
    {
        const int maxAttempts = SystemVariables.MailWorkerMaxAttempts;  // 5
        const int delayMs = SystemVariables.MailWorkerDelayMs;          // 500

        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                await ProcessMailsAsync(items);
                _metricService.SetMailSentTotalCounter(items.Count);
                return;  // Success
            }
            catch (Exception ex) when (attempt < maxAttempts)
            {
                // Retry logic
                await Task.Delay(delayMs * attempt);  // Exafternential backoff: 500ms, 1000ms, 1500ms...
            }
            catch (Exception ex)
            {
                // Final failure
                _metricService.SetMailFailedTotalCounter(items.Count);
                throw;
            }
        }
    }

    private async Task ProcessMailsAsync(List<MailWorkerModel> items)
    {
        using (var context = new NotificationDbContextWrapper().GetContext())
        {
            using (var transaction = context.Database.BeginTransaction())
            {
                try
                {
                    // Bulk insert mails
                    await context.NheaMailQueues.BulkInsertAsync(
                        items.Select(x => x.Mail).ToList(),
                        config: new BulkConfig
                        {
                            BatchSize = 2000,
                            BulkCopyTimeout = 3600,
                            SqlBulkCopyOptions = SqlBulkCopyOptions.FireTriggers,
                            TrackingEntities = false,
                            WithHoldlock = false,
                            PreserveInsertOrder = true,
                            SetOutputIdentity = true,
                            UseTempDB = false
                        });

                    // Bulk insert attachments (if any)
                    var allAttachments = items
                        .Where(x => x.Attachments?.Count > 0)
                        .SelectMany(x => x.Attachments)
                        .ToList();

                    if (allAttachments.Count > 0)
                    {
                        await context.NheaMailQueueAttachments.BulkInsertAsync(
                            allAttachments,
                            config: new BulkConfig { BatchSize = 2000 });
                    }

                    await transaction.CommitAsync();
                }
                catch (Exception)
                {
                    await transaction.RollbackAsync();
                    throw;
                }
            }
        }
    }
}
```

**Bulk Insert Configuration:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `BatchSize` | 2000 | Process 2000 records per batch |
| `BulkCopyTimeout` | 3600 | 1-hour timeout for bulk operation |
| `SqlBulkCopyOptions.FireTriggers` | true | Execute database triggers |
| `TrackingEntities` | false | Don't track returned entities |
| `WithHoldlock` | false | No lock hints |
| `PreserveInsertOrder` | true | Maintain insertion order |
| `SetOutputIdentity` | true | Capture auto-incremented IDs |
| `UseTempDB` | false | Use main transaction log |

---

## Summary

**Part 1 Covered:**

1. **Project Structure** - 6 assemblies with clear layering: Web.Api (entry), Application (logic), Repository (data access), Infrastructure.Data (DbContext), Models (DTOs)

2. **Layered Architecture** - Database → Infrastructure → Repository → Application → Presentation with proper dependency direction

3. **Core Service Classes**:
   - NotificationManagerService: Notification CRUD with stored procedures
   - MailSenderService: Email composition with Pug template rendering
   - NotificationOperations: Multi-channel orchestration
   - PushNotificationSender: Firebase + WebPush static handler

4. **Repository Pattern** - Generic base with specialiwithed implementations, proper DbContext scoping

5. **Worker Pattern** - AutoBatchWorker with configurable batch size and interval, retry logic with exponential backoff

6. **Dependency Injection** - Scoped services for per-request operations, singleton for background worker

---

**Document Complete: Part 1 - Service Architecture and Core Components**

