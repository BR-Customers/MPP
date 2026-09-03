<#
.SYNOPSIS
    Listen to an IND570 EPrint demand-output stream and dump what arrives.

.DESCRIPTION
    Commissioning aid for the EPrint transport (see
    docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md).

    Connects to the terminal's SECONDARY Ethernet port, where an EPrint
    connection publishes demand-output data with no Shared Data login. Prints
    every frame as both text and hex so the exact delimiters and field layout
    can be read off the wire rather than guessed.

    Read-only: opens a socket and reads. Writes nothing to the terminal.

    Run this, then have someone press PRINT on the scale with a known weight
    on the platform.

.EXAMPLE
    .\Test-IND570-EPrint.ps1 -IPAddress 172.17.20.127 -Port 1702
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IPAddress,

    # The terminal's SECONDARY port, set at Communication > Network > Port.
    [Parameter(Mandatory = $true)]
    [int]    $Port,

    [int]    $Seconds = 120
)

Write-Host "Connecting to ${IPAddress}:${Port} ..."
$client = New-Object Net.Sockets.TcpClient
try {
    $client.Connect($IPAddress, $Port)
} catch {
    Write-Host ("CONNECT FAILED: {0}" -f $_.Exception.GetBaseException().Message) -ForegroundColor Red
    Write-Host ""
    Write-Host "Check, in order:"
    Write-Host "  1. Communication > Network > Port > Secondary Port is set to $Port"
    Write-Host "  2. Communication > Connections has a row: Port=EPrint, Assignment=Demand Output"
    Write-Host "  3. The terminal has been POWER CYCLED since the secondary port changed"
    Write-Host "     (the manual says a manual power cycle may be required)"
    return
}

Write-Host "Connected. Listening $Seconds seconds - press PRINT on the scale now." -ForegroundColor Green
Write-Host ""

$stream = $client.GetStream()
$stream.ReadTimeout = 1000
$buffer = New-Object byte[] 4096
$deadline = (Get-Date).AddSeconds($Seconds)
$frames = 0

while ((Get-Date) -lt $deadline) {
    try {
        $n = $stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) {
            Write-Host "-- remote closed the connection --" -ForegroundColor Yellow
            break
        }
        $frames++
        $slice = New-Object byte[] $n
        [Array]::Copy($buffer, 0, $slice, 0, $n)

        $text = [Text.Encoding]::ASCII.GetString($slice)
        $text = $text.Replace("`r", "<CR>").Replace("`n", "<LF>")
        $text = $text.Replace([string][char]2, "<STX>").Replace([string][char]3, "<ETX>")

        $hex = ($slice | ForEach-Object { "{0:X2}" -f $_ }) -join " "

        Write-Host ("[{0:HH:mm:ss}] frame {1}, {2} bytes" -f (Get-Date), $frames, $n) -ForegroundColor Cyan
        Write-Host ("  TEXT: {0}" -f $text)
        Write-Host ("  HEX : {0}" -f $hex)
        Write-Host ""
    } catch [System.IO.IOException] {
        # read timeout - keep waiting until the deadline
    }
}

$client.Close()
Write-Host ("Done. {0} frame(s) received." -f $frames)
if ($frames -eq 0) {
    Write-Host ""
    Write-Host "No data. The socket opened, so EPrint is listening, but nothing was sent."
    Write-Host "Most likely: the Demand Output connection's Trigger is not the key being"
    Write-Host "pressed. Trigger=Scale fires on PRINT; Trigger 1/2/3 fire from a softkey"
    Write-Host "or discrete input instead."
}
