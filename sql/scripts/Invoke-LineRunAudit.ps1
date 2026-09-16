# =============================================================================
# Invoke-LineRunAudit.ps1 -- run the READ-ONLY line run audit against a database
# and save the output to notes\ as incident evidence.
#
#   The audit reconstructs a production line's last N hours: LOTs created, part
#   consumption, containers and trays, and -- the headline -- every refused
#   attempt in Audit.FailureLog, with the shortfall parsed out of the refusal
#   message and an ESTIMATE of how much production was physically made but never
#   recorded.
#
#   SQL: sql\scratch\2026-09-15_line_run_audit.sql. It writes nothing.
#   Design: docs\superpowers\specs\2026-09-15-line-run-audit-design.md
#
# Usage (from the repo root):
#   .\sql\scripts\Invoke-LineRunAudit.ps1                                  # MA2-6MACH, last 24h, prod
#   .\sql\scripts\Invoke-LineRunAudit.ps1 -LineCode MA2-6MAOP -Hours 48
#   .\sql\scripts\Invoke-LineRunAudit.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Username ""
#
# Password: taken from $env:SQLCMDPASSWORD if set, else a masked prompt. It is
# handed to sqlcmd through that environment variable, never on the command line,
# and the variable is restored afterwards.
#
# Output: printed, and saved to
#   notes\<date>_line-run-audit-<line>_<HHmm>.txt
# notes\ is committed on purpose -- this is evidence of a real incident, not a
# throwaway readiness check. Use -OutputDirectory to send it somewhere else.
#
# SAFETY: the .sql is scanned for write verbs before it is run. This script
# points at production; a read-only script that quietly stopped being read-only
# is exactly the failure worth one regex.
# =============================================================================
param(
    [string]$LineCode        = "MA2-6MACH",
    [int]   $Hours           = 24,
    [string]$ServerInstance  = "172.17.10.148",
    [string]$DatabaseName    = "MPP_MES_Prod",
    [string]$Username        = "Ignition",
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SqlFile  = Join-Path $RepoRoot "sql\scratch\2026-09-15_line_run_audit.sql"

if (-not (Test-Path $SqlFile)) { throw "Audit SQL not found: $SqlFile" }
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { throw "sqlcmd is not on PATH." }
if ($Hours -lt 1 -or $Hours -gt 720) { throw "-Hours must be between 1 and 720." }

$sql = Get-Content -Path $SqlFile -Raw

# ---- Read-only guard --------------------------------------------------------
# Strip comments AND string literals, then look for anything that writes.
# INSERT INTO a table VARIABLE (@Scope, @Fail) is how the script stages its own
# working sets and is allowed; everything else is not.
#
# This is a single-pass scanner rather than layered regexes on purpose. String
# literals here legitimately contain both "--" (the proc's own shortage message)
# and verbs in prose ("do not hand-UPDATE it"), so literals must be removed --
# but removing line comments FIRST would truncate a line mid-literal, unbalance
# the quotes, and let a later literal-strip swallow real SQL. That fails in the
# dangerous direction: a silent false negative on an actual write. One pass that
# knows which construct it is inside has neither problem.
function Remove-SqlNoise {
    param([string]$s)
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c  = $s[$i]
        $c2 = if ($i + 1 -lt $n) { $s[$i + 1] } else { [char]0 }
        if ($c -eq "'") {                                   # string literal ('' escapes)
            $i++
            while ($i -lt $n) {
                if ($s[$i] -eq "'") {
                    if ($i + 1 -lt $n -and $s[$i + 1] -eq "'") { $i += 2; continue }
                    $i++; break
                }
                $i++
            }
            [void]$sb.Append(' ')
        }
        elseif ($c -eq '-' -and $c2 -eq '-') {              # line comment
            while ($i -lt $n -and $s[$i] -ne "`n") { $i++ }
            [void]$sb.Append(' ')
        }
        elseif ($c -eq '/' -and $c2 -eq '*') {              # block comment
            $i += 2
            while ($i + 1 -lt $n -and -not ($s[$i] -eq '*' -and $s[$i + 1] -eq '/')) { $i++ }
            $i += 2
            [void]$sb.Append(' ')
        }
        else { [void]$sb.Append($c); $i++ }
    }
    $sb.ToString()
}

$stripped = Remove-SqlNoise $sql

$violations = @()

# DML: capture each statement's TARGET and judge it. Do NOT try to express
# "except table variables" as a lookahead -- an optional INTO lets the regex
# backtrack and match anyway, so the guard would flag its own INSERT INTO @Scope
# and refuse to run every time.
foreach ($m in [regex]::Matches($stripped, '(?is)\b(INSERT|UPDATE|DELETE|MERGE)\b\s+(?:INTO\s+|FROM\s+)?(@?[A-Za-z0-9_\.\[\]#]+)')) {
    $verb   = $m.Groups[1].Value.ToUpper()
    $target = $m.Groups[2].Value
    if (-not $target.StartsWith('@')) { $violations += "$verb $target" }
}

# DDL and anything that executes or moves data. None of these have a benign form
# in a read-only audit, so a bare word match is the right sensitivity.
foreach ($wp in @(
    @{ Name = "TRUNCATE";         Pattern = '(?i)\bTRUNCATE\b' },
    @{ Name = "DROP";             Pattern = '(?i)\bDROP\b' },
    @{ Name = "ALTER";            Pattern = '(?i)\bALTER\b' },
    @{ Name = "CREATE";           Pattern = '(?i)\bCREATE\b' },
    @{ Name = "EXEC";             Pattern = '(?i)\bEXEC(?:UTE)?\b' },
    @{ Name = "GRANT / REVOKE";   Pattern = '(?i)\b(?:GRANT|REVOKE|DENY)\b' },
    @{ Name = "BACKUP / RESTORE"; Pattern = '(?i)\b(?:BACKUP|RESTORE)\b' })) {
    if ([regex]::IsMatch($stripped, $wp.Pattern)) { $violations += $wp.Name }
}
$violations = $violations | Select-Object -Unique
if ($violations.Count -gt 0) {
    Write-Host ""
    Write-Host "  REFUSING TO RUN -- the audit SQL is no longer read-only." -ForegroundColor Red
    Write-Host "  Found: $($violations -join ', ')" -ForegroundColor Red
    Write-Host "  File : $SqlFile" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  This script runs against production. If the statement is genuinely" -ForegroundColor DarkGray
    Write-Host "  harmless, stage it into a table variable (INSERT INTO @x) instead," -ForegroundColor DarkGray
    Write-Host "  or run it deliberately through Deploy-ProdRelease.ps1." -ForegroundColor DarkGray
    exit 2
}

# ---- Parameter substitution -------------------------------------------------
# The .sql declares its own defaults so it stays runnable standalone in SSMS.
# Rewrite those two DECLARE lines in a temp copy rather than switching the file
# to sqlcmd -v variables, which SSMS does not honour unless SQLCMD mode is on.
# Fail loudly if a substitution misses: silently auditing the wrong line or the
# wrong window is worse than not running.
$safeLine = ($LineCode -replace "'", "''")

$nLine = 0; $nHours = 0
$patched = [regex]::Replace($sql,
    "(?m)^(DECLARE\s+@LineCode\s+NVARCHAR\(50\)\s*=\s*)N'[^']*'",
    { param($m) $script:nLine++; "$($m.Groups[1].Value)N'$safeLine'" })
$patched = [regex]::Replace($patched,
    "(?m)^(DECLARE\s+@Hours\s+INT\s*=\s*)\d+",
    { param($m) $script:nHours++; "$($m.Groups[1].Value)$Hours" })

if ($nLine -ne 1)  { throw "Could not set @LineCode in $SqlFile (matched $nLine times, expected 1). Refusing to run." }
if ($nHours -ne 1) { throw "Could not set @Hours in $SqlFile (matched $nHours times, expected 1). Refusing to run." }

$tempSql = Join-Path ([IO.Path]::GetTempPath()) ("line_run_audit_{0}.sql" -f ([guid]::NewGuid().ToString("N")))
Set-Content -Path $tempSql -Value $patched -Encoding utf8

# ---- Output destination -----------------------------------------------------
$OutDir = if ($OutputDirectory -ne "") { $OutputDirectory } else { Join-Path $RepoRoot "notes" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$lineSlug = ($LineCode -replace '[^A-Za-z0-9\-_]', '_')
$OutFile  = Join-Path $OutDir ("{0}_line-run-audit-{1}_{2}.txt" -f (Get-Date -Format "yyyy-MM-dd"), $lineSlug, (Get-Date -Format "HHmm"))

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
    Write-Host "  Line run audit  ->  $LineCode, last $Hours h" -ForegroundColor Cyan
    Write-Host "  $DatabaseName on $ServerInstance  (read-only)" -ForegroundColor DarkGray
    Write-Host ""

    # -b: non-zero exit on a SQL error. -C: trust the server certificate (as the
    # deploy scripts do). -W -s "|": trimmed, pipe-separated columns.
    $output = & sqlcmd -S $ServerInstance @auth -d $DatabaseName -i $tempSql -b -C -W -s "|" 2>&1
    $code = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" })

    $header = @(
        "LINE RUN AUDIT",
        "Line     : $LineCode",
        "Window   : last $Hours hours",
        "Database : $DatabaseName on $ServerInstance",
        "Run at   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (local)",
        "SQL      : $SqlFile",
        "",
        "All displayed timestamps are EASTERN (stored UTC, converted at read).",
        "Section 3.5 is an ESTIMATE, not a count -- see its own header.",
        ""
    )
    ($header + $text) | Set-Content -Path $OutFile -Encoding utf8

    foreach ($line in $text) {
        if     ($line -like "===*" -or $line -like "###*")     { Write-Host $line -ForegroundColor Cyan }
        elseif ($line -match "\*\*\*")                          { Write-Host $line -ForegroundColor Red }
        elseif ($line -match "BLIND HOUR|ABANDONED|BLOCKER|NEVER succeeded|TOTAL LOSS|INVESTIGATE|NEGATIVE") { Write-Host $line -ForegroundColor Red }
        elseif ($line -match "SHORT|EMPTY|STALE|LOW |DEPRECATED|MISSING|degraded|OVERSTATED") { Write-Host $line -ForegroundColor Yellow }
        elseif ($line -match "\|(ok|clean|active|live|flowing)(\||$)") { Write-Host $line -ForegroundColor Green }
        else                                                    { Write-Host $line }
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
    if (Test-Path $tempSql) { Remove-Item $tempSql -Force -ErrorAction SilentlyContinue }
}
