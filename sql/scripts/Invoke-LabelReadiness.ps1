# =============================================================================
# Invoke-LabelReadiness.ps1 -- run the READ-ONLY 6MA CH container label / AIM
# readiness check against a database and save the output.
#
#   Checks: printer Endpoint, AIM connection + posting gate, AIM serial pool,
#   Honda label template, FG pack-out, open container, line components, PLC map.
#   The SQL is sql/scratch/2026-09-10_6ma_ch_label_readiness.sql. It writes
#   nothing.
#
# Usage (from the repo root):
#   .\sql\scripts\Invoke-LabelReadiness.ps1                       # prod, prompts for the Ignition SQL password
#   .\sql\scripts\Invoke-LabelReadiness.ps1 -Username ""          # Windows auth
#   .\sql\scripts\Invoke-LabelReadiness.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Username ""
#
# Password: taken from $env:SQLCMDPASSWORD if set, else a masked prompt. It is
# handed to sqlcmd through that environment variable, never on the command
# line, and the variable is restored afterwards.
#
# Output: printed, and saved to dist\readiness\<db>_label_readiness_<stamp>.txt
# (dist\ is gitignored).
# =============================================================================
param(
    [string]$ServerInstance = "172.17.10.148",
    [string]$DatabaseName   = "MPP_MES_Prod",
    [string]$Username       = "Ignition"
)

$ErrorActionPreference = "Stop"
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SqlFile   = Join-Path $RepoRoot "sql\scratch\2026-09-10_6ma_ch_label_readiness.sql"
$OutDir    = Join-Path $RepoRoot "dist\readiness"
$Stamp     = Get-Date -Format "yyyy-MM-dd_HHmmss"
$OutFile   = Join-Path $OutDir ("{0}_label_readiness_{1}.txt" -f $DatabaseName, $Stamp)

if (-not (Test-Path $SqlFile)) { throw "Readiness SQL not found: $SqlFile" }
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { throw "sqlcmd is not on PATH." }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$savedEnvPw = $env:SQLCMDPASSWORD
try {
    if ($Username -ne "") {
        if (-not $env:SQLCMDPASSWORD) {
            $sec  = Read-Host "SQL password for '$Username' on $ServerInstance" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { $env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if (-not $env:SQLCMDPASSWORD) { throw "No password entered." }
        }
        $auth = @("-U", $Username)
    } else {
        $auth = @("-E")
    }

    Write-Host ""
    Write-Host "  6MA CH label readiness  ->  $DatabaseName on $ServerInstance" -ForegroundColor Cyan
    Write-Host "  (read-only)" -ForegroundColor DarkGray
    Write-Host ""

    # -b: non-zero exit on a SQL error. -C: trust the server certificate (as the
    # deploy scripts do). -W -s "|": trimmed, pipe-separated columns.
    $output = & sqlcmd -S $ServerInstance @auth -d $DatabaseName -i $SqlFile -b -C -W -s "|" 2>&1
    $code = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" })

    $header = @(
        "6MA CH label readiness",
        "Database : $DatabaseName on $ServerInstance",
        "Run at   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (local)",
        "SQL      : $SqlFile",
        ""
    )
    ($header + $text) | Set-Content -Path $OutFile -Encoding utf8

    foreach ($line in $text) {
        if     ($line -like "---*")                                        { Write-Host $line -ForegroundColor Cyan }
        elseif ($line -match "\|OK( |$)")                                  { Write-Host $line -ForegroundColor Green }
        elseif ($line -match "SET |MISSING|EMPTY|SHORT|DISABLED|NOT |CHECK|REVIEW|CONTAINS|MORE THAN") { Write-Host $line -ForegroundColor Yellow }
        else                                                               { Write-Host $line }
    }

    Write-Host ""
    if ($code -ne 0) {
        Write-Host "  sqlcmd exited $code -- see the output above." -ForegroundColor Red
    }
    Write-Host "  Saved: $OutFile" -ForegroundColor DarkGray
    exit $code
}
finally {
    $env:SQLCMDPASSWORD = $savedEnvPw
}
