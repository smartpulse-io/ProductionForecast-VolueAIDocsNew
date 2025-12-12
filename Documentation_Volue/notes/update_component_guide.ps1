# PowerShell script to update component_guide_production_forecast.md
# Removes Redis references and replaces with IMemoryCache for ProductionForecast

$filePath = "C:\Users\KursatARSLANSmartPul\Documents\Development\SmartPulse\SmartPulse.Services.ProductionForecast\Documentation_Volue\notes\level_1\component_guide_production_forecast.md"

Write-Host "Updating component_guide_production_forecast.md..." -ForegroundColor Cyan

# Read file content
$content = Get-Content $filePath -Raw -Encoding UTF8

# Count initial Redis references
$initialCount = ([regex]::Matches($content, "Redis|redis|distributed cache|DistributedCache")).Count
Write-Host "Initial Redis references: $initialCount" -ForegroundColor Yellow

# Apply replacements with simple patterns
$content = $content -replace "distributed caching via Redis", "local in-memory caching"
$content = $content -replace "Redis distributed cache", "IMemoryCache (local in-memory)"
$content = $content -replace "IDistributedCache", "IMemoryCache"
$content = $content -replace "_distributedCache", "_memoryCache"
$content = $content -replace "distributed cache", "local cache"
$content = $content -replace "Distributed Cache", "Local Cache"
$content = $content -replace "IStackExchangeRedisConnection _redis", "// No Redis connection (local cache only)"
$content = $content -replace "IStackExchangeRedisConnection redis", "// No Redis dependency"
$content = $content -replace "StackExchangeRedisConnection", "// Not used - IMemoryCache only"
$content = $content -replace "AddStackExchangeRedisConnection", "// Not used - AddMemoryCache instead"
$content = $content -replace "Redis Pub/Sub", "CDC polling"
$content = $content -replace "L2: Check Redis", "// No L2 tier - direct to database on cache miss"
$content = $content -replace "L2: Redis", "// No L2 tier"
$content = $content -replace "Populate L1 cache", "Populate cache"
$content = $content -replace "Populate both caches", "Populate cache"
$content = $content -replace "Remove from L1", "Remove from cache"
$content = $content -replace "Remove from L2", "// No L2 tier to remove from"
$content = $content -replace "Multi-tier cache", "Local cache"
$content = $content -replace "multi-tier cache", "local cache"
$content = $content -replace "DistributedDataSyncService", "// Not used - CDC handles sync"
$content = $content -replace "PublishCacheKeyAsync", "// Not used - no pub/sub"

# Write updated content back to file
$content | Set-Content $filePath -Encoding UTF8 -NoNewline

# Count remaining Redis references
$finalCount = ([regex]::Matches($content, "Redis|redis")).Count
Write-Host "Remaining Redis references: $finalCount" -ForegroundColor Yellow
Write-Host "Cleaned: $(($initialCount - $finalCount)) references" -ForegroundColor Green
Write-Host "Update complete" -ForegroundColor Cyan
