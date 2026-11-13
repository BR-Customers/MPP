param([string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SP_REVIEW_CHECKLIST.md'))
. "$PSScriptRoot\Lib-ReviewFormat.ps1"
$rows = @(Get-ReviewRows)
$c = Get-Counts $rows
$sb = New-Object System.Text.StringBuilder
function Add([string]$s) { [void]$sb.AppendLine($s) }
Add "# Stored-procedure review checklist"
Add ""
Add 'Project: MPP MES. Scope: the performance and collision/concurrency review described in CLAUDE.md (section "Stored-procedure review"). One proc revision = one branch = one PR; Jacques reviews and merges. Every stored procedure is listed below. The review log (notes/2026-11-13_sp-review-log.md, PR 12) uses the same labels and counts and lists only the checked and flagged procs.'
Add ""
Add "Last updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') local time"
Add ""
foreach ($l in (Get-LabelLines)) { Add $l }
foreach ($l in (Get-ProgressLines $c (Get-Date -Format 'yyyy-MM-dd HH:mm'))) { Add $l }
Add "Functions (57 files) are not on this list; they are reviewed only where a proc depends on them."
Add ""
foreach ($g in ($rows | Group-Object Schema | Sort-Object Name)) {
    $gc = @($g.Group | Where-Object { $_.Status -ne 'pending' }).Count
    Add "## $($g.Name) ($gc of $($g.Count) checked)"
    Add ""
    foreach ($r in ($g.Group | Sort-Object Name)) { Add (Format-ProcLine $r) }
    Add ""
}
[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
"wrote $Out | no-changes=$($c.NoChg) edited=$($c.Edited) not-yet=$($c.Pending) (flagged $($c.Flagged)) total=$($c.Total)"
