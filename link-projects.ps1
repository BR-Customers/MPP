# link-projects.ps1 -- RUN FROM AN ELEVATED (Administrator) PowerShell.
#
# Junctions the gateway's Core + MPP project folders to the repo working copies,
# matching how data\projects\MPP_Config is already linked. After this, file edits
# in the repo (ignition\projects\Core | MPP) are seen by the gateway and picked up
# by .\scan.ps1 -- the standard dev loop.
#
# It is non-destructive: any existing REAL gateway folder is renamed to
# "<name>.realbak-<timestamp>" (not deleted) before the junction is created, so
# nothing is lost and the step is reversible. Already-junctioned folders are left
# alone (idempotent).
#
# One-time use (per machine). After it succeeds, run .\scan.ps1 from a normal shell.

$ErrorActionPreference = "Stop"

$gw   = "C:\Program Files\Inductive Automation\Ignition\data\projects"
$repo = "C:\Users\NoahNesbitt\Documents\Dev\MPP\ignition\projects"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Elevation check
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not elevated. Re-run this script from an Administrator PowerShell." -ForegroundColor Red
    exit 1
}

foreach ($name in @("Core", "MPP", "MPP_Config")) {
    $link   = Join-Path $gw   $name
    $target = Join-Path $repo $name

    if (-not (Test-Path $target)) {
        Write-Host "[$name] repo target missing ($target) -- SKIPPING." -ForegroundColor Yellow
        continue
    }

    $item = Get-Item $link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq "Junction") {
        Write-Host "[$name] already a junction -> $($item.Target). Nothing to do." -ForegroundColor Green
        continue
    }

    if ($item) {
        $bak = "$link.realbak-$stamp"
        Write-Host "[$name] backing up real gateway folder -> $bak"
        Move-Item -LiteralPath $link -Destination $bak -Force
    }

    Write-Host "[$name] creating junction $link -> $target"
    cmd /c mklink /J "`"$link`"" "`"$target`"" | Write-Host

    $check = Get-Item $link -Force
    if ($check.LinkType -eq "Junction") {
        Write-Host "[$name] OK (junction -> $($check.Target))" -ForegroundColor Green
    } else {
        Write-Host "[$name] FAILED to create junction." -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done. Now run  .\scan.ps1  from a normal (non-elevated) shell to register the resources with the gateway." -ForegroundColor Cyan
Write-Host "If a folder was locked by the running gateway, disable the Core/MPP project in the Gateway web UI (or stop the Ignition service), re-run this, then re-enable." -ForegroundColor DarkGray
