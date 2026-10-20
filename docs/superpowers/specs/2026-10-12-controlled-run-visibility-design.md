# Super-lot piece 6 — visibility: LOT Detail, genealogy, reports, dashboards

> **Status: DRAFT, revised 2026-10-20. NOT APPROVED. NOT BUILT.** Decisions in section 6
> are open. Pieces 1 to 5 are built on `jacques/controlled-run-super-lot`; this piece reads
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

### 3.2 The LOT's own history

The LOT's 20-year history should show super-lot membership without the run-level log.
Add per-LOT rows (entity `Lot`, so they land in `Lots.LotEventLog`) for **joining** and
**leaving** a super-lot, written by the member helper, one row per LOT (a container's
tray LOTs each get one). This covers the LOT that was already tagged when it joined and
the LOT that left by removal or close, which today leave nothing on the LOT. Existing
`CrtActivated` / `CrtCleared` rows are unchanged.

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

- **Trim rework destination.** `Lot_MoveToValidated` treats an override move as a
  rework from the caller's `@OperationTypeCode = 'TrimIn'` alone; it never checks that
  the destination is a trim location.
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

## 6. Decisions for Jacques

1. **Scope and order** of 3.1 to 3.7.
2. **LOT Detail Super-lots tab:** how much of the results / release / deviation to show
   per row.
3. **Per-LOT join / leave history rows (3.2):** agreed?
4. **Production terminals:** add the run number to the CRT refusal message?
5. **Report:** one per-super-lot report only, or also a list report?
6. **Dashboard:** the one tile in 3.5, or other numbers?
7. **Trim rework destination check (3.8):** add it?
8. **Timing gaps and small display gaps (3.8):** fix in this piece, or leave as stated
   limits?

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft, written as a handoff for another agent. Not approved. |
| 2026-10-20 | Revised against pieces 1-5 as built: section 2 refreshed from code; section 3 rewritten as what this piece adds (no "after piece N" / "(ready)"); piece 4 trace items and piece 5 carry-overs folded in; decisions restated. |
