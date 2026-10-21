# Super-lot piece 6 — visibility: LOT Detail, genealogy, reports, dashboards

> **Status: APPROVED 2026-10-21. NOT BUILT.** Decisions in section 6. Pieces 1 to 5 are built on `jacques/controlled-run-super-lot`; this piece reads
> what they write and adds no new quality behaviour of its own.

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`; the build
notes at the end of the piece 3, 4 and 5 specs; `CLAUDE.md` (the Reporting Module section
and the view-edit boundary); `ignition-context-pack/10_reporting_module.md` and the global
`ignition-reporting` skill before touching any report.
**Branch:** `jacques/controlled-run-super-lot`. Nothing deploys until all six pieces are in.

---

## 1. Problem

Change order B asks for nonconformance status to be visible "across the LOT Detail
screen, genealogy reporting, and dashboards". Everything about a super-lot is recorded
and managed on the super-lot page (`/shop-floor/controlled-runs`): members, results,
deviation, signed release, repack, rework, vendor returns. **Off that page, almost none of
it shows.** Someone looking at a LOT on LOT Detail, a container in Global Trace, or a
trace report for Honda sees a CRT pill at most: not which super-lot, not why, not what
the inspection found, not who signed the release.

Piece 6 closes that gap. It is reads and display: new read procs, extra columns on
existing ones, edits to existing screens, one report, and one dashboard tile.

## 2. What exists (refreshed 2026-10-20 against pieces 1-5 as built)

| Surface | Today |
|---|---|
| LOT Detail (`Views/ShopFloor/LotDetail`) | "CRT Active" pill (`custom.lot.CrtActive`); Enable/Disable CRT toggle (supervisor elevation, `Lot.setCrt` / `clearCrt`, this LOT only, no mention of a super-lot). Tabs: History, Genealogy, Paused-at, Linked Container, Inspections, Hold, Scrap, Correct Count, **Vendor Return** (piece 5), Notes. **No run number, no link to the super-lot page, no `ControlledRun` call anywhere in the view or its components.** |
| Per-unit clear | Piece 3 D5: a per-unit clear on LOT Detail **stays allowed** for a super-lot member; the member then reads as untagged and still leaves only by signed release, removal or close. So the toggle is not refused; the open question is only what it should *say*. |
| LOT history (`Lots.LotEventLog`, 20-year) | Per-LOT rows from this feature: `CrtActivated` (only for a LOT the join newly tags; text "CRT · Activated (super-lot CR000123)"), `CrtCleared` (one per tagged LOT on signed release, tray LOTs included; also `ContainerRework_Void`, `Lot_ClearCrt`), `LotStatusChanged`, `VendorReturnMarked` / `Confirmed` / `Cancelled`, `LotReworkStarted`, `LotMoved`, `MissedCrtInspect`, `LotCreated` (top-up tray from `ContainerRework_MovePieces`). **Gaps:** a LOT already tagged when it joins gets no LOT row; leaving by `ControlledRun_RemoveMember` or by close writes no LOT row; a scrap/accept result writes only the run-level row. |
| Container history | Entity `Container`: `ContainerReworkResumed`, `…StageChanged`, `…Scrapped`, `ContainerVoided`, `ContainerPiecesMoved`; `ContainerReworkOpened` is under entity `ContainerRework`. |
| Super-lot audit | Run-level, entity `ControlledRun`, `Audit.OperationLog`: `ControlledRunOpened`, `…MemberAdded`, `…MemberRemoved`, `…WindowChanged`, `…Cancelled`, `…Closed`, `…LabelPrinted`, `…DeviationRaised`, `…ResultRecorded`, `…ResultVoided`, `…Released`. |
| Super-lot page (`/shop-floor/controlled-runs`) | Tabs Members, Results, Sign-off, **History (placeholder: greyed, "later piece", no action)**. Page config has **no route parameter**; the selected run comes only from the list, the scan box (`ControlledRun.findByScan`: run label, LTT or container label) or page messages. Close button's `enabled` is an expression (`Open && !AutoJoin && Cleared = Members`) — a rule in a view. |
| Read procs (by run) | `ControlledRun_Get`, `_GetByNumber`, `_List(@StatusCode,@Text)` (text = run number / reason / part, not LOT), `_ListMembers`, `_ListMemberResults`, `_ListMemberOrigin`, `_ListMemberRework`, `_ListSignatures`, `ControlledRunResult_ListByRun`, `ControlledRunDeviation_ListByRun`, `_PreviewSelection`. `ControlledRun_Get` has **no `CanClose`**. `ufn_ControlledRunMemberResults` v1.3 carries `AppliedReturnQty`, not yet exposed by `_ListMemberResults`. |
| Read procs (by LOT / container) | `ControlledRun_GetOpenByMember(@LotId,@ContainerId)` (open run only). `VendorReturn_ListByLot`, `_GetEligibility`, `_ListOpen`. `ContainerRework_Get` / `_ListSerials` / `_ListTargets` / `_ListTrays` (by container), `_ListAtLocation`. `LotRework`: function `ufn_OpenLotRework` only, no list read. **No read returns every super-lot a LOT or container was ever in.** |
| Genealogy / trace | `Lot_GetGenealogyTree` (GenealogyViewer, GlobalTrace), `GlobalTrace_Resolve`, `Container_GetTraceDetail` + `SerializedPart_GetTraceDetail` (via `GlobalTrace.loadDetail`), `Lot_GetGenealogyEdgeTree` (Lot Detail report only). **None reads CRT, super-lot, rework, vendor return or `ContainerSerial.RemovedAt`**: a scrapped serial still shows in the container it was packed in (piece 4 build notes). LOT Detail's own Genealogy tab uses `getParents` / `getChildren`. |
| Reports | Folders: Die Cast Shot Count, Downtime by Date Range, Downtime Report, Hold Status, Inventory, Lot Detail, Production Line Performance, Rejects Part Matrix, Rejects Plant Summary, Rejects Transaction Detail, Shipping History. Registry = 11 hard-coded `selectReport(...)` buttons in `Views/Reports` + `BlueRidge/Reports/code.py`. **No report mentions CRT or a super-lot**, the Lot Detail report included. |
| Supervisor Dashboard | Tiles: Open Downtime, Paused LOTs, Shift Availability, AIM Pool, Print Failures, Shifts Not Reconciled, **Parts to Return** (piece 5, 30 s poll, opens `VendorReturnConfirm`). No CRT or super-lot tile. |
| Terminal refusals | "LOT X is marked CRT and cannot be moved to a production location / used / split until Quality clears it." No run number. |

## 3. What piece 6 adds

### 3.1 LOT Detail

- **Super-lot marker** beside the CRT pill when the LOT (or, for a tray LOT, its
  container) is in an open super-lot: the run number; tapping it opens the super-lot
  page **on that super-lot**. The page needs a way to arrive with a run selected; today
  it has none (section 2). `ControlledRun_GetOpenByMember` already answers "which open
  super-lot".
- **Super-lots tab**: every super-lot this LOT was ever in, open and ended, newest first.
  Per row: run number, reason, status, how it joined and when, how it left (removed /
  released / closed / cancelled), and this LOT's results there (accepted, scrap by
  defect, returned) with the release signer and time, and the deviation number if one
  covers it. New read keyed by LOT, folding a tray LOT to its container's membership.
- **CRT toggle wording.** The toggle stays allowed (piece 3 D5). When the LOT is in an
  open super-lot the confirm step names it and says that clearing here clears only this
  LOT; the super-lot is released from its own page.

### 3.2 The LOT's own history: ALL of it (Jacques, 2026-10-21)

**Every super-lot event that touches a LOT is written onto that LOT** (entity `Lot`, so it
lands in `Lots.LotEventLog`, the 20-year traceability class; `Audit.OperationLog` is the
7-year class), at the moment it happens, one row per LOT (a container member's tray
LOTs each get one):

- joined (and how: selected / scanned in / auto-joined / sync), including a LOT that
  was already CRT-tagged when it joined, which today leaves nothing on the LOT;
- left: removed (with the reason), super-lot closed, super-lot cancelled;
- each result recorded against it (accepted, scrap with defect and quantity, returned to
  vendor) and each result voided;
- a deviation raised that covers it;
- the signed release, with the signer.

The run-level rows in `Audit.OperationLog` stay as they are. Existing per-LOT rows
(`CrtActivated`, `CrtCleared`, vendor return, trim rework, container rework) are
unchanged.

**The LOT Detail History tab shows the LOT's audit log too.** Today
`Lots.Lot_GetAttributeHistory` builds the timeline from the record tables (attribute,
status, movement, pause / resume, genealogy, label, production, reject, die-cast
contribution) and deliberately leaves `Lots.LotEventLog` out ("the lifecycle timeline,
not the audit trail"). That hides every event that exists only in the audit log: CRT on
and off, vendor returns, trim rework, the missed-inspection flag, and everything above.
Jacques, 2026-10-21: the History tab shows **all** history, so the audit stream is added
to the timeline. This reverses the earlier choice on purpose.

- **No duplicates, by an exclude flag on the event type.** Some audit event types repeat
  a line the timeline already draws from a record table (LOT created, moved, status
  changed, die-cast pieces added, and others found by inventory). New column
  `Audit.LogEventType.RepeatsLotTimeline BIT NOT NULL DEFAULT 0`; the migration sets it
  to 1 for those types; the history read skips flagged types. A new event type defaults
  to 0 and so **shows by default** (exclude list, Jacques's choice over an include list).
  The full inventory of event types written against a LOT, and which repeat a timeline
  stream, is a plan task done from the code, not guessed.
- **Test guards the flag:** every flagged type really has a timeline stream, and no
  unflagged type written by a timeline-stream proc duplicates one.
- **Cost:** read per LOT on demand (LOT Detail, Lot Detail report), never from a
  dashboard or timer. `LotEventLog` is clustered on `(LotId, LoggedAt)`, so the read is a
  seek costing that LOT's rows (Dev: avg 2, max 5), not the table size. The table is
  partitioned monthly (240 partitions at full retention); the read adds
  `LoggedAt >= Lot.CreatedAt` (nothing can be logged against a LOT before it exists, so
  this loses nothing) to touch only the months the LOT has lived.
- The Lot Detail report is not changed (6c): it already reads the raw `LotEventLog`.

### 3.3 Genealogy and trace

- **Marker on nodes** in the genealogy tree and Global Trace: a node that is or was in a
  super-lot shows the run number and where it stands (open / released / closed). Added
  as a second read keyed by the node ids, so the recursive tree query is not touched.
- **Container trace after a repack (piece 4):** scrapped serials marked as scrapped
  instead of shown as still packed; the voided serial and the new one; pieces moved out
  and in. Today `Container_GetTraceDetail`, `SerializedPart_GetTraceDetail` and
  `GlobalTrace_Resolve` show a removed serial as still in its container.
- **Vendor returns and trim reworks (piece 5)** already land on the LOT's history; the
  trace detail shows them for the LOT node too.

### 3.4 Super-lot report

One Reporting Module report per super-lot, the document Quality files and the one sent
in answer to a customer complaint: header (number, reason, selection in words, opened,
closed), members with how they joined and left, results by outcome, scrap by defect
code, vendor returns, trim reworks, containers repacked (old / new serial), the
deviation text, and every signature with its meaning and statement. Added to the
`/shop-floor/reports` landing page and reachable from the super-lot page. Report SQL
calls read procs, written and tested first.

### 3.5 Dashboard

An **Open super-lots** tile on the Supervisor Dashboard: count open, age of the oldest,
members still tagged; tap opens the super-lot page.

### 3.6 The super-lot page's History tab

Replace the placeholder with the run's audit trail (`Audit.OperationLog` rows for entity
`ControlledRun`) merged with its signatures, newest first. There is no read proc over
`OperationLog` by entity today; one is added.

### 3.7 Rules out of views

`ControlledRun_Get` gains `CanClose` (and the reason when not), and the page's Close
button binds to it instead of re-deriving the rule in an expression.

### 3.8 Carried from earlier pieces (decide in section 6)

- ~~Trim rework destination check~~ - not wanted (decision 8).
- **Two narrow timing gaps.** `ControlledRunResult_Record`'s inlined vendor-return mirror
  does not refuse a LOT whose status turned Closed / Scrap under the lock (piece 5); a
  result voided between `ControlledRun_Release`'s check and its write is not re-checked
  (piece 3).
- **Small display gaps:** `ControlledRun_ListMemberResults` does not expose
  `AppliedReturnQty`; the Members tab does not show "pulled back from finished stock"
  (`WasCompleteAtJoin`).
- **Docs:** regenerate `MPP_MES_DATA_MODEL.docx` (last built 2026-09-23); fix the `.md`
  header line, which still reads v2.2.

## 4. Constraints

- **All displayed timestamps are Eastern**, converted in the read proc.
- **Existing views are edited in Designer**, not by file edit (LOT Detail,
  GenealogyViewer, GlobalTrace, SupervisorDashboard). New views may be file-authored.
  The six super-lot views from piece 1 are committed generated JSON and now count as
  existing views.
- Every `view.custom.*` a binding reads needs a fully shaped default, and binding
  sources must return the shaped empty object, never `None`.
- Read procs: no status row, no `OUTPUT` params, empty set means not found.
- No rule in Python or a view expression (3.7 removes the one that exists).

## 5. Testing this piece must add

- The new read procs: a LOT in no super-lot, in one, in several over time; a tray LOT
  resolving through its container; Eastern conversion.
- Per-LOT join / leave events land in `Lots.LotEventLog`, one per LOT, for every join
  method and every way of leaving.
- Report SQL returns the same counts as `ControlledRun_Get` for the same super-lot.
- Gateway: each changed view renders with no component error for a LOT with no
  super-lot history (the empty-shape case is where these break).

## 6. Decisions (answered by Jacques, 2026-10-21)

1. **LOT Detail (3.1): agreed.** Run number beside the CRT pill, opening the super-lot
   page on that super-lot; a Super-lots tab with every super-lot ever, its results,
   release signer and deviation.
2. **LOT history (3.2): yes, and "history" means ALL of it.** Every super-lot event is
   written onto the LOT, and the History tab shows the LOT's audit log too, with
   duplicates excluded by a flag on the event type (exclude list).
3. **Genealogy and trace markers (3.3): yes**, including the repack trace fixes.
4. **Report (3.4): one report per super-lot, with all the details.** No list report.
5. **Dashboard (3.5): agreed**, the single Open super-lots tile.
6. **Terminal refusal message: yes.** The CRT refusal names the super-lot, e.g.
   "(super-lot CR000123)", in every proc that raises it (section 2, Terminal refusals).
7. **CRT toggle wording: agreed.** Clearing one LOT that is in an open super-lot stays
   behind the supervisor override; it already is (LOT Detail `doCrtToggle` ->
   `requireElevation(..., "CrtToggle", ...)` in both directions). The Quality AD role
   replaces "any supervisor" later; not built, no seam added here beyond the existing
   elevation action code.
8. **Trim rework destination check: not needed.** Dropped from 3.8; stays as stated in
   the piece 5 build notes.
9. **Timing gaps and display gaps (3.8): fix in this piece**, as small tasks.

### 6b. Screen mocks (approved by Jacques as drawn, 2026-10-21)

`notes/2026-10-21_super-lot-piece-6-screen-mocks.html`, seven screens. The four "Check"
notes on them are settled as drawn:

- History-tab kind labels for the new rows are specific: "Super-lot", "CRT",
  "Vendor return", "Rework" (not one "Quality" label).
- A scrapped serial stays in the container trace list, struck through and marked
  "Scrapped <date> (<defect>)"; it is not hidden.
- The super-lot report carries a one-row-per-member summary, not each member's full
  event history.
- The super-lot page gains an address that arrives on one super-lot:
  `/shop-floor/controlled-runs/<RunNumber>` (alongside the existing bare address).

### 6c. Builder check (2026-10-21)

**Answered by Jacques:**

- **What a deviation "covers".** `Quality.ControlledRunDeviation` is run-level (no link to
  members or results). A deviation covers **every member still in the super-lot when it
  is signed**: `ControlledRunDeviation_Raise` writes a "Deviation <DV> raised" row onto
  each of those LOTs (container members: their trays). No schema change. The report
  lists Use-as-is pieces as their own outcome; it does not claim which Use-as-is entry
  falls under which deviation. Mock 7's "covers 30 pieces on 2 members" is wrong and is
  read as "Use as is: 30 pieces" plus the deviation text.
- **Container members.** Every per-LOT row for a container member goes onto the tray
  LOTs **in the container at the moment of the event** (`Lots.ContainerTray` as it stands
  then). A tray that arrives later by a repack does not inherit the container's earlier
  super-lot rows; its genealogy points back to its source. The same point-in-time rule
  drives the Super-lots tab fold (a tray LOT shows the super-lots its container was in
  while the tray was in it) and the trace markers. A container-level result is written
  onto each tray naming the container, e.g. "Container 20031 · Result recorded · Scrap 3
  (Porosity)", so it never reads as each tray losing 3; when piece 4 later applies the
  scrap to one tray, that tray gets its ordinary reject row.

**Settled by the builder (Claude's calls, open to Jacques's objection):**

- **Lot Detail report: no change.** It reads `Lots.Lot_GetLifecycle`, which already
  returns the raw `LotEventLog`, so the new per-LOT rows reach it with no work. It does
  not use the History-tab read; matching the tab exactly would be a `data.bin` layout
  change and is not in scope. (Mock 2's note "the report shows the same rows" overstated
  this.)
- **Scrapped serials: all five readers** named in the piece 4 build notes are fixed:
  `Container_GetTraceDetail`, `SerializedPart_GetTraceDetail`, `GlobalTrace_Resolve`,
  `Container_ListShipped`, `Hold_ListAssociatedContainers`.
- **History-tab kind labels come from SQL** (a column on `Audit.LogEventType` or a CASE in
  the read), never Python, with a fallback label for any other unflagged type.
- **"Super-lot closed / cancelled" rows** go only to members still in the super-lot at
  that moment; released or removed members have already left.
- **The two timing gaps** get the `VendorReturn_Mark` v1.2 fix: re-check under the lock,
  raise into CATCH.
- **No backfill** of per-LOT rows for super-lots that already exist on Dev.
- **Run-number address:** page URL parameter `/shop-floor/controlled-runs/:runNumber`
  beside the bare route; the dashboard tile opens the bare route with the Open filter.
- **Marker read** takes the node ids as one comma-separated string (a list argument to
  `runScript` arrives as `QualifiedValue[]` and throws).
- **CRT refusal text** changes in every proc that raises it today: `Lot_MoveTo`,
  `Lot_MoveToValidated`, `Assembly_ScanIn`, `MachiningIn_RecordPick`, `MachiningOut_Mint`,
  `Lot_Split`, and `Lot_Merge` (which names the offending LOTs).
- **Branch:** built on `claude/super-lot-piece-6` (branched from
  `jacques/controlled-run-super-lot`), merged back into it.

## Build notes (2026-10-21)

Where the build differs from the design above, what was verified, and what was not.

- **Deviations from the design as written.**
  - `Lots.Container_ListSerials` gained an optional `@IncludeRemoved BIT = 0` (default is today's behaviour for every existing caller). The trace passes 1 and gets `RemovedAt` / `RemovedReason` / `MovedInFromContainerName` / `MovedInAt` per serial, so a scrapped serial stays listed, struck through. There is no second proc.
  - On the three per-container readers (`Container_GetTraceDetail`, `Container_ListShipped`, `Hold_ListAssociatedContainers`) the removed-serial trio is replaced by three counts, `ScrappedSerialCount`, `MovedOutSerialCount`, `MovedInSerialCount`, so one column name never means "this serial" in one proc and "one of several" in another.
  - Task 3 widened beyond the original proc list: `VendorReturn_Cancel` (result voided), `ContainerRework_Void` (left, container voided) and `ContainerRework_Scrap` (result recorded) also write per-LOT rows ("every super-lot event that touches a LOT").
  - "Deviation covers a member" is one predicate everywhere: `AddedAt <= RaisedAt AND (EndedAt IS NULL OR RaisedAt < EndedAt)`.
  - `ControlledRun_ListByLot` returns `JoinedByInitials` / `LeftByInitials`; `ControlledRun_ListHistory` signature `Detail` follows the approved mock (release `<Meaning> - "<Statement>" - <n> members`, deviation `Deviation <DV> - <Description>`).
  - `ElevationModal` gained an optional `actionNote` (wrapped amber note) and `Session.requireElevation` an optional `note`, so the long release sentence is not squeezed into the modal title (mock 3).
  - `Quality.ControlledRun_ReportOutcomes` gained an optional `@Section` (`Outcome` / `Defect`) so the report uses two bare-EXEC data sources; the PRINTED time comes from SQL in Eastern, not ReportMill `@Date@`.
  - The super-lot report counts results of ended members too (it is the complaint record); the screen's `ListMemberResults` shows current members only.
  - `VendorReturn_Mark`'s fix was applied to `ControlledRunResult_Record` and `ControlledRun_Release` (status re-check under the lock, raise into CATCH).
  - Global Trace's genealogy table was replaced by the `NodeRow` tree with super-lot chips inside a 320px scrolling box (mock 4); `NodeRow` label and arrow taps open LOT Detail; the container's super-lot chips sit in the container panel header, because the tree proc returns LOTs only. The dead `BlueRidge.Lots.GlobalTrace.genealogyRows` was removed (commit 916810db).
  - The Lot Detail report is unchanged, as settled in section 6c.
- **Verified.** Migration `0114` and every changed proc on a clean private database (`MPP_MES_CRTest`): `sql/tests/0114_SuperLotVisibility/` (9 files) plus the existing folders that exercise a changed proc, and one full-suite run at the end (counts in `PROJECT_STATUS.md`). Report data sources executed read-only through pyodbc. Views, named queries and scripts verified from files: JSON parses, Python compiles in memory, every named query and script reference resolves.
- **NOT verified: no screen, report or named query has run on a gateway.** The gateway reads the main checkout; the walk happens after the branch is merged into `jacques/working`, with `0114` and the changed repeatables applied to `MPP_MES_Dev` additively. Walk-check items:
  - LOT Detail: no chip and empty Super-lots tab for a LOT never in a super-lot (no Component Error); chip, rows and pill colours for the fixture LOT; rows fit in 64px; the 11-tab strip width; chip and run number reach `/shop-floor/controlled-runs/<RN>`.
  - Release elevation prompt: `ElevationModal` (540px fixed height plus the amber note) keeps Authenticate on screen; note colours in the modal theme. This and the other typed-credential paths were not driven.
  - Super-lot page: `/shop-floor/controlled-runs/CR000001` selects the run; `/NOPE` selects nothing and does not error; the bare address is unchanged; the sibling-path binding `{../HistoryRepeater.props.instances}`; History newest first with Signature rows purple; Close enabled from `CanClose` (the blocked-reason tooltip is invisible on touch; consider a visible label); a 48px member row may clip two sub-lines; the URL stays stale after selecting another card; `params.runNumber` onChange at startup.
  - Genealogy Viewer and Global Trace: no chips and no error for a plain LOT; chips on root and nodes for the fixture, amber Open / grey Released; chip text fits at 170px; the Global Trace tree layout change; repacked container shows the replaced serial struck with "void MM/dd", Repack and Serial changes; struck table cells (`{value, style}` cell objects, unproven here); `lots/Container_ListSerials` with `includeRemoved` (sqlType 6) through JDBC.
  - Supervisor Dashboard: Open super-lots tile with and without open runs, the 30 s poll, navigation, the datetime in the custom dict.
  - Super-lot report: tile on the Reports page and the picker (status-agnostic, accepts a typed `CR000001`); every section has content with no `<N/A>` or literal `@token@`; outcome totals equal the Results tab for the same run; PRINTED shows Eastern time; a run with no results or members; PDF pagination ("Page 1 of 3"); text fit for long reason, "Other" and signature statements; Print report disabled with no selection and downloads `Super-lot CRxxxxxx.pdf`; empty-picker toast.
- **Deferred minors** (recorded in the build ledger, none blocks the merge): the new-column pin in `010_schema.sql` checks at least 13 flagged codes rather than the exact set; join history text is the join method name ("New production"), not "auto-joined"; a Release vs Record/Void lock-order deadlock is possible (victim sees "Unexpected error" 1205); a Void/Record blocked by Release proceeds after it without an `EndedAt` re-check; a moved-in-then-scrapped serial counts in both the moved-in and scrapped counts; `Hold_ListAssociatedContainers` omits containers all of whose LOT serials left; no index on `ContainerSerialHistory` Old/NewContainerId; `getRunByNumber` has no `_refreshToken`; the report's returns/trim reworks are not listed for container tray LOTs.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft, written as a handoff for another agent. Not approved. |
| 2026-10-20 | Revised against pieces 1-5 as built: section 2 refreshed from code; section 3 rewritten as what this piece adds (no "after piece N" / "(ready)"); piece 4 trace items and piece 5 carry-overs folded in; decisions restated. |
| 2026-10-21 | Jacques answered decisions 1-9 (section 6); trim destination check dropped; "all history" scope open. |
| 2026-10-21 | 3.2 settled: all super-lot events written per LOT; History tab unions the LOT audit log with a `LogEventType.RepeatsLotTimeline` exclude flag; cost note. |
| 2026-10-21 | Screen mocks approved as drawn (6b). |
| 2026-10-21 | Builder check: deviation covers every member still in the super-lot at signing; container rows go to trays in the container at the moment; builder calls listed (6c). Approved for planning. |
| 2026-10-21 | Build notes added: where the build differs from this design, what was verified (SQL on a private database; views from files) and what was not (no gateway walk yet), with the walk-check list. |
