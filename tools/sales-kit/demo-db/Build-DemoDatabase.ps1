# Build-DemoDatabase.ps1 -- build MPP_MES_Demo, the sanitized sample-plant database the sales kit
# is captured from. Disposable: drops and rebuilds MPP_MES_Demo every run. Never touches Dev.
#
#   .\tools\sales-kit\demo-db\Build-DemoDatabase.ps1 [-ServerInstance localhost]
#
# Steps: Reset-DevDatabase.ps1 (migrations + repeatables, no sql\seeds, no demo threads);
# the generic seeds the screens need (operation templates, the placeholder shipper-ID pool);
# sql\seeds_demo\*.sql in name order; sanitize_db.py (customer text -> sample text); every
# verify_*.sql here; the sanitized gate (test_dump_text.py). Any failure stops the build.
[CmdletBinding()]
param(
    [string]$ServerInstance = "localhost",
    [string]$DatabaseName   = "MPP_MES_Demo"
)
$ErrorActionPreference = "Stop"
if ($DatabaseName -ne "MPP_MES_Demo") { throw "Build-DemoDatabase: only builds MPP_MES_Demo (got '$DatabaseName')." }

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo    = (Resolve-Path (Join-Path $Here "..\..\..")).Path
$SqlRoot = Join-Path $Repo "sql"

function Invoke-DemoSqlFile([string]$Path) {
    Write-Host "  Running: $(Split-Path -Leaf $Path)" -ForegroundColor DarkGray
    $text = Get-Content -Raw $Path
    if ($text -match '(?im)^\s*USE\s+\[?MPP_MES_') { throw "$Path contains a USE statement; demo scripts must not pick their database." }
    $out = & sqlcmd -S $ServerInstance -E -C -I -b -d $DatabaseName -i $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed on $Path"
    }
    $out | Where-Object { $_ -match 'PASS|FAIL' } | ForEach-Object { Write-Host "    $_" }
}

Write-Host "[demo 1/4] Reset (schema only)..." -ForegroundColor Cyan
& (Join-Path $SqlRoot "scripts\Reset-DevDatabase.ps1") -ServerInstance $ServerInstance -DatabaseName $DatabaseName -SkipSeeds -SkipDemoSeed
if (-not $?) { throw "Reset-DevDatabase failed" }

Write-Host "[demo 2/4] Generic seeds..." -ForegroundColor Cyan
foreach ($f in @("022_seed_die_cast_operation_template.sql", "024_seed_trim_operation_templates.sql",
                 "026_seed_machining_operation_templates.sql", "027_seed_assembly_operation_templates.sql",
                 "028_seed_aim_pool_dev.sql")) {
    Invoke-DemoSqlFile (Join-Path $SqlRoot "seeds\$f")
}

Write-Host "[demo 3/4] Sample-plant seeds..." -ForegroundColor Cyan
Get-ChildItem (Join-Path $SqlRoot "seeds_demo") -Filter "*.sql" | Sort-Object Name | ForEach-Object { Invoke-DemoSqlFile $_.FullName }

Write-Host "[demo 4/4] Sanitize, verify, gate..." -ForegroundColor Cyan
& python -I (Join-Path $Here "sanitize_db.py") --server $ServerInstance
if ($LASTEXITCODE -ne 0) { throw "sanitize_db.py failed" }
Get-ChildItem $Here -Filter "verify_*.sql" | Sort-Object Name | ForEach-Object { Invoke-DemoSqlFile $_.FullName }
& python -I (Join-Path $Here "test_dump_text.py")
if ($LASTEXITCODE -ne 0) { throw "sanitized gate failed: customer text left in MPP_MES_Demo" }
Write-Host "MPP_MES_Demo built, sanitized and verified." -ForegroundColor Green
