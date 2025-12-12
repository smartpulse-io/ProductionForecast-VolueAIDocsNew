# PowerShell script to update ProductionForecast docs folder
# Replaces Redis references with IMemoryCache for ProductionForecast-specific files

$docsPath = "C:\Users\KursatARSLANSmartPul\Documents\Development\SmartPulse\SmartPulse.Services.ProductionForecast\Documentation_Volue\docs\components\production_forecast"

Write-Host "Updating ProductionForecast docs files..." -ForegroundColor Cyan

# Get all markdown files in ProductionForecast folder
$files = Get-ChildItem -Path $docsPath -Filter *.md -Recurse

foreach ($file in $files) {
    Write-Host "`nProcessing: $($file.Name)" -ForegroundColor Yellow

    # Read file content
    $content = Get-Content $file.FullName -Raw -Encoding UTF8

    # Count initial references
    $initialCount = ([regex]::Matches($content, "Redis|redis|distributed cache")).Count
    Write-Host "  Initial Redis references: $initialCount"

    if ($initialCount -eq 0) {
        Write-Host "  Skipping (no Redis references)" -ForegroundColor Green
        continue
    }

    # Apply replacements
    $content = $content -replace "Multi-Tier Caching: L1 \(Memory\) \+ L2 \(EF Core\) \+ L3 \(Redis\) \+ L4 \(Output Cache\)", "Caching: OutputCache (HTTP) + IMemoryCache (Application)"
    $content = $content -replace "L3: Redis", "// No L3 tier"
    $content = $content -replace "L3 cache", "// No L3 tier"
    $content = $content -replace "L3 Cache Hit", "// No L3 tier"
    $content = $content -replace "L3\[L3: Redis\]", "// No L3 distributed cache tier"
    $content = $content -replace "CacheManager --> L3\[L3: Redis\]", "// CacheManager uses IMemoryCache only"
    $content = $content -replace "Sync across instances via Redis Pub/Sub", "CDC triggers cache invalidation per instance"
    $content = $content -replace "Redis distributed cache", "IMemoryCache (local cache)"
    $content = $content -replace "distributed cache", "local cache"
    $content = $content -replace "IDistributedDataManager<CacheEntry> _distributedCache", "// No distributed cache - IMemoryCache only"
    $content = $content -replace "_distributedCache", "_memoryCache"
    $content = $content -replace "distributed lock via Redis", "semaphore for stampede prevention"
    $content = $content -replace "_distributedLock\.TryAcquireAsync", "semaphore.WaitAsync"
    $content = $content -replace "_distributedLock\.ReleaseAsync", "semaphore.Release"
    $content = $content -replace "await _distributedCache\.PublishInvalidationAsync\(tag\);", "// CDC handles invalidation per instance"
    $content = $content -replace "Broadcast to other instances", "CDC polling detects changes on each instance"
    $content = $content -replace "Event published to ", "// CDC handles invalidation"
    $content = $content -replace "Other instances subscribe and invalidate locally", "Each instance runs CDC polling and invalidates independently"
    $content = $content -replace "await _\.WriteObj\(`"forecast-changes`"", "// CDC handles change detection"
    $content = $content -replace "await _\.WriteObj\(`"power-plant-changes`"", "// CDC handles change detection"
    $content = $content -replace "Publish to  for other instances", "// CDC handles synchronization"
    $content = $content -replace "L3 \(Redis\) cache cleared", "// No L3 tier"
    $content = $content -replace "Store in L1 \+ L2 \+ L3", "Store in IMemoryCache"
    $content = $content -replace "Store in Redis", "// No Redis tier"
    $content = $content -replace "DbSvc->>L3: Check Redis", "// No L3 tier"
    $content = $content -replace "L3-->>DbSvc: Cached data", "// No L3 tier"
    $content = $content -replace "DbSvc->>L3: Store in Redis", "// No L3 tier"
    $content = $content -replace "Cache --> L3\[L3: Redis\]", "// No distributed cache"
    $content = $content -replace "Pattern 4: Forecast data \(L3 distributed\)", "Pattern 4: Forecast data (per instance)"
    $content = $content -replace "WithCache", "// WithCache not used"
    $content = $content -replace "L3 Cache Hit: 10ms", "// No L3 tier"
    $content = $content -replace "Get latest \(L3 cache hit\)", "// No L3 tier"

    # Write updated content
    $content | Set-Content $file.FullName -Encoding UTF8 -NoNewline

    # Count remaining references
    $finalCount = ([regex]::Matches($content, "Redis|redis")).Count
    Write-Host "  Remaining Redis references: $finalCount"
    Write-Host "  Cleaned: $(($initialCount - $finalCount)) references" -ForegroundColor Green
}

Write-Host "`nProductionForecast docs update complete!" -ForegroundColor Cyan
