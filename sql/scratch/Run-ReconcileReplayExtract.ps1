# ============================================================
# Run-ReconcileReplayExtract.ps1
#
# Runs the READ-ONLY die-cast reconciliation REPLAY EXTRACT against a target
# database and writes one CSV per result set, plus a readable summary.
#
# The SQL it runs (2026-09-29_reconcile_replay_extract.sql) is SELECTs only --
# no writes, no transaction, no temp tables, no procedure calls. Safe on
# MPP_MES_Prod during production. This script re-checks that before connecting
# and refuses to run if a write keyword has appeared in the file.
#
# WHY THIS EXISTS (and how it differs from Run-DieCastOnRecord.ps1):
#   Run-DieCastOnRecord reports what is ON RECORD -- a summary for reading
#   beside a paper sheet. This one pulls the rows needed to REBUILD the shift
#   as a SQL test fixture, including the five tables that export deliberately
#   omits (ProductionEvent, LotStatusHistory, LotAttributeChange, LotMovement,
#   LotGenealogy). Those five decide whether a LOT's count is locked, which is
#   the assertion the Machine 11 replay turns on.
#
# Connection conventions mirror Run-DieCastOnRecord.ps1 / Deploy-ProdRelease.ps1:
# SQL auth as 'Ignition', password from $env:SQLCMDPASSWORD or a masked prompt,
# TrustServerCertificate.
#
# Usage:
#   .\Run-ReconcileReplayExtract.ps1                                   # prod, DC1-M11 / DMO125, 09-16..09-19
#   .\Run-ReconcileReplayExtract.ps1 -PressCode DC1-M202 -DieCode ""   # every die on that press
#   .\Run-ReconcileReplayExtract.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Username ""
#
# Output: dist\reconcile-replay\<db>_<stamp>\  (A_Scope.csv .. V_LotStatusCodes.csv
#         plus summary.txt). Zip the whole folder and send it back together with
#         a photo or scan of the paper press sheet for the same shifts.
# ============================================================

[CmdletBinding()]
param(
    [string]$ServerInstance = "172.17.10.148",
    [string]$DatabaseName   = "MPP_MES_Prod",
    [string]$Username       = "Ignition",      # "" = Windows authentication
    [string]$PressCode      = "DC1-M11",
    [string]$DieCode        = "DMO125",        # "" = every die on the press
    [string]$FromEtDate     = "2026-09-16",
    [string]$ToEtDate       = "2026-09-19",
    [string]$OutDir         = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$SqlFile   = Join-Path $ScriptDir "2026-09-29_reconcile_replay_extract.sql"
if (-not (Test-Path $SqlFile)) { throw "SQL file not found: $SqlFile" }

foreach ($d in @($FromEtDate, $ToEtDate)) {
    if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "Date '$d' must be yyyy-MM-dd." }
}
if ($PressCode -eq "") { throw "-PressCode is required." }
foreach ($v in @($PressCode, $DieCode)) {
    if ($v -match "'") { throw "Quote character in '$v' -- refusing." }
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($OutDir -eq "") { $OutDir = Join-Path $RepoRoot ("dist\reconcile-replay\{0}_{1}" -f $DatabaseName, $stamp) }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Summary = Join-Path $OutDir "summary.txt"

function Log([string]$msg = "", [string]$color = "Gray") {
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $Summary -Value $msg -Encoding UTF8
}

Log "Die cast reconciliation -- replay extract" "Cyan"
Log "  Target : $DatabaseName on $ServerInstance"
Log "  Press  : $PressCode"
Log ("  Die    : {0}" -f $(if ($DieCode -eq "") { "(every die on the press)" } else { $DieCode }))
Log "  Window : $FromEtDate .. $ToEtDate (Eastern, inclusive)"
Log "  Output : $OutDir"
Log ""

# ---------- the query, with the parameters applied ----------
$sql = Get-Content -Raw -Path $SqlFile

$subs = @(
    @{ Pattern = '(?m)^DECLARE @PressCode  NVARCHAR\(100\) = N''[^'']*'';';
       Value   = "DECLARE @PressCode  NVARCHAR(100) = N'$PressCode';"; Name = 'PressCode' },
    @{ Pattern = '(?m)^DECLARE @DieCode    NVARCHAR\(100\) = N''[^'']*'';';
       Value   = "DECLARE @DieCode    NVARCHAR(100) = N'$DieCode';";   Name = 'DieCode' },
    @{ Pattern = '(?m)^DECLARE @FromEtDate DATE          = ''[^'']*'';';
       Value   = "DECLARE @FromEtDate DATE          = '$FromEtDate';"; Name = 'FromEtDate' },
    @{ Pattern = '(?m)^DECLARE @ToEtDate   DATE          = ''[^'']*'';';
       Value   = "DECLARE @ToEtDate   DATE          = '$ToEtDate';";   Name = 'ToEtDate' }
)
foreach ($s in $subs) {
    if ($sql -notmatch $s.Pattern) { throw "Could not find the $($s.Name) parameter line in $SqlFile." }
    $sql = [regex]::Replace($sql, $s.Pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $s.Value }, 1)
}
foreach ($s in $subs) {
    if ($sql -notmatch [regex]::Escape($s.Value)) { throw "Failed to set $($s.Name) in $SqlFile." }
}

# Refuse to run anything that is not read-only, however the file got edited.
# Scan EXECUTABLE SQL only: blank out string literals first, then comments.
# Without this the guard trips on ordinary English in the header ("would drop
# precisely the rows...") and the temptation is to weaken the guard rather than
# the prose. Literals go first so a '--' inside one cannot eat a closing quote.
$scan = [regex]::Replace($sql, "N?'(?:[^']|'')*'", "''")
$scan = [regex]::Replace($scan, '(?m)--.*$', '')
$scan = [regex]::Replace($scan, '(?s)/\*.*?\*/', '')
foreach ($word in @('INSERT INTO', 'UPDATE ', 'DELETE ', 'MERGE ', 'DROP ', 'ALTER ', 'TRUNCATE ', 'EXEC ', 'EXECUTE ', 'sp_')) {
    if ($scan -match [regex]::Escape($word)) { throw "'$($word.Trim())' found in executable SQL in $SqlFile -- refusing to run. This script runs read-only SQL only." }
}

# ---------- credentials (same handling as Run-DieCastOnRecord.ps1) ----------
$Password = ""
if ($Username -ne "") {
    if ($env:SQLCMDPASSWORD) { $Password = $env:SQLCMDPASSWORD }
    else {
        $sec  = Read-Host "  SQL password for '$Username'" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($Password -eq "") { throw "No password entered." }
    }
}

$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$b["Data Source"]            = $ServerInstance
$b["Initial Catalog"]        = $DatabaseName
$b["Application Name"]       = "MPP Reconcile Replay Extract (read-only)"
$b["Encrypt"]                = $true
$b["TrustServerCertificate"] = $true
if ($Username -ne "") { $b["User ID"] = $Username; $b["Password"] = $Password }
else { $b["Integrated Security"] = $true }

$ds = New-Object System.Data.DataSet
$conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 300
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$da.Fill($ds)
} finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
    $conn.Dispose()
}

# ---------- one CSV per result set, named from its [Set] column ----------
# Empty sets still get a correctly named file, recovered from the SELECT literal
# in file order -- an absent file and an empty file mean different things.
$labels = [regex]::Matches($sql, "SELECT N'([A-Z] [A-Za-z]+)' AS \[Set\]") | ForEach-Object { $_.Groups[1].Value }
$i = 0
foreach ($t in $ds.Tables) {
    $i++
    $label = "{0:00}_Unnamed" -f $i
    if ($t.Columns.Contains("Set") -and $t.Rows.Count -gt 0) {
        $label = ([string]$t.Rows[0]["Set"]) -replace '[^A-Za-z0-9]+', '_'
    } elseif ($labels.Count -ge $i) {
        $label = $labels[$i - 1] -replace '[^A-Za-z0-9]+', '_'
    }
    $path = Join-Path $OutDir "$label.csv"
    $t | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    Log ("  {0,-22} {1,6} rows  ->  {2}" -f $label, $t.Rows.Count, (Split-Path -Leaf $path))
}

# ---------- what resolved, echoed back ----------
if ($ds.Tables.Count -gt 0 -and $ds.Tables[0].Rows.Count -gt 0) {
    $w = $ds.Tables[0].Rows[0]
    Log ""
    Log ("  Database {0} | schema {1} | press {2} ({3}) | dies {4} | shifts {5} | LOTs {6}" -f `
         $w["DatabaseName"], $w["SchemaVersionLatest"], $w["PressCode"], $w["PressResolved"], `
         $w["DiesResolved"], $w["ShiftsInWindow"], $w["LotsInScope"]) "Cyan"

    if ([string]$w["PressResolved"] -ne "ok") {
        Log "  !! The press code did not resolve -- every set below is empty. Check -PressCode." "Red"
    } elseif ([int]$w["LotsInScope"] -eq 0) {
        Log "  !! No LOTs in scope -- check -DieCode and the date window." "Yellow"
    }
}

Log ""
Log "Done. Zip the output folder and send it back with the press sheet." "Green"
