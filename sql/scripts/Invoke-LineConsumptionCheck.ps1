# =============================================================================
# Invoke-LineConsumptionCheck.ps1 -- run the READ-ONLY line consumption check
# and save every section of its output to its own file.
#
#   SQL: sql\scratch\2026-10-05_line_consumption_vs_expected.sql. It writes nothing.
#
# Usage (from the repo root):
#   .\sql\scripts\Invoke-LineConsumptionCheck.ps1 -From "2026-10-01" -To "2026-10-05"
#   .\sql\scripts\Invoke-LineConsumptionCheck.ps1 -LineCode MA2-6MAOP -From "2026-10-04 06:00" -To "2026-10-04 14:30"
#   .\sql\scripts\Invoke-LineConsumptionCheck.ps1 -From ... -To ... -ServerInstance localhost -DatabaseName MPP_MES_Dev -Username ""
#
# -From is inclusive, -To exclusive, both EASTERN.
#
# Password: taken from $env:SQLCMDPASSWORD if set, else a masked prompt. It is
# handed to sqlcmd through that environment variable, never on the command line,
# and the variable is restored afterwards.
#
# Output: a folder (git-ignored -- it is prod data)
#   sql\scratch\_out_line_consumption_<line>_<yyyyMMdd_HHmm>\
#     00_full.txt             everything, in order
#     01_window.txt ...       one pipe-separated file per "=== N. title" section
# The console shows only a row count per section; read the files.
#
# SAFETY: the .sql is scanned for write verbs before it is run (same guard as
# Invoke-LineRunAudit.ps1 -- keep the two in step).
# =============================================================================
param(
    [string]  $LineCode        = "MA2-6MACH",
    [Parameter(Mandatory = $true)][datetime]$From,
    [Parameter(Mandatory = $true)][datetime]$To,
    [string]  $ServerInstance  = "172.17.10.148",
    [string]  $DatabaseName    = "MPP_MES_Prod",
    [string]  $Username        = "Ignition",
    [string]  $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SqlFile  = Join-Path $RepoRoot "sql\scratch\2026-10-05_line_consumption_vs_expected.sql"

if (-not (Test-Path $SqlFile)) { throw "SQL not found: $SqlFile" }
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { throw "sqlcmd is not on PATH." }
if ($To -le $From) { throw "-To must be after -From." }

$sql = Get-Content -Path $SqlFile -Raw

# ---- Read-only guard (mirrors Invoke-LineRunAudit.ps1; rationale lives there) --
# Single pass: strip string literals and comments, then look for anything that
# writes. INSERT INTO a table VARIABLE is how the script stages its working sets
# and is allowed; everything else is not.
function Remove-SqlNoise {
    param([string]$s)
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c  = $s[$i]
        $c2 = if ($i + 1 -lt $n) { $s[$i + 1] } else { [char]0 }
        if ($c -eq "'") {
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
        elseif ($c -eq '-' -and $c2 -eq '-') {
            while ($i -lt $n -and $s[$i] -ne "`n") { $i++ }
            [void]$sb.Append(' ')
        }
        elseif ($c -eq '/' -and $c2 -eq '*') {
            $i += 2
            while ($i + 1 -lt $n -and -not ($s[$i] -eq '*' -and $s[$i + 1] -eq '/')) { $i++ }
            $i += 2
            [void]$sb.Append(' ')
        }
        else { [void]$sb.Append($c); $i++ }
    }
    $sb.ToString()
}

$stripped   = Remove-SqlNoise $sql
$violations = @()
foreach ($m in [regex]::Matches($stripped, '(?is)\b(INSERT|UPDATE|DELETE|MERGE)\b\s+(?:INTO\s+|FROM\s+)?(@?[A-Za-z0-9_\.\[\]#]+)')) {
    if (-not $m.Groups[2].Value.StartsWith('@')) { $violations += "$($m.Groups[1].Value.ToUpper()) $($m.Groups[2].Value)" }
}
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
$violations = @($violations | Select-Object -Unique)
if ($violations.Count -gt 0) {
    Write-Host ""
    Write-Host "  REFUSING TO RUN -- the SQL is no longer read-only." -ForegroundColor Red
    Write-Host "  Found: $($violations -join ', ')" -ForegroundColor Red
    Write-Host "  File : $SqlFile" -ForegroundColor DarkGray
    exit 2
}

# ---- Parameter substitution ---------------------------------------------------
# The .sql keeps its own defaults so it stays runnable in SSMS; rewrite the three
# DECLAREs in a temp copy. Fail loudly if a substitution misses -- silently
# checking the wrong line or window is worse than not running.
$safeLine = ($LineCode -replace "'", "''")
$fromLit  = $From.ToString("yyyy-MM-dd HH:mm:ss")
$toLit    = $To.ToString("yyyy-MM-dd HH:mm:ss")

$script:nLine = 0; $script:nFrom = 0; $script:nTo = 0
$patched = [regex]::Replace($sql,
    "(?m)^(DECLARE\s+@LineCode\s+NVARCHAR\(50\)\s*=\s*)N'[^']*'",
    { param($m) $script:nLine++; "$($m.Groups[1].Value)N'$safeLine'" })
$patched = [regex]::Replace($patched,
    "(?m)^(DECLARE\s+@FromEastern\s+DATETIME2\(3\)\s*=\s*)'[^']*'",
    { param($m) $script:nFrom++; "$($m.Groups[1].Value)'$fromLit'" })
$patched = [regex]::Replace($patched,
    "(?m)^(DECLARE\s+@ToEastern\s+DATETIME2\(3\)\s*=\s*)'[^']*'",
    { param($m) $script:nTo++; "$($m.Groups[1].Value)'$toLit'" })

if ($script:nLine -ne 1) { throw "Could not set @LineCode (matched $($script:nLine) times, expected 1). Refusing to run." }
if ($script:nFrom -ne 1) { throw "Could not set @FromEastern (matched $($script:nFrom) times, expected 1). Refusing to run." }
if ($script:nTo   -ne 1) { throw "Could not set @ToEastern (matched $($script:nTo) times, expected 1). Refusing to run." }

$tempSql = Join-Path ([IO.Path]::GetTempPath()) ("line_consumption_{0}.sql" -f ([guid]::NewGuid().ToString("N")))
Set-Content -Path $tempSql -Value $patched -Encoding utf8

# ---- Output destination -------------------------------------------------------
$lineSlug = ($LineCode -replace '[^A-Za-z0-9\-_]', '_')
$OutDir = if ($OutputDirectory -ne "") { $OutputDirectory } else {
    Join-Path $RepoRoot ("sql\scratch\_out_line_consumption_{0}_{1}" -f $lineSlug, (Get-Date -Format "yyyyMMdd_HHmm"))
}
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
    Write-Host "  Line consumption check  ->  $LineCode, $fromLit to $toLit (Eastern)" -ForegroundColor Cyan
    Write-Host "  $DatabaseName on $ServerInstance  (read-only)" -ForegroundColor DarkGray
    Write-Host ""

    # -b: non-zero exit on a SQL error. -C: trust the server certificate.
    # -W -s "|": trimmed, pipe-separated columns.
    $output = & sqlcmd -S $ServerInstance @auth -d $DatabaseName -i $tempSql -b -C -W -s "|" 2>&1
    $code = $LASTEXITCODE
    $text = @($output | ForEach-Object { "$_" })

    $header = @(
        "LINE CONSUMPTION CHECK",
        "Line     : $LineCode",
        "Window   : $fromLit to $toLit (Eastern; from inclusive, to exclusive)",
        "Database : $DatabaseName on $ServerInstance",
        "Run at   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (local)",
        ""
    )
    ($header + $text) | Set-Content -Path (Join-Path $OutDir "00_full.txt") -Encoding utf8

    # ---- Split on "=== N. title ===" into one file per section -----------------
    $current = $null; $buf = @(); $sections = @()
    foreach ($line in $text) {
        if ($line -match '^===\s+(\d+)\.\s+(.+?)\s*=*$') {
            if ($current) { $sections += [pscustomobject]@{ Name = $current; Lines = $buf } }
            $slug = (($Matches[2] -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower())
            if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50).Trim('-') }
            $current = "{0:D2}_{1}.txt" -f [int]$Matches[1], $slug
            $buf = @($line)
        }
        elseif ($current) { $buf += $line }
    }
    if ($current) { $sections += [pscustomobject]@{ Name = $current; Lines = $buf } }

    foreach ($s in $sections) {
        $s.Lines | Set-Content -Path (Join-Path $OutDir $s.Name) -Encoding utf8
        # Data rows = pipe-separated lines after the dashed rule under the header.
        $rule = -1
        for ($i = 0; $i -lt $s.Lines.Count; $i++) { if ($s.Lines[$i] -match '^-+(\|-+)*$') { $rule = $i; break } }
        $rows = if ($rule -ge 0) { @($s.Lines[($rule + 1)..($s.Lines.Count)] | Where-Object { $_ -and $_.Trim() -ne "" }).Count } else { 0 }
        Write-Host ("  {0,-62} {1,6} rows" -f $s.Name, $rows)
    }

    Write-Host ""
    if ($code -ne 0) {
        Write-Host "  sqlcmd exited $code -- see 00_full.txt." -ForegroundColor Red
        $text | Select-Object -Last 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    Write-Host "  Saved: $OutDir" -ForegroundColor DarkGray
    exit $code
}
finally {
    $env:SQLCMDPASSWORD = $savedEnvPw
    if (Test-Path $tempSql) { Remove-Item $tempSql -Force -ErrorAction SilentlyContinue }
}
