# ProductionForecast - Data Layer & Entities

**Component:** ProductionForecast Service
**Layer:** Data Access Layer

---

## ⚠️ CRITICAL - ProductionForecast Caching & Messaging

**ProductionForecast uses:**
- ✅ IMemoryCache (local in-memory cache ONLY)
- ✅ OutputCache middleware (ASP.NET Core)
- ✅ Electric.Core for CDC (Change Data Capture - cache invalidation trigger)

**ProductionForecast does NOT use:**
- ❌ Redis (no distributed cache)
- ❌ Apache Pulsar (no messaging)
- ❌ DistributedDataManager
- ❌ Electric.Core Pulsar features

---


## Overview

The ProductionForecast data layer provides the foundation for all forecast data storage, retrieval, and management. Built on Entity Framework Core with SQL Server, it implements temporal tables for audit trails and optimized query patterns.

**Key Features:**
- **Temporal Tables**: Automatic history tracking for CompanyPowerPlants and CompanyProperties
- **Composite Primary Keys**: Natural key constraints reflecting business domain
- **Query Optimization**: Strategic indexes on hot columns (UnitNo, DeliveryStart, ProviderKey)
- **Bulk Operations**: Batch inserts via trigger-based staging tables
- **Table-Valued Functions**: SQL Server TVFs for complex forecast queries
- **Connection Resilience**: Retry policy with exponential backoff

---

## Database Context

### ForecastDbContext

**Location**: `SmartPulse.Entities/Sql/ForecastDbContext.cs`

The central database context managing entity collections spanning forecast data, organizational hierarchy, and security.

**Inheritance Chain**:
```
ForecastDbContext
    ?
Infrastructure.Data.BaseDbContext
    ?
Microsoft.EntityFrameworkCore.DbContext
```

**Key DbSets**:
- **Forecast Core** (6): T004Forecast, T004ForecastBatchInfo, T004ForecastBatchInsert, T004ForecastLock, T004ForecastLockBatchInfo, T004ForecastProviderKey
- **Organization** (6): PowerPlant, PowerPlantType, CompanyPowerPlant, CompanyProperty, GroupCompany, GroupProperty
- **Security** (4): SysRole, SysRoleAppPermission, SysUserRole, SysApplication
- **Entity Management** (3): T000EntitySystemHierarchy, T000EntityPermission, T000EntityProperty
- **Query Models** (3): UnitForecastEntity, UnitForecastLatestEntity, MunitForecastsCurrentActiveLocksEntity

**Database Functions**:
- `sv000get_unit_unix_timezone` - Get unit timezone
- `tb004get_munit_forecasts_use_pointofdatetime` - Get forecasts at specific point in time
- `tb004get_munit_forecasts_latest` - Get latest forecasts
- `tb004get_munit_forecasts_latest_with_full_series` - Get full series of latest forecasts
- `tb004get_munit_forecasts_use_deliverystartdatetimebefore` - Get forecasts before delivery start
- `tb004get_munit_forecasts_current_active_locks` - Get current active locks

**Connection Configuration**:
```csharp
optionsBuilder.UseSqlServer(connectionString, options =>
{
    options.EnableRetryOnFailure(
        maxRetryCount: 5,
        maxRetryDelay: TimeSpan.FromSeconds(30),
        errorNumbersToAdd: new List<int>() { 19 })
    .CommandTimeout(180)
    .MaxBatchSize(1)
    .TranslateParameterizedCollectionsToConstants();
});
```

---

## Entity Models

### T004Forecast (Main Table)

**Purpose**: Central forecast data table storing all production predictions

**Schema**:
```csharp
public class T004Forecast
{
    // Composite PK (7 columns)
    public Guid BatchId { get; set; }
    public string UnitType { get; set; }        // Max 5 chars
    public int UnitNo { get; set; }             // Unit identifier (int)
    public DateTimeOffset DeliveryStart { get; set; }
    public DateTimeOffset DeliveryEnd { get; set; }
    public string ProviderKey { get; set; }     // Max 50 chars
    public DateTimeOffset ValidAfter { get; set; }

    // Data column
    public decimal? PredictionValue { get; set; }  // decimal(36,4)
}
```

**Database Table**: `t004forecast`

**Indexes**:
1. PK: `pk_t004forecast` (BatchId, UnitType, UnitNo, DeliveryStart, DeliveryEnd, ProviderKey, ValidAfter)
2. IX: `ix_t004forecast-delivery_start-delivery_end-provider_key-unit_type-unit_no-valid_after`
3. IX: `ix_t004forecast-valid_after-provider_key-unit_type-unit_no-delivery_start-delivery_end`

### T004ForecastBatchInfo

**Purpose**: Metadata tracking for batch operations

```csharp
public class T004ForecastBatchInfo
{
    public Guid BatchId { get; set; }           // PK (newsequentialid())
    public string? Note { get; set; }           // Max 255 chars
    public DateTimeOffset StartTime { get; set; }
    public DateTimeOffset? EndTime { get; set; } // Computed
    public int UserId { get; set; }
    public byte FromSystem { get; set; }
    public int RequestedRecordCount { get; set; } // Computed
    public int AffectedRecordCount { get; set; }  // Computed
    public byte UseAlgorithmForDateTime { get; set; }

    // Navigation
    public virtual ICollection<T004ForecastBatchInsert> T004forecastBatchInserts { get; }
}
```

**Database Table**: `t004forecast_batch_info`

### T004ForecastBatchInsert

**Purpose**: Staging table for batch inserts with trigger-based processing

```csharp
public class T004ForecastBatchInsert
{
    // Composite PK (same as T004Forecast)
    public Guid BatchId { get; set; }
    public string UnitType { get; set; }
    public int UnitNo { get; set; }
    public DateTimeOffset DeliveryStart { get; set; }
    public DateTimeOffset DeliveryEnd { get; set; }
    public string ProviderKey { get; set; }
    public DateTimeOffset ValidAfter { get; set; }

    public decimal? PredictionValue { get; set; }
    public int? MeasureUnit { get; set; }

    // Navigation
    public virtual T004ForecastBatchInfo Batch { get; set; }
}
```

**Database Table**: `t004forecast_batch_insert`
**Trigger**: `trii_t004forecast_batch_insert` - Processes inserts into main forecast table

### T004ForecastLock

**Purpose**: Forecast lock management for specific time periods

```csharp
public class T004ForecastLock
{
    // Composite PK (5 columns)
    public Guid BatchId { get; set; }
    public string UnitType { get; set; }
    public int UnitNo { get; set; }
    public DateTimeOffset DeliveryStart { get; set; }
    public DateTimeOffset DeliveryEnd { get; set; }

    public bool Enabled { get; set; }
    public DateTimeOffset UpdatedDate { get; set; }
    public int UpdatedUserId { get; set; }

    // Navigation
    public virtual T004ForecastLockBatchInfo Batch { get; set; }
}
```

**Database Table**: `t004forecast_lock`

### T004ForecastProviderKey

**Purpose**: Provider key tracking per unit

```csharp
public class T004ForecastProviderKey
{
    // Composite PK
    public string UnitType { get; set; }
    public int UnitNo { get; set; }
    public string ProviderKey { get; set; }

    public DateTimeOffset FirstInsertDate { get; set; }
    public DateTimeOffset LastInsertDate { get; set; }
    public int? MeasureUnit { get; set; }
}
```

**Database Table**: `t004forecast_provider_key`
**Trigger**: `trai_t004forecast_provider_key` - Auto-updates on insert

### PowerPlant

**Purpose**: Power plant master data

```csharp
public class PowerPlant
{
    public int Id { get; set; }                  // PK
    public string Name { get; set; }             // Unique, max 512 chars
    public int TypeId { get; set; }              // FK to PowerPlantType
    public double? Lat { get; set; }
    public double? Lon { get; set; }
    public double InstalledPowerMW { get; set; }
    public double? InstalledMechanicPowerMW { get; set; }
    public string DataIpAddress { get; set; }
    public int DataRegisterNo { get; set; }
    public string? WebChartColor { get; set; }
    public int TimeZoneOffset { get; set; }
    public bool? IsActive { get; set; }
    public string? LocationIklimCoName { get; set; }
    public string? LocationIklimCoId { get; set; }
    public string? Ru5Location { get; set; }
    public string? AdditionalSettings { get; set; }
    public bool? IsSfk { get; set; }
    public int? QuestionLimit { get; set; }
    public bool? InstructionsEnabled { get; set; }
    public bool? DgpReviseSettings { get; set; }
    public string Timezone { get; set; }         // Default: 'Europe/Istanbul'

    // Navigation
    public virtual PowerPlantType Type { get; set; }
    public virtual ICollection<CompanyPowerPlant> CompanyPowerPlants { get; }
}
```

**Database Table**: `PowerPlant`

### CompanyPowerPlant

**Purpose**: Many-to-many mapping between companies and power plants

```csharp
public class CompanyPowerPlant
{
    public int Id { get; set; }
    public int CompanyId { get; set; }
    public int PowerPlantId { get; set; }        // FK to PowerPlant

    // Navigation
    public virtual PowerPlant PowerPlant { get; set; }
}
```

**Database Table**: `CompanyPowerPlants`
**Temporal Table**: `CompanyPowerPlants_History` (ValidFrom, ValidTo)

### Security Entities

#### SysUserRole

```csharp
public class SysUserRole
{
    public int Id { get; set; }                  // PK (Identity)
    public int UserId { get; set; }
    public int RoleId { get; set; }              // FK to SysRole

    // Navigation
    public virtual SysRole SysRole { get; set; }
}
```

#### SysRoleAppPermission

```csharp
public class SysRoleAppPermission
{
    public int Id { get; set; }                  // PK (Identity)
    public int RoleId { get; set; }
    public long ApplicationId { get; set; }
}
```

---

## Query Models

### UnitForecastEntity

**Purpose**: Result type for forecast queries via TVFs

```csharp
public class UnitForecastEntity
{
    public decimal Value { get; set; }           // decimal(36,4)
    // Additional properties mapped from TVF results
}
```

**Usage**: Keyless entity for `tb004get_munit_forecasts_use_pointofdatetime`

### UnitForecastLatestEntity

**Purpose**: Result type for latest forecast queries

```csharp
public class UnitForecastLatestEntity
{
    public decimal Value { get; set; }           // decimal(36,4)
    // Additional properties mapped from TVF results
}
```

**Usage**: Keyless entity for `tb004get_munit_forecasts_latest`

### MunitForecastsCurrentActiveLocksEntity

**Purpose**: Result type for active locks query

```csharp
public class MunitForecastsCurrentActiveLocksEntity
{
    // Properties mapped from tb004get_munit_forecasts_current_active_locks
}
```

---

## Database Schema

### T004Forecast Table

```sql
CREATE TABLE t004forecast (
    batch_id UNIQUEIDENTIFIER NOT NULL,
    unit_type NVARCHAR(5) NOT NULL,
    unit_no INT NOT NULL,
    delivery_start DATETIME2(0) NOT NULL,
    delivery_end DATETIME2(0) NOT NULL,
    provider_key NVARCHAR(50) NOT NULL,
    valid_after DATETIME2(2) NOT NULL,
    prediction_value DECIMAL(36,4) NULL,
    CONSTRAINT pk_t004forecast PRIMARY KEY (
        batch_id, unit_type, unit_no, delivery_start,
        delivery_end, provider_key, valid_after
    )
);

-- Indexes
CREATE INDEX ix_t004forecast_delivery
    ON t004forecast (delivery_start, delivery_end, provider_key,
                     unit_type, unit_no, valid_after);

CREATE INDEX ix_t004forecast_valid_after
    ON t004forecast (valid_after, provider_key, unit_type,
                     unit_no, delivery_start, delivery_end);
```

### Temporal Tables

```sql
-- CompanyPowerPlants with temporal support
CREATE TABLE CompanyPowerPlants (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId INT NOT NULL,
    PowerPlantId INT NOT NULL,
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START,
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = dbo.CompanyPowerPlants_History
));
```

---

## Query Patterns

### Using Table-Valued Functions

```csharp
// Get latest forecasts for a unit
var forecasts = await _context.MunitForecastsLatest(
    unitType: "WIND",
    unitNo: 123,
    providerKey: "provider1",
    from: DateTimeOffset.UtcNow.AddDays(-7),
    to: DateTimeOffset.UtcNow,
    resolution: 60,
    useAlgorithmForDateTime: 0
).ToListAsync();

// Get active locks
var locks = await _context.MunitForecastsCurrentActiveLocks(
    unitType: "SOLAR",
    unitNo: 456,
    fromDateTime: DateTimeOffset.UtcNow,
    toDateTime: DateTimeOffset.UtcNow.AddDays(1)
).ToListAsync();
```

### N+1 Query Prevention

```csharp
// BAD: N+1 queries
var plants = await _context.PowerPlants.ToListAsync();
foreach (var plant in plants)
{
    var companies = plant.CompanyPowerPlants;  // N queries!
}

// GOOD: Single query with includes
var plants = await _context.PowerPlants
    .Include(p => p.CompanyPowerPlants)
    .ToListAsync();
```

### AsNoTracking for Read-Only Queries

```csharp
// Read-only queries don't need change tracking
var forecasts = await _context.T004Forecasts
    .AsNoTracking()
    .Where(f => f.UnitNo == unitNo)
    .ToListAsync();
```

**Performance**: 15-30% faster, 40-60% less memory

---

## Best Practices

- **Composite Keys** - Reflect natural business constraints
- **Temporal Tables** - Automatic audit history for key entities
- **Strategic Indexes** - Covering indexes on hot query paths
- **TVFs** - Use table-valued functions for complex forecast queries
- **Trigger-based Inserts** - Staging table pattern for batch processing
- **NoTracking** - Read-only queries use `.AsNoTracking()`
- **Connection Resilience** - Retry policy with 5 attempts, 30s max delay

---

## Related Documentation

- [ProductionForecast Web API Layer](./web_api_layer.md)
- [Business Logic & Caching](./business_logic_caching.md)
- [HTTP Client & Models](./http_client_models.md)
- [ProductionForecast README](./README.md)
- [EF Core Configuration](../../data/ef_core.md)
- [CDC Architecture](../../data/cdc.md)

