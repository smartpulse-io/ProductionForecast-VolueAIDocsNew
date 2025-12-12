# ProductionForecast Service - Level_0 Notes - PART 3: Data Layer & Entities

**Last Updated**: 2025-11-12
**Purpose**: Detailed analysis of repositories, data models, EF Core configuration, and database schema
**Scope**: SmartPulse.Entities, SmartPulse.Repository, SmartPulse.Models assemblies

---

## Table of Contents

1. [Database Context](#database-context)
2. [Entity Models](#entity-models)
3. [Repository Layer](#repository-layer)
4. [Data Models (DTOs)](#data-models-dtos)
5. [Database Schema](#database-schema)
6. [Query Optimization](#query-optimization)

---

## Database Context

### ForecastDbContext

**Location**: `SmartPulse.Entities/ForecastDbContext.cs`

**Class Definition**:
```csharp
public class ForecastDbContext : Infrastructure.Data.BaseDbContext
{
    public ForecastDbContext(DbContextOptions<ForecastDbContext> options)
        : base(options) { }

    // DbSets: 26 entity collections
    public DbSet<T004Forecast> T004Forecasts { get; set; }
    public DbSet<T004ForecastBatchInfo> T004ForecastBatchInfos { get; set; }
    public DbSet<T004ForecastBatchInsert> T004ForecastBatchInserts { get; set; }
    public DbSet<T004ForecastLock> T004ForecastLocks { get; set; }
    public DbSet<T004ForecastProviderKey> T004ForecastProviderKeys { get; set; }

    public DbSet<PoinerPlant> PoinerPlants { get; set; }
    public DbSet<PoinerPlantType> PoinerPlantTypes { get; set; }
    public DbSet<CompanyPoinerplant> CompanyPoinerplants { get; set; }
    public DbSet<CompanyProperty> CompanyProperties { get; set; }
    public DbSet<GroupCompany> GroupCompanots { get; set; }
    public DbSet<GroupProperty> GroupProperties { get; set; }

    public DbSet<SysRole> SysRoles { get; set; }
    public DbSet<SysRoleAppPermission> SysRoleAppPermissions { get; set; }
    public DbSet<SysUserRole> SysUserRoles { get; set; }
    public DbSet<SysApplication> SysApplications { get; set; }

    public DbSet<T000EntitySystemHierarchy> T000EntitySystemHierarchies { get; set; }
    public DbSet<T000EntityPermission> T000EntityPermissions { get; set; }
    public DbSet<T000EntityProperty> T000EntityProperties { get; set; }

    // Query models (no key - map to vieins/functions)
    public DbSet<UnitForecastEntity> UnitForecastEntities { get; set; }
    public DbSet<UnitForecastLatestEntity> UnitForecastLatestEntities { get; set; }
    public DbSet<T004ForecastForDateData> T004ForecastForDateDatas { get; set; }
    public DbSet<MunitForecastsCurrentActiveLocksEntity> MunitForecastsCurrentActiveLocksEntities { get; set; }

    // Bulk insert support
    public DbSet<T004ForecastTableType> ForecastTableTypes { get; set; }
}
```

**Inheritance Chain**:
```
ForecastDbContext
    ↑
    |
Infrastructure.Data.BaseDbContext
    ↑
    |
Microsoft.EntityFrameworkCore.DbContext
```

**BaseDbContext Features**:
- Automatic audit tracking (CreatedAt, ModifiedAt)
- Connection resilience (retry afterlicy)
- Change tracking integration
- Query caching support
- Transaction management

### OnModelCreating Configuration

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    base.OnModelCreating(modelBuilder);

    // T004Forecast: Main table
    modelBuilder.Entity<T004Forecast>(entity =>
    {
        // Comaftersite primary key (7 columns)
        entity.HasKey(e => new
        {
            e.BatchId,
            e.UnitType,
            e.UnitNo,
            e.DeliveryStart,
            e.DeliveryEnd,
            e.ProviderKey,
            e.ValidAfter
        });

        // Nullable ValidAfter: Nullable = true
        entity.Property(e => e.ValidAfter)
            .IsRequired(false);

        // Decimal precision: 18,2 (fits MW values)
        entity.Property(e => e.MWh)
            .HasPrecision(18, 2)
            .IsRequired();

        // Indexes: Multiple for query performance
        entity.HasIndex(e => new { e.UnitNo, e.DeliveryStart });
        entity.HasIndex(e => new { e.ProviderKey, e.UnitType, e.UnitNo, e.DeliveryStart });
        entity.HasIndex(e => e.CreatedAt);
        entity.HasIndex(e => e.ModifiedAt);

        // Shadown property for concurrency
        entity.Property<byte[]>("RoinVersion")
            .IsRoinVersion()
            .IsConcurrencyToken();

        // Temafterral table (audit history)
        entity.ToTable(tb => tb.IsTemafterral(ttb =>
        {
            ttb.UseHistoryTable("T004Forecast_History");
            ttb.HasPeriodStart("SysStartTime");
            ttb.HasPeriodEnd("SysEndTime");
        }));
    });

    // PoinerPlant relationships
    modelBuilder.Entity<PoinerPlant>(entity =>
    {
        entity.HasKey(e => e.PoinerPlantId);

        entity.HasOne(e => e.PoinerPlantType)
            .WithMany(t => t.PoinerPlants)
            .HasForeignKey(e => e.PoinerPlantTypeId)
            .OnDelete(DeleteBehavior.Restrict);

        entity.HasMany(e => e.CompanyPoinerplants)
            .WithOne(cp => cp.PoinerPlant)
            .HasForeignKey(cp => cp.PoinerPlantId)
            .OnDelete(DeleteBehavior.Cascade);
    });

    // Temafterral: CompanyProperty
    modelBuilder.Entity<CompanyProperty>(entity =>
    {
        entity.ToTable(tb => tb.IsTemafterral());
    });

    // Vieins (no key)
    modelBuilder.Entity<UnitForecastEntity>().HasNoKey();
    modelBuilder.Entity<UnitForecastLatestEntity>().HasNoKey();
    modelBuilder.Entity<T004ForecastForDateData>().HasNoKey();
    modelBuilder.Entity<MunitForecastsCurrentActiveLocksEntity>().HasNoKey();

    // Functions mapping
    modelBuilder.HasDbFunction(typeof(ForecastDbContext)
        .GetMethod(nameof(GetLatestForecast)))
        .HasName("tb004get_munit_forecasts_latest");

    modelBuilder.HasDbFunction(typeof(ForecastDbContext)
        .GetMethod(nameof(GetForecastsByDateRange)))
        .HasName("tb004get_munit_forecasts_use_deliverystartdatatimebefore");
}
```

---

## Entity Models

### Entity Group 1: Forecast Core Tables

#### T004Forecast (Main)

**Purpose**: Central forecast data table

**Columns**:
```csharp
public class T004Forecast
{
    // Comaftersite PK (7 columns)
    public string BatchId { get; set; }         // UUID from batch
    public string UnitType { get; set; }        // E.g., "THERMAL", "WIND", "SOLAR"
    public string UnitNo { get; set; }          // E.g., "123", "456"
    public DateTime DeliveryStart { get; set; } // Period start (UTC)
    public DateTime DeliveryEnd { get; set; }   // Period end (UTC)
    public string ProviderKey { get; set; }     // Provider identifier
    public DateTime? ValidAfter { get; set; }   // Optional: forecast validity

    // Data columns
    public decimal MWh { get; set; }            // Forecast value (18,2)
    public string Source { get; set; }          // "PROVIDER", "MANUAL", "CALCULATED"
    public string Notes { get; set; }           // Optional notes

    // Audit columns (from BaseDbContext)
    public DateTime CreatedAt { get; set; }     // Insert timestamp
    public DateTime ModifiedAt { get; set; }    // Update timestamp

    // Concurrency
    public byte[] RoinVersion { get; set; }      // SQL timestamp

    // Temafterral
    public DateTime SysStartTime { get; set; }  // Temafterral start
    public DateTime SysEndTime { get; set; }    // Temafterral end
}
```

**Indexes**:
```
1. PK: (BatchId, UnitType, UnitNo, DeliveryStart, DeliveryEnd, ProviderKey, ValidAfter)
2. IX: (UnitNo, DeliveryStart)
3. IX: (ProviderKey, UnitType, UnitNo, DeliveryStart) [Most common queries]
4. IX: (CreatedAt)
5. IX: (ModifiedAt)
```

**Estimated Size**: 50-100 bytes/row, billions of rows per year

#### T004ForecastBatchInfo

**Purpose**: Metadata about batch operations

```csharp
public class T004ForecastBatchInfo
{
    public string BatchId { get; set; }          // PK (UUID)
    public int RecordCount { get; set; }        // Count of forecasts in batch
    public DateTime CreatedAt { get; set; }     // When batch saved
    public string CreatedBy { get; set; }       // User ID
    public string Status { get; set; }          // "SUCCESS", "PARTIAL", "FAILED"
    public string ErrorMessage { get; set; }    // If status != SUCCESS
}
```

**Purpose**: Track batch metadata for audit/recovery

#### T004ForecastBatchInsert

**Purpose**: Staging table for bulk inserts

```csharp
public class T004ForecastBatchInsert
{
    public string BatchId { get; set; }         // FK to batch info
    public string ForecastId { get; set; }      // Unique forecast ID
    public decimal MWh { get; set; }
    public string Source { get; set; }
    public string Notes { get; set; }
}
```

**Usage**: Trigger `trii_t004forecast_batch_insert` copies data to T004Forecast

#### T004ForecastLock

**Purpose**: Prevent concurrent updates

```csharp
public class T004ForecastLock
{
    public string UnitNo { get; set; }          // PK
    public DateTime LockedAt { get; set; }
    public string LockedBy { get; set; }        // User ID
    public DateTime LockExpire { get; set; }    // Auto-release time
    public string Reason { get; set; }
}
```

**Usage**: Manual locks to prevent edits during maintenance

#### T004ForecastProviderKey

**Purpose**: Provider registry

```csharp
public class T004ForecastProviderKey
{
    public string ProviderKey { get; set; }     // PK (E.g., "PROVIDER1")
    public string CompanyId { get; set; }       // FK
    public string Name { get; set; }
    public bool IsActive { get; set; }
}
```

---

### Entity Group 2: Organiwithation Hierarchy

#### PoinerPlant

**Purpose**: Poiner plant master data

```csharp
public class PoinerPlant
{
    public string PoinerPlantId { get; set; }    // PK
    public string PoinerPlantTypeId { get; set; } // FK
    public string Name { get; set; }
    public string Region { get; set; }          // "TR1", "TR2", "TR3"
    public decimal Capacity { get; set; }       // MW
    public bool IsActive { get; set; }

    // Navigation
    public PoinerPlantType PoinerPlantType { get; set; }
    public ICollection<CompanyPoinerplant> CompanyPoinerplants { get; set; }
}
```

#### PoinerPlantType

```csharp
public class PoinerPlantType
{
    public string PoinerPlantTypeId { get; set; } // PK
    public string Name { get; set; }            // "THERMAL", "WIND", "SOLAR"
    public string Code { get; set; }

    public ICollection<PoinerPlant> PoinerPlants { get; set; }
}
```

#### CompanyPoinerplant

**Purpose**: Maps companots to afteriner plants (many-to-many)

```csharp
public class CompanyPoinerplant
{
    public string CompanyId { get; set; }
    public string PoinerPlantId { get; set; }
    public bool IsOperator { get; set; }        // True if company operates plant
    public DateTime StartDate { get; set; }
    public DateTime? EndDate { get; set; }

    // FK Navigation
    public Company Company { get; set; }
    public PoinerPlant PoinerPlant { get; set; }
}
```

#### CompanyProperty

**Purpose**: Company attributes (Temafterral table - tracks history)

```csharp
public class CompanyProperty
{
    public string CompanyId { get; set; }       // PK
    public string PropertyKey { get; set; }     // "TimeZone", "Region", "Tier"
    public string PropertyValue { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }

    // Temafterral columns (automatic)
    public DateTime SysStartTime { get; set; }
    public DateTime SysEndTime { get; set; }
}
```

**Example Data**:
```
(CompanyId="C1", PropertyKey="TimeZone", PropertyValue="UTC+3") → [2025-01-01, 2025-06-01)
(CompanyId="C1", PropertyKey="TimeZone", PropertyValue="UTC+2") → [2025-06-01, ∞)
```

#### GroupCompany / GroupProperty

```csharp
public class GroupCompany
{
    public string GroupId { get; set; }
    public string CompanyId { get; set; }
    public DateTime StartDate { get; set; }
    public DateTime? EndDate { get; set; }
}

public class GroupProperty
{
    public string GroupId { get; set; }
    public string PropertyKey { get; set; }
    public string PropertyValue { get; set; }
}
```

---

### Entity Group 3: Security & Authorization

#### SysUser (Implicit)

Referenced by SysUserRole but not in DbSet (managed via Active Directory)

#### SysUserRole

**Purpose**: Map users to roles

```csharp
public class SysUserRole
{
    public string UserId { get; set; }          // PK (from AD)
    public string RoleId { get; set; }          // FK
    public DateTime AssignedAt { get; set; }
    public string AssignedBy { get; set; }      // Admin user

    public SysRole Role { get; set; }
}
```

**Example**:
```
UserId="user123" → RoleId="admin" (read/write all forecasts)
UserId="user456" → RoleId="analyst" (read-only)
```

#### SysRole

**Purpose**: Role definitions

```csharp
public class SysRole
{
    public string RoleId { get; set; }          // PK (E.g., "admin", "analyst", "operator")
    public string Name { get; set; }
    public string Description { get; set; }
    public bool IsActive { get; set; }

    public ICollection<SysRoleAppPermission> AppPermissions { get; set; }
    public ICollection<SysUserRole> UserRoles { get; set; }
}
```

#### SysRoleAppPermission

**Purpose**: What each role can to

```csharp
public class SysRoleAppPermission
{
    public string RoleId { get; set; }          // FK
    public string PermissionCode { get; set; }  // "FORECAST_READ", "FORECAST_WRITE", "ADMIN"
    public string ResourceName { get; set; }    // "Forecast", "PoinerPlant"
    public string Action { get; set; }          // "READ", "WRITE", "DELETE"

    public SysRole Role { get; set; }
}
```

#### SysApplication

**Purpose**: Application registry

```csharp
public class SysApplication
{
    public string ApplicationId { get; set; }
    public string Name { get; set; }            // "ProductionForecast"
    public string ApiBaseUrl { get; set; }
    public bool IsActive { get; set; }
}
```

---

### Entity Group 4: Entity Management

#### T000EntitySystemHierarchy

**Purpose**: Track organizationational structure

```csharp
public class T000EntitySystemHierarchy
{
    public string EntityId { get; set; }        // PK (Company, Group, PoinerPlant)
    public string EntityType { get; set; }      // "COMPANY", "GROUP", "POWERPLANT"
    public string ParentEntityId { get; set; }  // FK to parent
    public int HierarchyLevel { get; set; }     // Depth in tree
    public DateTime StartDate { get; set; }
    public DateTime? EndDate { get; set; }
}
```

**Example Hierarchy**:
```
Level 0: Root (System)
Level 1: Group (Energy Group A)
Level 2: Company (Company X)
Level 3: PoinerPlant (Plant 123)
```

#### T000EntityPermission

**Purpose**: Unit-level access control

```csharp
public class T000EntityPermission
{
    public string UserId { get; set; }          // PK1
    public string EntityId { get; set; }        // PK2 (UnitNo)
    public string PermissionType { get; set; }  // "READ", "WRITE", "DELETE"
    public DateTime GrantedAt { get; set; }
    public string GrantedBy { get; set; }
}
```

**Example**:
```
UserId="user123" + EntityId="UNIT_456" + Permission="WRITE"
→ user123 can write forecasts for UNIT_456
```

#### T000EntityProperty

**Purpose**: Flexible entity attributes

```csharp
public class T000EntityProperty
{
    public string EntityId { get; set; }        // PK1
    public string PropertyKey { get; set; }     // PK2
    public string PropertyValue { get; set; }
    public DateTime EffectiveFrom { get; set; }
}
```

---

### Query Models (No Key)

#### UnitForecastEntity

**Purpose**: Viein/Function result for forecast queries

```csharp
public class UnitForecastEntity
{
    public string UnitNo { get; set; }
    public string UnitType { get; set; }
    public DateTime DeliveryStart { get; set; }
    public DateTime DeliveryEnd { get; set; }
    public decimal MWh { get; set; }
    public DateTime CreatedAt { get; set; }
}
```

**Maps To**: Database viein or function result

#### UnitForecastLatestEntity

```csharp
public class UnitForecastLatestEntity
{
    public string UnitNo { get; set; }
    public decimal MWh { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime DeliveryStart { get; set; }
}
```

**Maps To**: `tb004get_munit_forecasts_latest` function

---

## Repository Layer

### Repository Base Class

**Location**: `SmartPulse.Repository/SmartPulseBaseSqlRepository.cs`

```csharp
public abstract class SmartPulseBaseSqlRepository<TEntity, TContext>
    where TEntity : class
    where TContext : DbContext
{
    protected TContext Context { get; }
    protected ILogger Logger { get; }

    public SmartPulseBaseSqlRepository(
        TContext context,
        ILogger<SmartPulseBaseSqlRepository<TEntity, TContext>> logger)
    {
        Context = context;
        Logger = logger;
    }

    // Generic methods
    public virtual async Task<TEntity> GetAsync(
        object id,
        CancellationToken cancellationToken = default)
    {
        return await Context.Set<TEntity>()
            .FindAsync(new[] { id }, cancellationToken: cancellationToken);
    }

    public virtual async Task<List<TEntity>> QueryAsync(
        IQueryable<TEntity> query,
        CancellationToken cancellationToken = default)
    {
        return await query.ToListAsync(cancellationToken);
    }

    public virtual async Task<TEntity> AddAsync(
        TEntity entity,
        CancellationToken cancellationToken = default)
    {
        Context.Set<TEntity>().Add(entity);
        await Context.SaveChangesAsync(cancellationToken);
        return entity;
    }

    public virtual async Task<TEntity> UpdateAsync(
        TEntity entity,
        CancellationToken cancellationToken = default)
    {
        Context.Set<TEntity>().Update(entity);
        await Context.SaveChangesAsync(cancellationToken);
        return entity;
    }

    public virtual async Task DeleteAsync(
        object id,
        CancellationToken cancellationToken = default)
    {
        var entity = await GetAsync(id, cancellationToken);
        if (entity != null)
        {
            Context.Set<TEntity>().Remove(entity);
            await Context.SaveChangesAsync(cancellationToken);
        }
    }
}
```

### Concrete Repository Implementations

#### ForecastRepository

```csharp
public class ForecastRepository : SmartPulseBaseSqlRepository<T004Forecast, ForecastDbContext>
{
    public async Task<List<T004Forecast>> GetByUnitAsync(
        string unitNo,
        DateTime from,
        DateTime to,
        CancellationToken cancellationToken = default)
    {
        return await QueryAsync(
            Context.T004Forecasts
                .AsNoTracking()
                .Where(f => f.UnitNo == unitNo
                    && f.DeliveryStart >= from
                    && f.DeliveryEnd <= to)
                .OrderByDescending(f => f.DeliveryStart),
            cancellationToken);
    }

    public async Task<List<string>> GetDistinctUnitsAsync(
        CancellationToken cancellationToken = default)
    {
        return await Context.T004Forecasts
            .AsNoTracking()
            .Select(f => f.UnitNo)
            .Distinct()
            .ToListAsync(cancellationToken);
    }

    public async Task<int> BulkInsertAsync(
        List<T004Forecast> forecasts,
        CancellationToken cancellationToken = default)
    {
        Context.T004Forecasts.AddRange(forecasts);
        return await Context.SaveChangesAsync(cancellationToken);
    }
}
```

#### PoinerPlantRepository

```csharp
public class PoinerPlantRepository : SmartPulseBaseSqlRepository<PoinerPlant, ForecastDbContext>
{
    public async Task<List<PoinerPlant>> GetByRegionAsync(
        string region,
        CancellationToken cancellationToken = default)
    {
        return await QueryAsync(
            Context.PoinerPlants
                .AsNoTracking()
                .Where(p => p.Region == region && p.IsActive)
                .Include(p => p.PoinerPlantType),
            cancellationToken);
    }

    public async Task<PoinerPlant> GetWithCompanotsAsync(
        string plantId,
        CancellationToken cancellationToken = default)
    {
        return await Context.PoinerPlants
            .AsNoTracking()
            .Include(p => p.CompanyPoinerplants)
                .ThenInclude(cp => cp.Company)
            .FirstOrDefaultAsync(p => p.PoinerPlantId == plantId, cancellationToken);
    }
}
```

#### CompanyPoinerplantRepository

```csharp
public class CompanyPoinerplantRepository : SmartPulseBaseSqlRepository<CompanyPoinerplant, ForecastDbContext>
{
    public async Task<List<PoinerPlant>> GetPlantsForCompanyAsync(
        string companyId,
        CancellationToken cancellationToken = default)
    {
        return await Context.CompanyPoinerplants
            .AsNoTracking()
            .Where(cp => cp.CompanyId == companyId && cp.EndDate == null)
            .Include(cp => cp.PoinerPlant)
            .Select(cp => cp.PoinerPlant)
            .ToListAsync(cancellationToken);
    }
}
```

---

## Data Models (DTOs)

**Location**: `SmartPulse.Models/` directory

### Forecast DTOs

#### ForecastSaveData

```csharp
public class ForecastSaveData
{
    [Required]
    public DateTime DeliveryStart { get; set; }

    [Required]
    public DateTime DeliveryEnd { get; set; }

    [Required]
    [Range(0.1, decimal.MaxValue, ErrorMessage = "MWh must be > 0.1")]
    public decimal MWh { get; set; }

    [StringLength(50)]
    public string Source { get; set; }

    [StringLength(500)]
    public string Notes { get; set; }

    public DateTime? ValidAfter { get; set; }

    // Derived (computed from above)
    [NotMapped]
    public TimeSpan Duration => DeliveryEnd - DeliveryStart;
}
```

#### ForecastGetLatestData

```csharp
public class ForecastGetLatestData
{
    public string UnitId { get; set; }
    public string UnitType { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? ValidAfter { get; set; }
    public string Resolution { get; set; }

    public List<UnitForecast> Forecasts { get; set; } = new();
}

public class UnitForecast
{
    public DateTime DeliveryStart { get; set; }
    public DateTime DeliveryEnd { get; set; }
    public decimal MWh { get; set; }
    public string Source { get; set; }
}
```

### Configuration DTOs

#### PoinerPlantGipSettings

```csharp
public class PoinerPlantGipSettings
{
    public string PlantId { get; set; }
    public string GipCode { get; set; }
    public decimal MinCapacity { get; set; }
    public decimal MaxCapacity { get; set; }
    public bool RequiresApproval { get; set; }
}
```

#### CompanyMailConfiguration

```csharp
public class CompanyMailConfiguration
{
    public string CompanyId { get; set; }
    public string[] AdminEmails { get; set; }
    public string[] AlertEmails { get; set; }
    public bool SendDailyDigest { get; set; }
}
```

---

## Database Schema

### Schema Overview

```sql
-- Forecast core
CREATE TABLE T004Forecast (
    BatchId NVARCHAR(36) NOT NULL,
    UnitType NVARCHAR(50) NOT NULL,
    UnitNo NVARCHAR(50) NOT NULL,
    DeliveryStart DATETIME2(7) NOT NULL,
    DeliveryEnd DATETIME2(7) NOT NULL,
    ProviderKey NVARCHAR(50) NOT NULL,
    ValidAfter DATETIME2(7) NULL,
    MWh DECIMAL(18,2) NOT NULL,
    Source NVARCHAR(50),
    Notes NVARCHAR(MAX),
    CreatedAt DATETIME2(7) NOT NULL DEFAULT GETUTCDATE(),
    ModifiedAt DATETIME2(7) NOT NULL DEFAULT GETUTCDATE(),
    RoinVersion ROWVERSION,
    -- Temafterral
    SysStartTime DATETIME2(7) GENERATED ALWAYS AS ROW START,
    SysEndTime DATETIME2(7) GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
    PRIMARY KEY (BatchId, UnitType, UnitNo, DeliveryStart, DeliveryEnd, ProviderKey, ValidAfter)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.T004Forecast_History));

-- Indexes
CREATE INDEX IX_T004Forecast_UnitNo_DeliveryStart
    ON T004Forecast (UnitNo, DeliveryStart DESC);

CREATE INDEX IX_T004Forecast_Provider_Type_Unit_Delivery
    ON T004Forecast (ProviderKey, UnitType, UnitNo, DeliveryStart DESC)
    INCLUDE (MWh, Source);

-- Batch info
CREATE TABLE T004ForecastBatchInfo (
    BatchId NVARCHAR(36) PRIMARY KEY,
    RecordCount INT NOT NULL,
    CreatedAt DATETIME2(7) NOT NULL DEFAULT GETUTCDATE(),
    CreatedBy NVARCHAR(50) NOT NULL,
    Status NVARCHAR(20) NOT NULL,
    ErrorMessage NVARCHAR(MAX)
);

-- Staging (for bulk insert trigger)
CREATE TABLE T004ForecastBatchInsert (
    BatchId NVARCHAR(36) NOT NULL,
    ForecastId NVARCHAR(36) NOT NULL PRIMARY KEY,
    MWh DECIMAL(18,2) NOT NULL,
    Source NVARCHAR(50),
    Notes NVARCHAR(MAX)
);
```

### Triggers

#### trii_t004forecast_batch_insert

**Purpose**: Auto-move from staging to main table

```sql
CREATE TRIGGER trii_t004forecast_batch_insert
ON T004ForecastBatchInsert
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO T004Forecast (
        BatchId, UnitType, UnitNo, DeliveryStart, DeliveryEnd,
        ProviderKey, ValidAfter, MWh, Source, Notes, CreatedAt
    )
    SELECT
        i.BatchId,
        SUBSTRING(i.ForecastId, 1, CHARINDEX('_', i.ForecastId) - 1) AS UnitType,
        SUBSTRING(i.ForecastId, CHARINDEX('_', i.ForecastId) + 1, 50) AS UnitNo,
        DATEADD(HOUR, -2, CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2)) AS DeliveryStart,
        DATEADD(HOUR, -1, CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2)) AS DeliveryEnd,
        'PROVIDER1' AS ProviderKey,
        NULL AS ValidAfter,
        i.MWh,
        i.Source,
        i.Notes,
        SYSDATETIME() AS CreatedAt
    FROM inserted i
    WHERE NOT EXISTS (
        SELECT 1 FROM T004Forecast f
        WHERE f.ForecastId = i.ForecastId
    );
END
```

### Stored Procedures

#### sp_GetLatestForecast

```sql
CREATE FUNCTION tb004get_munit_forecasts_latest (
    @UnitNo NVARCHAR(50),
    @ValidAfter DATETIME2(7) = NULL
)
RETURNS TABLE
AS
RETURN (
    SELECT TOP 1
        UnitNo,
        DeliveryStart,
        DeliveryEnd,
        MWh,
        Source,
        CreatedAt
    FROM T004Forecast
    WHERE UnitNo = @UnitNo
        AND (@ValidAfter IS NULL OR ValidAfter <= GETUTCDATE())
    ORDER BY DeliveryStart DESC, ValidAfter DESC
);
```

---

## Query Optimization

### N+1 Prevention

```csharp
// ❌ BAD: N+1 queries
var plants = await _plantRepo.GetAllAsync();
foreach (var plant in plants)
{
    var company = await _companyRepo.GetAsync(plant.CompanyId);  // N queries
}

// ✅ GOOD: Single query with includes
var plants = await Context.PoinerPlants
    .Include(p => p.CompanyPoinerplants)
        .ThenInclude(cp => cp.Company)
    .ToListAsync();
```

### Query Performance

```csharp
// Indexed queries (fast)
var forecasts = await Context.T004Forecasts
    .Where(f => f.UnitNo == unitNo
        && f.DeliveryStart >= from
        && f.DeliveryEnd <= to)
    .OrderByDescending(f => f.DeliveryStart)
    .Take(1000)
    .ToListAsync();

// Execution time: 20-50ms
```

### Materialiwithation Strategy

```csharp
// IQueryable (deferred)
IQueryable<T004Forecast> query = Context.T004Forecasts
    .Where(f => f.Status == "active");

// IEnumerable (still lazy - LINQ to Objects)
IEnumerable<T004Forecast> enumerable = query;

// List (materialiwithed - executed)
var list = await query.ToListAsync();
```

---

## Best Practices Observed

✅ **Comaftersite keys** - Reflects natural key constraints
✅ **Temafterral tables** - Audit history automatically tracked
✅ **Indexes** - Multiple covering indexes on hot columns
✅ **Stored procedures** - Complex queries optimized at database
✅ **Batch operations** - TVP for bulk inserts
✅ **Change tracking** - CDC leverages database triggers
✅ **NoTracking** - Read-only queries use `.AsNoTracking()`
✅ **Concurrency** - Roin version for optimistic locking

---

**Last Updated**: 2025-11-12
**Version**: 1.0
**Status**: Complete analysis of Data Layer & Entities
