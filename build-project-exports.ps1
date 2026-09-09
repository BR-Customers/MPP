# ============================================================================
# build-project-exports.ps1 -- build Ignition 8.3 project export .zip files
#                              from the repo's file-based project folders.
#
# WHY THIS EXISTS
#   The normal deploy path for this project is NOT export/import: the Gateway
#   junctions into ignition/projects/<P> and picks up changes via scan.ps1
#   (see ignition-context-pack/09_repo_gateway_sync.md). That works because the
#   Gateway and the repo are on the same machine.
#
#   A BRAND-NEW Gateway -- e.g. MPP's production server, which has no projects
#   on it yet -- has nothing to junction to and no repo checkout. Import a zip
#   once to seed it, then set up the git-sync loop (or keep importing).
#
# FORMAT (verified against a real Ignition-produced export,
#         Downloads\MPP_2026-08-20_0713.zip, gateway 8.3.5-rc1)
#   * project.json sits at the ROOT of the zip -- NOT nested under a folder
#     named after the project.
#   * Every other entry is a resource path relative to that root, e.g.
#     com.inductiveautomation.perspective/views/<Path>/view.json
#   * Entry separators are FORWARD SLASHES. This matters: Compress-Archive on
#     Windows PowerShell 5.1 has historically written backslash separators,
#     which Java-side consumers read as one long filename instead of a tree.
#     This script therefore builds entries by hand via System.IO.Compression
#     rather than using Compress-Archive.
#   * Files only -- no explicit directory entries (matches the donor).
#
# WHAT IS EXCLUDED (and why)
#   thumbnail.png          Gateway-regenerated per-view preview. 159 of them in
#                          this repo; gitignored for the same reason.
#   views/**/data.bin      Gateway-regenerated view binary. NOTE the path
#                          restriction: report data.bin under
#                          com.inductiveautomation.reporting/reports/<R>/ is a
#                          REAL authored resource and IS included (12 of them).
#   .gitkeep / .git*       Repo scaffolding, meaningless to the Gateway.
#   *.realbak*             link-projects.ps1's backups of pre-junction folders.
#   pull.log, Thumbs.db, desktop.ini    Runtime / OS noise.
#
# Usage:
#   .\build-project-exports.ps1                       # Core, MPP, MPP_Config
#   .\build-project-exports.ps1 -Projects MPP
#   .\build-project-exports.ps1 -OutputDir C:\deploy -NoTimestamp
#
# IMPORT ORDER ON THE TARGET GATEWAY
#   Core FIRST. MPP and MPP_Config both declare "parent": "Core" and will not
#   resolve their inherited views, scripts, named queries or styles until the
#   parent project exists.
# ============================================================================

[CmdletBinding()]
param(
    [string[]]$Projects  = @('Core', 'MPP', 'MPP_Config'),
    [string]  $OutputDir = '',
    [switch]  $NoTimestamp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression            # ZipArchive / ZipArchiveMode
Add-Type -AssemblyName System.IO.Compression.FileSystem # ZipFile / ZipFileExtensions

$RepoRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectsDir = Join-Path $RepoRoot 'ignition\projects'
if ($OutputDir -eq '') { $OutputDir = Join-Path $RepoRoot 'dist\ignition-exports' }

# Excluded if the file NAME matches...
$ExcludedNames = @('thumbnail.png', '.gitkeep', 'pull.log', 'Thumbs.db', 'desktop.ini')
# ...or if the RELATIVE PATH matches one of these (forward-slash form).
$ExcludedPathPatterns = @(
    '(^|/)views/.*/data\.bin$',   # view binary -- regenerated. Reports' data.bin is NOT matched.
    '(^|/)\.git',                 # .git, .gitignore, .gitattributes
    '\.realbak',                  # link-projects.ps1 backups
    '(^|/)__pycache__(/|$)',      # CPython bytecode -- see below
    '\.py[co]$'
)

# __pycache__ is not merely noise: a script-python resource is a LEAF folder holding
# code.py + resource.json. Ship a __pycache__ subfolder inside it and the Gateway
# renders the resource as a FOLDER instead of a module, so BlueRidge.Common.Util
# stops being callable and Jython falls through to a same-named Java package:
#   AttributeError: 'com.inductiveautomation...' object has no attribute 'Util'
# The bytecode is CPython 3.x anyway; Ignition runs Jython 2.7 and never reads it.

function Test-Excluded {
    param([string]$RelPath, [string]$Name)
    if ($ExcludedNames -contains $Name) { return $true }
    foreach ($p in $ExcludedPathPatterns) { if ($RelPath -match $p) { return $true } }
    return $false
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  IGNITION PROJECT EXPORTS' -ForegroundColor Cyan
Write-Host "  Source: $ProjectsDir" -ForegroundColor Cyan
Write-Host "  Output: $OutputDir" -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmm'
$results  = @()

foreach ($proj in $Projects) {

    $srcDir = Join-Path $ProjectsDir $proj
    if (-not (Test-Path $srcDir)) { throw "Project folder not found: $srcDir" }

    # A folder without project.json is not an Ignition project (the repo carries
    # a couple of empty stubs -- MPP_MES, 'Refrence project' -- that are not).
    $projJson = Join-Path $srcDir 'project.json'
    if (-not (Test-Path $projJson)) {
        throw "$proj has no project.json -- not an Ignition project, refusing to export it."
    }

    $meta   = Get-Content $projJson -Raw | ConvertFrom-Json
    $title  = $meta.title
    $parent = if ($meta.parent -ne '') { $meta.parent } else { '<none>' }

    $zipName = if ($NoTimestamp) { "$proj.zip" } else { "${proj}_$stamp.zip" }
    $zipPath = Join-Path $OutputDir $zipName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    $srcFull = (Resolve-Path $srcDir).Path.TrimEnd('\')
    $all     = @(Get-ChildItem -Path $srcFull -Recurse -File -Force)

    $included = @()
    $skipped  = 0
    foreach ($f in $all) {
        $rel = $f.FullName.Substring($srcFull.Length + 1).Replace('\', '/')
        if (Test-Excluded -RelPath $rel -Name $f.Name) { $skipped++; continue }
        $included += [pscustomobject]@{ Full = $f.FullName; Rel = $rel }
    }

    # SAFETY NET. This builder walks the FILESYSTEM, so anything sitting in the working
    # tree ships -- including files git deliberately ignores. That is how __pycache__
    # reached a customer Gateway and broke 17 script modules. Git's ignore list is the
    # best available statement of "this is local junk, not project source", so anything
    # still included that git ignores is reported loudly rather than shipped silently.
    $ignored = @()
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $relPaths = $included | ForEach-Object { "ignition/projects/$proj/$($_.Rel)" }
        $ignored  = @($relPaths | git -C $RepoRoot check-ignore --stdin 2>$null)
        # check-ignore exits 1 when NOTHING matched -- the good case here. Clear it so
        # the script's own exit status still means what it says.
        $global:LASTEXITCODE = 0
    }
    if ($ignored.Count -gt 0) {
        Write-Host ("               WARNING: {0} git-ignored file(s) are being shipped:" -f $ignored.Count) -ForegroundColor Red
        $ignored | Select-Object -First 10 | ForEach-Object { Write-Host "                 $_" -ForegroundColor Red }
        Write-Host '                 Add them to $ExcludedNames / $ExcludedPathPatterns, or delete them.' -ForegroundColor Yellow
    }

    # A resource.json's "files" array is a MANIFEST: the Gateway materializes the
    # resource from exactly the files it names. If we exclude a file (thumbnail.png)
    # but ship a resource.json still promising it, the import produces a resource the
    # Gateway cannot build -- the whole project then fails to load and the Designer
    # dies with "NullPointerException ... because \"project\" is null". A genuine
    # Ignition export never has this problem because it writes the manifest to match
    # what it actually emits. So must we: drop excluded names from "files" too.
    $rewritten = 0

    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        # project.json first, so it lands at the top of the archive like a real export.
        foreach ($entry in ($included | Sort-Object { if ($_.Rel -eq 'project.json') { '' } else { $_.Rel } })) {

            $manifestJson = $null
            if ($entry.Rel -like '*resource.json') {
                $obj = Get-Content $entry.Full -Raw | ConvertFrom-Json
                if ($obj.PSObject.Properties.Name -contains 'files') {
                    $declared = @($obj.files)
                    $kept     = @($declared | Where-Object { -not (Test-Excluded -RelPath $_ -Name $_) })
                    if ($kept.Count -ne $declared.Count) {
                        # PS 5.1's ConvertTo-Json collapses a 1-element array to a scalar,
                        # which would emit "files": "view.json" and break the schema. Emit
                        # the array by hand through a placeholder instead.
                        $obj.files    = @('__FILES__')
                        $manifestJson = $obj | ConvertTo-Json -Depth 20
                        $arr = '[' + (($kept | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']'
                        $manifestJson = $manifestJson -replace '"files":\s*\[\s*"__FILES__"\s*\]', ('"files": ' + $arr)
                        $manifestJson = $manifestJson -replace '"files":\s*"__FILES__"',            ('"files": ' + $arr)
                        $rewritten++
                    }
                }
            }

            if ($null -ne $manifestJson) {
                $ze = $zip.CreateEntry($entry.Rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $sw = New-Object System.IO.StreamWriter($ze.Open(), (New-Object System.Text.UTF8Encoding($false)))
                try { $sw.Write($manifestJson) } finally { $sw.Dispose() }
            }
            else {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $entry.Full, $entry.Rel,
                    [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        }
    }
    finally { $zip.Dispose() }

    if ($rewritten -gt 0) {
        Write-Host ("               {0} resource.json manifest(s) rewritten to drop excluded files" -f $rewritten) -ForegroundColor DarkYellow
    }

    $sizeKb = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
    $hash   = (Get-FileHash $zipPath -Algorithm SHA256).Hash.Substring(0, 16)

    Write-Host ("  {0,-12} '{1}'" -f $proj, $title) -ForegroundColor Green
    Write-Host ("               parent: {0} | inheritable: {1}" -f $parent, $meta.inheritable) -ForegroundColor Gray
    Write-Host ("               {0} files ({1} excluded) -> {2}  [{3} KB]" -f $included.Count, $skipped, $zipName, $sizeKb) -ForegroundColor Gray

    $results += [pscustomobject]@{
        Project = $proj; Title = $title; Parent = $parent
        Files = $included.Count; Excluded = $skipped; SizeKB = $sizeKb
        Zip = $zipName; Sha256 = $hash
    }
}

Write-Host ''
Write-Host 'IMPORT ORDER: Core first (MPP and MPP_Config inherit from it).' -ForegroundColor Yellow
Write-Host ''
$results | Format-Table -AutoSize
