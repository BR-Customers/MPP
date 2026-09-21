# tools/training-deck/render_slides.ps1 -- export every slide to PNG via PowerPoint.
param([string]$Deck = "docs\training\diecast\MPP_DieCast_Training.pptx",
      [string]$OutDir = "$env:TEMP\training-deck-render")
$ErrorActionPreference = "Stop"
$deckPath = (Resolve-Path $Deck).Path
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$pp = New-Object -ComObject PowerPoint.Application
try {
    $pres = $pp.Presentations.Open($deckPath, $true, $false, $false)   # read-only, no window
    foreach ($s in $pres.Slides) { $s.Export((Join-Path $OutDir ("slide-{0:D2}.png" -f $s.SlideIndex)), "PNG", 1920, 1080) }
    $pres.Close()
} finally { $pp.Quit(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($pp) }
Get-ChildItem $OutDir | Select-Object -ExpandProperty FullName
