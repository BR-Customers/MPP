param([Parameter(Mandatory)][string]$Out)
# Builds notes/<date>_sp-review-log.md (ASCII only). Same labels, counts and per-proc lines as Build-Checklist.ps1 (shared Lib-ReviewFormat.ps1).
. "$PSScriptRoot\Lib-ReviewFormat.ps1"
$rows = @(Get-ReviewRows)
$c = Get-Counts $rows
$sb = New-Object System.Text.StringBuilder
function Add([string]$s) { [void]$sb.AppendLine($s) }
Add "# Stored-procedure review log"
Add ""
Add 'Kept per CLAUDE.md, section "Stored-procedure review", rule 3: findings with no code change are recorded here, one line per proc (what was checked, what was found, PR link if one was opened). Started 2026-11-13. This is a living log; later commits add procs as they are reviewed. It lists the checked and flagged procs only; the full list of all stored procedures is the SP_REVIEW_CHECKLIST, which uses the same labels and counts.'
Add ""
Add '- **Scope:** performance and collision / concurrency (heap scans, whole-table aggregates, polled reads without an index, check-then-write races, lock order). Not behaviour changes.'
Add '- Write paths (Assembly_CompleteTray, MachiningOut_Mint, RejectEvent_RecordByPartFifo, TrimOut_Record, Lot_Move*, Lot_Merge, Lot_UpdateStatus, Container_Complete, DieCastLot_*, controlled-run mutations, Hold_Place) are NOT rewritten without Jacques''s decision; findings on them are recorded here only.'
Add ""
foreach ($l in (Get-LabelLines)) { Add $l }
foreach ($l in (Get-ProgressLines $c (Get-Date -Format 'yyyy-MM-dd HH:mm'))) { Add $l }
foreach ($g in ($rows | Group-Object Schema | Sort-Object Name)) {
    $lines = @($g.Group | Sort-Object Name | Where-Object { $_.Status -ne 'pending' -or $_.Flagged } | ForEach-Object { Format-ProcLine $_ })
    if ($lines.Count -gt 0) { Add "## $($g.Name)"; Add ""; foreach ($l in $lines) { Add $l }; Add "" }
}
[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
"wrote $Out | no-changes=$($c.NoChg) edited=$($c.Edited) not-yet=$($c.Pending) (flagged $($c.Flagged)) total=$($c.Total)"
