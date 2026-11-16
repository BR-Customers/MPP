# Review report: c_LocAud_01 (Location tail + Audit schema), 45 procs

All 45 files read in full. Read-only; nothing run. "Verified" = read in the repo (proc file or `sql/migrations/versioned/*.sql`); "inferred" = reasoned from code, not measured.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| Location_ListForEligibilityPicker | OK | L | read; nothing to change | n/a |
| Location_ListMachiningDestinations | OK | L | read; nothing to change (config tables only; per-line ancestor TVF is inline and tiny) | n/a |
| Location_ListProductionLines | OK | L | read; nothing to change | n/a |
| Location_MoveDown | OK | L | read; nothing to change (admin reorder, read-then-swap unlocked but rare and single-admin) | n/a |
| Location_MoveUp | OK | L | read; nothing to change (same as MoveDown) | n/a |
| Location_SaveAll | OK | L | read; nothing to change (Code check-then-insert is backstopped by `UQ_Location_Code`, verified 0002:78) | n/a |
| Location_Update | OK | L | read; nothing to change | n/a |
| PlcDeviceType_List | OK | L | read; nothing to change | n/a |
| PrinterFgAssignment_ListForStation | OK | L | read; nothing to change | n/a |
| PrinterFgAssignment_SaveAll | OK | L | read; nothing to change (validations before txn, delete+insert on tiny table) | n/a |
| Printer_GetById | OK | L | read; nothing to change | n/a |
| SessionPolicy_Get | OK | L | read; nothing to change (single-row table) | n/a |
| SessionPolicy_Update | OK | L | read; nothing to change | n/a |
| TerminalPlcDevice_Deprecate | OK | L | read; nothing to change | n/a |
| TerminalPlcDevice_GetByInstancePath | OK | L | read; nothing to change (no index on `UdtInstancePath`, but table is a few dozen to hundreds of rows; called per PLC trigger edge) | n/a |
| TerminalPlcDevice_GetByTerminal | OK | L | read; nothing to change (`IX_TerminalPlcDevice_Terminal` exists) | n/a |
| TerminalPlcDevice_Save | OK | L | read; nothing to change (unique filtered index `UQ_TerminalPlcDevice_ActiveDeviceCode` backstops the DeviceCode race) | n/a |
| Terminal_GetByIpAddress | OK | L | read; nothing to change (function on column defeats `IX_LocationAttribute_DefinitionValue` seek but the IpAddress def has ~134 rows; once per session start) | n/a |
| Terminal_GetClosureContext | OK | L | read; nothing to change | n/a |
| Terminal_GetPrinter | OK | L | read; nothing to change | n/a |
| Terminal_List | OK | L | read; nothing to change | n/a |
| Terminal_ListByLineOf | OK | L | read; nothing to change | n/a |
| Terminal_ListContextCells | OK | L | read; nothing to change (recursive CTE over config tree, MAXRECURSION 8) | n/a |
| Terminal_ListDefaultMachines | OK | L | read; nothing to change | n/a |
| Terminal_SetClosureMethod | WATCH | L | unlocked pre-txn read of an open `Lots.Container`, then unconditional status UPDATE (see below) | Yes |
| Terminal_SetCrtEnabled | OK | L | read; nothing to change | n/a |
| Terminal_SetScaleRunningPart | OK | L | read; nothing to change (human-cadence; calls inline TVF `Workorder.ufn_ScaleStationEligibleParts`, which reads `Lots.Lot`: belongs to another batch) | n/a |
| Audit_LogConfigChange | OK | L | read; nothing to change (single INSERT + 3 code-table seeks, no result set) | n/a |
| Audit_LogFailure | OK | L | read; nothing to change | n/a |
| Audit_LogInterfaceCall | OK | L | read; nothing to change | n/a |
| Audit_LogOperation | OK | L | read; nothing to change (routes Lot events to `Lots.LotEventLog`; note LotEventLog has FK `LotId -> Lots.Lot(Id)`, so each LOT audit write does an FK check against the Lot heap's PK inside the caller's txn; same on every caller, no ordering difference found) | n/a |
| ConfigLog_GetByEntity | OK | L | read; nothing to change (seek on `IX_ConfigLog_EntityType (LogEntityTypeId, EntityId, LoggedAt DESC)`, verified 0001:177; unbounded by date but per-entity) | n/a |
| ConfigLog_List | OK | L | read; nothing to change (date-bounded, `IX_ConfigLog_LoggedAt`, TOP 1000; admin screen) | n/a |
| FailureLog_DistinctProcedures | WATCH | L | whole-log DISTINCT, no date bound, on a log that is never purged | Yes |
| FailureLog_GetByEntity | WATCH | L | no `(LogEntityTypeId, EntityId)` index on FailureLog; no date bound; no UI caller found | Yes |
| FailureLog_GetTopProcs | OK | L | read; nothing to change (date-bounded range seek, GROUP BY) | n/a |
| FailureLog_GetTopReasons | OK | L | read; nothing to change (date-bounded; two catch-all `@x IS NULL OR` terms are residual filters inside a seeked date range) | n/a |
| FailureLog_List | WATCH | L | the one Audit reader that can join the `Lots.Lot` heap on a leading-wildcard `LotName LIKE` | Yes |
| FailureLog_Record | OK | L | read; nothing to change | n/a |
| InterfaceLog_Record | OK | L | read; nothing to change | n/a |
| LogEntityType_List | OK | L | read; nothing to change | n/a |
| LogEventType_List | OK | L | read; nothing to change | n/a |
| LogSeverity_List | OK | L | read; nothing to change | n/a |
| OperatorChange_Log | OK | L | read; nothing to change (single `Audit_LogOperation` call; fires per PIN sign-in) | n/a |
| Partition_MaintainWindow | WATCH | L | global SPLIT/MERGE of `pf_MonthlyUtc` takes Sch-M on every table on `ps_MonthlyUtc` | Yes |

No CANDIDATE: nothing in this batch touches `Lots.Lot` / `LotMovement` on a polled path, none uses the catch-all-OR-on-indexed-column shape on a hot table, and no log writer does anything beyond a single INSERT.

---

## WATCH details

### Terminal_SetClosureMethod
Lines 130-133 (read, before the txn, no lock):
```
SELECT TOP 1 @OpenContainerId = Id, @PriorConStatus = ContainerStatusCodeId
FROM Lots.Container
WHERE CurrentLocationId = @CellId AND ContainerStatusCodeId = 1   -- 1 = Open
```
Lines 159-165 (act, inside the txn):
```
IF @OpenContainerId IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM Quality.HoldEvent WHERE ContainerId = @OpenContainerId AND ReleasedAt IS NULL)
...
UPDATE Lots.Container SET ContainerStatusCodeId = 4 WHERE Id = @OpenContainerId;  -- 4 = Hold
```
- Verified: the read is outside `BEGIN TRANSACTION` (line 147) and unlocked; the UPDATE carries no `ContainerStatusCodeId = 1` guard and the HoldEvent NOT EXISTS has no UPDLOCK/HOLDLOCK.
- Inferred, not run: if `Assembly_CompleteTray` (or a close/ship path) changes that container's status between line 133 and line 165, this proc would stamp a no-longer-open container as Hold (and write a HoldEvent with a stale `PriorContainerStatusCodeId`). Window is milliseconds and the proc is a supervisor changeover, so likelihood is very low. Not traced against `Container` writers in other batches; "same shape as" any read-then-write on a hot status column.
- Table order in the txn: LocationAttribute -> HoldEvent -> Container -> Audit; I did not compare to `Quality.Hold_Place` (other batch), so no deadlock claim.
- Proposed fix: add `AND ContainerStatusCodeId = 1` to the UPDATE and re-check `@@ROWCOUNT` (or re-read the container `WITH (UPDLOCK, HOLDLOCK)` as the first statement inside the txn). Status row and message text stay identical.
- Callers/frequency: Config/shop-floor "closure mode changeover" button via `BlueRidge.Location.Terminal` script; elevated supervisor action, a few times per shift at most.

### FailureLog_DistinctProcedures
Lines 16-19:
```
SELECT DISTINCT ProcedureName FROM Audit.FailureLog WHERE ProcedureName IS NOT NULL ORDER BY ProcedureName;
```
- Verified: `IX_FailureLog_ProcedureName (ProcedureName, AttemptedAt DESC)` exists (0020:~934), so this is a narrow index scan, not a heap/clustered scan. It still reads one index row per failure ever logged: all partitions, no date bound. Verified `Audit.FailureLog` is not in `Audit.PartitionRetention` (only `LotEventLog` and `LotGenealogy` are registered), so it is never purged and only grows.
- Inferred: cost is O(total failures). Fine today; it grows linearly with every rejected mutation / AIM failure, forever.
- Proposed fix: same rows, same order via a skip-scan recursive CTE (`SELECT MIN(ProcedureName)` then repeatedly `MIN(ProcedureName) WHERE ProcedureName > prev`), which does one index seek per distinct name (a few dozen) instead of reading every row.
- Callers/frequency: Audit > Failure Log browser, `ProcedureDropdown` binding `runScript("...distinctProcedures", 0)`; evaluated when that admin screen loads. Rare.

### FailureLog_GetByEntity
Lines 67-68:
```
WHERE fl.LogEntityTypeId = @LogEntityTypeId
  AND fl.EntityId = @EntityId
```
- Verified (0001, 0020, 0116): FailureLog's indexes are clustered `CIX_FailureLog_AttemptedAt`, `IX_FailureLog_AppUser`, `IX_FailureLog_EntityEvent (LogEntityTypeId, LogEventTypeId, AttemptedAt DESC)`, `IX_FailureLog_ProcedureName`, `IX_FailureLog_Location_AttemptedAt`, `IX_FailureLog_Lot_AttemptedAt`. None has `EntityId`. Contrast `ConfigLog` (`IX_ConfigLog_EntityType` includes EntityId) and `OperationLog` / `LotEventLog` (EntityType index includes EntityId).
- Inferred: the best plan is a seek on `LogEntityTypeId` across all event types and dates with a key lookup per row to test `EntityId` (or a full clustered scan); cost grows with all failures of that entity type, with no date bound.
- Verified: `BlueRidge.Audit.FailureLog.getByEntity` (code.py:103) exists, but I found no view or script that calls it (only the definition), so this is latent.
- Proposed fix: if a caller is ever wired in, a new versioned migration adding `IX_FailureLog_EntityType (LogEntityTypeId, EntityId, AttemptedAt DESC)` (partition-aligned on `ps_MonthlyUtc(AttemptedAt)`) serves it with no proc change; the result set is unaffected.
- Callers/frequency: none found; would be an on-demand history popup.

### FailureLog_List
Lines 74, 82:
```
LEFT JOIN  Lots.Lot            lot ON lot.Id = fl.LotId
...
AND (@LotNameLike IS NULL OR lot.LotName LIKE N'%' + @LotNameLike + N'%')
```
- Verified: date bound is present (`AttemptedAt >= @StartDate AND < DATEADD(day,1,@EndDate)`, line 75-76) and the view defaults to the last 7 days (FailureLog view.json:1016). `COUNT(*) OVER()` forces the whole matching range to be evaluated before TOP 1000, and `AttemptedParameters` / `FailureReason` are returned for 1000 rows (NVARCHAR(MAX) in the select list).
- Inferred, not measured: when `@LotNameLike` is supplied the leading-wildcard LIKE is non-sargable and, because the predicate is on the LEFT JOIN's right side, makes it effectively an inner join; the plan is then likely a scan of `Lots.Lot` (a heap, ~41k rows) or of whatever index carries `LotName`, with shared locks while writers run. Same family as the 2026-11-10 incident only in that it reads `Lots.Lot` without a seek; I have not traced a deadlock and an admin query this small is unlikely to matter.
- Proposed fix: none required unless it shows up in a lock trace; if it does, resolve `@LotNameLike` to a table variable of matching `Lot.Id` first (one scan, `WITH (NOLOCK)`-free), then join `FailureLog` on `IX_FailureLog_Lot_AttemptedAt`. Columns and order unchanged.
- Callers/frequency: Audit > Failure Log browser (`search()` in `BlueRidge/Audit/FailureLog/code.py`), per operator Search click; admin only.

### Partition_MaintainWindow
Lines 87-88 and 171:
```
ALTER PARTITION SCHEME ps_MonthlyUtc NEXT USED [PRIMARY];
ALTER PARTITION FUNCTION pf_MonthlyUtc() SPLIT RANGE (@NextBoundary);
...
ALTER PARTITION FUNCTION pf_MonthlyUtc() MERGE RANGE (@Boundary);
```
- Verified: `pf_MonthlyUtc` is shared by every partitioned table (OperationLog, InterfaceLog, FailureLog, LotEventLog, LotMovement, LotStatusHistory, ProductionEvent family, RejectEvent, etc.; 0020/0021/0067/0084/0097/0113/0116). SPLIT and MERGE are function-wide, so each takes schema-modification locks on all of them and waits behind (and then blocks) any running query on those tables. Verified the proc has no transaction and no `LOCK_TIMEOUT`; verified it runs from a daily Gateway timer (`projects/MPP/ignition/timer/PartitionMaintenance/handleTimerEvent.py`).
- Verified today it is effectively a no-op: 0020 seeds boundaries 2026-04-01 .. 2027-07-01 (16 months), so the SPLIT guard (line 80-85) does not fire until mid-2027, and only `Lots.LotEventLog` and `Lots.LotGenealogy` are registered (240 months), so the minimum cutoff is 20 years back and no MERGE happens.
- Inferred, not run: from mid-2027 the monthly SPLIT lands on the rightmost partition, which by then holds the current month's rows, and only ensures ONE month of lead (line 78), so that partition is never empty at split time except if the timer fires at the very start of the month. A split of a non-empty partition is slower and holds Sch-M longer; with Sch-M queued behind a long reader, plant-floor queue reads can stall behind it.
- Proposed fix: ensure several months of lead (split boundaries until `@FirstOfMonth + 3 months` exist) so the split target is always empty, and set `SET LOCK_TIMEOUT` with a retry on the next daily run. Status/Message result unchanged.
- Callers/frequency: once a day from the Gateway timer; effectively monthly in terms of real work. Nothing to do before 2027.

---

Other observations (not findings): every `*_Update/_Save/_Deprecate/_SetX` proc here follows the validate-before-txn, ROLLBACK-only-in-CATCH pattern and calls `Audit_LogConfigChange` / `Audit_LogOperation` inside the txn as a plain single-row INSERT; none touches `Lots.Lot` in a transaction, so none participates in the Lot/LotMovement/Container lock-ordering concern. The log writers all insert at the tail of a date-partitioned clustered index and add no lock beyond FK validation to small code tables, `Location.AppUser`, `Location.Location` and (for `LotEventLog` / `FailureLog.LotId`) `Lots.Lot`'s PK.

COUNTS: OK=40 WATCH=5 CANDIDATE=0
