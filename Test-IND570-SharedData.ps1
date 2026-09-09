<#
.SYNOPSIS
    Read (and optionally write) an IND570 print template over the Shared Data Server.

.DESCRIPTION
    The Shared Data Server runs on the terminal's PRIMARY Ethernet port, fixed at
    1701 (User Guide 3.8.7). It is separate from the EPrint output port and the two
    run concurrently, so this does not disturb Ignition's connection on 1702.

    Print templates 1-10 are shared data variables pt0101..pt0110, each a string of
    up to 1001 characters (Shared Data Reference 7.2.3.1). The Weights and Measures
    seal does not protect template editing.

    PROTOCOL, as observed on the bench 2026-09-02 (the manual documents the commands
    but not the framing):

      - On connect the server sends a blank line, then "53 Ready for user".
      - EVERY response is followed by a line containing a single ">" prompt.
        That prompt - not a pause - marks the end of a response. Framing on
        timing instead reads each reply one command behind the one that caused it,
        which makes a successful login look like a failure.
      - "user <name>" alone returned "12 Access OK" on this terminal: no password
        required. The manual's "51 Enter Password" path is handled anyway.

    DEFAULT IS READ-ONLY. Nothing is written unless -NewTemplate is supplied.

.EXAMPLE
    .\Test-IND570-SharedData.ps1 -IPAddress 172.17.20.127

.EXAMPLE
    .\Test-IND570-SharedData.ps1 -IPAddress 172.17.20.127 -NewTemplate '!/wt0102...!/E0'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IPAddress,

    [int]    $Port     = 1701,
    [string] $User     = "admin",
    [string] $Password = "admin",

    # pt0101 = Template 1
    [string] $Variable = "pt0101",

    # Supply ONLY when you intend to overwrite. Omit for a read-only check.
    [string] $NewTemplate,

    [int]    $TimeoutMs = 8000
)

$ErrorActionPreference = "Stop"

# Read lines until the ">" prompt. Returns the response lines, prompt excluded.
function Read-Response {
    param($Reader, [int] $TimeoutMs)
    $lines = @()
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $l = $Reader.ReadLine()
        } catch {
            break          # socket read timeout
        }
        if ($null -eq $l) { break }
        $t = $l.Trim()
        if ($t -eq ">") { return $lines }
        if ($t -ne "")  { $lines += $t }
    }
    return $lines
}

# This terminal answers slowly (~1 s). Anything still sitting in the buffer belongs
# to the PREVIOUS command, so discard it before issuing a new one - otherwise every
# reply is attributed to the command after the one that caused it.
function Clear-Stale {
    param($Stream, $Reader)
    $n = 0
    while ($Stream.DataAvailable) {
        if ($null -eq $Reader.ReadLine()) { break }
        $n++
    }
    return $n
}

function Send-Cmd {
    param($Stream, $Writer, $Reader, [string] $Text, [string] $Echo, [int] $TimeoutMs)
    if (-not $Echo) { $Echo = $Text }
    $dropped = Clear-Stale $Stream $Reader
    if ($dropped -gt 0) { Write-Host ("  (discarded {0} stale line(s))" -f $dropped) -ForegroundColor DarkGray }
    Write-Host ("  > {0}" -f $Echo) -ForegroundColor DarkGray
    $Writer.WriteLine($Text)
    Start-Sleep -Milliseconds 400
    # @() is required: PowerShell unwraps a one-element array to a bare string, and
    # [-1] on a string returns its last CHARACTER, not the last line. That turned
    # "12 Access OK" into "K" and made every successful login look like a failure.
    $arr = @(Read-Response $Reader $TimeoutMs)
    foreach ($l in $arr) { Write-Host ("  < {0}" -f $l) }
    if ($arr.Count -eq 0) { return "" }
    return [string] $arr[$arr.Count - 1]
}

Write-Host "Connecting to ${IPAddress}:${Port} (Shared Data Server) ..."
$client = New-Object Net.Sockets.TcpClient
try {
    $client.Connect($IPAddress, $Port)
} catch {
    Write-Host ("CONNECT FAILED: {0}" -f $_.Exception.GetBaseException().Message) -ForegroundColor Red
    return
}
$stream = $client.GetStream()
$stream.ReadTimeout = $TimeoutMs
$reader = New-Object IO.StreamReader($stream)
$writer = New-Object IO.StreamWriter($stream)
$writer.AutoFlush = $true
Write-Host "Connected." -ForegroundColor Green

try {
    # Consume the connect greeting, up to and including its prompt.
    $greeting = Read-Response $reader $TimeoutMs
    foreach ($g in $greeting) { Write-Host ("  < {0}   (greeting)" -f $g) -ForegroundColor DarkGray }

    $r = Send-Cmd $stream $writer $reader "user $User" $null $TimeoutMs
    if ($r -match '^51') {
        $r = Send-Cmd $stream $writer $reader "pass $Password" "pass ********" $TimeoutMs
    }
    if ($r -notmatch '^12') {
        Write-Host ("LOGIN FAILED (last reply: '{0}') - stopping before any read or write." -f $r) -ForegroundColor Red
        Send-Cmd $stream $writer $reader "quit" $null 2000 | Out-Null
        return
    }
    Write-Host "Logged in." -ForegroundColor Green
    Write-Host ""

    Write-Host "--- current value of $Variable  (THIS IS YOUR BACKUP - keep it) ---" -ForegroundColor Cyan
    $before = Send-Cmd $stream $writer $reader "read $Variable" $null $TimeoutMs
    Write-Host ""

    if ($PSBoundParameters.ContainsKey('NewTemplate') -and $NewTemplate) {
        Write-Host "--- WRITING $Variable ---" -ForegroundColor Yellow
        $w = Send-Cmd $stream $writer $reader "write $Variable=$NewTemplate" $null $TimeoutMs
        Write-Host ""
        Write-Host "--- reading back ---" -ForegroundColor Cyan
        $after = Send-Cmd $stream $writer $reader "read $Variable" $null $TimeoutMs
        Write-Host ""
        if ($w -match 'OK') {
            Write-Host "Write acknowledged. Compare the read-back against what you sent." -ForegroundColor Green
            Write-Host "Then POWER CYCLE the terminal and re-run the read - changes may" -ForegroundColor Yellow
            Write-Host "live in RAM until saved." -ForegroundColor Yellow
        } else {
            Write-Host ("Write NOT acknowledged (reply: '{0}'). Value may be unchanged." -f $w) -ForegroundColor Red
        }
    } else {
        Write-Host "Read-only run. Pass -NewTemplate to write." -ForegroundColor DarkGray
    }

    Send-Cmd $stream $writer $reader "quit" $null 2000 | Out-Null
} finally {
    $client.Close()
}
