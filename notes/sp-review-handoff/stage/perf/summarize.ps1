param([string]$File)
$lbl = $null; $d = [ordered]@{}
foreach ($line in Get-Content $File) {
    if ($line -like '===*') { $lbl = $line.Trim(); $d[$lbl] = @{ lotReads = 0; lotScans = 0; allReads = 0; rows = ''; chk = '' }; continue }
    if (-not $lbl) { continue }
    if ($line -match "^Table '(\w+)'\. Scan count (\d+), logical reads (\d+)") {
        $d[$lbl].allReads += [int]$Matches[3]
        if ($Matches[1] -eq 'Lot') { $d[$lbl].lotReads += [int]$Matches[3]; $d[$lbl].lotScans += [int]$Matches[2] }
    }
    elseif ($line -match '^\s+(\d+)\s+(-?\d+)\s*$') { $d[$lbl].rows = $Matches[1]; $d[$lbl].chk = $Matches[2] }
}
foreach ($k in $d.Keys) { '{0,-34} rows={1,-5} checksum={2,-12} Lot: {3,6} reads / {4,3} scans   all tables: {5,6} reads' -f $k, $d[$k].rows, $d[$k].chk, $d[$k].lotReads, $d[$k].lotScans, $d[$k].allReads }
