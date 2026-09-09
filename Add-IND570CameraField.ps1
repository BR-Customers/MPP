<#
.SYNOPSIS
    Append the camera-input field to the IND570 demand-output template, over TCP.

.DESCRIPTION
    Reads print template 1 (shared data pt0101) from the terminal, copies it to
    template 4 (pt0104) as a verified backup, then rewrites template 1 with a
    camera line appended. The template is never typed by hand.

    Produces one extra output line per weighment:   CAM=0   or   CAM=1
    from a CR/LF, the literal "CAM=", and shared data di0104 = "Input Status 4"
    (Shared Data Reference 5.1.1.1, "0 = Off, 1 = On").

    Uses the Shared Data Server on the PRIMARY Ethernet port (1701), which is
    independent of the EPrint port Ignition reads on. Ignition can stay enabled.

    PROTOCOL NOTES, learned the hard way on this terminal:

      * It greets on connect with a blank line then "53 Ready for user", and ends
        each response with a ">" prompt.
      * Response timing is VARIABLE - sometimes under a second, sometimes several.
        Any approach that sleeps a fixed time and then reads whatever arrived will
        intermittently attribute a reply to the wrong command. This script instead
        waits for the specific text it expects, with a generous deadline.
      * "user <name>" alone returns "12 Access OK" here; NO password is required.
        Sending "pass" anyway is NOT harmless - it answers "83 Command not
        recognized" and drops the session back to unauthenticated, after which
        every command fails with "84 Exec USER command first".

.EXAMPLE
    .\Add-IND570CameraField.ps1 -IPAddress 172.17.20.127 -WhatIfOnly

.EXAMPLE
    .\Add-IND570CameraField.ps1 -IPAddress 172.17.20.127

.EXAMPLE
    .\Add-IND570CameraField.ps1 -IPAddress 172.17.20.127 -Restore
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IPAddress,

    [int]    $Port       = 1701,
    [string] $User       = "admin",
    [string] $Password   = "admin",
    [string] $Target     = "pt0101",
    [string] $BackupSlot = "pt0104",
    [int]    $TimeoutSec = 20,

    [switch] $WhatIfOnly,
    [switch] $Restore
)

$ErrorActionPreference = "Stop"

$SUFFIX_OLD = '!/n002/!/E0'
$SUFFIX_NEW = '!/n001/"CAM="!/X1/!/di0104!/L1/!/n002/!/E0'

Write-Host "Connecting to ${IPAddress}:${Port} (Shared Data Server) ..."
$client = New-Object Net.Sockets.TcpClient
try { $client.Connect($IPAddress, $Port) }
catch {
    Write-Host ("CONNECT FAILED: {0}" -f $_.Exception.GetBaseException().Message) -ForegroundColor Red
    return
}
$stream = $client.GetStream()
Write-Host "Connected." -ForegroundColor Green

# Byte-level line assembly. No ReadLine, so no read-timeout exceptions and no
# lost buffered data; whatever has arrived is drained into a text buffer and cut
# into complete lines only when a newline is actually present.
$script:pending = ""

function Pump {
    $lines = @()
    while ($stream.DataAvailable) {
        $b = New-Object byte[] 8192
        $n = $stream.Read($b, 0, 8192)
        if ($n -le 0) { break }
        $script:pending += [Text.Encoding]::ASCII.GetString($b, 0, $n)
    }
    while ($script:pending.Contains("`n")) {
        $i = $script:pending.IndexOf("`n")
        $line = $script:pending.Substring(0, $i).Trim("`r").Trim()
        $script:pending = $script:pending.Substring($i + 1)
        if ($line -ne "" -and $line -ne ">") { $lines += $line }
    }
    return $lines
}

# Send (optionally), then wait until a line matching $Pattern arrives, or the
# deadline passes. Returns the matching line, or $null.
function Expect {
    param([string] $Send, [string] $Pattern, [string] $Echo, [int] $Seconds = 0)
    if ($Seconds -le 0) { $Seconds = $TimeoutSec }
    if ($Send) {
        if (-not $Echo) { $Echo = $Send }
        Write-Host ("  > {0}" -f $Echo) -ForegroundColor DarkGray
        $w = New-Object IO.StreamWriter($stream)
        $w.AutoFlush = $true
        $w.WriteLine($Send)
    }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($l in Pump) {
            Write-Host ("  < {0}" -f $l)
            if ($l -match $Pattern) { return $l }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Get-Value {
    param([string] $Line)
    if (-not $Line) { return $null }
    return ($Line -replace '^[^~]*~','' -replace '~$','')
}

try {
    # Greeting. Not fatal if it never shows.
    Expect $null '53|Ready' $null 5 | Out-Null

    $login = Expect "user $User" 'Access OK|Enter Password|No access'
    if (-not $login) {
        Write-Host "No login response within timeout. Stopping." -ForegroundColor Red
        return
    }
    if ($login -match 'Enter Password') {
        $login = Expect "pass $Password" 'Access OK|No access' "pass ********"
    }
    if (-not $login -or $login -notmatch 'Access OK') {
        Write-Host ("Login failed: '{0}'" -f $login) -ForegroundColor Red
        return
    }
    Write-Host "Logged in." -ForegroundColor Green

    if ($Restore) {
        Write-Host ""
        Write-Host "--- RESTORE $BackupSlot -> $Target ---" -ForegroundColor Yellow
        $bak = Get-Value (Expect "read $BackupSlot" '~')
        if (-not $bak -or $bak -notmatch '!/E0$') {
            Write-Host "Backup slot empty or unreadable. Nothing restored." -ForegroundColor Red
            return
        }
        Expect "write $Target=$bak" 'OK|~' | Out-Null
        $chk = Get-Value (Expect "read $Target" '~')
        if ($chk -eq $bak) { Write-Host "Restored and verified." -ForegroundColor Green }
        else               { Write-Host "Restore did NOT verify." -ForegroundColor Red }
        return
    }

    Write-Host ""
    Write-Host "--- current $Target ---" -ForegroundColor Cyan
    $old = Get-Value (Expect "read $Target" '~')
    if (-not $old -or $old -notmatch '!/E0$') {
        Write-Host "Could not read a valid template. Stopping." -ForegroundColor Red
        return
    }
    if ($old -like '*di0104*') {
        Write-Host "Camera field already present. Nothing to do." -ForegroundColor Yellow
        return
    }
    if ($old -notlike "*$SUFFIX_OLD") {
        Write-Host "Template does not end in '$SUFFIX_OLD'. Stopping rather than guessing." -ForegroundColor Red
        return
    }

    $new = $old.Substring(0, $old.Length - $SUFFIX_OLD.Length) + $SUFFIX_NEW
    Write-Host ""
    Write-Host "OLD: $old"
    Write-Host "NEW: $new" -ForegroundColor Green
    Write-Host ""

    if ($WhatIfOnly) {
        Write-Host "-WhatIfOnly set. Nothing written." -ForegroundColor Yellow
        return
    }

    Write-Host "--- backing up $Target to $BackupSlot ---" -ForegroundColor Cyan
    Expect "write $BackupSlot=$old" 'OK|~' | Out-Null
    $bakCheck = Get-Value (Expect "read $BackupSlot" '~')
    if ($bakCheck -ne $old) {
        Write-Host "BACKUP DID NOT VERIFY. Refusing to modify $Target." -ForegroundColor Red
        return
    }
    Write-Host "Backup verified." -ForegroundColor Green

    Write-Host ""
    Write-Host "--- writing $Target ---" -ForegroundColor Cyan
    Expect "write $Target=$new" 'OK|~' | Out-Null
    $after = Get-Value (Expect "read $Target" '~')
    Write-Host ""
    if ($after -eq $new) {
        Write-Host "SUCCESS - template updated and verified." -ForegroundColor Green
        Write-Host "Press the operator button and look for a 'CAM=' line in Ignition."
        Write-Host "Then power-cycle the terminal and re-run -WhatIfOnly to confirm it persisted." -ForegroundColor Yellow
    } else {
        Write-Host "Read-back does NOT match what was sent." -ForegroundColor Red
        Write-Host ("Restore with:  .\Add-IND570CameraField.ps1 -IPAddress {0} -Restore" -f $IPAddress) -ForegroundColor Yellow
    }
} finally {
    try { Expect "quit" 'Goodbye|13' $null 3 | Out-Null } catch { }
    $client.Close()
}
