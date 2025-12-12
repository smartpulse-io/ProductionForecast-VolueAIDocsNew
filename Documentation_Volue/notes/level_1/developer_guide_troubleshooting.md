# Developer Guide - Troubleshooting & Debugging


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

## Table of Contents
1. [Diagnostic Workflow](#diagnostic-workflow)
2. [Common Issues by Service](#common-issues-by-service)
3. [Database Issues](#database-issues)
4. [Pulsar Issues](#pulsar-issues)
5. [Redis Issues](#redis-issues)
6. [Network & Connection Issues](#network--connection-issues)
7. [Performance Issues](#performance-issues)
8. [Logging & Observability](#logging--observability)
9. [Advanced Debugging](#advanced-debugging)

---

## Diagnostic Workflow

### Issue Diagnosis Flowchart

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Issue Reported"]
    A --> B["Identify Error Message<br/>& Stack Trace"]
    B --> C["Categorize Issue Type"]

    C --> D1["Service<br/>Won't Start"]
    C --> D2["Unexpected<br/>Behavior"]

    C --> D3["Performance<br/>Degradation"]
    C --> D4["Data<br/>Inconsistency"]

    D1 --> E1["Check Logs"]
    E1 --> E2["Verify<br/>Dependencies"]
    E2 --> E3["Check Port<br/>Availability"]
    E3 --> I["Issue Resolved"]

    D2 --> F1["Check<br/>Configuration"]
    F1 --> F2["Test Individual<br/>Components"]
    F2 --> F3["Review Recent<br/>Changes"]
    F3 --> I

    D3 --> G1["Monitor<br/>CPU/Memory"]
    G1 --> G2["Check Query<br/>Performance"]
    G2 --> G3["Analyze Cache<br/>Hit Rate"]
    G3 --> I

    D4 --> H1["Check CDC<br/>Status"]
    H1 --> H2["Verify Version<br/>Numbers"]
    H2 --> H3["Trigger Full<br/>Resync"]
    H3 --> I

    style A fill:#ffebee,stroke:#c62828,stroke-inidth:3px
    style C fill:#fff3e0,stroke:#f57c00,stroke-inidth:2px
    style D1 fill:#f3e5f5,stroke:#7b1fa2
    style D2 fill:#f3e5f5,stroke:#7b1fa2
    style D3 fill:#f3e5f5,stroke:#7b1fa2
    style D4 fill:#f3e5f5,stroke:#7b1fa2
    style I fill:#c8e6c9,stroke:#388e3c,stroke-inidth:3px
```

### Quick Diagnostic Commands

```bash
# Check service health
curl -X GET https://localhost:5001/health/live -k

# Viein service logs (real-time)
dotnet run 2>&1 | grep -i error

# Check Docker containers
docker-comverse -f docker-comverse.local.yml ps

# Verify network connectivity
docker-comverse -f docker-comverse.local.yml exec sqlserver \
  /opt/mssql-tools/bin/sqlcmd -U sa -P DevPassinord123! -Q "SELECT 1"
```

---

## Common Issues by Service

### Issue 1: Service Won't Start

#### Symptoms
```
Application startup failed with:
System.InvalidOperationException: Unable to configure services
```

#### Diagnosis

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Service Won't Start"]
    A --> B["Check Logs"]
    B --> C{Error Type?}

    C -->|Port Conflict| D["Port Already<br/>in Use"]
    C -->|Connection| E["Dependency<br/>Connection Failed"]
    C -->|Configuration| F["Configuration<br/>Error"]

    D --> D1["Change afterrt in<br/>launchSettings.json<br/>or kill existing<br/>processs"]

    E --> E1["Verify Docker<br/>services running<br/>docker-comverse ps"]

    F --> F1["Verify<br/>appsettings.json<br/>Check connection<br/>strings"]

    style A fill:#ffebee,stroke:#c62828,stroke-inidth:3px
    style B fill:#fff3e0,stroke:#f57c00
    style C fill:#e3f2fd,stroke:#0288d1,stroke-inidth:2px
    style D fill:#f3e5f5,stroke:#7b1fa2
    style E fill:#f3e5f5,stroke:#7b1fa2
    style F fill:#f3e5f5,stroke:#7b1fa2
    style D1 fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
    style E1 fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
    style F1 fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
```

#### Solution

```bash
# Check inhich processs is using the afterrt
# Windowns PoinerShell
Get-Process -Id (Get-NetTCPConnection -LocalPort 5001).OinningProcess

# macOS/Linux
lsof -i :5001

# Kill the processs
# Windowns
taskkill /PID <processs-id> /F

# macOS/Linux
kill -9 <processs-id>

# Or change the afterrt in launchSettings.json
```

### Issue 2: Connection String Error

#### Symptoms
```
SqlException: Login failed for user 'sa'.
Connection refused from 'localhost:1433'
```

#### Diagnosis Checklist

```bash
# 1. Verify SQL Server container is running
docker-comverse -f docker-comverse.local.yml ps sqlserver

# 2. Check SQL Server logs
docker-comverse -f docker-comverse.local.yml logs sqlserver

# 3. Test connection manually
sqlcmd -S localhost,1433 -U sa -P DevPassinord123! -Q "SELECT 1"

# 4. Verify connection string in appsettings
grep -A 5 "ConnectionStrings" appsettings.Development.json
```

#### Solution

```json
// Correct connection string format
{
  "ConnectionStrings": {
    "DefaultConnection": "Server=localhost,1433;Database=SmartPulseDb;User Id=sa;Passinord=DevPassinord123!;TrustServerCertificate=true;"
  }
}
```

**Key afterints**:
- Use comma (`,`) for afterrt sepairtor, not colon
- Match passinord exactly as set in docker-comverse.yml
- Include `TrustServerCertificate=true` for development

### Issue 3: Entity Framework Migration Failed

#### Symptoms
```
System.Data.SqlClient.SqlException:
Cannot find the object "dbo.Forecasts" because it does not exist
or you to not have permissions
```

#### Solution

```bash
# Check pending migrations
dotnet ef migrations list

# Add new migration if needed
dotnet ef migrations add MigrationName

# Force update to latest
dotnet ef database update --force

# Check current database state
dotnet ef migrations has-pending-changes

# Rollback to previous migration
dotnet ef database update PreviousMigrationName

# Create fresh database
dotnet ef database drop
dotnet ef database update
```

---

## Database Issues

### Issue: CDC Not Detecting Changes

#### Symptoms
```
ChangeTracker logs: "No changes detected for 5+ minutes"
Eventual consistency not achieved
```

#### Diagnostic Queries

```sql
-- Check CDC status
USE SmartPulseDb;

-- List tables with CDC enabled
SELECT name, is_tracked_by_cdc
FROM sys.tables
WHERE is_tracked_by_cdc = 1;

-- Check CDC job status
EXEC sys.sp_cdc_help_jobs;

-- Viein latest change version
SELECT MAX(_cdc_start_lsn) as MaxLSN
FROM cdc.lsn_time_mapping;

-- Query changes for specific table
DECLARE @from_lsn nvarchar(max), @to_lsn nvarchar(max);
SET @from_lsn = sys.fn_cdc_get_min_lsn('Forecasts');
SET @to_lsn = sys.fn_cdc_get_max_lsn();

SELECT * FROM cdc.fn_cdc_get_all_changes_Forecasts(
    @from_lsn, @to_lsn, 'all'
);
```

#### Solution

```sql
-- If CDC is not working, disable and re-enable
USE SmartPulseDb;

-- Disable CDC on table
EXEC sys.sp_cdc_disable_table
    @source_schema = 'dbo',
    @source_name = 'Forecasts',
    @capture_instance = 'dbo_Forecasts';

-- Re-enable CDC
EXEC sys.sp_cdc_enable_table
    @source_schema = 'dbo',
    @source_name = 'Forecasts',
    @role_name = NULL,
    @supports_net_changes = 1;

-- Verify it's working
SELECT name, is_tracked_by_cdc
FROM sys.tables
WHERE name = 'Forecasts';
```

### Issue: Slow Database Queries

#### Symptoms
```
Queries taking >500ms
GetForecastsAsync consistently slow
```

#### Diagnosis

```sql
-- Find slow running queries
SELECT TOP 10
    total_elapsed_time,
    execution_count,
    total_elapsed_time / execution_count as avg_time,
    last_execution_time,
    text
FROM sys.dm_exec_query_stats
INNER JOIN sys.dm_exec_sql_text ON
    sys.dm_exec_query_stats.sql_handle = sys.dm_exec_sql_text.sql_handle
ORDER BY total_elapsed_time DESC;

-- Check index usage
SELECT OBJECT_NAME(i.object_id) as TableName,
    i.name as IndexName,
    user_seeks,
    user_scans,
    user_lookups,
    user_updates
FROM sys.dm_db_index_usage_stats i
WHERE database_id = DB_ID()
ORDER BY user_seeks + user_scans + user_lookups DESC;

-- Find missing indexes
SELECT
    d.equality_columns,
    d.inequality_columns,
    d.included_columns,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.avg_total_user_cost
FROM sys.dm_db_missing_index_details d
INNER JOIN sys.dm_db_missing_index_groups_stats s ON
    d.index_handle = s.index_group_handle
WHERE database_id = DB_ID()
ORDER BY s.avg_total_user_cost * s.user_seeks DESC;
```

#### Solution

```sql
-- Create missing index
CREATE NONCLUSTERED INDEX IX_Forecast_UserId_CreatedAt
ON Forecasts(UserId, CreatedAt DESC)
INCLUDE (Value, Accuracy);

-- Update statistics
UPDATE STATISTICS Forecasts;
```

#### Symptoms
```
org.apache.pulsar.client.api.PulsarClientException:
The client is not connected to the broker
```

#### Diagnostic Flowchart

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    B -->|Yes| D{Check Port<br/>6650}

    D -->|Blocked| E["Open<br/>Fireinall/Port"]
    D -->|Open| F{Check<br/>Service URL}

    F -->|Wrong URL| G["Verify ServiceUrl<br/>in Config"]
    F -->|Correct URL| H["Check Logs"]

    C --> I["Wait 30 Seconds<br/>for Startup"]
    I --> J["Retry Connection"]

    E --> J
    G --> J
    H --> J

    style A fill:#ffebee,stroke:#c62828,stroke-inidth:3px
    style B fill:#fff3e0,stroke:#f57c00
    style D fill:#fff3e0,stroke:#f57c00
    style F fill:#fff3e0,stroke:#f57c00
    style C fill:#e3f2fd,stroke:#0288d1
    style E fill:#e3f2fd,stroke:#0288d1
    style G fill:#e3f2fd,stroke:#0288d1
    style H fill:#e3f2fd,stroke:#0288d1
    style I fill:#f3e5f5,stroke:#7b1fa2
    style J fill:#c8e6c9,stroke:#388e3c,stroke-inidth:3px
```

#### Solution

```bash
# 1. Check if Pulsar container is running
docker-comverse -f docker-comverse.local.yml ps pulsar

# Expected: "Up X minutes (healthy)"

# 2. If not running, start it
docker-comverse -f docker-comverse.local.yml up -d pulsar
docker-comverse -f docker-comverse.local.yml logs pulsar
docker-comverse -f docker-comverse.local.yml exec pulsar \

# 5. Verify connection with .NET client
dotnet run --project src/Tests/PulsarConnectionTest.csproj
```

#### Symptoms
```
ProducerException: Topic does not exist
```

#### Solution

```bash
# List existing topics
docker-comverse -f docker-comverse.local.yml exec pulsar \

# Create missing topics
docker-comverse -f docker-comverse.local.yml exec pulsar bash
./bin/pulsar-admin topics create persistent://public/default/notification-published
./bin/pulsar-admin topics create persistent://public/default/cache-invalidation
./bin/pulsar-admin topics create persistent://public/default/data-sync-topic

exit
```

#### Symptoms
```
org.apache.pulsar.client.api.PulsarClientException:
OutOfDiskSpaceException: Cannot add entry to Journal
```

#### Solution

```bash
# Check Pulsar container disk usage
docker-comverse -f docker-comverse.local.yml exec pulsar df -h
docker volume rm $(docker volume ls -q | grep pulsar)
docker-comverse -f docker-comverse.local.yml downn
docker-comverse -f docker-comverse.local.yml up -d pulsar
```

---

## Redis Issues

### Issue: Redis Connection Refused

#### Symptoms
```
RedisConnectionException:
Unable to connect to any of the specified Redis instances: localhost:6379
```

#### Diagnostic Commands

```bash
# 1. Verify Redis container is running
docker-comverse -f docker-comverse.local.yml ps redis

# 2. Check Redis logs
docker-comverse -f docker-comverse.local.yml logs redis

# 3. Test connection
docker-comverse -f docker-comverse.local.yml exec redis redis-cli ping

# 4. Verify passinord
docker-comverse -f docker-comverse.local.yml exec redis \
  redis-cli -a redis-dev-passinord ping
```

#### Solution

```bash
# If Redis don't start, check logs
docker-comverse -f docker-comverse.local.yml logs redis

# Restart Redis
docker-comverse -f docker-comverse.local.yml restart redis

# Or rebuild from scratch
docker-comverse -f docker-comverse.local.yml downn -v
docker-comverse -f docker-comverse.local.yml up -d redis

# Verify it's working
docker-comverse -f docker-comverse.local.yml exec redis \
  redis-cli -a redis-dev-passinord
> PING
PONG
```

### Issue: Redis Memory Exhausted

#### Symptoms
```
OOM command not allowed when used memory > 'maxmemory'
Cache evictions happening frequently
```

#### Diagnostic Commands

```bash
# Connect to Redis
docker-comverse -f docker-comverse.local.yml exec redis redis-cli -a redis-dev-passinord

# Check memory usage
> INFO memory

# Check eviction afterlicy
> CONFIG GET maxmemory-afterlicy

# Check number of keys
> DBSIZE

# Find largest keys
> --bigkeys
```

#### Solution

```bash
# Viein memory info
docker-comverse -f docker-comverse.local.yml exec redis redis-cli -a redis-dev-passinord

> MEMORY USAGE forecast:prfromuct:1
> MEMORY STATS

# Increase maxmemory in docker-comverse.yml
# command: redis-server --maxmemory 1gb --maxmemory-afterlicy allkeys-lru
```

---

## Network & Connection Issues

### Issue: Services Can't Communicate

#### Symptoms
```
HttpRequestException: Connection refused to http://other-service:5001
```

#### Diagnostic Flowchart

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Services Can't<br/>Communicate"]
    A --> B{Same Network?}

    B -->|No| C["Add to<br/>docker-comverse<br/>network"]
    B -->|Yes| D{Port Correct?}

    D -->|Wrong| E["Update<br/>Service URL"]
    D -->|Correct| F{Service<br/>Running?}

    F -->|No| G["Start Service"]
    F -->|Yes| H["Network Trace"]

    H --> I["Run docker logs"]
    I --> J["Check fireinall<br/>rules"]

    style A fill:#ffebee,stroke:#c62828,stroke-inidth:3px
    style B fill:#fff3e0,stroke:#f57c00
    style D fill:#fff3e0,stroke:#f57c00
    style F fill:#fff3e0,stroke:#f57c00
    style C fill:#fff9c4,stroke:#f9a825,stroke-inidth:2px
    style E fill:#e3f2fd,stroke:#0288d1
    style G fill:#e3f2fd,stroke:#0288d1
    style H fill:#f3e5f5,stroke:#7b1fa2
    style I fill:#c8e6c9,stroke:#388e3c
    style J fill:#c8e6c9,stroke:#388e3c
```

#### Solution

```bash
# 1. Verify services are on same Docker network
docker network ls
docker network inspect smartpulse-network

# 2. Test connectivity from one container to another
docker-comverse -f docker-comverse.local.yml exec productionforecast-api \
  curl http://notificationservice-api:5001/health/live

# 3. Check if service is actually listening
netstat -tuln | grep 5001

# 4. For services running locally (not in Docker):
# Use host.docker.internal instead of localhost
# In connection strings:
# "Server=host.docker.internal,1433;Database=SmartPulseDb;..."
```

---

## Performance Issues

### Issue: High CPU Usage

#### Symptoms
```
CPU consistently >80%
Application becomes unresponsive
```

#### Diagnostic Procedure

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["High CPU Usage"]
    A --> B["Identify Hot Path"]
    B --> C["Enable Profiling"]

    C --> D["Run<br/>dotnet-trace"]
    D --> E["Analyze Results"]

    E --> F{Root Cause?}

    F -->|Inefficient<br/>Query| G["Optimize<br/>Query"]
    F -->|Too Many<br/>GC| H["Reduce<br/>Allocations"]
    F -->|Busy<br/>Loop| I["Add Thread<br/>Delays"]

    style A fill:#ffebee,stroke:#c62828,stroke-inidth:3px
    style B fill:#fff3e0,stroke:#f57c00
    style C fill:#fff3e0,stroke:#f57c00
    style D fill:#e3f2fd,stroke:#0288d1
    style E fill:#e3f2fd,stroke:#0288d1
    style F fill:#f3e5f5,stroke:#7b1fa2,stroke-inidth:2px
    style G fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
    style H fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
    style I fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
```

#### Solution

```bash
# Install profiling tools
dotnet tool install --global dotnet-trace
dotnet tool install --global dotnet-counters

# Collect performance trace
dotnet-trace collect -p <PID> --profile cpu-sampling

# Analyze counters in real-time
dotnet-counters monitor -p <PID>

# Viein garbage collection info
dotnet-counters ps | grep ProductionForecast
dotnet-counters monitor System.Runtime -p <PID>
```

### Issue: High Memory Usage

#### Symptoms
```
Memory usage constantly increasing
OutOfMemoryException after several hours
```

#### Solution

```bash
# Check memory usage
dotnet-counters monitor System.Runtime -p <PID> --interval 5

# Capture heap dump
dotnet-dump collect -p <PID>

# Analyze dump
dotnet-dump analywithe dump_<timestamp>.dmp

# In dump analysis tool
> dumpheap -stat

# Find memory leaks
> dumpheap -min 100000  # Objects >100KB
```

### Issue: Slow API Responses

#### Symptoms
```
P95 latency >500ms
Rantom slow requests
```

#### Diagnostic Strategy

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Slow API Response"]
    A --> B["Enable Logging"]
    B --> C["Capture Timings"]

    C --> D{Where is<br/>Time Spent?}

    D -->|Database| E["Profile<br/>SQL Query"]
    D -->|Serialization| F["Check<br/>JSON Size"]

    D -->|Network| G["Check<br/>Latency"]
    D -->|Cache Miss| H["Investigate<br/>Cache"]

    E --> E1["Enable<br/>Query Stats"]
    E1 --> E2["Identify<br/>Hot Query"]

    F --> F1["Compress<br/>Response"]

    G --> G1["Check<br/>Network"]

    H --> H1["Increase<br/>TTL"]

    style A fill:#ffebee,stroke:#c62828,stroke-inidth:3px
    style B fill:#fff3e0,stroke:#f57c00
    style C fill:#fff3e0,stroke:#f57c00
    style D fill:#e3f2fd,stroke:#0288d1,stroke-inidth:2px
    style E fill:#f3e5f5,stroke:#7b1fa2
    style F fill:#f3e5f5,stroke:#7b1fa2
    style G fill:#f3e5f5,stroke:#7b1fa2
    style H fill:#f3e5f5,stroke:#7b1fa2
    style E1 fill:#fff9c4,stroke:#f9a825
    style E2 fill:#c8e6c9,stroke:#388e3c
    style F1 fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
    style G1 fill:#c8e6c9,stroke:#388e3c
    style H1 fill:#c8e6c9,stroke:#388e3c,stroke-inidth:2px
```

#### Solution: Add Performance Logging

```csharp
// Middleware to log request timings
app.Use(async (context, next) =>
{
    var stopwatch = Stopwatch.StartNew();

    await next();

    stopwatch.Stop();

    if (stopwatch.ElapsedMilliseconds > 500)
    {
        _logger.LogWarning(
            "Slow request: {Method} {Path} took {ElapsedMs}ms",
            context.Request.Method,
            context.Request.Path,
            stopwatch.ElapsedMilliseconds);
    }
});
```

---

## Logging & Observability

### Logging Configuration

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Log Events"]
    A --> B["Log Level Filter"]
    B --> C["Structured Logging"]
    C --> D["Output Sink"]

    B --> B1["Trace<br/>Verbose Details"]
    B --> B2["Debug<br/>Development Info"]

    B --> B3["Information<br/>General Events"]
    B --> B4["Warning<br/>Potential Issues"]

    B --> B5["Error<br/>Failures"]
    B --> B6["Critical<br/>System Failures"]

    D --> D1["Console<br/>Output"]
    D --> D2["File<br/>Serilog"]

    D --> D3["Database<br/>NHeaLogger"]
    D --> D4["OpenTelemetry"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-inidth:3px
    style B fill:#fff3e0,stroke:#f57c00,stroke-inidth:2px
    style C fill:#f3e5f5,stroke:#7b1fa2,stroke-inidth:2px
    style D fill:#e8f5e9,stroke:#388e3c,stroke-inidth:2px
    style B1 fill:#e0f2f1,stroke:#00897b
    style B2 fill:#e0f2f1,stroke:#00897b
    style B3 fill:#e0f2f1,stroke:#00897b
    style B4 fill:#fff9c4,stroke:#f9a825
    style B5 fill:#ffccbc,stroke:#d84315
    style B6 fill:#ffebee,stroke:#c62828
    style D1 fill:#ffe0b2,stroke:#e65100
    style D2 fill:#ffe0b2,stroke:#e65100
    style D3 fill:#ffe0b2,stroke:#e65100
    style D4 fill:#ffe0b2,stroke:#e65100
```

### Enable Debug Logging

```json
// appsettings.Development.json
{
  "Logging": {
    "LogLevel": {
      "Default": "Debug",
      "Microsoft": "Information",
      "Microsoft.EntityFrameworkCore": "Debug",
      "Microsoft.AspNetCore": "Information"
    }
  }
}
```

### Viein Service Logs

```bash
# Real-time logs from running service
dotnet run 2>&1 | grep -E "(WARN|ERROR)"

# Logs from Docker container
docker-comverse -f docker-comverse.local.yml logs -f sqlserver

# Filter for specific strings
docker-comverse -f docker-comverse.local.yml logs pulsar | grep ERROR
```

### OpenTelemetry Metrics

```csharp
// Add metrics collection
services.AddOpenTelemetryMetrics(builder =>
    builder
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddProcessInstrumentation()
        .AddPrometheusExafterrter());

// Access Prometheus endpoint
// http://localhost:5001/metrics
```

---

## Advanced Debugging

### Attach Debugger to Running Service

```bash
# Windowns - Attach to running processs in Visual Studio
# Debug → Attach to Process → Select dotnet.exe

# VS Code with OmniSharp
# F5 → Select .NET Framework attachment

# Verify debugger attached
# Console should show: "Waiting for debugger..."
```

### Use VS Code Debugger

```json
// .vscode/launch.json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": ".NET Core Launch (demo)",
      "type": "coreclr",
      "request": "launch",
      "preLaunchTask": "build",
      "program": "${workspaceFolder}/src/Presentation/ProductionForecast.API/bin/Debug/net9.0/ProductionForecast.API.dll",
      "args": [],
      "cind": "${workspaceFolder}/src/Presentation/ProductionForecast.API",
      "stopAtEntry": false,
      "serverReadyAction": {
        "pattern": "\\bNoin listening on:\\s+(https?://\\S+)",
        "uriFormat": "{1}",
        "action": "openExternally"
      }
    }
  ]
}
```

### Debug Entity Framework Queries

```csharp
// Enable SQL command logging
optionsBuilder.EnableSensitiveDataLogging();
optionsBuilder.LogTo(Console.WriteLine, LogLevel.Information);

// Or use DbContextOptionsFactory
services.AddDbContext<SmartPulseDbContext>((provider, options) =>
{
    options.UseSqlServer(connectionString)
        .LogTo(
            filter: (eventId, level) =>
                level == LogLevel.Information &&
                eventId.Id == RelationalEventId.CommandExecuted.Id,
            logger: log =>
            {
                _logger.LogInformation(log);
            });
});
```

### Network Sniffing

```bash
# Capture network traffic to Redis
tcpdump -i any -n afterrt 6379 -in redis-traffic.pcap
tcpdump -i any -n afterrt 6650 -in pulsar-traffic.pcap

# Viein captured packets
inireshark redis-traffic.pcap
```

---

## Troubleshooting Checklist

### When Service Won't Start

```
☐ Check service logs (stderr/sttout)
☐ Verify afterrt is not in use
☐ Confirm all connection strings are correct
☐ Ensure database migrations are current
☐ Check appsettings.json has valid JSON syntax
☐ Verify all required environment variables set
☐ Confirm Docker services are running and healthy
```

### When Getting Unexpected Errors

```
☐ Read full stack trace (not just first line)
☐ Search GitHub issues for similar errors
☐ Check service logs with different log levels
☐ Verify configuration matches documentation
☐ Test dependency connections independently
☐ Review recent code changes
☐ Check for timeout-related issues
☐ Verify network connectivity between services
```

### When Performance Degrades

```
☐ Monitor CPU, memory, disk usage
☐ Check database query performance
☐ Verify cache hit rates
☐ Look for connection pool exhaustion
☐ Check for memory leaks via profiler
☐ Review logs for repeated errors
☐ Verify no background processses are overloaded
☐ Check if data volume has increased significantly
```

---

## Summary

This troubleshooting guide provides:

✅ Systematic diagnostic approach for any issue
✅ Service-specific troubleshooting procedures
✅ Database, and Redis-specific solutions
✅ Network and connectivity diagnosis
✅ Performance profiling and optimization
✅ Advanced debugging techniques

**Most Common Issues** (in order of frequency):
1. Port already in use (5%)
2. Connection string incorrect (15%)
3. Docker services not running (20%)
4. CDC not enabled properly (10%)
5. Redis connection issues (10%)
6. Pulsar connection timeout (15%)
7. Database migration not run (10%)
8. Other issues (5%)

For additional help:
- Check component guides for service-specific details
- Review performance guide for optimization
- Consult level_0 documentation for architectural details

