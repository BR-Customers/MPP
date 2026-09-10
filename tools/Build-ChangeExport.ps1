# ============================================================
# Build-ChangeExport.ps1 -- package ONLY the resources a change touched, in the
#                           shape the Designer's Import expects.
#
# WHY THIS EXISTS RATHER THAN build-project-exports.ps1
#   That script ships whole projects (860 / 356 / 246 files). Importing a full
#   project into a LIVE prod gateway replaces far more than the thing you are
#   shipping, and every unrelated resource in the archive is a chance to
#   clobber something a person changed on the gateway. This builds an archive
#   containing exactly the resources a commit range touched.
#
# SHAPE (verified against a genuine Designer export,
#        example_export_Core_2026-09-10_1939.zip, 2026-09-10)
#   project.json                                   <- at the ZIP ROOT
#   com.inductiveautomation.perspective/views/<path>/resource.json + view.json
#   ignition/named-query/<folder>/<name>/resource.json + query.sql
#   ignition/script-python/<pkg>/<mod>/resource.json + code.py
#   No thumbnail.png. No __pycache__. Forward-slash separators.
#
#   A RESOURCE IS A FOLDER, not a file. If a view.json changed, the archive
#   must carry its resource.json too -- the Gateway builds the resource from
#   exactly the files that manifest names, so shipping one without the other
#   is how you get "View Not Found" or a Designer NullPointerException.
#
# Usage:
#   .\tools\Build-ChangeExport.ps1 -Since 8c8a8f8c
#   .\tools\Build-ChangeExport.ps1 -Since 8c8a8f8c -Label cavity-alpha-code
#   .\tools\Build-ChangeExport.ps1 -Since HEAD~5 -OutDir C:\temp\exports
#
# IMPORT ORDER AT THE GATEWAY: Core FIRST. MPP and MPP_Config both declare
# "parent": "Core" and will not resolve inherited resources without it.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Since,                      # git ref: everything changed AFTER this
    [string]$Until   = "HEAD",
    [string]$Label   = "change",
    [string]$OutDir  = "dist\ignition-exports"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot

$ProjectsRoot = Join-Path $RepoRoot "ignition\projects"
$Projects     = @("Core", "MPP", "MPP_Config")   # Core first -- see header

# Same exclusions as build-project-exports.ps1, for the same reasons.
$ExcludedNames = @('thumbnail.png', '.gitkeep', 'pull.log', 'Thumbs.db', 'desktop.ini')

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Scoped Ignition change export" -ForegroundColor Cyan
Write-Host "  Range: $Since..$Until" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 1. Which resource FOLDERS did the range touch?
# ------------------------------------------------------------
$changed = & git diff --name-only "$Since..$Until" -- "ignition/projects"
if ($LASTEXITCODE -ne 0) { throw "git diff failed for range $Since..$Until" }
if (-not $changed) { Write-Host "  Nothing changed under ignition/projects in that range." -ForegroundColor Yellow; return }

# Map each changed FILE to the resource folder that owns it: the nearest
# ancestor directory containing a resource.json.
$resourceDirs = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($rel in $changed) {
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    $dir  = Split-Path -Parent $full
    while ($dir -and $dir.StartsWith($ProjectsRoot)) {
        if (Test-Path (Join-Path $dir "resource.json")) { [void]$resourceDirs.Add($dir); break }
        $dir = Split-Path -Parent $dir
    }
}

if ($resourceDirs.Count -eq 0) { Write-Host "  No owning resource folders found." -ForegroundColor Yellow; return }

# ------------------------------------------------------------
# 2. Group by project and build one archive each
# ------------------------------------------------------------
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFull = Join-Path $RepoRoot $OutDir
if (-not (Test-Path $outFull)) { New-Item -ItemType Directory -Force $outFull | Out-Null }

$built = @()
$rewritten = 0
foreach ($proj in $Projects) {
    $projRoot = Join-Path $ProjectsRoot $proj
    $mine = @($resourceDirs | Where-Object { $_.StartsWith($projRoot + [IO.Path]::DirectorySeparatorChar) })
    if ($mine.Count -eq 0) {
        Write-Host ("  {0,-12} no changed resources -- skipped" -f $proj) -ForegroundColor DarkGray
        continue
    }

    # -- collect entries: project.json, then each resource folder's manifest + payload
    $entries = @()   # @{ Rel = 'zip/path'; Src = 'C:\...' }

    $projJson = Join-Path $projRoot "project.json"
    if (-not (Test-Path $projJson)) { throw "$proj has no project.json" }
    $entries += @{ Rel = "project.json"; Src = $projJson }

    foreach ($dir in ($mine | Sort-Object)) {
        $relDir = $dir.Substring($projRoot.Length + 1).Replace('\', '/')
        $manifestPath = Join-Path $dir "resource.json"
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

        # Ship exactly the files the manifest declares -- and make the manifest
        # match what we actually ship. A resource.json naming a file that is not
        # in the archive is what killed the Designer twice before
        # (NullPointerException: ... because "project" is null).
        $declared = @()
        if ($manifest.PSObject.Properties.Name -contains 'files' -and $manifest.files) {
            $declared = @($manifest.files)
        }
        $kept = @($declared | Where-Object { $ExcludedNames -notcontains $_ })

        foreach ($fname in $kept) {
            $fpath = Join-Path $dir $fname
            if (-not (Test-Path $fpath)) {
                throw "$relDir/resource.json declares '$fname' but it is not on disk. The Gateway builds the resource from this manifest; a missing file stops the whole project resolving."
            }
            $entries += @{ Rel = "$relDir/$fname"; Src = $fpath }
        }

        if ($kept.Count -ne $declared.Count) {
            # thumbnail.png is Gateway-regenerated and gitignored, so it is
            # excluded from the payload -- which means the manifest must stop
            # promising it. Rewritten in memory; the file on disk is untouched.
            #
            # PS 5.1's ConvertTo-Json collapses a 1-element array to a scalar,
            # which would emit "files": "view.json" and break the schema a
            # second way. Emit the array by hand through a placeholder.
            $manifest.files = @('__FILES__')
            $json = $manifest | ConvertTo-Json -Depth 20
            $arr  = '[' + (($kept | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']'
            $json = $json -replace '"files":\s*\[\s*"__FILES__"\s*\]', ('"files": ' + $arr)
            $json = $json -replace '"files":\s*"__FILES__"',              ('"files": ' + $arr)
            $entries += @{ Rel = "$relDir/resource.json"; Text = $json }
            $script:rewritten++
        }
        else {
            $entries += @{ Rel = "$relDir/resource.json"; Src = $manifestPath }
        }
    }

    # -- write the archive by hand: Compress-Archive on PS 5.1 writes BACKSLASH
    #    separators, which Java-side consumers read as one long filename.
    $zipName = "{0}_{1}_{2}.zip" -f $proj, $Label, $stamp
    $zipPath = Join-Path $outFull $zipName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($e in $entries) {
            if ($e.ContainsKey('Text')) {
                $ze = $zip.CreateEntry($e.Rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $sw = New-Object System.IO.StreamWriter($ze.Open(), (New-Object System.Text.UTF8Encoding($false)))
                try { $sw.Write($e.Text) } finally { $sw.Dispose() }
            }
            else {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $e.Src, $e.Rel,
                    [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        }
    } finally { $zip.Dispose() }

    # -- verify what we just wrote, rather than trusting it
    $verify = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($verify.Entries | ForEach-Object { $_.FullName })
        $back  = @($names | Where-Object { $_ -like '*\*' })
        if ($back.Count -gt 0) { throw "$zipName contains $($back.Count) backslash entry name(s)." }
        if ($names -notcontains 'project.json') { throw "$zipName has no project.json at the root." }
        $thumbs = @($names | Where-Object { $_ -like '*thumbnail.png' })
        if ($thumbs.Count -gt 0) { throw "$zipName contains $($thumbs.Count) thumbnail.png." }
        $pyc = @($names | Where-Object { $_ -like '*__pycache__*' -or $_ -like '*.pyc' })
        if ($pyc.Count -gt 0) { throw "$zipName contains $($pyc.Count) bytecode entr(ies)." }

        Write-Host ("  {0,-12} {1,3} resource(s), {2,3} entries  ->  {3}" -f `
            $proj, $mine.Count, $names.Count, $zipName) -ForegroundColor Green
        foreach ($dir in ($mine | Sort-Object)) {
            Write-Host ("      {0}" -f $dir.Substring($projRoot.Length + 1).Replace('\','/')) -ForegroundColor DarkGray
        }
    } finally { $verify.Dispose() }

    $built += $zipPath
}

Write-Host ""
Write-Host "  Built $($built.Count) archive(s) in $OutDir" -ForegroundColor Cyan
if ($rewritten -gt 0) {
    Write-Host "  $rewritten manifest(s) rewritten to drop an excluded file (thumbnail.png)." -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  IMPORT ORDER: Core FIRST -- MPP and MPP_Config declare parent Core" -ForegroundColor Yellow
Write-Host "  and will not resolve inherited resources without it." -ForegroundColor Yellow
Write-Host ""
Write-Host "  DEPLOY THE SQL FIRST. These views and named queries call procs and" -ForegroundColor Yellow
Write-Host "  read columns that must already exist." -ForegroundColor Yellow
Write-Host ""
