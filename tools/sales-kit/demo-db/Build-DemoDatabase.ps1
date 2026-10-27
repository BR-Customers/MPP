# Build-DemoDatabase.ps1 -- build MPP_MES_Demo, the sanitized sample-plant database the sales kit
# is captured from. Disposable: drops and rebuilds MPP_MES_Demo every run. Never touches Dev.
#
#   .\tools\sales-kit\demo-db\Build-DemoDatabase.ps1 [-ServerInstance localhost] [-WithQualityScenario]
#
# -WithQualityScenario (sales-kit module 4): after the base verifies pass, also runs
# sql\seeds_demo\opt\*.sql (a hard Hold, an open super-lot and its members), sanitizes again and
# runs verify_demo_quality.sql. Opt-in so modules 1-3 can be recaptured without super-lot state.
#
# Steps: Reset-DevDatabase.ps1 (migrations + repeatables, no sql\seeds, no demo threads);
# the generic seeds the screens need (operation templates, the placeholder shipper-ID pool);
# sql\seeds_demo\*.sql in name order; sanitize_db.py (customer text -> sample text); every
# verify_*.sql here; the sanitized gate (test_dump_text.py). Any failure stops the build.
[CmdletBinding()]
param(
    [string]$ServerInstance = "localhost",
    [string]$DatabaseName   = "MPP_MES_Demo",
    [switch]$WithQualityScenario
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

Write-Host "[demo 1/5] Reset (schema only)..." -ForegroundColor Cyan
& (Join-Path $SqlRoot "scripts\Reset-DevDatabase.ps1") -ServerInstance $ServerInstance -DatabaseName $DatabaseName -SkipSeeds -SkipDemoSeed
if (-not $?) { throw "Reset-DevDatabase failed" }

Write-Host "[demo 2/5] Generic seeds..." -ForegroundColor Cyan
foreach ($f in @("022_seed_die_cast_operation_template.sql", "024_seed_trim_operation_templates.sql",
                 "026_seed_machining_operation_templates.sql", "027_seed_assembly_operation_templates.sql",
                 "028_seed_aim_pool_dev.sql")) {
    Invoke-DemoSqlFile (Join-Path $SqlRoot "seeds\$f")
}

Write-Host "[demo 3/5] Sample-plant seeds..." -ForegroundColor Cyan
Get-ChildItem (Join-Path $SqlRoot "seeds_demo") -Filter "*.sql" | Sort-Object Name | ForEach-Object { Invoke-DemoSqlFile $_.FullName }

Write-Host "[demo 4/5] Sanitize, verify..." -ForegroundColor Cyan
& python -I (Join-Path $Here "sanitize_db.py") --server $ServerInstance
if ($LASTEXITCODE -ne 0) { throw "sanitize_db.py failed" }
# verify_demo_quality.sql belongs to the opt scenario; the base verifies run before it is loaded
Get-ChildItem $Here -Filter "verify_*.sql" | Where-Object Name -ne "verify_demo_quality.sql" | Sort-Object Name | ForEach-Object { Invoke-DemoSqlFile $_.FullName }

if ($WithQualityScenario) {
    Write-Host "[demo 4b] Quality scenario..." -ForegroundColor Cyan
    Get-ChildItem (Join-Path $SqlRoot "seeds_demo\opt") -Filter "*.sql" | Sort-Object Name | ForEach-Object { Invoke-DemoSqlFile $_.FullName }
    & python -I (Join-Path $Here "sanitize_db.py") --server $ServerInstance
    if ($LASTEXITCODE -ne 0) { throw "sanitize_db.py failed" }
    Invoke-DemoSqlFile (Join-Path $Here "verify_demo_quality.sql")
}

Write-Host "[demo 5/5] Sanitized gate..." -ForegroundColor Cyan
& python -I (Join-Path $Here "test_dump_text.py")
if ($LASTEXITCODE -ne 0) { throw "sanitized gate failed: customer text left in MPP_MES_Demo" }
Write-Host "MPP_MES_Demo built, sanitized and verified." -ForegroundColor Green
