# Super-lot piece 4 (container repack) Implementation Plan

> **For agentic workers:** executed natively in one session (in-session TDD, one review at
> the end). Procs follow existing committed shapes; where a task says "mirror of X", open X
> and keep its structure.

**Goal:** A completed container can be opened for rework, have parts scrapped out of it,
be topped up with loose pieces from another container, be finished at Quality or at a
line, and come back complete with a new shipper serial; an emptied container is voided.

**Architecture:** Two new container statuses and one `Lots.ContainerRework` row per
rework. Tray LOTs stay Closed; six `Lots.ContainerRework_*` mutation procs change them
directly, gated on the container's rework status. A piece move is a `ConsumptionEvent`
with `Consumption` genealogy into a newly minted tray LOT. Re-completion reuses
`Lots.Container_Complete` unchanged. Views: one Repack popup from the super-lot page, one
pick popup from the line inventory card.

**Tech stack:** SQL Server 2022, Ignition 8.3 Perspective (file-based), Jython 2.7.

**Spec:** `docs/superpowers/specs/2026-10-12-controlled-run-container-repack-design.md`

## Global Constraints

- FDS-11-011: no `OUTPUT` params; one result set; every rejection before
  `BEGIN TRANSACTION`; `ROLLBACK` only in CATCH; a status-row proc never `EXEC`s another;
  `EXEC` args are literals or `@variables`.
- ASCII-only SQL literals. UTC stored, Eastern returned.
- Audit description `<SUBJECT> <middot> <CATEGORY> <middot> <ACTION>`.
- Named queries in Core only; status-row procs are NQ `type: Query`.
- Tests on the private database `MPP_MES_CRTest` only.
- `Workorder.Assembly_CompleteTray` and `Lots.Container_Complete` are NOT modified.
- The pass-through repack origin filter (`Received` / `ReceivedOffsite`) is not touched:
  tray LOTs minted here are `Manufactured`.
- New views are new folders; existing views are changed by a JSON-level script.
- The FDS is not edited. No `Co-Authored-By`. Stage explicit paths.

## Review Focus

1. **A voided serial that was never posted** must not be offered to the AIM sweep, and a
   re-completed container must show its NEW serial everywhere a serial is read by container.
2. **Moving more than the receiver can hold, or more than the donor tray has** - refused
   whole; counts on both sides stay consistent (`ContainerTray.PartsClosedCount` = tray LOT
   `PieceCount`).
3. **A container in rework that is a super-lot member** cannot be released or validated
   per unit; once re-completed it can.
4. **Serialized container:** a quantity scrap or move with no serial is refused; a serial
   from another container is refused; a scrapped serial disappears from the container's
   serial list.
5. **Void with pieces left** is refused; void of an empty member ends the membership and the
   super-lot can then close.

## Tasks

### Task 1: Migration `0111_container_rework`
Create `sql/migrations/versioned/0111_container_rework.sql` (shape of `0110`): statuses 6
and 7, `Lots.ContainerRework`, the three `AimShipperIdPool` void columns, the two
`ContainerSerial` columns, end reason `ContainerVoided` (5), six audit event codes, entity
type `ContainerRework`. Test: `sql/tests/0111_ContainerRework/010_schema.sql`.

### Task 2: Open, stage, resume, void
`R__Lots_ContainerRework_Open.sql`, `_SetStage.sql`, `_Resume.sql`, `_Void.sql`; modify
`R__Lots_AimShipperIdPool_ListUnposted.sql`, `_GetForPost.sql`,
`R__Lots_Container_ListPendingValidation.sql` (voided rows). Test `020_lifecycle.sql`
including re-completion through `Lots.Container_Complete` (new serial; old voided; old
never in `ListUnposted`).

### Task 3: Scrap and move
`R__Lots_ContainerRework_Scrap.sql`, `_MovePieces.sql` (LOT mint = mirror of the tray mint
in `Assembly_CompleteTray`; consumption = mirror of its pass-through block); readers of
`Lots.ContainerSerial` skip removed rows. Tests `030_scrap.sql`, `040_move.sql`.

### Task 4: Super-lot tie-in and reads
Modify `R__Quality_ufn_zzz_ControlledRunMemberResults.sql` ("Being reworked"),
`R__Quality_ControlledRun_Get.sql` / `_List.sql` (end reason 5). Create
`R__Lots_ContainerRework_Get.sql`, `_ListTrays.sql`, `_ListSerials.sql`, `_ListTargets.sql`,
`_ListAtLocation.sql`, `R__Lots_AimShipperIdPool_ListVoided.sql`. Test `050_superlot.sql`.
Run the `0109`, `0056`, `0064`, `0028`, `0029` suites for regressions.

### Task 5: Named queries and script module
NQ folders under `Core/.../named-query/lots/`; new `BlueRidge/Lots/ContainerRework/code.py`
(thin wrappers + display shaping + `completeHere`); `AimPost.postOne` refuses a voided row;
`ControlledRun.memberInstances` carries `containerId`.

### Task 6: Views
Generate `Popups/ControlledRunRepack`, `PlantFloor/ReworkTrayRow`, `PlantFloor/ReworkSerialRow`,
`Popups/ReworkContainerPick`, `PlantFloor/ReworkPickRow`. Scripted edits:
`ControlledRunMemberRow` (Repack icon on container rows), `ControlledRuns` (`repack` action),
`LineInventory` (button while a refill-ready container is at the line). Scan; walk on the
gateway as far as a typed credential allows.

### Task 7: Docs and end review
Data model (rev 3.5), extended properties, `PROJECT_STATUS.md`, spec status + build notes;
apply `0111` + procs to `MPP_MES_Dev` (additive); one independent review; full test run.
