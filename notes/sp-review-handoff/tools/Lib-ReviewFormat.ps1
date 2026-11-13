# Shared by Build-Checklist.ps1 and Build-ReviewLog.ps1 so the two files use IDENTICAL labels, counts and wording.
$script:SP = Join-Path (Split-Path -Parent $PSScriptRoot) 'data'
function ConvertTo-Ascii([string]$s) { [regex]::Replace([string]$s, '[^\x20-\x7E]', '?') }

function Get-ReviewRows {
    $st = @{}; Import-Csv "$script:SP\status.csv" | ForEach-Object { $st[$_.Proc] = $_ }
    foreach ($f in (Get-Content "$script:SP\all_procs.txt")) {
        if ($f -match '^R__([A-Za-z]+)_(.+)\.sql$') {
            $key = "$($Matches[1])_$($Matches[2])"
            $s = if ($st.ContainsKey($key)) { $st[$key] } else { $null }
            $status = if ($s) { $s.Status } else { 'pending' }
            $note = if ($s) { ConvertTo-Ascii $s.Note } else { '' }
            [pscustomobject]@{ Schema = $Matches[1]; Name = $Matches[2]; Key = $key; Status = $status; Note = $note
                               Flagged = ($status -eq 'pending' -and $note -match 'FLAGGED|VERIFIED') }
        }
    }
}

function Get-Counts($rows) {
    [pscustomobject]@{
        Total   = @($rows).Count
        NoChg   = @($rows | Where-Object Status -eq 'complete').Count
        Edited  = @($rows | Where-Object Status -eq 'edited').Count
        Pending = @($rows | Where-Object Status -eq 'pending').Count
        Flagged = @($rows | Where-Object Flagged).Count
    }
}

# one line per proc, identical in both files
function Format-ProcLine($r) {
    $tail = if ($r.Note) { " - $($r.Note)" } else { "" }
    switch ($r.Status) {
        'complete' { "- [x] $($r.Schema).$($r.Name) (no changes)$tail" }
        'edited'   { "- [x] $($r.Schema).$($r.Name) (edited)$tail" }
        default    { if ($r.Flagged) { "- [ ] $($r.Schema).$($r.Name) (flagged)$tail" } else { "- [ ] $($r.Schema).$($r.Name)$tail" } }
    }
}

function Get-ProgressLines($c, $stamp) {
    @(
        "## Progress at $stamp local", "",
        "| | Procs |", "|---|---|",
        "| Checked, no changes | $($c.NoChg) |",
        "| Checked and edited | $($c.Edited) |",
        "| Not yet checked | $($c.Pending) |",
        "| &nbsp;&nbsp;of which flagged by a reviewer, awaiting verification | $($c.Flagged) |",
        "| **Total stored procedures** | **$($c.Total)** |", ""
    )
}

function Get-LabelLines {
    @(
        "## Labels (the same in the checklist and in the review log)", "",
        '- `- [x] (no changes)` = checked, nothing worth changing. Unless the note says "measured", this is a reviewer''s static read of the SQL, not a query-plan test, and it was not independently re-checked.',
        '- `- [x] (edited)` = checked and changed. The note links the pull request (or the pushed branch while the PR is pending). Those changes were measured on a throwaway database and tested on the old and new version.',
        '- `- [ ] (flagged)` = not checked yet: a reviewer found something specific. It is only a claim until the note says VERIFIED. Flagged procs have no PR yet.',
        '- `- [ ]` with no label = not gotten to yet.',
        "",
        '### Why some procs are flagged and others are "no changes"', "",
        'Every proc was read in full by a reviewer looking for two kinds of problem at the plant''s real volumes:', "",
        '- **Speed:** does it scan a table that keeps growing (like Lots.Lot or the label table) because no index fits its query? Does it aggregate a whole table on every call? The risk is higher when something polls it every few seconds.',
        '- **Collisions:** could two screens or stations step on each other, such as a check-then-write race, or tables locked in an order that could deadlock?', "",
        '**"No changes"** means the reviewer found nothing worth changing. Typical reasons: it reads a small configuration table; it finds rows by an indexed key or is bounded by a date range; it already uses the careful locking pattern; or it was already fixed.', "",
        '**"Flagged"** means the reviewer found something specific. A **CANDIDATE** is a concrete problem likely worth its own change (for example the banner read that scanned the whole label table every 5 seconds). A **WATCH** is suspicious but needs a measurement or more context to decide; many are possible double-submit races in write procs.', "",
        'Flagged does not mean broken, and it does not mean decided. A flagged proc stays unchecked until the finding is verified; then it becomes "edited" (with a PR link) or "no changes" if it turns out to be fine. The banner read is the example: flagged, verified, fixed, now "edited".', "",
        'Two cautions: a "no changes" mark is a reviewer''s judgment from reading the code, not a test, so a reviewer could miss something; and a flagged finding is only a claim until it is verified (the note says "VERIFIED" when it has been).', ""
    )
}
