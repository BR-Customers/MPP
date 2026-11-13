param([Parameter(Mandatory)][string]$Report)
# Merges one agent report (results\c_<name>.md) into status.csv, then rebuilds the checklist.
# Accepts proc names as "Schema.Name", "Schema_Name", "R__Schema_Name(.sql)" or a bare "Name".
# Never overwrites a proc already marked edited or complete.
$sp = Join-Path (Split-Path -Parent $PSScriptRoot) 'data'
$map = [ordered]@{}
Import-Csv "$sp\status.csv" | ForEach-Object { $map[$_.Proc] = $_ }
$keys = @{}; $byName = @{}
foreach ($f in (Get-Content "$sp\all_procs.txt")) {
    if ($f -match '^R__([A-Za-z]+)_(.+)\.sql$') { $k = "$($Matches[1])_$($Matches[2])"; $keys[$k] = $true; if (-not $byName.ContainsKey($Matches[2])) { $byName[$Matches[2]] = $k } }
}
$n = @{ complete = 0; flagged = 0; skipped = 0; unmatched = 0 }
foreach ($line in Get-Content $Report) {
    $line = $line -replace '`', ''
    if ($line -match '^\|\s*([A-Za-z0-9_.]+?)(?:\.sql)?\s*\|\s*(OK|WATCH|CANDIDATE)\s*\|\s*([HML])\s*\|\s*(.*?)\s*\|[^|]*\|?\s*$') {
        $cell = $Matches[1]; $verdict = $Matches[2]; $risk = $Matches[3]
        $why = ($Matches[4] -replace '"', "'")
        if ($why.Length -gt 170) { $why = $why.Substring(0, 167) + '...' }
        $norm = ($cell -replace '^R__', '') -replace '\.', '_'
        $key = $null
        if ($keys.ContainsKey($norm)) { $key = $norm } elseif ($byName.ContainsKey($norm)) { $key = $byName[$norm] }
        if (-not $key) { $n.unmatched++; continue }
        if ($map.Contains($key) -and $map[$key].Status -in @('edited', 'complete')) { $n.skipped++; continue }
        if ($verdict -eq 'OK') {
            $map[$key] = [pscustomobject]@{ Proc = $key; Status = 'complete'; Note = 'agent static read, not independently verified; nothing to change' }; $n.complete++
        } else {
            $map[$key] = [pscustomobject]@{ Proc = $key; Status = 'pending'; Note = "FLAGGED $verdict (risk $risk) by agent read, unverified: $why" }; $n.flagged++
        }
    }
}
$map.Values | Export-Csv "$sp\status.csv" -NoTypeInformation -Encoding ASCII
"merged $(Split-Path $Report -Leaf): complete=$($n.complete) flagged=$($n.flagged) skipped(existing edited/complete)=$($n.skipped) unmatched-names=$($n.unmatched)"
& "$PSScriptRoot\Build-Checklist.ps1"
