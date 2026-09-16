# ============================================================
# Deploy-ProdRelease.ps1 -- bring a LIVE database up to this checkout, in
#                           ONE transaction, with a read-only preview first.
#
# THREE MODES
#   -Mode Preview   (default) READ-ONLY. Works out exactly what would change,
#                   runs every pre-flight gate against the live data, writes
#                   a report + the deploy script it WOULD run, and prints a
#                   plan fingerprint. Touches nothing.
#   -Mode Rehearse  Runs the real deploy script inside a transaction against
#                   the live data, verifies it, then ROLLS BACK. Proves the
#                   migrations and procs apply cleanly to prod's actual rows.
#                   Takes the same locks as Execute for the same few seconds.
#   -Mode Execute   Backup (COPY_ONLY + VERIFYONLY), then the deploy script,
#                   COMMITTED only if every step and check passes. Any error
#                   anywhere rolls the whole release back -- no partial state.
#
# WHAT GETS APPLIED
#   * versioned migrations not recorded in dbo.SchemaVersion, in order
#   * ONLY the repeatables whose object definition on the target differs from
#     this checkout (or is missing) -- found by comparing text, not by trusting
#     commit history. Functions first, then procs.
#   * R__Descriptions_ExtendedProperties (documentation only) runs AFTER the
#     commit, outside the transaction, so it never holds locks on every table.
#   No seeds. Nothing else.
#
# SAFETY
#   * refuses on out-of-order pending migrations, a dirty sql/ tree, or any
#     BLOCK finding from the pre-flight gates
#   * -ExpectedPlan <fingerprint> makes Execute refuse if anything changed
#     between the preview you reviewed and the run
#   * inside the transaction: DEADLOCK_PRIORITY LOW (the plant wins a deadlock),
#     LOCK_TIMEOUT (abort cleanly rather than queue the plant behind us)
#
# PASSWORD
#   Never pass it on the command line. Either set it masked first:
#     $env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
#         [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'pw' -AsSecureString)))
#   or let this script prompt (masked) when -Username is given.
#
# USAGE
#   .\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition
#   .\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Rehearse -ExpectedPlan <fp>
#   .\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Execute  -ExpectedPlan <fp>
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ServerInstance,
    [string]$DatabaseName = "MPP_MES_Prod",
    [string]$Username     = "",
    [ValidateSet("Preview", "Rehearse", "Execute")] [string]$Mode = "Preview",
    [string]$ExpectedPlan = "",
    [string]$BackupDir    = "",        # default: the instance's default backup path
    [switch]$SkipBackup,
    [int]$LockTimeoutSeconds = 30,
    [string]$ReportRoot   = "",
    [switch]$Force                     # skip typed confirmation; REQUIRES -ExpectedPlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SqlRoot    = Split-Path -Parent $ScriptDir
$RepoRoot   = Split-Path -Parent $SqlRoot
$Versioned  = Join-Path $SqlRoot "migrations\versioned"
$Repeatable = Join-Path $SqlRoot "migrations\repeatable"
$PostCommitFiles = @("R__Descriptions_ExtendedProperties.sql")

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($ReportRoot -eq "") { $ReportRoot = Join-Path $RepoRoot "dist\deploy-reports" }
$ReportDir = Join-Path $ReportRoot ("{0}_{1}_{2}" -f $DatabaseName, $Mode, $stamp)
New-Item -ItemType Directory -Force (Join-Path $ReportDir "diffs") | Out-Null
$Summary = Join-Path $ReportDir "summary.txt"

function Log([string]$msg = "", [string]$color = "Gray") {
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $Summary -Value $msg -Encoding UTF8
}
function Head([string]$msg) { Log ""; Log $msg "Cyan" }

# ------------------------------------------------------------
# Credentials: env var or masked prompt. sqlcmd reads SQLCMDPASSWORD itself,
# so the password is never on a command line and sqlcmd never prompts into a
# captured stream (the Update-Prod hang).
# ------------------------------------------------------------
$savedEnvPw = $env:SQLCMDPASSWORD
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
    $SqlcmdAuth = @("-U", $Username)
} else { $SqlcmdAuth = @("-E") }

function New-Conn([string]$db = $DatabaseName) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b["Data Source"] = $ServerInstance
    $b["Initial Catalog"] = $db
    $b["Application Name"] = "MPP Deploy-ProdRelease"
    $b["Encrypt"] = $true
    $b["TrustServerCertificate"] = $true
    if ($Username -ne "") { $b["User ID"] = $Username; $b["Password"] = $Password }
    else { $b["Integrated Security"] = $true }
    $c = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    $c.Open(); return $c
}
$Conn = $null
function Q([string]$sql, [string]$db = "") {
    $c = if ($db -ne "") { New-Conn $db } else { $script:Conn }
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300
        $dt = New-Object System.Data.DataTable
        (New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($dt) | Out-Null
        return ,@($dt.Rows)
    } finally { if ($db -ne "") { $c.Close() } }
}
function S([string]$sql) { $r = Q $sql; if ($r.Count -eq 0) { return $null }; return $r[0][0] }
function Table($rows, [string[]]$cols) {
    if (-not $rows -or $rows.Count -eq 0) { Log "    (none)" "DarkGray"; return }
    $w = @{}; foreach ($c in $cols) { $w[$c] = $c.Length }
    foreach ($r in $rows) { foreach ($c in $cols) { $v = "$($r[$c])"; if ($v.Length -gt $w[$c]) { $w[$c] = [Math]::Min($v.Length, 60) } } }
    Log ("    " + (($cols | ForEach-Object { $_.PadRight($w[$_]) }) -join "  "))
    foreach ($r in $rows) {
        Log ("    " + (($cols | ForEach-Object { $v = "$($r[$_])"; if ($v.Length -gt 60) { $v = $v.Substring(0, 57) + "..." }; $v.PadRight($w[$_]) }) -join "  "))
    }
}
function Save-Csv($rows, [string]$name) {
    if (-not $rows -or $rows.Count -eq 0) { return }
    $rows | ForEach-Object { $o = [ordered]@{}; foreach ($col in $_.Table.Columns) { $o[$col.ColumnName] = $_[$col.ColumnName] }; [pscustomobject]$o } |
        Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $ReportDir $name)
}

$Findings = New-Object System.Collections.ArrayList
function Finding([string]$sev, [string]$gate, [string]$detail) {
    [void]$Findings.Add([pscustomobject]@{ Severity = $sev; Gate = $gate; Detail = $detail })
    $col = @{ BLOCK = "Red"; WARN = "Yellow"; INFO = "DarkGray" }[$sev]
    Log ("  [{0}] {1}: {2}" -f $sev, $gate, $detail) $col
}

# Read a .sql file the way sqlcmd does: UTF-8 only with a BOM, otherwise the
# Windows codepage. The stored module text is whatever sqlcmd sent.
function Read-SqlText([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    return [Text.Encoding]::GetEncoding(1252).GetString($bytes)
}
$ModuleRx = [regex]'(?im)^\s*CREATE\s+(?:OR\s+ALTER\s+)?(PROC|PROCEDURE|FUNCTION|VIEW|TRIGGER)\s+\[?(\w+)\]?\.\[?(\w+)\]?'
$HeaderRx = [regex]'(?i)\bCREATE\s+(?:OR\s+ALTER\s+)?(PROC|PROCEDURE|FUNCTION|VIEW|TRIGGER)\b'
# SQL Server stores CREATE OR ALTER as "CREATE   "; normalise both sides.
function Norm([string]$t) {
    $t = ($t -replace "`r`n", "`n" -replace "`r", "`n").Trim()
    return $HeaderRx.Replace($t, 'CREATE $1', 1)
}
function Sha([string]$text) {
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
    return -join ($h | ForEach-Object { $_.ToString("x2") })
}

try {
# ============================================================
Log "============================================================" "Cyan"
Log "  Deploy-ProdRelease  --  $Mode" "Cyan"
Log "  Target: $DatabaseName on $ServerInstance" "Cyan"
Log "  Report: $ReportDir" "Cyan"
Log "============================================================" "Cyan"

# ---------- [1] checkout ----------
Head "[1] Checkout"
$head = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
$branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
Log "  $branch @ $head"
$dirty = @(& git -C $RepoRoot status --porcelain -- sql/migrations)
if ($dirty.Count -gt 0) {
    $dirty | ForEach-Object { Log "    $_" "Red" }
    Finding "BLOCK" "checkout" "sql/migrations has uncommitted changes -- deploy only committed code"
}

# ---------- [2] connection ----------
Head "[2] Connection"
$Conn = New-Conn "master"
$who = Q "SELECT SUSER_SNAME() AS Login, IS_SRVROLEMEMBER('sysadmin') AS SysAdmin, @@SERVERNAME AS Server, CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(40)) AS Version, CAST(SERVERPROPERTY('Edition') AS NVARCHAR(80)) AS Edition"
Log ("  {0} on {1} ({2}, {3}); sysadmin={4}" -f $who[0].Login, $who[0].Server, $who[0].Version, $who[0].Edition, $who[0].SysAdmin)
$dbrow = Q "SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = N'$DatabaseName'"
if ($dbrow.Count -eq 0) { throw "Database '$DatabaseName' does not exist on $ServerInstance." }
Log ("  {0}: {1}, recovery {2}" -f $dbrow[0].name, $dbrow[0].state_desc, $dbrow[0].recovery_model_desc)
$Conn.Close(); $Conn = New-Conn
if (-not (S "SELECT OBJECT_ID(N'dbo.SchemaVersion')")) { throw "dbo.SchemaVersion missing -- cannot tell what is applied." }

# ---------- [3] migrations ----------
Head "[3] Versioned migrations"
$applied = @{}
foreach ($r in (Q "SELECT MigrationId FROM dbo.SchemaVersion")) { $applied[[string]$r.MigrationId] = $true }
$files = @(Get-ChildItem $Versioned -Filter *.sql | Sort-Object Name)
$num = { param($id) if ($id -match '^(\d+)') { [int]$Matches[1] } else { -1 } }
$maxApplied = [int](($applied.Keys | ForEach-Object { & $num $_ } | Measure-Object -Maximum).Maximum)
$pending = @($files | Where-Object { -not $applied.ContainsKey($_.BaseName) })
$last = Q "SELECT TOP 5 MigrationId, AppliedAt FROM dbo.SchemaVersion ORDER BY MigrationId DESC"
Log "  Database: $($applied.Count) applied, highest $('{0:D4}' -f $maxApplied). Most recent:"
Table $last @("MigrationId", "AppliedAt")
$orphans = @($applied.Keys | Where-Object { -not (Test-Path (Join-Path $Versioned "$_.sql")) } | Sort-Object)
foreach ($o in $orphans) { Finding "WARN" "migrations" "recorded in the database but not in this checkout: $o" }
$ooo = @($pending | Where-Object { (& $num $_.BaseName) -le $maxApplied })
foreach ($o in $ooo) { Finding "BLOCK" "migrations" "out of order: $($o.Name) is pending below the applied high-water mark ($maxApplied)" }
if ($pending.Count -eq 0) { Log "  No pending migrations." "Green" }
else { Log "  Pending ($($pending.Count)):" "Yellow"; $pending | ForEach-Object { Log "    + $($_.Name)" "Yellow" } }
$pendingIds = @($pending | ForEach-Object { $_.BaseName })

# Anything in a pending migration that cannot run inside our transaction.
foreach ($m in $pending) {
    $t = Read-SqlText $m.FullName
    $code = [regex]::Replace($t, '(?s)/\*.*?\*/|--[^\n]*', '')
    if ($code -match '(?i)\b(BEGIN\s+TRAN|COMMIT\b|ROLLBACK\b|ALTER\s+DATABASE|BACKUP\s+|RECONFIGURE)') {
        Finding "BLOCK" "migrations" "$($m.Name) contains '$($Matches[1])' -- cannot run inside the release transaction"
    }
}

# ---------- [4] repeatables: what actually differs on the target ----------
Head "[4] Repeatables -- target definitions vs this checkout"
$defs = @{}
foreach ($r in (Q "SELECT LOWER(SCHEMA_NAME(o.schema_id) + '.' + o.name) AS K, m.definition AS D FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id WHERE o.is_ms_shipped = 0")) {
    $defs[[string]$r.K] = [string]$r.D
}
$tierOf = @{ FUNCTION = 1; VIEW = 2; PROC = 3; PROCEDURE = 3; TRIGGER = 4 }
$repoKeys = @{}
$toApply = New-Object System.Collections.ArrayList
$counts = @{ NEW = 0; CHANGED = 0; SAME = 0 }
foreach ($f in (Get-ChildItem $Repeatable -Filter "R__*.sql" | Sort-Object Name)) {
    if ($PostCommitFiles -contains $f.Name) { continue }
    $text = Read-SqlText $f.FullName
    $batches = [regex]::Split(($text -replace "`r`n", "`n"), '(?im)^[ \t]*GO[ \t]*(?:--.*)?$')
    $status = "SAME"; $tier = 9; $objs = @()
    foreach ($b in $batches) {
        $m = $ModuleRx.Match($b)
        if (-not $m.Success) { continue }
        $key = ($m.Groups[2].Value + "." + $m.Groups[3].Value).ToLower()
        $repoKeys[$key] = $true; $objs += $key
        $t = $tierOf[$m.Groups[1].Value.ToUpper()]; if ($t -lt $tier) { $tier = $t }
        if (-not $defs.ContainsKey($key)) { $status = "NEW" }
        elseif ((Norm $b) -ne (Norm $defs[$key])) {
            if ($status -ne "NEW") { $status = "CHANGED" }
            $safe = $key -replace '[^\w\.]', '_'
            [IO.File]::WriteAllText((Join-Path $ReportDir "diffs\$safe.target.sql"), (Norm $defs[$key]))
            [IO.File]::WriteAllText((Join-Path $ReportDir "diffs\$safe.repo.sql"), (Norm $b))
            $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            & git -c core.autocrlf=false -c core.safecrlf=false diff --no-index --no-color -- (Join-Path $ReportDir "diffs\$safe.target.sql") (Join-Path $ReportDir "diffs\$safe.repo.sql") 2>$null |
                Out-File -Encoding utf8 (Join-Path $ReportDir "diffs\$safe.diff")
            $ErrorActionPreference = $eap
        }
    }
    if ($objs.Count -eq 0) { continue }
    $counts[$status]++
    if ($status -ne "SAME") { [void]$toApply.Add([pscustomobject]@{ File = $f.Name; Path = $f.FullName; Status = $status; Tier = $tier; Objects = ($objs -join ", ") }) }
}
$toApply = @($toApply | Sort-Object Tier, File)
Log ("  {0} identical, {1} changed, {2} new on the target." -f $counts.SAME, $counts.CHANGED, $counts.NEW)
foreach ($a in $toApply) { Log ("    {0,-8} {1}" -f $a.Status, $a.File) $(if ($a.Status -eq "NEW") { "Yellow" } else { "Gray" }) }
if ($counts.CHANGED -gt 0) { Log "  Per-object diffs (target -> repo): $ReportDir\diffs" "DarkGray" }

$migText = (Get-ChildItem $Versioned -Filter *.sql | ForEach-Object { Read-SqlText $_.FullName }) -join "`n"
$orphanMods = @($defs.Keys | Where-Object { -not $repoKeys.ContainsKey($_) } | Where-Object {
    # objects a versioned migration creates are not orphans
    $parts = $_ -split '\.'
    $migText -notmatch ('(?i)CREATE\s+(OR\s+ALTER\s+)?(VIEW|FUNCTION|PROC|PROCEDURE|TRIGGER)\s+\[?' + [regex]::Escape($parts[0]) + '\]?\.\[?' + [regex]::Escape($parts[1]) + '\b')
} | Sort-Object)
foreach ($o in $orphanMods) { Finding "WARN" "repeatables" "object on the target with no file in this checkout: $o (left untouched)" }

# Columns this release drops or renames, and anything that SURVIVES the deploy
# still naming them. The objects this deploy re-creates are checked from their
# repo text; everything else from its live definition.
$dropped = @()
foreach ($m in $pending) {
    $t = [regex]::Replace((Read-SqlText $m.FullName), '(?s)/\*.*?\*/|--[^\n]*', '')
    foreach ($x in [regex]::Matches($t, '(?i)ALTER\s+TABLE\s+\[?(\w+)\]?\.\[?(\w+)\]?\s+DROP\s+COLUMN\s+\[?(\w+)\]?')) {
        $dropped += [pscustomobject]@{ Table = "$($x.Groups[1].Value).$($x.Groups[2].Value)"; Column = $x.Groups[3].Value; Migration = $m.BaseName }
    }
}
if ($dropped.Count -gt 0) {
    Log "  Columns dropped by this release:"
    $dropped | ForEach-Object { Log "    $($_.Table).$($_.Column)   ($($_.Migration))" }
    $reapplied = @{}; foreach ($a in $toApply) { foreach ($o in ($a.Objects -split ', ')) { $reapplied[$o] = $a.Path } }
    foreach ($d in $dropped) {
        $rx = '(?i)\b' + [regex]::Escape($d.Column) + '\b'
        foreach ($k in $defs.Keys) {
            $src = if ($reapplied.ContainsKey($k)) { Read-SqlText $reapplied[$k] } else { $defs[$k] }
            $code = [regex]::Replace($src, '(?s)/\*.*?\*/|--[^\n]*', '')
            if ($code -match $rx) { Finding "BLOCK" "dropped-column" "$k still references '$($d.Column)' ($($d.Table)) and would break after $($d.Migration)" }
        }
    }
}

# ---------- [5] pre-flight gates for the pending migrations ----------
Head "[5] Pre-flight gates (read-only, against live data)"
$has = { param($id) $pendingIds -contains $id }

if (& $has "0072_toolcavity_itemid") { Finding "INFO" "0072" "adds Tools.ToolCavity.ItemId (family-die cavity-to-part map)" }
if ((& $has "0072_toolcavity_itemid") -and (& $has "0076_toolcavity_alpha_code")) {
    Finding "BLOCK" "0076" "0072 and 0076 are both pending. 0076 letters cavities per part using the map 0072 creates -- in one run every map is empty and family dies get die-wide letters, permanently. Deploy through 0075, map the cavities, then 0076."
}

if (& $has "0073_diecast_shot_counter_reading") {
    $nulls = S "SELECT COUNT(*) FROM Workorder.DieCastContribution"
    Finding "INFO" "0073" "backfills a counter reading on $nulls existing contribution row(s)"
    $openShiftRows = S "SELECT COUNT(*) FROM Workorder.DieCastContribution c JOIN Oee.Shift s ON s.Id = c.ShiftId WHERE s.ActualEnd IS NULL"
    if ($openShiftRows -gt 0) { Finding "WARN" "0073" "$openShiftRows contribution(s) in a shift still running -- the backfill sets their watermark from PieceDelta. Deploy at a shift change if you can." }
}

if (& $has "0074_diecast_counter_anchor") { Finding "INFO" "0074" "adds DieCastCounterAnchor + 4 reasons; watermarks unchanged until an anchor is recorded" }

if (& $has "0075_defectcode_scale_adjustment") {
    if (-not (S "SELECT COUNT(*) FROM Parts.OperationCategory WHERE Code = N'Trim'")) { Finding "BLOCK" "0075" "Parts.OperationCategory 'Trim' is missing" }
    $ex = Q "SELECT Code, Description FROM Quality.DefectCode WHERE Code = N'260'"
    if ($ex.Count -gt 0) { Finding "WARN" "0075" "defect code 260 already exists as '$($ex[0].Description)' -- the insert will be skipped" }
    else { Finding "INFO" "0075" "adds defect code 260 'Scale Adjustment' (Trim, charged to TrimShop)" }
}

if ((& $has "0076_toolcavity_alpha_code") -and (S "SELECT COL_LENGTH('Tools.ToolCavity','CavityNumber')")) {
    $haveItemId = [bool](S "SELECT COL_LENGTH('Tools.ToolCavity','ItemId')")
    if ($haveItemId) {
        $over = Q "SELECT t.Code AS Die, COUNT(*) AS N FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId GROUP BY t.Code, ISNULL(tc.ItemId,-1) HAVING COUNT(*) > 26"
        foreach ($r in $over) { Finding "BLOCK" "0076" "die $($r.Die) has a (die, part) group of $($r.N) cavities -- no 27th letter" }

        # Any die with SOME cavities mapped and some not. Covers the migration's
        # own gate (family die, one unmapped) AND a single-part die with a
        # partial map, which the migration does not catch: both groups start
        # at 'a', so one part gets two 'a' cavities.
        $partial = Q @"
SELECT t.Code AS Die, COUNT(DISTINCT tc.ItemId) AS Parts,
       SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) AS Unmapped, COUNT(*) AS Active
FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId
WHERE tc.DeprecatedAt IS NULL
GROUP BY t.Code
HAVING COUNT(DISTINCT tc.ItemId) >= 1 AND SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) > 0
"@
        foreach ($r in $partial) { Finding "BLOCK" "0076" "die $($r.Die): $($r.Unmapped) of $($r.Active) active cavities unmapped while $($r.Parts) part(s) are mapped -- map every cavity (or none) first" }

        # A family die with NO map at all passes the migration and gets
        # die-wide letters a..l. Detect family dies from what they have made.
        $unmappedFamily = Q @"
SELECT t.Code AS Die, t.Name, h.Parts, h.PartList
FROM Tools.Tool t
CROSS APPLY (SELECT COUNT(DISTINCT l.ItemId) AS Parts,
                    STRING_AGG(CAST(i.PartNumber AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY i.PartNumber) AS PartList
             FROM (SELECT DISTINCT ItemId FROM Lots.Lot WHERE ToolId = t.Id) l
             JOIN Parts.Item i ON i.Id = l.ItemId) h
WHERE h.Parts >= 2
  AND EXISTS (SELECT 1 FROM Tools.ToolCavity tc WHERE tc.ToolId = t.Id AND tc.DeprecatedAt IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolCavity tc WHERE tc.ToolId = t.Id AND tc.DeprecatedAt IS NULL AND tc.ItemId IS NOT NULL)
"@
        foreach ($r in $unmappedFamily) { Finding "BLOCK" "0076" "die $($r.Die) has made $($r.Parts) parts ($($r.PartList)) but has no cavity map -- it would get die-wide letters. Map it first." }

        $named = Q "SELECT t.Code AS Die, t.Name FROM Tools.Tool t WHERE t.Name LIKE N'%famil%' AND t.DeprecatedAt IS NULL AND NOT EXISTS (SELECT 1 FROM Tools.ToolCavity tc WHERE tc.ToolId = t.Id AND tc.DeprecatedAt IS NULL AND tc.ItemId IS NOT NULL) AND EXISTS (SELECT 1 FROM Tools.ToolCavity tc WHERE tc.ToolId = t.Id AND tc.DeprecatedAt IS NULL)"
        foreach ($r in $named) { Finding "WARN" "0076" "die $($r.Die) is named '$($r.Name)' but has no cavity map -- confirm it is really single-part" }
    }

    $pop = S "SELECT COUNT(*) FROM Lots.Lot WHERE NULLIF(LTRIM(RTRIM(CavityNumber)), N'') IS NOT NULL"
    if ($pop -gt 0) { Finding "BLOCK" "0076" "Lots.Lot.CavityNumber holds $pop value(s); the migration refuses to drop it" }
    $noCav = S "SELECT COUNT(*) FROM Lots.Lot WHERE ToolId IS NOT NULL AND ToolCavityId IS NULL"
    if ($noCav -gt 0) { Finding "WARN" "0076" "$noCav die-cast LOT(s) have a die but no cavity; they keep working, but that path is retired for new LOTs" }

    # The letters, exactly as the migration will derive them.
    $letters = Q @"
SELECT t.Code AS Die, ISNULL(i.PartNumber, N'(unmapped)') AS Part, tc.CavityNumber AS Ord,
       CASE WHEN tc.DeprecatedAt IS NULL THEN N'' ELSE N'deprecated' END AS State,
       ISNULL(tc.Description, N'') AS Description,
       CHAR(96 + ROW_NUMBER() OVER (PARTITION BY tc.ToolId, ISNULL(tc.ItemId,-1) ORDER BY tc.CavityNumber, tc.Id)) AS NewCode
FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId LEFT JOIN Parts.Item i ON i.Id = tc.ItemId
ORDER BY t.Code, Part, tc.CavityNumber
"@
    Save-Csv $letters "0076_cavity_letters.csv"
    Log "  Cavity letters 0076 will assign (all rows -> 0076_cavity_letters.csv):"
    Table @($letters | Where-Object { $_.State -eq "" }) @("Die", "Part", "Ord", "NewCode", "Description")

    # Deprecated rows take letters too, so active letters can skip (a, c, d).
    $gapGroups = @($letters | Where-Object { $_.State -eq "" } | Group-Object Die, Part | Where-Object {
        $codes = @($_.Group | ForEach-Object { [int][char]$_.NewCode } | Sort-Object)
        ($codes[0] -ne 97) -or (($codes[-1] - $codes[0] + 1) -ne $codes.Count) })
    foreach ($g in $gapGroups) { Finding "WARN" "0076" "$($g.Name): active letters $((@($g.Group | ForEach-Object { $_.NewCode }) -join ',')) -- deprecated cavities consume letters in this group" }

    $adv = @($letters | Where-Object { $_.State -eq "" -and $_.Description.Length -ge 3 -and
        $_.Description -cmatch '[^a-zA-Z][A-Z][a-z]$' -and $_.Description.Substring($_.Description.Length - 1) -cne $_.NewCode })
    foreach ($a in $adv) { Finding "WARN" "0076" "$($a.Die) '$($a.Description)' becomes '$($a.NewCode)' -- the letter typed in the description disagrees" }
}
if (& $has "0077_downtime_approximate_utc_repair") {
    # Exactly the rows the migration's UPDATE matches, shown before and after.
    $apx = Q @"
SELECT de.Id, loc.Code AS Location, ss.Name AS Shift, sh.ActualStart AS ShiftStartET,
       CAST(de.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS ShownNowET,
       CAST(sh.ActualStart AS DATETIME2(0)) AS ShownAfterET, de.DurationMinutes AS Minutes
FROM Oee.DowntimeEvent de
JOIN Oee.Shift sh ON sh.Id = de.ShiftId
LEFT JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
JOIN Location.Location loc ON loc.Id = de.LocationId
WHERE de.IsApproximate = 1 AND de.DurationMinutes IS NOT NULL AND de.StartedAt = sh.ActualStart
ORDER BY de.Id
"@
    Finding "INFO" "0077" "moves $($apx.Count) approximate downtime event(s) from Eastern wall-clock to UTC (times below)"
    Save-Csv $apx "0077_approximate_repair.csv"
    Table $apx @("Id", "Location", "Shift", "ShownNowET", "ShownAfterET", "Minutes")
}
# ============================================================
# Release 2026-09-15 (evening) -- three bodies of work:
#   0085 + 0087   defect codes scoped by area
#   0088          reject identity backfill
#   (repeatable)  Machining IN claimed by route, not by location
# ============================================================

# ---- 0085 -- DC-999 -> 999 --------------------------------------------------
if (& $has "0085_defectcode_warmup_999") {
    $taken = S "SELECT COUNT(*) FROM Quality.DefectCode WHERE Code = N'999'"
    if ($taken -gt 0) { Finding "BLOCK" "0085" "defect code '999' already exists -- 0085 renames DC-999 into it and will raise rather than clobber" }
    else { Finding "INFO" "0085" "renames DC-999 -> 999 in place; Id is unchanged so its booked Warmup rejects follow the row" }
}

# ---- 0087 -- (area, charge-to, code) replaces a plant-wide unique Code -------
if (& $has "0087_defectcode_area_scoped_codes") {
    # The one way this release can roll back hard: CREATE UNIQUE INDEX over a
    # duplicate triple. Zero today only because Code is still globally unique,
    # so this catches a row added between the preview and the window.
    $dupes = S "SELECT COUNT(*) FROM (SELECT OperationCategoryId, ChargeToPartyId, Code FROM Quality.DefectCode GROUP BY OperationCategoryId, ChargeToPartyId, Code HAVING COUNT(*) > 1) x"
    if ($dupes -gt 0) { Finding "BLOCK" "0087" "$dupes duplicate (area, charge-to, code) triple(s) -- CREATE UNIQUE INDEX fails mid-transaction and rolls the whole release back" }

    # 0087 resolves all six of these by code and raises if one is missing.
    $lookups = S "SELECT (SELECT COUNT(*) FROM Parts.OperationCategory WHERE Code IN (N'DieCast', N'Trim', N'MachiningAssembly')) + (SELECT COUNT(*) FROM Quality.ChargeToParty WHERE Code IN (N'DieCast', N'TrimShop', N'MachineShop'))"
    if ($lookups -ne 6) { Finding "BLOCK" "0087" "expected 6 lookup rows (3 OperationCategory + 3 ChargeToParty), found $lookups -- 0087 raises on a missing code" }

    # NULLs compare EQUAL in a unique index, so two NULL-charge rows sharing an
    # area and a number would collide where today they do not.
    $nullCharge = S "SELECT COUNT(*) FROM Quality.DefectCode WHERE ChargeToPartyId IS NULL"
    if ($nullCharge -gt 0) { Finding "WARN" "0087" "$nullCharge defect code(s) carry a NULL ChargeToPartyId -- NULLs compare equal in the new unique index. Read them before committing." }

    # IsExcused feeds the OEE quality calculation and 0087 must not disturb it:
    # 3a updates Description only, 3b hard-codes IsExcused = 0 for genuinely new
    # rows. Record the count so the post-Execute check can prove it held. (A
    # fresh-reset ordering bug lost two of these in Dev -- seed 030, fixed
    # separately; prod never re-runs seeds, so this is the proof it stayed put.)
    $excused = S "SELECT COUNT(*) FROM Quality.DefectCode WHERE IsExcused = 1 AND Code NOT LIKE N'TEST%'"
    Finding "INFO" "0087" "$excused excused defect code(s) today -- 0087 touches only Description and inserts at IsExcused = 0, so this must still be $excused after Execute"

    $before = S "SELECT COUNT(*) FROM Quality.DefectCode"
    Finding "INFO" "0087" "defect codes $before -> expected 233 (78 inserted, 8 re-worded, 0 deleted, no existing Id changed)"
    $rejects = S "SELECT COUNT(*) FROM Workorder.RejectEvent"
    Finding "INFO" "0087" "$rejects booked reject(s) key on DefectCodeId (Id, not Code) -- the count must still be $rejects after Execute"
}

# ---- 0088 -- reject identity backfill ---------------------------------------
if (& $has "0088_diecast_release_scrap_identity_backfill") {
    # 0084 repointed every reject reader at RejectEvent.ItemId. Three of the five
    # writers kept the pre-0084 column list, so what they have written since 0084
    # went out carries no part and is invisible to the scrap matrix Honda reads
    # and to Reconcile Shift's SHIFT SCRAP column.
    $unlab = Q @"
SELECT ISNULL(re.Remarks, N'(none)') AS Remarks, COUNT(*) AS Rows_,
       SUM(CASE WHEN re.ItemId IS NULL THEN 1 ELSE 0 END) AS NoPart,
       SUM(CASE WHEN re.ItemId IS NULL THEN re.Quantity ELSE 0 END) AS QtyNoPart,
       CAST(MAX(re.RecordedAt) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS LastET
FROM Workorder.RejectEvent re
GROUP BY re.Remarks
HAVING SUM(CASE WHEN re.ItemId IS NULL THEN 1 ELSE 0 END) > 0
ORDER BY 3 DESC
"@
    if ($unlab.Count -gt 0) {
        Save-Csv $unlab "0088_unlabelled_rejects.csv"
        Log "  Reject rows carrying no part (invisible to the scrap matrix and to SHIFT SCRAP):"
        Table $unlab @("Remarks", "Rows_", "NoPart", "QtyNoPart", "LastET")
    }

    $inScope = S "SELECT COUNT(*) FROM Workorder.RejectEvent WHERE Remarks = N'Die-cast final release scrap' AND (ItemId IS NULL OR ToolId IS NULL OR ToolCavityId IS NULL OR ShiftId IS NULL OR CellLocationId IS NULL)"
    Finding "INFO" "0088" "$inScope die-cast release-scrap row(s) will be relabelled"

    # The residue 0088 refuses to guess at: a release taken with no counter
    # reading and no final delta writes no contribution row, so there is nothing
    # to pair a shift against. A wrong shift moves scrap onto another crew.
    $orphan = S @"
SELECT COUNT(*) FROM Workorder.RejectEvent re
WHERE re.Remarks = N'Die-cast final release scrap'
  AND (re.ShiftId IS NULL OR re.CellLocationId IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastContribution dc
                  WHERE dc.LotId = re.LotId
                    AND ABS(DATEDIFF(SECOND, dc.EventAt, re.RecordedAt)) <= 5)
"@
    if ($orphan -gt 0) { Finding "WARN" "0088" "$orphan release-scrap row(s) have no contribution row within 5s to take a shift from -- 0088 leaves these NULL deliberately and prints its own warning. They need a decision, not a re-run." }

    # Out of scope BY DESIGN. The v1.4 / v2.6 proc fixes ship in this same
    # release and stop new ones, but 0088 backfills only die-cast release scrap.
    $outScope = S "SELECT COUNT(*) FROM Workorder.RejectEvent WHERE Remarks IN (N'Trim OUT scrap', N'Machining OUT scrap') AND ItemId IS NULL"
    if ($outScope -gt 0) { Finding "WARN" "0088" "$outScope trim/machining reject(s) stay unlabelled after this release -- 0088 covers die-cast release scrap only. A second backfill is owed; see the runbook." }
}

# ---- Machining IN claimed by route, not by location -------------------------
# No versioned migration in this body of work: both changes are CREATE OR ALTER
# repeatables, so these gates key off the apply list, not $pendingIds.
if (@($toApply | ForEach-Object { $_.File }) -contains "R__Workorder_MachiningIn_RecordPick.sql") {

    # GATE 1 -- the dangerous one. The OLD proc checked only "is the LOT in trim
    # storage" plus "does this part's route mention MachiningIn anywhere". It did
    # NOT check MachiningIn was the step actually due. Every row here is a basket
    # an operator can claim today and will find refused the morning after.
    $stranded = Q @"
SELECT l.Id, l.LotName, i.PartNumber, loc.Name AS AtLocation,
       ISNULL(ns.OperationTypeCode, N'(no pending step)') AS NextStep
FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
JOIN Parts.Item i ON i.Id = l.ItemId
JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
OUTER APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns
WHERE loc.LocationTypeDefinitionId = 14
  AND EXISTS (SELECT 1 FROM Location.Location a
              WHERE a.Id = loc.ParentLocationId AND a.Code LIKE N'TRIM%')
  AND ISNULL(ns.OperationTypeCode, N'') <> N'MachiningIn'
ORDER BY loc.Name, i.PartNumber
"@
    if ($stranded.Count -gt 0) {
        Save-Csv $stranded "machining_in_newly_blocked.csv"
        Finding "BLOCK" "machining-in" "$($stranded.Count) LOT(s) in trim storage are claimable today and would be REFUSED after this release (their next step is not MachiningIn). Record the missing checkpoints first, or run the window when trim storage is empty -- either way the list belongs in the guide."
        Table $stranded @("Id", "LotName", "PartNumber", "AtLocation", "NextStep")
    }

    # GATE 3 -- the read now excludes Open. An Open basket parked in trim storage
    # is already anomalous, but it vanishes from the queue on release.
    $openInStore = S @"
SELECT COUNT(*) FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code = N'Open'
JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
WHERE loc.LocationTypeDefinitionId = 14
  AND EXISTS (SELECT 1 FROM Location.Location a
              WHERE a.Id = loc.ParentLocationId AND a.Code LIKE N'TRIM%')
"@
    if ($openInStore -gt 0) { Finding "BLOCK" "machining-in" "$openInStore Open LOT(s) sit in trim storage and disappear from the Machining IN queue on release (the read now excludes Open). Somebody must know which." }

    # GATE 4 -- the old inline lookup accepted a DRAFT route; ufn_NextPendingRouteStep
    # requires PublishedAt. A part running on an unpublished route stops being claimable.
    $draftRoute = Q @"
SELECT i.PartNumber, COUNT(*) AS OpenLots
FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
JOIN Parts.Item i ON i.Id = l.ItemId
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt
                  WHERE rt.ItemId = l.ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL)
  AND EXISTS (SELECT 1 FROM Parts.RouteTemplate rt
              JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
              JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
              JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
              WHERE rt.ItemId = l.ItemId AND oty.Code = N'MachiningIn')
GROUP BY i.PartNumber
"@
    foreach ($r in $draftRoute) { Finding "BLOCK" "machining-in" "part $($r.PartNumber) has $($r.OpenLots) open LOT(s) and a MachiningIn step on an UNPUBLISHED route -- claimable today, not after. Publish the route first." }

    # GATE 2 -- informational: the size of the behaviour change. Rows at the
    # Warehouse are the point of the release. Rows at a sort cage, an offsite
    # facility or a shipping location are the spec's residual risk in real data.
    $newlyVisible = Q @"
SELECT loc.Name AS AtLocation, i.PartNumber, COUNT(*) AS Lots
FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code NOT IN (N'Closed', N'Open')
JOIN Parts.Item i ON i.Id = l.ItemId
JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
CROSS APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns
WHERE ns.OperationTypeCode = N'MachiningIn'
  AND NOT (loc.LocationTypeDefinitionId = 14
           AND EXISTS (SELECT 1 FROM Location.Location a
                       WHERE a.Id = loc.ParentLocationId AND a.Code LIKE N'TRIM%'))
GROUP BY loc.Name, i.PartNumber ORDER BY COUNT(*) DESC
"@
    if ($newlyVisible.Count -gt 0) {
        Save-Csv $newlyVisible "machining_in_newly_visible.csv"
        Finding "INFO" "machining-in" "$(($newlyVisible | Measure-Object -Property Lots -Sum).Sum) LOT(s) newly appear in Machining IN queues -- quote this in the guide so nobody is surprised by a queue that grew overnight"
        Table $newlyVisible @("AtLocation", "PartNumber", "Lots")
    }

    # The two changed procs both call this; the read proc did not before.
    if (-not (S "SELECT OBJECT_ID(N'Lots.ufn_NextPendingRouteStep')")) {
        Finding "BLOCK" "machining-in" "Lots.ufn_NextPendingRouteStep does not exist on the target -- both changed procs depend on it"
    }
}

if (@($Findings | Where-Object { $_.Gate -match '^00\d\d$' }).Count -eq 0 -and $pending.Count -gt 0) { Log "  No gates fired." "Green" }

# ---------- [6] live activity + backups ----------
Head "[6] Live activity"
$sess = Q "SELECT host_name AS Host, program_name AS Program, COUNT(*) AS Sessions FROM sys.dm_exec_sessions WHERE database_id = DB_ID() AND session_id <> @@SPID AND is_user_process = 1 GROUP BY host_name, program_name ORDER BY COUNT(*) DESC"
Table $sess @("Host", "Program", "Sessions")
$longTx = Q "SELECT s.session_id AS Spid, s.host_name AS Host, DATEDIFF(SECOND, t.transaction_begin_time, SYSDATETIME()) AS Seconds FROM sys.dm_tran_session_transactions st JOIN sys.dm_tran_active_transactions t ON t.transaction_id = st.transaction_id JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id WHERE s.database_id = DB_ID() AND st.session_id <> @@SPID AND DATEDIFF(SECOND, t.transaction_begin_time, SYSDATETIME()) > 5"
foreach ($t in $longTx) { Finding "WARN" "activity" "session $($t.Spid) ($($t.Host)) has a transaction open $($t.Seconds)s -- it will block the deploy's locks" }
try {
    $plant = Q @"
SELECT (SELECT COUNT(*) FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId WHERE s.Code = N'Open' AND l.ToolId IS NOT NULL) AS OpenBaskets,
       (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL) AS RunningShifts,
       (SELECT CAST(MAX(EventAt) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) FROM Workorder.DieCastContribution) AS LastDieCastEntryET,
       (SELECT CAST(MAX(CreatedAt) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) FROM Lots.Lot) AS LastLotCreatedET
"@
    Table $plant @("OpenBaskets", "RunningShifts", "LastDieCastEntryET", "LastLotCreatedET")
} catch { Log "  (plant activity query unavailable: $($_.Exception.Message))" "DarkGray" }

Head "[7] Backups"
$bk = Q "SELECT type AS T, CAST(MAX(backup_finish_date) AS DATETIME2(0)) AS LastFinished FROM msdb.dbo.backupset WHERE database_name = N'$DatabaseName' GROUP BY type"
Table $bk @("T", "LastFinished")
$defaultBackupPath = [string](S "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(400))")
Log "  Instance default backup path: $defaultBackupPath"
if ($Mode -eq "Execute" -and $SkipBackup) { Finding "WARN" "backup" "-SkipBackup: this run will NOT take a backup. Rollback after commit means a restore from an older one." }

# ---------- [8] plan ----------
Head "[8] Plan"
$planLines = @("HEAD|$head")
foreach ($m in $pending) { $planLines += "M|$($m.Name)|$(Sha (Read-SqlText $m.FullName))" }
foreach ($a in $toApply) { $planLines += "R|$($a.File)|$(Sha (Read-SqlText $a.Path))" }
$fingerprint = (Sha ($planLines -join "`n")).Substring(0, 12)
$planLines | Set-Content -Encoding UTF8 (Join-Path $ReportDir "plan.txt")
Log "  $($pending.Count) migration(s), $($toApply.Count) repeatable(s) in one transaction; then $($PostCommitFiles -join ', ') after commit."
Log "  Plan fingerprint: $fingerprint" "White"

# The deploy script. Written in every mode so it can be read before it runs.
$lockMs = $LockTimeoutSeconds * 1000
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine(":on error exit")
[void]$sb.AppendLine("-- Deploy-ProdRelease  plan $fingerprint  ($branch @ $head)  generated $stamp")
[void]$sb.AppendLine("SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;")
[void]$sb.AppendLine("SET DEADLOCK_PRIORITY LOW; SET LOCK_TIMEOUT $lockMs;")
[void]$sb.AppendLine("GO")
[void]$sb.AppendLine("IF OBJECT_ID('tempdb..#DeployWm') IS NOT NULL DROP TABLE #DeployWm;")
[void]$sb.AppendLine("BEGIN TRANSACTION;")
[void]$sb.AppendLine("PRINT '== transaction open';")
# Freeze the die-cast tables for the few seconds this takes: plant writes wait
# rather than landing between our steps. If we cannot get them in time we
# abort before changing anything.
[void]$sb.AppendLine("SELECT TOP 0 1 AS x FROM Lots.Lot WITH (TABLOCKX, HOLDLOCK);")
[void]$sb.AppendLine("SELECT TOP 0 1 AS x FROM Tools.ToolCavity WITH (TABLOCKX, HOLDLOCK);")
[void]$sb.AppendLine("SELECT TOP 0 1 AS x FROM Workorder.DieCastContribution WITH (TABLOCKX, HOLDLOCK);")
# Watermarks before, so we can prove the release did not move them.
[void]$sb.AppendLine("IF OBJECT_ID(N'Workorder.ufn_DieShotWatermark') IS NOT NULL AND COL_LENGTH('Workorder.DieCastContribution','ShotCounterReading') IS NOT NULL")
[void]$sb.AppendLine("    SELECT l.ToolId, c.ShiftId, c.CellLocationId, Workorder.ufn_DieShotWatermark(l.ToolId, c.ShiftId, c.CellLocationId) AS Wm")
[void]$sb.AppendLine("    INTO #DeployWm FROM Workorder.DieCastContribution c JOIN Lots.Lot l ON l.Id = c.LotId")
[void]$sb.AppendLine("    WHERE c.ShiftId IS NOT NULL GROUP BY l.ToolId, c.ShiftId, c.CellLocationId;")
[void]$sb.AppendLine("GO")
$step = 0
foreach ($m in $pending) {
    $step++
    [void]$sb.AppendLine("PRINT '== [$step] migration $($m.BaseName)';")
    [void]$sb.AppendLine("GO")
    [void]$sb.AppendLine(":r `"$($m.FullName)`"")
    [void]$sb.AppendLine("GO")
    [void]$sb.AppendLine("IF @@TRANCOUNT <> 1 RAISERROR(N'Transaction lost after $($m.BaseName)', 16, 1);")
    [void]$sb.AppendLine("IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'$($m.BaseName)') RAISERROR(N'$($m.BaseName) did not record itself', 16, 1);")
    [void]$sb.AppendLine("GO")
}
foreach ($a in $toApply) {
    $step++
    [void]$sb.AppendLine("PRINT '== [$step] $($a.File)';")
    [void]$sb.AppendLine("GO")
    [void]$sb.AppendLine(":r `"$($a.Path)`"")
    [void]$sb.AppendLine("GO")
    [void]$sb.AppendLine("IF @@TRANCOUNT <> 1 RAISERROR(N'Transaction lost after $($a.File)', 16, 1);")
    [void]$sb.AppendLine("GO")
}
[void]$sb.AppendLine("PRINT '== verifying inside the transaction';")
foreach ($a in $toApply) {
    foreach ($o in ($a.Objects -split ', ')) {
        [void]$sb.AppendLine("IF OBJECT_ID(N'$o') IS NULL RAISERROR(N'$o missing after deploy', 16, 1);")
    }
}
[void]$sb.AppendLine("IF OBJECT_ID('tempdb..#DeployWm') IS NOT NULL AND OBJECT_ID(N'Workorder.ufn_DieShotWatermark') IS NOT NULL")
[void]$sb.AppendLine("   AND EXISTS (SELECT 1 FROM #DeployWm w WHERE ISNULL(Workorder.ufn_DieShotWatermark(w.ToolId, w.ShiftId, w.CellLocationId), -1) <> ISNULL(w.Wm, -1))")
[void]$sb.AppendLine("    RAISERROR(N'A die watermark changed during the deploy -- refusing to commit', 16, 1);")
if ($pendingIds -contains "0076_toolcavity_alpha_code") {
    [void]$sb.AppendLine("IF COL_LENGTH('Tools.ToolCavity','CavityNumber') IS NOT NULL OR COL_LENGTH('Lots.Lot','CavityNumber') IS NOT NULL RAISERROR(N'0076: CavityNumber still present', 16, 1);")
    [void]$sb.AppendLine("IF EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE CavityCode IS NULL OR CavityCode = N'') RAISERROR(N'0076: a cavity has no code', 16, 1);")
    [void]$sb.AppendLine("IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ToolCavity_ActiveToolItemCode') RAISERROR(N'0076: unique index missing', 16, 1);")
}
[void]$sb.AppendLine("PRINT '== checks passed';")
[void]$sb.AppendLine("GO")
if ($Mode -eq "Execute") {
    [void]$sb.AppendLine("COMMIT TRANSACTION;")
    [void]$sb.AppendLine("PRINT '== COMMITTED';")
} else {
    [void]$sb.AppendLine("ROLLBACK TRANSACTION;")
    [void]$sb.AppendLine("PRINT '== ROLLED BACK (rehearsal / preview script) -- nothing was kept';")
}
[void]$sb.AppendLine("GO")
$deploySql = Join-Path $ReportDir "deploy.sql"
[IO.File]::WriteAllText($deploySql, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Log "  Deploy script: $deploySql" "DarkGray"

# ---------- verdict ----------
$blocks = @($Findings | Where-Object Severity -eq "BLOCK")
$warns  = @($Findings | Where-Object Severity -eq "WARN")
$Findings | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $ReportDir "findings.csv")
Head "Verdict"
if ($blocks.Count -gt 0) {
    Log "  BLOCKED by $($blocks.Count) finding(s):" "Red"
    $blocks | ForEach-Object { Log "    - [$($_.Gate)] $($_.Detail)" "Red" }
    Log "  Nothing was written." "Red"
    exit 2
}
if ($pending.Count -eq 0 -and $toApply.Count -eq 0) {
    Log "  $DatabaseName already matches this checkout. Nothing to do." "Green"
    exit 0
}
Log ("  Clear to deploy. {0} warning(s) to read above." -f $warns.Count) $(if ($warns.Count) { "Yellow" } else { "Green" })

if ($Mode -eq "Preview") {
    Log ""
    Log "  PREVIEW -- nothing was written. Next:" "Cyan"
    Log "    -Mode Rehearse -ExpectedPlan $fingerprint   (applies + rolls back on the live data)" "Cyan"
    Log "    -Mode Execute  -ExpectedPlan $fingerprint" "Cyan"
    exit 0
}

# ============================================================
# Rehearse / Execute
# ============================================================
if ($ExpectedPlan -ne "" -and $ExpectedPlan -ne $fingerprint) {
    Log "  ABORT: plan is $fingerprint but -ExpectedPlan is $ExpectedPlan -- the target or the checkout changed since the preview." "Red"
    exit 3
}
if ($Force -and $ExpectedPlan -eq "") { throw "-Force requires -ExpectedPlan (the fingerprint from the preview you reviewed)." }
if (-not $Force) {
    Log ""
    if ($Mode -eq "Execute") {
        Log "  This COMMITS $($pending.Count) migration(s) + $($toApply.Count) repeatable(s) to $DatabaseName." "Yellow"
        if ($pendingIds -contains "0076_toolcavity_alpha_code") { Log "  0076 DROPS two columns. After commit, rollback = restore from backup." "Red" }
        $ans = Read-Host "  Type the database name ($DatabaseName) to proceed"
        if ($ans -ne $DatabaseName) { Log "  Aborted." "Yellow"; exit 1 }
    } else {
        Log "  Rehearsal applies everything to the live data inside a transaction and rolls it back." "Yellow"
        Log "  Plant writes to Lots.Lot / ToolCavity / DieCastContribution wait for those seconds." "Yellow"
        $ans = Read-Host "  Type REHEARSE to proceed"
        if ($ans -cne "REHEARSE") { Log "  Aborted." "Yellow"; exit 1 }
    }
}

if ($Mode -eq "Execute" -and -not $SkipBackup) {
    Head "[9] Backup"
    $dir = if ($BackupDir -ne "") { $BackupDir } else { $defaultBackupPath }
    $lastMig = ($applied.Keys | Sort-Object | Select-Object -Last 1)
    $bak = Join-Path $dir ("{0}_pre-release_{1}_{2}.bak" -f $DatabaseName, ($lastMig -replace '_.*', ''), $stamp)
    Log "  BACKUP DATABASE -> $bak (COPY_ONLY, CHECKSUM)"
    $c = $Conn.CreateCommand(); $c.CommandTimeout = 3600
    $comp = if ("$($who[0].Edition)" -match 'Express') { "" } else { ", COMPRESSION" }
    $c.CommandText = "BACKUP DATABASE [$DatabaseName] TO DISK = N'$bak' WITH COPY_ONLY, CHECKSUM, INIT$comp"
    [void]$c.ExecuteNonQuery()
    $c.CommandText = "RESTORE VERIFYONLY FROM DISK = N'$bak' WITH CHECKSUM"
    [void]$c.ExecuteNonQuery()
    Log "  Backup written and verified." "Green"
    Add-Content (Join-Path $ReportDir "backup.txt") $bak
}

Head "[10] Running the release transaction"
if ($Password -ne "") { $env:SQLCMDPASSWORD = $Password }
$logFile = Join-Path $ReportDir "deploy.log"
$sw = [Diagnostics.Stopwatch]::StartNew()
$out = & sqlcmd -S $ServerInstance @SqlcmdAuth -d $DatabaseName -i $deploySql -b -I -C 2>&1
$code = $LASTEXITCODE
$sw.Stop()
$out | ForEach-Object { "$_" } | Set-Content -Encoding UTF8 $logFile
$out | ForEach-Object { "$_" } | Where-Object { $_ -match '^==|Msg \d+|Migration|^\d{4}[: ]|ADVISORY|abort|error' } | ForEach-Object { Log "    $_" $(if ($_ -match 'Msg \d+|abort|error') { "Red" } else { "Gray" }) }
Log ("  sqlcmd exit {0} after {1:N1}s (full log: deploy.log)" -f $code, $sw.Elapsed.TotalSeconds)
if ($code -ne 0) {
    Log "  FAILED -- the transaction was rolled back; $DatabaseName is unchanged." "Red"
    exit 1
}
if ($Mode -eq "Rehearse") {
    Log ""
    Log "  REHEARSAL PASSED and was rolled back. Lock window: $([Math]::Round($sw.Elapsed.TotalSeconds,1))s." "Green"
    Log "  Execute with:  -Mode Execute -ExpectedPlan $fingerprint" "Cyan"
    exit 0
}

# ---------- after commit ----------
Head "[11] After commit"
foreach ($pf in $PostCommitFiles) {
    $p = Join-Path $Repeatable $pf
    if (-not (Test-Path $p)) { continue }
    $o2 = & sqlcmd -S $ServerInstance @SqlcmdAuth -d $DatabaseName -i $p -b -I -C 2>&1
    if ($LASTEXITCODE -eq 0) { Log "  $pf applied." "Green" }
    else { Finding "WARN" "post-commit" "$pf failed (documentation only; the release stands): $($o2 | Select-Object -Last 1)" }
}
$Conn.Close(); $Conn = New-Conn
$stillPending = @($files | Where-Object { -not (S "SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'$($_.BaseName)'") })
if ($stillPending.Count) { Finding "WARN" "verify" "still not recorded: $(($stillPending | ForEach-Object BaseName) -join ', ')" } else { Log "  Every repo migration is recorded." "Green" }
$drift = 0
foreach ($a in $toApply) {
    $text = Read-SqlText $a.Path
    foreach ($b in [regex]::Split(($text -replace "`r`n", "`n"), '(?im)^[ \t]*GO[ \t]*(?:--.*)?$')) {
        $m = $ModuleRx.Match($b); if (-not $m.Success) { continue }
        $d = S "SELECT m.definition FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID(N'$($m.Groups[2].Value).$($m.Groups[3].Value)')"
        if (-not $d -or (Norm $b) -ne (Norm ([string]$d))) { $drift++; Finding "WARN" "verify" "$($m.Groups[2].Value).$($m.Groups[3].Value) does not match the repo after deploy" }
    }
}
if ($drift -eq 0) { Log "  All $($toApply.Count) applied repeatable(s) now match the repo byte-for-byte." "Green" }
if ($pendingIds -contains "0076_toolcavity_alpha_code") {
    $final = Q "SELECT t.Code AS Die, ISNULL(i.PartNumber, N'(unmapped)') AS Part, tc.CavityCode AS Code, ISNULL(tc.Description, N'') AS Description FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId LEFT JOIN Parts.Item i ON i.Id = tc.ItemId WHERE tc.DeprecatedAt IS NULL ORDER BY t.Code, Part, tc.CavityCode"
    Save-Csv $final "0076_cavity_letters_final.csv"
    Log "  Final active cavity codes -> 0076_cavity_letters_final.csv"
}
Head "DONE"
Log "  $DatabaseName is at this checkout ($head). Import the Ignition exports NOW -- Core first." "Green"
exit 0
}
catch {
    Log "  ERROR: $($_.Exception.Message)" "Red"
    Log "  Nothing was committed by this run unless [10] printed COMMITTED." "Red"
    exit 1
}
finally {
    if ($Conn) { try { $Conn.Close() } catch {} }
    $env:SQLCMDPASSWORD = $savedEnvPw
}

