# Review: c_OeeTools_01 (Tools schema, 55 procs)

Scope note: this batch is Tools configuration. The hot die-cast writes (shot-counter increment in `Workorder.DieCastShiftOutput_Record`, cavity credit in `Lots.DieCastLot_*`) are NOT in this batch. The only shot-counter write here is `Tools.Tool_CorrectShotCount`, a manual correction. Only three procs touch `Lots.Lot` (`ToolAssignment_GetCellContext`, `ToolAssignment_Release`, `ToolCavity_Deprecate`); every other proc reads or writes only small Tools / Parts / Location tables plus Audit.

Polled reads (Die Cast screen `DieCastBody/view.json`, 20 s timer bumping `view.custom.refreshToken`, per open terminal): `Tool_GetShotStatusForCell` (via `getShotStatusForCellOrEmpty`) and `ToolAssignment_ListActiveByCell` (via `getMountedToolForCellOrEmpty`). Both seek `UQ_ToolAssignment_ActiveCell` (filtered unique on `CellLocationId WHERE ReleasedAt IS NULL`, verified in 0010) and return 0-1 rows. They cannot matter. `ufn_ShotStatus` is an inline TVF (verified), not multi-statement.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| R__Tools_DieRankCompatibility_GetPair | OK | L | read; nothing to change | n/a |
| R__Tools_DieRankCompatibility_List | OK | L | read; nothing to change | n/a |
| R__Tools_DieRankCompatibility_Remove | OK | L | read; nothing to change | n/a |
| R__Tools_DieRankCompatibility_SaveAll | OK | L | read; nothing to change | n/a |
| R__Tools_DieRankCompatibility_Upsert | OK | L | read; nothing to change (check-then-write on a tiny admin table, unique-constrained) | n/a |
| R__Tools_DieRank_Create | OK | L | read; nothing to change | n/a |
| R__Tools_DieRank_Deprecate | OK | L | read; nothing to change | n/a |
| R__Tools_DieRank_Get | OK | L | read; nothing to change | n/a |
| R__Tools_DieRank_GetByCode | OK | L | read; nothing to change | n/a |
| R__Tools_DieRank_List | OK | L | read; nothing to change | n/a |
| R__Tools_DieRank_MoveDown | OK | L | read; nothing to change | n/a |
| R__Tools_DieRank_MoveUp | OK | L | read; nothing to change | n/a |
| R__Tools_DieRank_Update | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAssignment_Assign | OK | L | read; nothing to change (check-then-insert is backed by filtered UNIQUE indexes UQ_ToolAssignment_ActiveTool / _ActiveCell, verified in 0010) | n/a |
| R__Tools_ToolAssignment_GetCellContext | WATCH | L | OpenBasketCount subquery reads `Lots.Lot` heap per die (see below); on-demand popup, not polled | yes (same predicate, same count) |
| R__Tools_ToolAssignment_History | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAssignment_ListActiveByCell | OK | L | read; nothing to change (polled 20 s, filtered-unique seek, 0-1 rows) | n/a |
| R__Tools_ToolAssignment_ListByTool | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAssignment_Release | WATCH | L | open-basket guard reads `Lots.Lot` heap per die (same predicate as GetCellContext); rare supervisor action | yes |
| R__Tools_ToolAttributeDefinition_Create | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttributeDefinition_Deprecate | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttributeDefinition_Get | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttributeDefinition_ListByType | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttributeDefinition_MoveDown | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttributeDefinition_MoveUp | OK | L | read; nothing to change (mirror of MoveDown, diffed) | n/a |
| R__Tools_ToolAttributeDefinition_Update | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttribute_ListByTool | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttribute_Remove | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttribute_SaveAll | OK | L | read; nothing to change | n/a |
| R__Tools_ToolAttribute_Upsert | OK | L | read; nothing to change | n/a |
| R__Tools_ToolCavityStatusCode_List | OK | L | read; nothing to change | n/a |
| R__Tools_ToolCavity_Create | OK | L | read; nothing to change | n/a |
| R__Tools_ToolCavity_Deprecate | WATCH | L | open-basket check filters `Lots.Lot` on `ToolCavityId`, which has no index (heap scan); rare admin action | yes |
| R__Tools_ToolCavity_ListActiveByTool | OK | L | read; nothing to change (small table, `IX_ToolCavity_Tool`) | n/a |
| R__Tools_ToolCavity_ListByTool | OK | L | read; nothing to change | n/a |
| R__Tools_ToolCavity_ListForItemTool | OK | L | read; nothing to change | n/a |
| R__Tools_ToolCavity_SaveAll | OK | L | read; nothing to change (table-variable work on tens of rows, no Lots access) | n/a |
| R__Tools_ToolCavity_UpdateStatus | OK | L | read; nothing to change | n/a |
| R__Tools_ToolStatusCode_List | OK | L | read; nothing to change | n/a |
| R__Tools_ToolType_Get | OK | L | read; nothing to change | n/a |
| R__Tools_ToolType_List | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_CorrectShotCount | OK | L | read; nothing to change (single-row `UPDATE ... WITH (UPDLOCK, HOLDLOCK)` guarded by `ShotCount = @ExpectedShotCount`; touches only Tools.Tool then Audit; no Lots access) | n/a |
| R__Tools_Tool_Create | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_Deprecate | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_Duplicate | OK | L | read; nothing to change (one-shot INSERT...SELECT of a die's cavities/attributes) | n/a |
| R__Tools_Tool_Get | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_GetByCode | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_GetShotStatusForCell | OK | L | read; nothing to change (polled 20 s, filtered-unique seek + inline TVF) | n/a |
| R__Tools_Tool_List | OK | L | read; nothing to change (catch-all `OR` on a config table of dozens of rows, not worth touching) | n/a |
| R__Tools_Tool_ListCompatibleCells | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_ListEligibleForCell | OK | L | read; nothing to change (opened on demand from the Die Mount popup; duplicated predicate over small config tables) | n/a |
| R__Tools_Tool_ListForItem | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_ListMountableForCell | OK | L | read; nothing to change | n/a |
| R__Tools_Tool_Update | OK | L | read; nothing to change (does not write ShotCount, so no collision with the shift-output increment) | n/a |
| R__Tools_Tool_UpdateStatus | OK | L | read; nothing to change | n/a |

## WATCH details

### 1. ToolAssignment_GetCellContext and ToolAssignment_Release (same predicate, one finding)

`R__Tools_ToolAssignment_GetCellContext.sql` lines 74-81:
```
ISNULL((SELECT COUNT(*)
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        INNER JOIN Tools.ToolCavity   tc ON tc.Id = l.ToolCavityId
        WHERE l.ToolId = ta.ToolId
          AND sc.Code = N'Open'
          AND tc.ToolId = ta.ToolId
          AND tc.DeprecatedAt IS NULL), 0)
```
`R__Tools_ToolAssignment_Release.sql` lines 102-110: the identical count with `l.ToolId = @ToolId`.

- VERIFIED: `Lots.Lot` is a heap; the only index that serves `l.ToolId` is `IX_Lot_ToolId ON Lots.Lot (ToolId) WHERE ToolId IS NOT NULL` (0020 line 563). The index carries neither `LotStatusId` nor `ToolCavityId`, so every LOT the die has ever made (open and closed) is fetched by RID lookup into the heap before `sc.Code = 'Open'` can be tested. The `IX_Lot_NotClosed_*` indexes from 0118 are keyed on Location / Item, so they cannot serve this.
- INFERRED, not run: per-die lot history grows without bound (~41k LOTs spread over the dies), so the cost grows linearly with die age. Whether the optimizer matches the `IS NOT NULL` filtered index for `l.ToolId = ta.ToolId` is not confirmed; a miss would mean a heap scan of `Lots.Lot` instead.
- Concurrency: the RID lookups take shared row/page locks on the same heap the die-cast writers insert into. This is the same shape as the 2026-11-10 incident, but at a few hundred rows per call, on demand, and with no sign of parallelism. I am not claiming a deadlock. I also found no `READ_COMMITTED_SNAPSHOT` setting in `sql/`, so I assumed plain READ COMMITTED.
- Callers: `GetCellContext` is wrapped by `BlueRidge.Parts.Tool.getCellMountContextOrEmpty`, bound in the Die Mount popup (`MPP/.../Popups/DieMount/view.json`, line 16, keyed on `view.custom.refreshToken`, no timer in that view) and the Config Tool `CellMountCard`. It runs when a popup is opened or refreshed, not on a poll. `Release` runs on a supervisor action; the Die Mount release button script re-calls `getCellMountContextOrEmpty` first, so about 2 executions of the same count per release click.
- Possible fix (a measurement is needed first): add `LotStatusId` and `ToolCavityId` as INCLUDE columns on `IX_Lot_ToolId` in a new numbered migration. The proc text does not need to change, and the result set stays identical. The two procs must stay in step with each other and with `Lots.Lot_GetOpenByTool` (Release header governing rule).

### 2. ToolCavity_Deprecate

`R__Tools_ToolCavity_Deprecate.sql` lines 71-75:
```
IF EXISTS (SELECT 1
           FROM Lots.Lot l
           INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
           WHERE l.ToolCavityId = @Id
             AND sc.Code = N'Open')
```
- VERIFIED by grep of every `CREATE INDEX ... ON Lots.Lot` in `sql/migrations/versioned/*.sql` (0020, 0117, 0118): there is no index on `Lots.Lot.ToolCavityId`. The predicate therefore scans the `Lots.Lot` heap (about 41k rows prod) under shared locks.
- INFERRED: it runs only when a die manager deprecates a cavity in the Config Tool (`ToolCavity_Deprecate` named query, wrapped in `BlueRidge.Parts.Tool`). Frequency is a handful of times a year, so this is not worth a change on its own. Noted only because it is the one proc in this batch with a guaranteed full `Lots.Lot` scan. If an index on `ToolCavityId` were ever added for another reason, this proc would benefit with no text change.

COUNTS: OK=52 WATCH=3 CANDIDATE=0
