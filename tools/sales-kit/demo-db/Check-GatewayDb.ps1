# Check-GatewayDb.ps1 -- which database is the Dev gateway's MPP connection using right now?
#
#   .\tools\sales-kit\demo-db\Check-GatewayDb.ps1 [-Expect Demo|Dev]
#
# Reads the connection's configured target and asks the running app which plant it shows (the
# Terminal Selector's root node, via capture.js --probe). With -Expect it exits 1 on a mismatch.
#
# The switch itself is done by a gateway admin in the web UI (the config file is Administrators-
# only): Config > Connections > Databases > MPP > Edit > Extra Connection Properties
#   capture session :  databaseName=MPP_MES_Demo
#   afterwards      :  databaseName=MPP_MES_Dev        (always switch back the same session)
[CmdletBinding()]
param([ValidateSet("Demo", "Dev", "")][string]$Expect = "")
$ErrorActionPreference = "Stop"
$cfg = "C:\Program Files\Inductive Automation\Ignition\data\config\resources\core\ignition\database-connection\MPP\config.json"
$props = (Get-Content -Raw $cfg | ConvertFrom-Json).connectionProps
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location (Join-Path $Here "..\capture")
try { $root = (& node capture.js --probe 2>&1 | Select-Object -Last 1) } finally { Pop-Location }
$plant = if ($root -eq "Sample Components Co.") { "Demo" } elseif ($root) { "Dev" } else { "unknown" }
Write-Host "MPP connection props : $props"
Write-Host "App shows plant root : $root   -> $plant"
if ($Expect -and $plant -ne $Expect) { Write-Host "Expected $Expect" -ForegroundColor Red; exit 1 }
