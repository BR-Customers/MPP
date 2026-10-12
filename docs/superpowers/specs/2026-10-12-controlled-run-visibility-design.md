# Super-lot piece 6 — visibility: LOT Detail, genealogy, reports, dashboards

> **Status: DRAFT 2026-10-12. NOT APPROVED. NOT BUILT.** Handoff for another agent.
> Last of six pieces. It reads what the other five write, so its exact content depends on
> the shapes pieces 3 to 5 settle on. The parts that depend only on piece 1 can be built
> at any time and are marked **(ready)**.

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`; the piece
1 spec (built) and the piece 3 spec; `CLAUDE.md` (the Reporting Module section and the
view-edit boundary); `ignition-context-pack/10_reporting_module.md` and the global
`ignition-reporting` skill before touching any report.
**Branch:** `jacques/controlled-run-super-lot`. Nothing deploys until all six pieces are in.

---

## 1. Problem

Change order B asks for nonconformance status to be visible "across the LOT Detail
screen, genealogy reporting, and dashboards". Today a LOT shows a CRT badge and nothing
else: not which super-lot it is in, not why, not what the inspection found, not who
released it. Someone looking at a container in the warehouse, a LOT at a line, or a
trace for Honda cannot tell that a quality case touched it.

## 2. What exists

| Surface | Today |
|---|---|
| LOT Detail (`Views/ShopFloor/LotDetail`) | CRT badge; Enable/Disable CRT toggle; tabs: History, Genealogy, Paused-at, Linked Container, Inspections, Hold, Notes |
| LOT history | `Lots.LotEventLog` (20-year retention) already receives `CrtActivated` / `CrtCleared`. Piece 1 writes "(super-lot CR000123)" into the `CrtActivated` description |
| Super-lot audit | Run-level events (`ControlledRunOpened`, `…MemberAdded`, `…Closed`, …) go to `Audit.OperationLog` with entity `ControlledRun` — **not** to a LOT's own timeline |
| Genealogy | `Lots.Lot_GetGenealogyTree`, `Lot_GetGenealogyEdgeTree`; views `GenealogyViewer`, `GlobalTrace`; `Lots.Container_GetTraceDetail` |
| Reports (Reporting Module) | `Lot Detail`, `Hold Status`, `Inventory`, `Shipping History`, three reject reports, and others, driven from `/shop-floor/reports` |
| Dashboards | `SupervisorDashboard` view |
| Read procs from piece 1 | `Quality.ControlledRun_GetOpenByMember(@LotId, @ContainerId)` (the open super-lot a unit is in), `ControlledRun_Get`, `_List`, `_ListMembers`, `Quality.ufn_ControlledRunMemberState` |

## 3. Proposed content

### 3.1 LOT Detail

- **(ready)** Next to the CRT badge, the super-lot number when the LOT (or, for a tray
  LOT, its container) is in an open super-lot, linking to
  `/shop-floor/controlled-runs`. `ControlledRun_GetOpenByMember` already answers this.
  The page needs to accept a run to select on arrival — a route parameter or a session
  hand-off; today it has none.
- **(ready)** A **Super-lots** tab: every super-lot this LOT has ever been in (open and
  ended), with reason, how it joined, how it left. Needs one new read proc over
  `ControlledRunMember` by LOT, folding a tray LOT to its container.
- After piece 3: the results recorded against it, the release and who signed it, and any
  deviation that covers it.
- Decide what the existing **Enable/Disable CRT** toggle does for a LOT that is in a
  super-lot (piece 3, decision 9.5). If super-lot members may only leave through the
  signed release, the toggle should say so and point to the super-lot instead of
  failing.

### 3.2 The LOT's own timeline

A LOT's 20-year history should say it was in a super-lot without needing the run-level
audit log. Piece 1 already puts the run number in the `CrtActivated` description. Add
**per-LOT** events for joining and leaving a super-lot (entity `Lot`, so they route to
`Lots.LotEventLog`) — including joins that tag nothing because the LOT was already
tagged, which today leave no trace on the LOT. One row per LOT, written by the silent
member helper.

### 3.3 Genealogy and trace

- Mark, on the genealogy tree and in Global Trace, each node that is or was in a
  super-lot, with the run number and outcome. This is the view Honda questions get
  answered from.
- The trace report for a container should show a repack (piece 4): old serial, new
  serial, what was removed and what was added.
- Do not change how the tree is computed. Add the marker as extra columns on the
  existing read procs, or as a second read keyed by the node ids, whichever keeps the
  recursive query untouched.

### 3.4 Reports

A **Super-lot report** in the Reporting Module, one per super-lot: header (number,
reason, criteria, opened, closed), members with how they joined and left, results by
disposition, scrap by defect code, the deviation text, and every signature with its
statement. This is the document Quality files and the one that would be sent in answer
to a customer complaint.

Possibly also a list report: super-lots by date range, part and status, with counts and
ageing. Ask before building two.

Reports are binary `data.bin` resources authored through the `ignition-reporting` skill;
their SQL calls read procs. Write the read procs first and test them like any other.

### 3.5 Dashboards

The least defined item in the change order. Candidates for the Supervisor Dashboard or a
Quality tile:

- Open super-lots, with age and how many members are still tagged.
- Pieces currently on CRT, by part and by area.
- Super-lots opened and closed per week; scrap attributed to super-lots.

Mock it and ask which numbers MPP actually want before building any of them.

### 3.6 The super-lot view's History tab

A placeholder today. It becomes the run-level audit trail (`Audit.OperationLog` rows for
the run) merged with its signatures, newest first.

## 4. Constraints

- **All displayed timestamps are Eastern**, converted in the read proc.
- **Existing views are edited in Designer**, not by file edit (LOT Detail,
  GenealogyViewer, GlobalTrace, SupervisorDashboard). New views may be file-authored.
  The six super-lot views from piece 1 are committed generated JSON and now count as
  existing views.
- Every `view.custom.*` a binding reads needs a fully shaped default, and binding
  sources must return the shaped empty object, never `None`.
- Read procs: no status row, no `OUTPUT` params, empty set means not found.
- No rule in Python or a view expression. Piece 1's view re-derives "can this super-lot
  be closed" in an expression; the review flagged it. A `CanClose` column from
  `ControlledRun_Get` would fix it and belongs with this piece's read-proc work.

## 5. Testing this piece must add

- The new read procs: a LOT in no super-lot, in one, in several over time; a tray LOT
  resolving through its container; Eastern conversion.
- Per-LOT join / leave events land in `Lots.LotEventLog`, one per LOT, for every join
  method and every way of leaving.
- Report SQL returns the same counts as `ControlledRun_Get` for the same super-lot.
- Gateway: each changed view renders with no component error for a LOT with no
  super-lot history (the empty-shape case is where these break).

## 6. Decisions for Jacques

1. **Which of 3.1 to 3.6 are wanted**, and in what order? The **(ready)** items could go
   in now.
2. **One super-lot report or two** (the per-case document, and a list)?
3. **Which dashboard numbers** does MPP actually want?
4. **Per-LOT join / leave events (3.2)** — agreed, given they add rows to a 20-year log?
5. **Should anything show at the production terminals?** Today an operator who scans a
   tagged LOT is told it is CRT and blocked. Telling them which super-lot it belongs to
   costs little; say whether it helps or is noise.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft, written as a handoff for another agent. Not approved. |
