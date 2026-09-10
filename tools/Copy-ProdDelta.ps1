# ============================================================================
# Copy-ProdDelta.ps1 -- copy ONLY the files that changed since prod's baseline
#                       into a live Gateway's project store.
#
# WHY THIS EXISTS
#   The normal path for a new Gateway is import a zip. Prod is live and carrying
#   real LOTs, so a full import is more blast radius than the change deserves.
#   This copies an explicit, reviewed list -- 25 files -- and touches nothing
#   else. It cannot delete, and it will not create a folder that has no
#   resource.json to go with it.
#
#   The list is derived from `git diff --name-status <baseline>..HEAD` over
#   ignition/projects, minus the resource.json files whose only change is
#   dropping a thumbnail.png entry (prod's imported tree never had those
#   thumbnails, so its manifests already agree with its payload).
#
# USAGE
#   .\tools\Copy-ProdDelta.ps1 -Destination "\\MESAPP01\c$\Program Files\Inductive Automation\Ignition\data\projects" -WhatIf
#   .\tools\Copy-ProdDelta.ps1 -Destination "C:\Program Files\Inductive Automation\Ignition\data\projects"
#
#   Run -WhatIf first. It prints every action and writes nothing.
#
# AFTER RUNNING: POST the project scan endpoint on that Gateway, then run
#   python tools/verify_project_tree.py "<Destination>\Core"   (and MPP, MPP_Config)
# ============================================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Destination,

    # Repo root; defaults to this script's parent.
    [string]$SourceRoot = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),

    [switch]$Force   # copy even when source and destination are already identical
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- the delta, explicit and reviewed ---------------------------------------
# Paths are relative to <root>\ignition\projects. Every new resource folder
# lists BOTH its content file and its resource.json: a folder without a
# manifest is invisible to the scanner (view renders "View Not Found";
# named query logs "Named query not found").
$Files = @(
    # ---- Core: named queries --------------------------------------------
    'Core\ignition\named-query\lots\DieCastLot_Release\query.sql'
    'Core\ignition\named-query\lots\DieCastLot_Release\resource.json'
    'Core\ignition\named-query\oee\DowntimeScope_ListForTerminal\query.sql'
    'Core\ignition\named-query\oee\DowntimeScope_ListForTerminal\resource.json'
    'Core\ignition\named-query\workorder\DieCastShiftOutput_Record\query.sql'
    'Core\ignition\named-query\workorder\DieCastShiftOutput_Record\resource.json'
    'Core\ignition\named-query\workorder\DieCast_GetReleasePreview\query.sql'
    'Core\ignition\named-query\workorder\DieCast_GetReleasePreview\resource.json'
    'Core\ignition\named-query\workorder\DieCast_GetShiftOutputBreakdown\query.sql'
    'Core\ignition\named-query\workorder\DieCast_GetShiftOutputBreakdown\resource.json'
    # ---- Core: script modules -------------------------------------------
    'Core\ignition\script-python\BlueRidge\Lots\Lot\code.py'
    'Core\ignition\script-python\BlueRidge\Oee\Downtime\code.py'
    'Core\ignition\script-python\BlueRidge\Parts\Tool\code.py'
    'Core\ignition\script-python\BlueRidge\Workorder\DieCast\code.py'
    # ---- MPP: views ------------------------------------------------------
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\PlantFloor\DieCastEntry\BulkOpenRow\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\PlantFloor\DieCastEntry\CavityLotRow\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\PlantFloor\DieCastEntry\OpenBasketRow\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\PlantFloor\DieCastEntry\ScrapLineRow\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\PlantFloor\ElevationModal\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\DieCastRelease\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\DieCastRelease\resource.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\DieCastLotReleaseHowTo\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\DieCastOpenHowTo\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\DieCastShiftOutputHowTo\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\DowntimeManager\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Views\ShopFloor\AppHeader\view.json'
    'MPP\com.inductiveautomation.perspective\views\BlueRidge\Views\ShopFloor\DieCastBody\view.json'
    # ---- MPP_Config: views ----------------------------------------------
    'MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Parts\Tools\Cavities\view.json'
    'MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Parts\Tools\_Tools\CavityRow\view.json'
)

$SrcBase = Join-Path $SourceRoot 'ignition\projects'
if (-not (Test-Path $SrcBase))     { throw "Source not found: $SrcBase" }
if (-not (Test-Path $Destination)) { throw "Destination not found: $Destination" }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  PROD DELTA COPY' -ForegroundColor Cyan
Write-Host ("  From: {0}" -f $SrcBase)
Write-Host ("  To:   {0}" -f $Destination)
if ($WhatIfPreference) { Write-Host '  MODE: -WhatIf -- nothing will be written' -ForegroundColor Yellow }
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

function Get-Sha([string]$p) {
    if (-not (Test-Path $p)) { return $null }
    return (Get-FileHash -Path $p -Algorithm SHA256).Hash
}

$copied = 0; $same = 0; $new = 0; $missing = @()

foreach ($rel in $Files) {
    $src = Join-Path $SrcBase $rel
    $dst = Join-Path $Destination $rel

    if (-not (Test-Path $src)) { $missing += $rel; continue }

    $dstDir = Split-Path -Parent $dst
    $isNew  = -not (Test-Path $dst)

    if ((Get-Sha $src) -eq (Get-Sha $dst) -and -not $Force) {
        $same++
        Write-Host ("  same     {0}" -f $rel) -ForegroundColor DarkGray
        continue
    }

    if (-not (Test-Path $dstDir)) {
        if ($PSCmdlet.ShouldProcess($dstDir, 'create directory')) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($dst, 'copy')) {
        Copy-Item -Path $src -Destination $dst -Force
    }
    if ($isNew) { $new++;    Write-Host ("  NEW      {0}" -f $rel) -ForegroundColor Green }
    else        { $copied++; Write-Host ("  replaced {0}" -f $rel) -ForegroundColor Yellow }
}

Write-Host ''
Write-Host ("  {0} replaced, {1} new, {2} already identical" -f $copied, $new, $same)
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host ("  !! {0} source file(s) MISSING -- nothing was copied for these:" -f $missing.Count) -ForegroundColor Red
    $missing | ForEach-Object { Write-Host ("     {0}" -f $_) -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host '  NEXT:' -ForegroundColor Cyan
Write-Host '   1. POST /data/api/v1/scan/projects on that Gateway'
Write-Host '      (needs BOTH X-Ignition-API-Token AND Content-Type: application/json)'
Write-Host '   2. python tools\verify_project_tree.py "<dest>\Core"   (and MPP, MPP_Config)'
Write-Host '   3. Gateway log: zero ResourceCollectionFileTree / NoSuchFileException lines'
Write-Host ''
