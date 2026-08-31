<#
.SYNOPSIS
    Read-only bench test for an IND570 EtherNet/IP - Modbus TCP combo option card.

.DESCRIPTION
    Proves, without writing anything to the terminal:

      1. TCP reachability on 502 (Modbus TCP) and 44818 (EtherNet/IP encapsulation).
      2. EtherNet/IP is alive, via the CIP ListIdentity encapsulation command
         (0x0063). Returns vendor / product code / revision / serial / product
         name. Needs no PLC and no scanner.
      3. Modbus TCP answers, via function code 3, and dumps slot 1 decoded four
         ways so the correct Byte Order and register base can be read off the
         output instead of guessed.

    Spec: docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md
    Protocol source: reference/IND570_PLC_Interface_Manual.md ch. 4, 5, App B, App C.

    NOTHING here writes to the terminal. No command register is touched, so a
    parked slot-1 command survives the test and a production scale is not
    disturbed. Still: prefer to run it with the Ignition IND570 device DISABLED
    until we have proven the card tolerates concurrent masters.

.EXAMPLE
    .\Test-IND570-Link.ps1 -IPAddress 10.24.24.51
.EXAMPLE
    .\Test-IND570-Link.ps1 -IPAddress 10.24.24.51 -UnitId 1 -MaxRegisters 8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IPAddress,

    # Modbus unit / slave id. IND570 normally ignores it; 1 is the safe default.
    [int]    $UnitId = 1,

    # How many holding registers to pull. 8 covers slots 1 and 2 in FP format.
    [int]    $MaxRegisters = 8,

    [int]    $TimeoutMs = 3000
)

$ErrorActionPreference = "Stop"

function Write-Head($text) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host $text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}

function Write-Pass($text) { Write-Host "  [PASS] $text" -ForegroundColor Green }
function Write-Fail($text) { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "  $text" }

function Connect-Tcp {
    param([string] $Address, [int] $Port, [int] $Timeout)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($Timeout, $false)) {
            $client.Close()
            return $null
        }
        $client.EndConnect($async)
        $client.ReceiveTimeout = $Timeout
        $client.SendTimeout = $Timeout
        return $client
    } catch {
        try { $client.Close() } catch { }
        return $null
    }
}

# MSB-first 4 bytes -> IEEE754 single. BitConverter is little-endian on x86, so
# the logical big-endian order has to be reversed before handing it over.
function ConvertTo-Float32 {
    param([byte[]] $MsbFirst)
    $r = New-Object byte[] 4
    $r[0] = $MsbFirst[3]; $r[1] = $MsbFirst[2]
    $r[2] = $MsbFirst[1]; $r[3] = $MsbFirst[0]
    return [BitConverter]::ToSingle($r, 0)
}

# ---------------------------------------------------------------------------
# 1. Port reachability
# ---------------------------------------------------------------------------
Write-Head "1. TCP reachability on $IPAddress"

$ports = @(
    @{ Port = 502;   Name = "Modbus TCP" },
    @{ Port = 44818; Name = "EtherNet/IP encapsulation" },
    @{ Port = 1701;  Name = "MT-SICS (IND400-style; not expected on IND570)" }
)
$open = @{}
foreach ($p in $ports) {
    $c = Connect-Tcp -Address $IPAddress -Port $p.Port -Timeout $TimeoutMs
    if ($c -ne $null) {
        Write-Pass ("{0,-5} open   - {1}" -f $p.Port, $p.Name)
        $open[$p.Port] = $true
        $c.Close()
    } else {
        Write-Info ("{0,-5} closed - {1}" -f $p.Port, $p.Name)
        $open[$p.Port] = $false
    }
}

if ((-not $open[502]) -and (-not $open[44818])) {
    Write-Host ""
    Write-Fail "Neither 502 nor 44818 answered. The option card is not reachable."
    Write-Info "Check, in this order:"
    Write-Info "  a. Card status LEDs (manual Table 5-4). LED1 off + LED4 off = cable"
    Write-Info "     unplugged AT THE TERMINAL. LED3 flashing red = unplugged at the"
    Write-Info "     scanner end. All green with LED4 blinking = connected."
    Write-Info "  b. Terminal IP / mask / gateway at Communication > PLC Interface >"
    Write-Info "     EtherNet/IP-Modbus TCP. A wrong DEFAULT GATEWAY on the device"
    Write-Info "     produces a silent cross-subnet timeout while same-subnet works."
    Write-Info "  c. Do NOT use ping as the health check - ICMP can be filtered or"
    Write-Info "     flaky while TCP is fine."
    exit 1
}

# ---------------------------------------------------------------------------
# 2. EtherNet/IP ListIdentity
# ---------------------------------------------------------------------------
Write-Head "2. EtherNet/IP - CIP ListIdentity (0x0063), read-only"

if (-not $open[44818]) {
    Write-Info "Port 44818 closed: the EtherNet/IP stack is not listening."
    Write-Info "On the combo card that usually means the terminal Data Format is set"
    Write-Info "for Modbus TCP use. Not a fault for our design - see the closing note."
} else {
    $c = Connect-Tcp -Address $IPAddress -Port 44818 -Timeout $TimeoutMs
    if ($c -eq $null) {
        Write-Fail "Could not open 44818 on the second attempt."
    } else {
        try {
            $stream = $c.GetStream()
            $pkt = New-Object byte[] 24        # header only, zero-length payload
            $pkt[0] = 0x63; $pkt[1] = 0x00     # Command = ListIdentity (little-endian)
            $stream.Write($pkt, 0, 24)
            $stream.Flush()

            $buf = New-Object byte[] 512
            $n = $stream.Read($buf, 0, 512)

            if ($n -lt 63) {
                Write-Fail "Short reply ($n bytes) - not a CIP identity response."
            } else {
                $status = [BitConverter]::ToUInt32($buf, 8)
                if ($status -ne 0) {
                    Write-Fail ("Encapsulation status 0x{0:X8} (non-zero = error)." -f $status)
                }
                $vendor   = [BitConverter]::ToUInt16($buf, 48)
                $devType  = [BitConverter]::ToUInt16($buf, 50)
                $prodCode = [BitConverter]::ToUInt16($buf, 52)
                $revMaj   = $buf[54]
                $revMin   = $buf[55]
                $serial   = [BitConverter]::ToUInt32($buf, 58)
                $nameLen  = $buf[62]
                $name     = ""
                if (($nameLen -gt 0) -and ((63 + $nameLen) -le $n)) {
                    $name = [System.Text.Encoding]::ASCII.GetString($buf, 63, $nameLen)
                }
                Write-Pass "EtherNet/IP stack responded to ListIdentity."
                Write-Info ("Product name : {0}" -f $name)
                Write-Info ("Vendor ID    : {0}" -f $vendor)
                Write-Info ("Device type  : {0}" -f $devType)
                Write-Info ("Product code : {0}" -f $prodCode)
                Write-Info ("Revision     : {0}.{1}" -f $revMaj, $revMin)
                Write-Info ("Serial       : {0}" -f $serial)
            }
        } catch {
            Write-Fail ("ListIdentity failed: {0}" -f $_.Exception.Message)
        } finally {
            $c.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Modbus TCP read
# ---------------------------------------------------------------------------
Write-Head "3. Modbus TCP - read holding registers (function code 3), read-only"

function Read-HoldingRegisters {
    param(
        [System.Net.Sockets.TcpClient] $Client,
        [int] $StartAddress,
        [int] $Quantity,
        [int] $Unit
    )
    $stream = $Client.GetStream()
    $req = New-Object byte[] 12
    $req[0] = 0x00; $req[1] = 0x01                        # transaction id
    $req[2] = 0x00; $req[3] = 0x00                        # protocol id = 0
    $req[4] = 0x00; $req[5] = 0x06                        # remaining length
    $req[6] = [byte] $Unit
    $req[7] = 0x03                                        # read holding registers
    $req[8]  = [byte] (($StartAddress -shr 8) -band 0xFF)
    $req[9]  = [byte] ($StartAddress -band 0xFF)
    $req[10] = [byte] (($Quantity -shr 8) -band 0xFF)
    $req[11] = [byte] ($Quantity -band 0xFF)
    $stream.Write($req, 0, 12)
    $stream.Flush()

    $buf = New-Object byte[] 512
    $n = $stream.Read($buf, 0, 512)
    if ($n -lt 9) { return @{ Ok = $false; Error = "short reply ($n bytes)" } }
    if (($buf[7] -band 0x80) -ne 0) {
        $codes = @{
            1 = "ILLEGAL FUNCTION"; 2 = "ILLEGAL DATA ADDRESS";
            3 = "ILLEGAL DATA VALUE"; 4 = "SLAVE DEVICE FAILURE"
        }
        $code = [int] $buf[8]
        $text = $codes[$code]
        if (-not $text) { $text = "exception $code" }
        return @{ Ok = $false; Error = "Modbus exception $code - $text" }
    }
    $byteCount = [int] $buf[8]
    $data = New-Object byte[] $byteCount
    [Array]::Copy($buf, 9, $data, 0, $byteCount)
    return @{ Ok = $true; Data = $data }
}

if (-not $open[502]) {
    Write-Fail "Port 502 closed - Modbus TCP is not listening on this card."
    Write-Info "Check Communication > PLC Interface > Data Format on the terminal."
} else {
    foreach ($base in @(0, 1)) {
        Write-Host ""
        Write-Host ("--- start address {0} ---" -f $base) -ForegroundColor Yellow
        $c = Connect-Tcp -Address $IPAddress -Port 502 -Timeout $TimeoutMs
        if ($c -eq $null) { Write-Fail "connect failed"; continue }
        try {
            $r = Read-HoldingRegisters -Client $c -StartAddress $base -Quantity $MaxRegisters -Unit $UnitId
            if (-not $r.Ok) {
                Write-Fail $r.Error
            } else {
                $d = $r.Data
                $regs = @()
                for ($i = 0; $i -lt $d.Length; $i += 2) {
                    $regs += ((([int] $d[$i]) -shl 8) -bor ([int] $d[$i + 1]))
                }
                Write-Pass ("{0} registers returned." -f $regs.Count)
                $line = ""
                for ($i = 0; $i -lt $regs.Count; $i++) {
                    $line += ("[{0}] 0x{1:X4} ({1})  " -f $i, $regs[$i])
                }
                Write-Info $line.Trim()

                # Slot 1 in Floating Point format: w0 = command response,
                # w1-w2 = FP value, w3 = scale status. (App B, Tables B-1 / B-2.)
                if ($regs.Count -ge 4) {
                    $cmdResp = $regs[0]
                    $status  = $regs[3]
                    $fpInd   = ($cmdResp -shr 8) -band 0x1F
                    $ack     = ($cmdResp -shr 14) -band 0x03
                    $di1     = ($cmdResp -shr 13) -band 0x01
                    $di2     = ($status  -shr 14) -band 0x01

                    Write-Host ""
                    Write-Info "Slot 1 decode:"
                    $fpNames = @{
                        0  = "gross weight"; 1  = "net weight"; 2 = "tare weight";
                        29 = "last error code"; 30 = "command OK, no response";
                        31 = "INVALID COMMAND"
                    }
                    $fpText = $fpNames[[int] $fpInd]
                    if (-not $fpText) { $fpText = "other - see Table B-2" }

                    $coherent = "(MISMATCH - data not coherent)"
                    if ($di1 -eq $di2) { $coherent = "(coherent)" }

                    Write-Info ("  FP indicator   : {0} ({1})" -f $fpInd, $fpText)
                    Write-Info ("  Command ack    : {0}" -f $ack)
                    Write-Info ("  Data integrity : DI1={0} DI2={1} {2}" -f $di1, $di2, $coherent)
                    Write-Info ("  Scale status   : 0x{0:X4}" -f $status)
                    Write-Info ("    bit0 Under={0}   bit2 OK={1}     bit4 Over={2}" -f
                                (($status -shr 0) -band 1), (($status -shr 2) -band 1), (($status -shr 4) -band 1))
                    Write-Info ("    bit5 always1={0} bit8 Enter={1}  bit12 Motion={2}" -f
                                (($status -shr 5) -band 1), (($status -shr 8) -band 1), (($status -shr 12) -band 1))
                    Write-Info ("    bit13 NetMode={0} bit15 DataOK={1}" -f
                                (($status -shr 13) -band 1), (($status -shr 15) -band 1))

                    $b = @(
                        [byte] (($regs[1] -shr 8) -band 0xFF), [byte] ($regs[1] -band 0xFF),
                        [byte] (($regs[2] -shr 8) -band 0xFF), [byte] ($regs[2] -band 0xFF)
                    )
                    Write-Host ""
                    Write-Info "  FP value under each Byte Order setting:"
                    Write-Info ("    Standard         (ABCD) : {0}" -f (ConvertTo-Float32 @($b[0], $b[1], $b[2], $b[3])))
                    Write-Info ("    Byte Swap        (BADC) : {0}" -f (ConvertTo-Float32 @($b[1], $b[0], $b[3], $b[2])))
                    Write-Info ("    Word Swap        (CDAB) : {0}" -f (ConvertTo-Float32 @($b[2], $b[3], $b[0], $b[1])))
                    Write-Info ("    Double Word Swap (DCBA) : {0}" -f (ConvertTo-Float32 @($b[3], $b[2], $b[1], $b[0])))
                    Write-Info "    ^ put a known weight on the platform; the line that reads"
                    Write-Info "      it is the Byte Order the terminal is set to. The spec"
                    Write-Info "      wants Double Word Swap (App C.2)."
                }
            }
        } catch {
            Write-Fail ("read failed: {0}" -f $_.Exception.Message)
        } finally {
            $c.Close()
        }
    }
}

Write-Head "What this does and does not prove"
Write-Info "PROVED by a good ListIdentity : the option card is alive, addressed"
Write-Info "  correctly, and its EtherNet/IP stack is running. It does NOT mean"
Write-Info "  Ignition can consume EtherNet/IP data - see below."
Write-Info ""
Write-Info "PROVED by a good FC3 read     : the register base (0 vs 1), the Byte"
Write-Info "  Order, the parked slot-1 command, and the live Scale Status word."
Write-Info "  This is the path our design actually uses."
Write-Info ""
Write-Info "NOT PROVED by either          : cyclic Class 1 I/O. That needs a real"
Write-Info "  EtherNet/IP SCANNER. The IND570 card is CIP Adapter Class - the"
Write-Info "  manual states it 'does not initiate connections on its own' - and"
Write-Info "  Ignition has no EtherNet/IP scanner driver."
Write-Host ""
