# ProductionForecast - HTTP Client & Models

**Component:** ProductionForecast Service
**Layer:** HTTP Communication & Data Transfer
**Last Updated:** 2025-11-13

---

## ⚠️ NOTE - ProductionForecast Simple Architecture

ProductionForecast uses IMemoryCache (local only), NOT Redis or Pulsar.
Electric.Core used ONLY for CDC (Change Data Capture).

---

## Overview

The ProductionForecast HTTP client layer provides communication with the Production Forecast API using modern .NET HTTP patterns. It implements automatic compression, request/response serialization, and comprehensive error handling.

**Key Features:**
- **Factory Pattern**: `IHttpClientFactory` for connection pooling and lifecycle management
- **GZIP Compression**: Automatic compression for large payloads (40-60% size reduction)
- **Request Normalization**: Reduces payload size by de-duplicating repeated values
- **Resilience**: Retry policies with exponential backoff
- **Distributed Tracing**: X-Internal-Trace-Id header propagation
- **Custom Serialization**: Optimized JSON serialization with property name compression

---

## HTTP Client Layer

### PFClient - Production Forecast HTTP Client

**Location**: `SmartPulse.Services.ProductionForecast/PFClient.cs`

**Pattern**: Adapter pattern wrapping `IHttpClientFactory`

**Class Definition**:
```csharp
public class PFClient : IProductionForecastService
{
    private readonly ILogger<IProductionForecastService> _logger;
    private readonly IHttpClientFactory _httpClientFactory;

    public string HttpClientName =>
        httpClientNameOverride ?? PFApi.HttpClientName;

    public HttpClient HttpClient =>
        _httpClientFactory.CreateClient(HttpClientName);

    public PFClient WithHttpClient(string httpClientName)
    {
        httpClientNameOverride = httpClientName;
        return this;
    }
}
```

**HTTP Client Registration**:
```csharp
services.AddHttpClient<IProductionForecastService, PFClient>(client =>
{
    client.DefaultRequestHeaders.Add("User-Agent", "SmartPulse.Services.ProductionForecast");
    client.Timeout = TimeSpan.FromSeconds(options.HttpClientTimeoutSeconds);
})
.AddTransientHttpErrorPolicy(p =>
    p.WaitAndRetryAsync(3, retryAttempt =>
        TimeSpan.FromSeconds(Math.Pow(2, retryAttempt))));
```

---

## API Methods

### GetLatest - Single Unit Query

**Method**:
```csharp
public async Task<ApiResponse<IEnumerable<IUnitForecast>>> GetLatest(
    string providerKey,
    UnitType unitType,
    int unitNo,
    ForecastGetQuery query,
    string traceId,
    DateTimeOffset? ifModifiedSince = null,
    int? userId = null)
```

**Endpoint**: `GET /api/v{version}/production-forecast/{providerKey}/{unitType}/{unitNo}/forecasts/latest`

**Query Parameters**:
- `from`: Start date (ISO 8601)
- `to`: End date (ISO 8601)
- `period`: Minutes (5, 10, 15, 30, 60)
- `no-details`: Boolean (remove metadata)

**Headers**:
- `X-Internal-Trace-Id`: Distributed tracing identifier
- `X-Internal-User-Id`: User context for audit
- `If-Modified-Since`: HTTP 304 caching support

**Performance**: ~50-150ms depending on network latency

### GetLatestMulti - Batch Query

**Method**:
```csharp
public async Task<ApiResponse<IEnumerable<IUnitForecast>>> GetLatestMulti(
    GetForecastMultiModel multiModel,
    string traceId,
    DateTimeOffset? ifModifiedSince = null)
```

**Endpoint**: `POST /api/v{version}/production-forecast/multi`

**Request Body**:
```csharp
public class GetForecastMultiModel
{
    public required string ProviderKey { get; set; }
    public required UnitType UnitType { get; set; }
    public int[]? UnitIds { get; set; }  // Null = all units
    public ForecastGetRequestMultiQuery Query { get; set; }
}
```

**Batch Performance**:
- 5-20 units: ~80-200ms
- 50+ units: ~200-500ms

**Optimization**: Reduces HTTP round-trips vs individual GetLatest calls

### Save - Forecast Data Persistence

**Method**:
```csharp
public async Task<ApiResponse<IEnumerable<IBatchForecast>>> Save(
    string providerKey,
    UnitType unitType,
    int unitNo,
    ForecastSaveQuery query,
    ForecastSaveRequestBody body,
    string traceId)
```

**Endpoint**: `POST /api/v{version}/production-forecast/{providerKey}/{unitType}/{unitNo}/forecasts`

**Request Processing**:
1. Normalize request body (compress repeated values)
2. Serialize to JSON
3. Compress with GZIP if payload > 1KB
4. Add trace headers
5. Send request

**Payload Optimization**: 40-60% reduction for large forecast batches

---

## GZIP Compression Handler

**File**: `GzipHandler.cs`

**Pattern**: Delegating HTTP message handler

```csharp
internal class GzipHandler : DelegatingHandler
{
    private const int MinimumPayloadSize = 1024;  // Don't compress <1KB

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        if ((request.Method == HttpMethod.Post || request.Method == HttpMethod.Put)
            && request.Content != null)
        {
            var originalContent = await request.Content.ReadAsStringAsync(cancellationToken);

            if (originalContent.Length < MinimumPayloadSize)
                return await base.SendAsync(request, cancellationToken);

            var compressedBytes = CompressContent(originalContent);
            var compressedContent = new ByteArrayContent(compressedBytes);
            compressedContent.Headers.ContentEncoding.Add("gzip");

            request.Content = compressedContent;
        }

        return await base.SendAsync(request, cancellationToken);
    }
}
```

**Performance Impact**:
- Compression time: ~5-15ms
- Payload reduction: 40-60%
- Network savings: 200-400ms for large forecasts
- Net gain: 150-300ms per operation

---

## Request/Response Models

### ApiResponse<T>

```csharp
public class ApiResponse<T> : IApiResponse<T> where T : class
{
    public int StatusCode { get; set; }
    public bool IsError { get; set; }
    public string Message { get; set; }
    public string? TraceId { get; set; }
    public Dictionary<string, object?>? AdditionalData { get; set; }
    public T? Data { get; set; }

    public void EnsureSuccess()
    {
        if (IsError)
            throw new ApiException(Message, this, StatusCode);
    }

    // Factory methods
    public static ApiResponse<T> Success(T? value = default, string? traceId = null)
    public static ApiResponse<T> NotModified(string? traceId = null)
    public static ApiResponse<T> InternalServerError(T? value = default, string? traceId = null)
    public static ApiResponse<T> BadRequest(string message, string? traceId = null)
}
```

**Success Response Example**:
```json
{
  "statusCode": 200,
  "isError": false,
  "message": "OK",
  "traceId": "3a2b1c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
  "data": [
    {
      "unitNo": 1,
      "period": 60,
      "predictions": [...]
    }
  ]
}
```

**Error Response Example**:
```json
{
  "statusCode": 400,
  "isError": true,
  "message": "Validation Error",
  "traceId": "3a2b1c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
  "additionalData": {
    "Period": ["Period must be one of: 1, 5, 10, 15, 30, 60"]
  },
  "data": null
}
```

### Exception Hierarchy

```csharp
// Base exception
public class ApiException : Exception
{
    public virtual int StatusCode { get; set; } = 500;
    public virtual bool ShouldBeTreatedAsError { get; set; } = true;
}

// Specific exceptions
public class BadRequestException : ApiException
{
    public override int StatusCode { get; set; } = 400;
    public override bool ShouldBeTreatedAsError { get; set; } = false;
}

public class ExistingDataException : ApiException
{
    public override int StatusCode { get; set; } = 204;
    public override bool ShouldBeTreatedAsError { get; set; } = false;
}

public class AuthorizationException : ApiException
{
    public override int StatusCode { get; set; } = 403;
    public override bool ShouldBeTreatedAsError { get; set; } = false;
}
```

---

## Forecast Data Models

### UnitForecast

```csharp
public class UnitForecast : IUnitForecast
{
    public int UnitNo { get; set; }
    public IPrediction[] Predictions { get; set; } = Array.Empty<Prediction>();
    public int Period { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? ApplyFinalForecast { get; set; } = null;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? ConformUpperLimit { get; set; } = null;
}
```

### NormalizedUnitForecast

```csharp
public class NormalizedUnitForecast : UnitForecast
{
    public required DateTimeOffset FirstDeliveryStart { get; set; }

    // Compression: Store arrays of unique values
    public List<string?>? BatchNotes { get; set; }
    public List<string?>? Providers { get; set; }
    public List<DateTimeOffset?>? CreateDates { get; set; }

    public NormalizedUnitForecast Denormalize()
    {
        // Reverses normalization - expands compressed arrays
        if (NormalizedPredictions?.Count > 0)
        {
            Predictions = NormalizedPredictions.Select(np => new Prediction
            {
                DeliveryStart = np.DeliveryStart,
                Value = np.Value,
                CreateDate = np.CreateDateIndex.HasValue ? CreateDates?[np.CreateDateIndex.Value] : null,
                BatchNote = np.BatchNoteIndex.HasValue ? BatchNotes?[np.BatchNoteIndex.Value] : null,
                ProviderKey = np.ProviderIndex.HasValue ? Providers?[np.ProviderIndex.Value] : null
            }).ToArray();
        }
        return this;
    }
}
```

**Normalization Example**:

Before normalization (2.5 KB):
```json
{
  "unitNo": 1,
  "period": 60,
  "predictions": [
    {
      "ds": "2024-01-01T00:00:00+03:00",
      "v": 450.5,
      "c": "2024-01-01T10:30:00+03:00",
      "bn": "Batch A",
      "pk": "provider1"
    },
    {
      "ds": "2024-01-01T01:00:00+03:00",
      "v": 455.2,
      "c": "2024-01-01T10:30:00+03:00",
      "bn": "Batch A",
      "pk": "provider1"
    }
  ]
}
```

After normalization (1.2 KB):
```json
{
  "unitNo": 1,
  "period": 60,
  "fds": "2024-01-01T00:00:00+03:00",
  "bns": ["Batch A"],
  "ps": ["provider1"],
  "cs": ["2024-01-01T10:30:00+03:00"],
  "predictions": [
    { "idx": 0, "ds": "2024-01-01T00:00:00+03:00", "v": 450.5, "ci": 0, "bni": 0, "pi": 0 },
    { "idx": 1, "ds": "2024-01-01T01:00:00+03:00", "v": 455.2, "ci": 0, "bni": 0, "pi": 0 }
  ]
}
```

**Compression Ratio**: 50-60% reduction

### Prediction

```csharp
public class Prediction : IPrediction
{
    public DateTimeOffset DeliveryStart { get; set; }
    public decimal? Value { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? CreateDate { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BatchNote { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ProviderKey { get; set; }

    public int MeasureUnit { get; set; } = 1;  // Default to MW
}
```

### BatchForecast

```csharp
public class BatchForecast : IBatchForecast
{
    public required Guid BatchId { get; set; }
    public required string ProviderKey { get; set; }
    public List<IUnitForecast> UnitForecasts { get; set; } = new();

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<BatchError>? Errors { get; set; }

    public void AddError(string code, string message, int unitNo, int period, IEnumerable<ErrorDelivery> deliveries)
    {
        Errors ??= new();
        Errors.Add(new BatchError(code, message, unitNo, period, deliveries.ToList()));
    }
}
```

### BatchError

```csharp
public class BatchError
{
    public int UnitNo { get; set; }
    public int Period { get; set; }
    public List<ErrorDelivery> Deliveries { get; set; }
    public string Message { get; set; }
    public string Code { get; set; }

    // Predefined error factories
    public static BatchError LowerLimit(int unitNo, int period)
    public static BatchError UpperLimit(int unitNo, int period)
    public static BatchError NoPredictions(int unitNo, int period)
    public static BatchError DuplicateDeliveries(int unitNo, int period, List<ErrorDelivery> deliveries)
    public static BatchError ExistingPredictions(int unitNo, int period)
}
```

---

## Configuration

### SystemVariables

```csharp
public static class SystemVariables
{
    public const string ServiceName = "ProductionForecast";
    public const int AdminUserId = 1;
    public const string IstanbulTimeZone = "Europe/Istanbul";
    public const int DefaultRoundingDigit = 2;

    // Environment-configured
    public static List<int> AllowedPeriods { get; private set; } = new() { 5, 10, 15, 30, 60 };
    public static string SelfRequestUrl { get; private set; } = "http://127.0.0.1:8080";
    public static bool ShouldNotifyPositionService { get; private set; } = true;

    public static void Refresh()
    {
        AllowedPeriods = GetAllowedPeriods().ToList();
        ShouldNotifyPositionService = GetBoolEnvironmentVariable("NOTIFY_POSITION_SERVICE", true);
        // ... more environment variable loading
    }
}
```

**Environment Variables**:
- `EMAIL_LIST`: Notification email addresses
- `SELF_REQ_URL`: Internal service URL
- `ALLOWED_PERIODS`: Valid period values (comma-separated)
- `NOTIFY_POSITION_SERVICE`: Enable position service notifications
- `LOG_CDC`: Log CDC operations

---

## Serialization Strategy

### JSON Options

```csharp
public static class PFApi
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
        Converters =
        {
            new JsonStringEnumConverter(),
            new DateTimeOffsetJsonConverter()
        }
    };
}
```

### Property Name Compression

**Bandwidth Optimization**:

| Property | Compact | Reason |
|----------|---------|--------|
| DeliveryStart | ds | Appears in every prediction |
| DeliveryEnd | de | Appears in every prediction |
| UnitNo | uId | Repeated across forecasts |
| Period | px | Repeated in periods |
| Value | v | Core forecast value |
| BatchNote | bn | Batch notes |
| ProviderKey | pk | Provider identifier |
| CreateDate | c | Creation timestamp |

---

## Thread Safety & Performance

### HTTP Client Safety

**Connection Pooling**:
- `IHttpClientFactory` manages pools
- Default pool lifetime: 2 minutes
- Thread-safe factory instances
- Automatic socket reuse

**Request Concurrency**:
- Multiple concurrent requests supported
- No locking required for operations
- Factory handles connection management

### Serialization Performance

**Benchmarks** (typical 100-unit forecast batch):

| Operation | Time | Memory |
|-----------|------|--------|
| Serialize to JSON | 2-5ms | 150-250 KB |
| Normalize payload | 3-8ms | 50-100 KB |
| GZIP compress | 5-15ms | 50-100 KB |
| Deserialize from JSON | 2-5ms | 100-150 KB |
| Decompress GZIP | 2-5ms | 150-250 KB |
| Denormalize | 3-8ms | 100-150 KB |

---

## Validation

### Custom Validation Attributes

```csharp
[AttributeUsage(AttributeTargets.Property)]
public class DateRangeAttribute : ValidationAttribute
{
    protected override ValidationResult? IsValid(object? value, ValidationContext validationContext)
    {
        if (value is DateTimeOffset startDate)
        {
            var endDateProperty = validationContext.ObjectType.GetProperty(_endDatePropertyName);
            if (endDateProperty?.GetValue(validationContext.ObjectInstance) is DateTimeOffset endDate)
            {
                if (startDate > endDate)
                    return new ValidationResult("Start date cannot be after end date.");
            }
        }
        return ValidationResult.Success;
    }
}

[AttributeUsage(AttributeTargets.Property)]
public class PeriodAttribute : ValidationAttribute
{
    protected override ValidationResult? IsValid(object? value, ValidationContext validationContext)
    {
        if (value is int period)
        {
            if (!SystemVariables.AllowedPeriods.Contains(period))
                return new ValidationResult($"Period must be one of: {string.Join(", ", SystemVariables.AllowedPeriods)}");
        }
        return ValidationResult.Success;
    }
}
```

---

## Related Documentation

- [ProductionForecast Web API Layer](./web_api_layer.md)
- [Business Logic & Caching](./business_logic_caching.md)
- [Data Layer & Entities](./data_layer_entities.md)
- [ProductionForecast README](./README.md)
- [Electric Core](../electric_core.md)
- [Integration](../../integration/.md)
- [Redis Integration](../../integration/redis.md)

---

**Last Updated**: 2025-11-13
**Version**: 1.0
**Status**: Production
