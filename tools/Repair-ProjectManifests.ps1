# ============================================================================
# Repair-ProjectManifests.ps1 -- find and fix resource.json manifests that name
#                                files which are not on disk.
#
# THE FAILURE THIS FIXES
#   A resource.json "files" array is a MANIFEST: the Gateway builds the resource
#   from it. Name a file that is not there and the Gateway logs
#
#       ResourceCollectionFileTree: Error creating dataFile for
#         resourceManifest=...\resource.json, file=thumbnail.png
#       java.nio.file.NoSuchFileException
#
#   per resource, the project fails to resolve, and the Designer dies on startup:
#
#       NullPointerException: Cannot invoke
#         ResourceCollection.getInheritanceStructure() because "project" is null
#
#   The Gateway keeps serving resources it has already loaded, so Perspective
#   sessions keep working. The Designer builds the project tree from scratch on
#   connect and gets null. "Runs fine but will not open in the Designer" is the
#   signature of exactly this and nothing else.
#
# WHY IT DRIFTS
#   thumbnail.png is Gateway-regenerated and gitignored, so a manifest naming one
#   is correct on the machine that generated it and wrong everywhere else.
#   Dropping the entry is the right direction: the Designer regenerates the
#   thumbnail and re-declares it the next time the view is saved.
#
# NO PYTHON, NO GATEWAY SCAN, NO NETWORK. Pure filesystem.
#
# USAGE
#   # report only -- writes nothing
#   .\Repair-ProjectManifests.ps1 -Path "C:\Program Files\Inductive Automation\Ignition\data\projects"
#
#   # repair
#   .\Repair-ProjectManifests.ps1 -Path "C:\Program Files\Inductive Automation\Ignition\data\projects" -Fix
#
#   Point -Path at the projects ROOT (scans every project under it) or at one
#   project folder. Needs write access to data\projects, so run it elevated --
#   that folder is usually SYSTEM-owned.
#
# AFTER -Fix: restart the Ignition Gateway service, then open the Designer.
#   A project scan is NOT enough here: the broken ResourceCollection is already
#   loaded in memory and the scan reconciles resources, not the failed project
#   tree. Restart is the reliable path.
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$Fix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path)) { throw "Not found: $Path" }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  IGNITION PROJECT MANIFEST CHECK' -ForegroundColor Cyan
Write-Host ("  Path: {0}" -f $Path)
if ($Fix) { Write-Host '  MODE: -Fix -- manifests WILL be rewritten' -ForegroundColor Yellow }
else      { Write-Host '  MODE: report only -- nothing will be written' -ForegroundColor Green }
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# PowerShell's -Recurse does NOT traverse junctions/symlinks. Point this at a
# projects ROOT whose children are junctions (the dev layout, where each project
# folder links into the repo) and it silently reports on almost nothing -- 198
# manifests instead of 725, and a clean bill of health for projects it never
# opened. Expand the top-level children explicitly and scan each by its resolved
# target so a linked project is scanned exactly like a real one.
$roots = @()
$topLevel = @(Get-ChildItem -Path $Path -Directory -Force -ErrorAction SilentlyContinue)
if ($topLevel.Count -gt 0 -and -not (Test-Path (Join-Path $Path 'project.json'))) {
    foreach ($c in $topLevel) {
        $target = $c.FullName
        if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $resolved = (Get-Item $c.FullName -Force).Target
            if ($resolved) {
                $target = @($resolved)[0]
                Write-Host ("  (following junction {0} -> {1})" -f $c.Name, $target) -ForegroundColor DarkGray
            }
        }
        $roots += $target
    }
} else {
    $roots = @($Path)
}

$manifests = @()
foreach ($r in $roots) {
    $manifests += @(Get-ChildItem -Path $r -Filter 'resource.json' -Recurse -File -ErrorAction SilentlyContinue)
}
$lying       = @()
$orphanDirs  = @()
$notLeaf     = @()
$unreadable  = @()

foreach ($m in $manifests) {
    $dir = $m.DirectoryName
    try   { $obj = Get-Content $m.FullName -Raw | ConvertFrom-Json }
    catch { $unreadable += $m.FullName; continue }

    if (-not ($obj.PSObject.Properties.Name -contains 'files')) { continue }

    # PS collapses a one-element JSON array to a scalar on parse -- force an array.
    $declared = @($obj.files)
    $present  = @($declared | Where-Object { Test-Path (Join-Path $dir $_) })
    $absent   = @($declared | Where-Object { -not (Test-Path (Join-Path $dir $_)) })

    if ($absent.Count -gt 0) {
        # WHICH DIRECTION THE REPAIR GOES DEPENDS ENTIRELY ON WHAT IS MISSING.
        #   thumbnail.png  -- a Gateway-regenerated PREVIEW. Dropping it from
        #                     the manifest loses nothing; the Designer makes a
        #                     new one and re-declares it on the next save.
        #   anything else  -- the resource's actual CONTENT. view.json, code.py,
        #                     query.sql ARE the resource. Dropping one from the
        #                     manifest does not repair anything; it deletes the
        #                     view/script/query from the project. The file has
        #                     to be PUT BACK, from the repo or the export zip.
        # Getting this backwards turns a one-file restore into data loss, so
        # -Fix refuses to touch the second kind.
        $regenerable = @($absent | Where-Object { $_ -eq 'thumbnail.png' })
        $content     = @($absent | Where-Object { $_ -ne 'thumbnail.png' })
        $lying += [pscustomobject]@{
            Manifest    = $m.FullName
            Dir         = $dir
            Missing     = ($absent -join ', ')
            Keep        = $present
            Repairable  = ($content.Count -eq 0)
            ContentGone = ($content -join ', ')
        }
    }
}

# A folder holding content but NO resource.json is invisible to the scanner:
# a view renders "View Not Found", a named query logs "Named query not found".
$contentNames = @('view.json','code.py','query.sql','style.json','props.json','config.json')
$allDirs = @()
foreach ($r in $roots) {
    $allDirs += @(Get-ChildItem -Path $r -Recurse -Directory -ErrorAction SilentlyContinue)
}
$allDirs | ForEach-Object {
    $d = $_.FullName
    $hasContent  = @(Get-ChildItem -Path $d -File -ErrorAction SilentlyContinue |
                     Where-Object { $contentNames -contains $_.Name })
    $hasManifest = Test-Path (Join-Path $d 'resource.json')
    if ($hasContent.Count -gt 0 -and -not $hasManifest) { $orphanDirs += $d }

    # A script-python resource is a LEAF of code.py + resource.json. Give it a
    # child folder (a __pycache__, say) and the Gateway renders it as a FOLDER,
    # not a module -- BlueRidge.Common.Util stops resolving and Jython falls
    # through to a same-named Java package.
    if (Test-Path (Join-Path $d 'code.py')) {
        $kids = @(Get-ChildItem -Path $d -Directory -ErrorAction SilentlyContinue)
        if ($kids.Count -gt 0) { $notLeaf += ("{0}  ->  {1}" -f $d, ($kids.Name -join ', ')) }
    }
}

Write-Host ("  {0} manifest(s) scanned" -f $manifests.Count)
Write-Host ''

$repairable = @($lying | Where-Object { $_.Repairable })
$lost       = @($lying | Where-Object { -not $_.Repairable })

if ($lying.Count -gt 0) {
    Write-Host ("  {0} MANIFEST(S) NAME A FILE THAT IS NOT ON DISK" -f $lying.Count) -ForegroundColor Red
    Write-Host '  ^ this is what stops the Designer opening the project' -ForegroundColor Red
    Write-Host ''
}

if ($lost.Count -gt 0) {
    Write-Host ("  {0} of them are MISSING CONTENT -- the resource itself is gone:" -f $lost.Count) -ForegroundColor Red
    $lost | ForEach-Object {
        Write-Host ("     {0}" -f $_.Manifest.Replace($Path, '')) -ForegroundColor Red
        Write-Host ("        MISSING: {0}   <-- restore this file; do NOT drop it" -f $_.ContentGone) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  Copy each named file back from the repo (or the export zip) into its' -ForegroundColor Cyan
    Write-Host '  folder. -Fix will NOT touch these: dropping content from a manifest' -ForegroundColor Cyan
    Write-Host '  deletes the resource from the project instead of repairing it.' -ForegroundColor Cyan
    Write-Host ''
}

if ($repairable.Count -gt 0) {
    Write-Host ("  {0} are a stale thumbnail.png reference (safe to drop):" -f $repairable.Count) -ForegroundColor DarkYellow
    $repairable | Select-Object -First 8 | ForEach-Object {
        Write-Host ("     {0}" -f $_.Manifest.Replace($Path, '')) -ForegroundColor DarkYellow
    }
    if ($repairable.Count -gt 8) { Write-Host ("     ... and {0} more" -f ($repairable.Count - 8)) -ForegroundColor DarkYellow }
}

if ($lying.Count -eq 0) { Write-Host '  no lying manifests' -ForegroundColor Green }

if ($orphanDirs.Count -gt 0) {
    Write-Host ''
    Write-Host ("  {0} folder(s) with content but NO resource.json (invisible to the scanner):" -f $orphanDirs.Count) -ForegroundColor Red
    $orphanDirs | Select-Object -First 8 | ForEach-Object { Write-Host ("     {0}" -f $_.Replace($Path, '')) -ForegroundColor DarkYellow }
}

if ($notLeaf.Count -gt 0) {
    Write-Host ''
    Write-Host ("  {0} script resource(s) with a child folder (renders as a folder, not a module):" -f $notLeaf.Count) -ForegroundColor Red
    $notLeaf | Select-Object -First 8 | ForEach-Object { Write-Host ("     {0}" -f $_.Replace($Path, '')) -ForegroundColor DarkYellow }
}

if ($unreadable.Count -gt 0) {
    Write-Host ''
    Write-Host ("  {0} unreadable manifest(s):" -f $unreadable.Count) -ForegroundColor Red
    $unreadable | ForEach-Object { Write-Host ("     {0}" -f $_.Replace($Path, '')) -ForegroundColor DarkYellow }
}

if (-not $Fix) {
    Write-Host ''
    if ($lying.Count -gt 0) {
        Write-Host '  Re-run with -Fix to drop the missing entries from those manifests.' -ForegroundColor Cyan
        Write-Host '  (Run elevated: data\projects is usually SYSTEM-owned.)' -ForegroundColor DarkGray
    }
    Write-Host ''
    exit ($(if ($lying.Count -gt 0 -or $orphanDirs.Count -gt 0 -or $notLeaf.Count -gt 0) { 1 } else { 0 }))
}

# ---- repair ---------------------------------------------------------------
$fixed = 0
foreach ($item in $repairable) {
    $raw = Get-Content $item.Manifest -Raw
    $obj = $raw | ConvertFrom-Json

    # Rebuild via a placeholder: PS 5.1 renders a one-element array as a SCALAR,
    # which breaks the schema just as surely as a lying manifest does.
    $obj.files = @('__FILES__')
    $json = $obj | ConvertTo-Json -Depth 30
    $arr  = "[`r`n" + (($item.Keep | ForEach-Object { '    "' + $_ + '"' }) -join ",`r`n") + "`r`n  ]"
    $json = $json -replace '"files":\s*\[\s*"__FILES__"\s*\]', ('"files": ' + $arr)
    $json = $json -replace '"files":\s*"__FILES__"',            ('"files": ' + $arr)

    Set-Content -Path $item.Manifest -Value $json -Encoding UTF8 -NoNewline
    $fixed++
}

Write-Host ''
Write-Host ("  REPAIRED {0} manifest(s)." -f $fixed) -ForegroundColor Green
if ($lost.Count -gt 0) {
    Write-Host ("  LEFT ALONE {0} manifest(s) whose CONTENT is missing -- restore those files by hand." -f $lost.Count) -ForegroundColor Red
}
Write-Host ''
Write-Host '  NEXT: restart the Ignition Gateway service, then open the Designer.' -ForegroundColor Cyan
Write-Host '        A project scan is NOT enough -- the failed project tree is' -ForegroundColor DarkGray
Write-Host '        already loaded in memory; the restart is what rebuilds it.' -ForegroundColor DarkGray
Write-Host ''
