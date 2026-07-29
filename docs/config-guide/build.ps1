<#
  Builds the self-contained MPP MES Configuration Guide.

  Reads config-guide.src.html (which references shots/*.png by relative path) and
  produces MPP_MES_Configuration_Guide.html with every screenshot inlined as a
  base64 data URI, so the deliverable is a single portable file that opens offline
  in any browser with no external assets.

  Usage (from this folder):
      powershell -ExecutionPolicy Bypass -File .\build.ps1

  To flesh out the guide, edit config-guide.src.html (and add screenshots under
  shots\), then re-run this script. Note: read with [IO.File]::ReadAllText so the
  UTF-8 em-dashes survive — Get-Content on Windows PowerShell 5.1 defaults to ANSI
  and would mangle them.
#>
param(
  [string]$Src = (Join-Path $PSScriptRoot "config-guide.src.html"),
  [string]$Shots = (Join-Path $PSScriptRoot "shots"),
  [string]$Out = (Join-Path $PSScriptRoot "MPP_MES_Configuration_Guide.html")
)

$html = [IO.File]::ReadAllText($Src, [Text.Encoding]::UTF8)
$missing = @()
Get-ChildItem $Shots -Filter *.png | Sort-Object Name | ForEach-Object {
  $needle = 'src="shots/' + $_.Name + '"'
  if ($html -notlike "*$needle*") { $missing += $_.Name }
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
  $html = $html.Replace($needle, 'src="data:image/png;base64,' + $b64 + '"')
}
[IO.File]::WriteAllText($Out, $html, (New-Object Text.UTF8Encoding($false)))

$remaining = ([regex]::Matches($html, 'src="shots/')).Count
$kb = [math]::Round((Get-Item $Out).Length / 1KB)
Write-Output "Built: $Out ($kb KB)"
Write-Output "Un-inlined shots/ refs remaining: $remaining"
if ($missing.Count) { Write-Warning ("Shots with no matching <img> in source: " + ($missing -join ', ')) }
if ($remaining -gt 0) { Write-Warning "Some shots/ image references were not inlined (missing PNG in shots\)." }
