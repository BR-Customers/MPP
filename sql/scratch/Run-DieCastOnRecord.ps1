# ============================================================
# Run-DieCastOnRecord.ps1
#
# Runs the READ-ONLY die-cast "what is on record" query against a target
# database and writes one CSV per result set, plus a readable summary.
#
# The SQL it runs (2026-09-21_diecast_on_record_window.sql) is SELECTs only --
# no writes, no transaction, no temp tables. Safe on MPP_MES_Prod during
# production.
#
# Connection conventions mirror Deploy-ProdRelease.ps1: SQL auth as 'Ignition',
# password from $env:SQLCMDPASSWORD or a masked prompt, TrustServerCertificate.
#
# Usage:
#   .\Run-DieCastOnRecord.ps1                       # prod, 168h, SQL auth
#   .\Run-DieCastOnRecord.ps1 -Hours 72
#   .\Run-DieCastOnRecord.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Username ""
#
# Output: dist\diecast-on-record\<db>_<stamp>\  (A_Window.csv .. I_Dies.csv
#         plus summary.txt). Send me the whole folder, zipped.
# ============================================================

[CmdletBinding()]
param(
    [string]$ServerInstance = "172.17.10.148",
    [string]$DatabaseName   = "MPP_MES_Prod",
    [string]$Username       = "Ignition",   # "" = Windows authentication
    [int]$Hours             = 168,
    [string]$OutDir         = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$SqlFile   = Join-Path $ScriptDir "2026-09-21_diecast_on_record_window.sql"
if (-not (Test-Path $SqlFile)) { throw "SQL file not found: $SqlFile" }

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($OutDir -eq "") { $OutDir = Join-Path $RepoRoot ("dist\diecast-on-record\{0}_{1}" -f $DatabaseName, $stamp) }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Summary = Join-Path $OutDir "summary.txt"

function Log([string]$msg = "", [string]$color = "Gray") {
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $Summary -Value $msg -Encoding UTF8
}

Log "Die cast -- what is on record" "Cyan"
Log "  Target : $DatabaseName on $ServerInstance"
Log "  Window : last $Hours hours"
Log "  Output : $OutDir"
Log ""

# ---------- credentials (same handling as Deploy-ProdRelease.ps1) ----------
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
$b["Application Name"]       = "MPP DieCast OnRecord (read-only)"
$b["Encrypt"]                = $true
$b["TrustServerCertificate"] = $true
if ($Username -ne "") { $b["User ID"] = $Username; $b["Password"] = $Password }
else { $b["Integrated Security"] = $true }

# ---------- the query, with the window applied ----------
$sql = Get-Content -Raw -Path $SqlFile
$sql = [regex]::Replace($sql, '(?m)^DECLARE @Hours INT = \d+;', "DECLARE @Hours INT = $Hours;")
if ($sql -notmatch "DECLARE @Hours INT = $Hours;") { throw "Could not set the window in $SqlFile." }

# Refuse to run anything that is not read-only, however the file got edited.
foreach ($word in @('INSERT INTO', 'UPDATE ', 'DELETE ', 'MERGE ', 'DROP ', 'ALTER ', 'TRUNCATE ', 'EXEC ')) {
    if ($sql -match [regex]::Escape($word)) { throw "'$($word.Trim())' found in $SqlFile -- refusing to run. This script runs read-only SQL only." }
}

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
$i = 0
foreach ($t in $ds.Tables) {
    $i++
    $label = "{0:00}_Unnamed" -f $i
    if ($t.Columns.Contains("Set") -and $t.Rows.Count -gt 0) {
        $label = ([string]$t.Rows[0]["Set"]) -replace '[^A-Za-z0-9]+', '_'
    } elseif ($t.Columns.Contains("Set")) {
        # Empty set: recover the label from the SELECT literal, in file order.
        $labels = [regex]::Matches($sql, "SELECT N'([A-I] [A-Za-z]+)' AS \[Set\]") | ForEach-Object { $_.Groups[1].Value }
        if ($labels.Count -ge $i) { $label = $labels[$i - 1] -replace '[^A-Za-z0-9]+', '_' }
    }
    $path = Join-Path $OutDir "$label.csv"
    $t | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    Log ("  {0,-14} {1,5} rows  ->  {2}" -f $label, $t.Rows.Count, (Split-Path -Leaf $path))
}

# ---------- the window, echoed back ----------
if ($ds.Tables.Count -gt 0 -and $ds.Tables[0].Rows.Count -gt 0) {
    $w = $ds.Tables[0].Rows[0]
    Log ""
    Log ("  Database {0} | window {1} -> {2} ET | {3} presses | {4} die cast LOTs touched" -f `
         $w["DatabaseName"], $w["FromEt"], $w["NowEt"], $w["DieCastPresses"], $w["DieCastLotsTouched"]) "Cyan"
}

Log ""
Log "Done. Zip the output folder and send it back with the press sheets." "Green"
