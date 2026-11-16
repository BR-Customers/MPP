# Review c_Lots_00 (Lots schema: AimPool / Container / ContainerRework / DieCastLot), 42 procs

All 42 files read in full. Index/constraint claims below were grepped in `sql/migrations/versioned/` (0020, 0028, 0029, 0034, 0055, 0078, 0111, 0114, 0118). Nothing was run against a database; plans and row counts are not measured.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| Lots.AimPoolConfig_Get | OK | L | read; nothing to change (single row, PK = 1) | n/a |
| Lots.AimPoolConfig_Update | OK | L | read; nothing to change (single-row config upsert) | n/a |
| Lots.AimShipperIdPool_Claim | OK | L | read; nothing to change (TOP 1 UPDLOCK/READPAST on IX_AimShipperIdPool_Available, race handled) | n/a |
| Lots.AimShipperIdPool_GetDepth | OK | L | read; nothing to change (COUNT/MIN over the filtered "available" index) | n/a |
| Lots.AimShipperIdPool_GetForPost | OK | L | read; nothing to change (UQ AimShipperId seek, UQ_Lot_LotName seek) | n/a |
| Lots.AimShipperIdPool_ListUnposted | OK | L | read; nothing to change (TOP @Top over IX_AimShipperIdPool_Unposted; 60 s sweep is cheap) | n/a |
| Lots.AimShipperIdPool_ListVoided | OK | L | read; nothing to change (no UI caller found; see note on missing ConsumedByContainerId index) | n/a |
| Lots.AimShipperIdPool_MarkPosted | OK | L | read; nothing to change (manual supervisor action) | n/a |
| Lots.AimShipperIdPool_RecordPostResult | OK | L | read; nothing to change (single-row atomic UPDATE) | n/a |
| Lots.AimShipperIdPool_Topup | OK | L | read; nothing to change (UQ on AimShipperId catches the check-then-insert race; single topup loop) | n/a |
| Lots.ContainerRework_Get | OK | L | read; nothing to change (one container by PK; user-opened screen) | n/a |
| Lots.ContainerRework_ListAtLocation | CANDIDATE | M | polled every 15 s per terminal; filters Lots.Container on status 7 with no index that can serve it | Yes |
| Lots.ContainerRework_ListSerials | OK | L | read; nothing to change | n/a |
| Lots.ContainerRework_ListTargets | OK | L | read; nothing to change (same unindexed status-7 scan as ListAtLocation, but user-triggered only; benefits from the same index) | n/a |
| Lots.ContainerRework_ListTrays | OK | L | read; nothing to change (IX_ConsumptionEvent_ProducedLotId exists) | n/a |
| Lots.ContainerRework_MovePieces | OK | L | read; nothing to change (re-checks under UPDLOCK/HOLDLOCK; lock order traced, no cycle with Assembly_CompleteTray found) | n/a |
| Lots.ContainerRework_Open | OK | L | read; nothing to change (status-guarded UPDATE) | n/a |
| Lots.ContainerRework_Resume | OK | L | read; nothing to change (status-guarded UPDATE) | n/a |
| Lots.ContainerRework_Scrap | OK | L | read; nothing to change (re-checks under lock) | n/a |
| Lots.ContainerRework_SetStage | OK | L | read; nothing to change (status-guarded UPDATE) | n/a |
| Lots.ContainerRework_Void | OK | L | read; nothing to change (status-guarded UPDATE) | n/a |
| Lots.ContainerSerial_Add | OK | L | read; nothing to change (UQ_ContainerSerial_Part catches the race) | n/a |
| Lots.ContainerSerial_Get | OK | L | read; nothing to change | n/a |
| Lots.ContainerStatusCode_Get | OK | L | read; nothing to change | n/a |
| Lots.ContainerStatusCode_List | OK | L | read; nothing to change | n/a |
| Lots.ContainerTray_Close | OK | L | read; nothing to change (UQ_ContainerTray_Position catches the check-then-insert race; header says retained for test flows) | n/a |
| Lots.Container_Complete | WATCH | M | final `UPDATE Lots.Container` has no `AND ContainerStatusCodeId = 1`; status is checked only before the transaction | Yes |
| Lots.Container_GetLabelData | OK | L | read; nothing to change | n/a |
| Lots.Container_GetOpenByCell | OK | L | read; nothing to change (served by IX_Container_OpenByLocation / filtered open indexes) | n/a |
| Lots.Container_GetTraceDetail | OK | L | read; nothing to change (single container; IX_CSH_* indexes exist) | n/a |
| Lots.Container_ListPendingValidation | CANDIDATE | M | OR across location and status 3 drives a scan of every completed container (they never leave the line), then a Lot seek per tray | Yes |
| Lots.Container_ListSerials | OK | L | read; nothing to change (already revised in 0114/v1.3) | n/a |
| Lots.Container_ListShipped | WATCH | L | reporting read, dates default NULL (unbounded), no index on CompletedAt, ~8 correlated seeks per container | Yes |
| Lots.Container_Open | OK | L | read; nothing to change | n/a |
| Lots.Container_Ship | OK | L | read; nothing to change (rare; UPDATE unguarded by status but Ship step is under review for removal) | n/a |
| Lots.Container_ValidateCrt | OK | L | read; nothing to change (race guard via OUTPUT/@@ROWCOUNT) | n/a |
| Lots.DieCastLot_Mint | OK | L | read; nothing to change (worker; insert order Lot, StatusHistory, Closure, Movement matches Assembly_CompleteTray) | n/a |
| Lots.DieCastLot_Open | WATCH | L | one-open-basket-per-(tool,cavity) is a lock-free check-then-insert | Yes |
| Lots.DieCastLot_Release | WATCH | M | Open-status check and watermark-derived delta are computed before the transaction; nothing in the write path re-checks status | Yes |
| Lots.DieCastLot_ReleaseMove | OK | L | read; nothing to change (worker; guard belongs in the caller, see Release) | n/a |
| Lots.DieCastLot_ResolveLtt | OK | L | read; nothing to change (UQ_Lot_LotName seek; user scans one LTT at a time) | n/a |
| Lots.DieCastLot_Void | OK | L | read; nothing to change (same unguarded-UPDATE shape as Release but rare, empty baskets only) | n/a |

Not in my batch, so no OK/handled rows needed: Lot_GetWipQueueByLocation, Lot_GetTrimStorageQueueForLine, Lot_GetComponentsAtCell, Lot_GetInspectionQueueByLocation.

---

## CANDIDATE: Lots.ContainerRework_ListAtLocation (v1.0)

Quoted:
```
39    WHERE c.ContainerStatusCodeId = 7 /* ReworkFilling */
40      AND c.CurrentLocationId IN (SELECT Id FROM Descendants)
```
(lines 17-21 resolve Descendants with a recursive CTE over Location.Location; lines 34-38 add two OUTER APPLYs per surviving container.)

VERIFIED:
- Lots.Container has a clustered PK and only two secondary indexes, both filtered to `ContainerStatusCodeId = 1` (IX_Container_OpenByLocation in 0028; IX_Container_OpenByCellItemStation in 0078). No index serves status 7 (ReworkFilling, seeded in 0111). So this is a scan of Lots.Container taking shared locks on a table that Assembly_CompleteTray, Container_Complete and ContainerRework_Resume write.
- Poll frequency, from `LineInventory/view.json` line 272: two bindings call `BlueRidge.Lots.ContainerRework.waitingCount` with a 15000 ms poll rate (button display and button text), and `waitingCount` runs the proc each time via `_waiting` (ContainerRework/code.py lines 240-252). LineInventory is docked on 5 entries in `page-config/config.json` and in the ReceivingDock view.

INFERRED, not run:
- Container table row count is unknown. It grows with every completed box and nothing deletes them, so the scan cost rises over time. Expected result is zero or one row at almost every call, which is why a tiny filtered index would turn it into a seek.
- Same shape as the 2026-11-10 incident reads (polled, no supporting index, S locks on a hot table). I have not traced a deadlock here.

Proposed fix: add a new versioned migration with a filtered index on `Lots.Container (CurrentLocationId, ItemId) WHERE ContainerStatusCodeId = 7` (INCLUDE the columns the select needs if desired); put Descendants into a table variable first, as the v3.3 reference does. Columns, order and rows unchanged. The same index also fixes the scan in `ContainerRework_ListTargets` (`c.ItemId = src.ItemId AND c.ContainerStatusCodeId = 7`).

Callers / frequency: every terminal page showing LineInventory, 2 calls per 15 s each (about 8 per minute per terminal). Also `waitingInstances` when the ReworkContainerPick popup is open.

---

## CANDIDATE: Lots.Container_ListPendingValidation (v1.1)

Quoted:
```
68    FROM Lots.Container c
69    INNER JOIN Lots.ContainerTray ct ON ct.ContainerId = c.Id
70    INNER JOIN Lots.Lot fgl          ON fgl.Id = ct.FinishedGoodLotId AND fgl.CrtActive = 1
...
74    WHERE c.CompletedAt IS NOT NULL
75      AND ((@ContainerId IS NOT NULL AND c.Id = @ContainerId)
76        OR (@ContainerId IS NULL AND @LocationId IS NOT NULL
77            AND (c.CurrentLocationId IN (SELECT Id FROM Descendants)
78              OR c.ContainerStatusCodeId = 3)))
```

VERIFIED:
- Container_Complete (R__Lots_Container_Complete.sql line 200) sets status 2 and CompletedAt but never changes `CurrentLocationId`. The only mover is Container_Ship, and R__Lots_Container_ListShipped.sql's header says nothing outside the dock Ship button sets status 3 and that step is itself under review for removal. So every completed container stays at its line's location, and the location arm of line 77 matches all historical completed containers of that line.
- The predicate has the catch-all OR shape the brief names (location arm OR status 3 arm OR single-container arm), which no index can serve; Lots.Container has no index on CompletedAt, location (non-open), or status 3.
- `Lots.Lot` has no index on `CrtActive` (checked 0020 and later migrations). Each historical tray is therefore probed on `Lots.Lot` (nonclustered PK on a heap: seek plus RID lookup, or a scan) just to test `CrtActive = 1`, which is true for almost none of them.
- Not timer-polled: `CrtValidation` popup (line 27) and AssemblyNonSerialized (line 66) / AssemblySerialized (lines 27, 40) call it through a `runScript(..., 0, ..., refreshToken)` binding (poll rate 0). The token is bumped on the `inventoryChanged` page message, on container complete, and on button clicks. So it re-runs on every tray completion at the cell, and once per container-complete path in `Container.py` (the `@ContainerId` probe).

INFERRED, not run:
- Actual cost depends on historical container count per line, which I could not see. Work per call grows with the line's completed-container count and tray count, which only goes up.

Proposed fix: new migration adding a filtered index on `Lots.Lot (Id) WHERE CrtActive = 1` (it is tiny; only pending LOTs qualify). In the proc, find the CRT-active tray rows first (seek that index, then `UQ_ContainerTray_FinishedGoodLot`), then apply the location / status-3 / `@ContainerId` predicate to that handful of containers, and put Descendants in a table variable first, per the v3.3 reference. Result columns, order and rows are unchanged (same joins and the same GROUP BY).

Secondary, not worth its own change: `Lots.AimShipperIdPool` has no index on `ConsumedByContainerId` (only the FK), so the LEFT JOIN at line 72 and similar lookups in ContainerRework_Open/Get and ListVoided scan the pool per call. Pool size is about one row per completed container; I judged it minor.

---

## WATCH: Lots.Container_Complete (v1.2)

Quoted:
```
80        IF @StatusCode <> 1
...
147       BEGIN TRANSACTION;
...
200       UPDATE Lots.Container SET ContainerStatusCodeId = 2, CompletedAt = SYSUTCDATETIME() WHERE Id = @ContainerId;
```
VERIFIED: status is read at lines 68-85 with no lock and before the transaction; the transaction claims the AIM pool row (lines 152-161, UPDLOCK/READPAST so two callers take different serials), inserts a ShippingLabel (lines 210-214), then runs the unguarded UPDATE at line 200. The only lost-race handling is for the pool being empty (line 188).

INFERRED, not run or reproduced: two overlapping calls for the same container (PLC auto-complete and the operator button, both of which call `Container.complete`: `Container/code.py` line 67, `AssemblyPlc/code.py` line 66 comments) would both pass the status check, claim two different serials, and write two live ShippingLabel rows for one container. ListUnposted would then offer both serials to AIM. I have not confirmed the two callers can actually overlap, which is why this is WATCH not CANDIDATE.

Proposed fix: take the status decision under a lock at the top of the transaction (`UPDATE ... SET ... WHERE Id = @ContainerId AND ContainerStatusCodeId = 1`, or UPDLOCK/HOLDLOCK read), and on zero rows COMMIT the empty transaction and return the existing "not open" status row, the same no-ROLLBACK pattern the proc already uses for the lost pool race. Result shape unchanged.

Callers / frequency: once per box (a few per hour per line).

Side note, hedged, not a finding: lock order here is Container (X) then the container's tray LOTs (Lot_CloseInline, line 235), while Assembly_CompleteTray inserts its new Lot (line 394) before it locks the Container (line 433). I found no way for Complete to need the in-flight tray LOT, so no cycle is traced; I only note it as the pair to look at if a deadlock ever involves a container.

---

## WATCH: Lots.DieCastLot_Release (v2.5) (and its siblings Open / Void)

Quoted (Release):
```
172   IF NOT EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
173                  WHERE l.Id = @LotId AND sc.Code = N'Open')
...
253   DECLARE @RelDieWatermark INT = Workorder.ufn_DieShotWatermark(@RelToolId, @ShiftId, @ResolvedCellLocationId);
266   IF @CounterReading IS NOT NULL AND @FinalPieceDelta IS NULL
268       SET @FinalPieceDelta = @CounterReading - Workorder.ufn_CavityShotWatermark(...)
...
292   BEGIN TRANSACTION;
302   EXEC Workorder.DieCastCredit_Write ... @ApplyToLot = 1 ...
```
and in `R__Lots_DieCastLot_ReleaseMove.sql` lines 34-37: `UPDATE Lots.Lot SET LotStatusId = @GoodStatusId, ... WHERE Id = @LotId;` (no status predicate).

VERIFIED: the Open check and the watermark-derived `@FinalPieceDelta` are computed before the transaction, unlocked. I read `Workorder.DieCastCredit_Write`: it inserts the contribution row and does `UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK) SET PieceCount = PieceCount + @PieceDelta` with no status check. So nothing inside the transaction notices that a concurrent Release already moved the LOT to Good.

INFERRED, not run: a double submit (double tap, or two terminals on the same press) would credit the delta twice and write two status-history and movement rows. Whether the view guards against double submit I did not check (callers are in the DieCast views, about 5 ignition files). Frequency: once per basket swap per cavity.

Proposed fix: in the transaction, lock and re-check the LOT first (`SELECT ... FROM Lots.Lot WITH (UPDLOCK, HOLDLOCK) WHERE Id = @LotId AND LotStatusId = <Open>`), recompute or verify the delta after the lock, and make the ReleaseMove UPDATE conditional; on a lost race return a Status 0 row (no ROLLBACK inside a possibly INSERT-EXEC-captured call). Result shape unchanged.

Sibling shapes (lower risk, not flagged separately):
- `DieCastLot_Void`: same unguarded `UPDATE Lots.Lot SET LotStatusId = Scrap` (line 59) after an unlocked Open/PieceCount=0 check; could flip a just-Released LOT back to Scrap. Rare (empty baskets only).

## WATCH: Lots.DieCastLot_Open (v1.2)

Quoted:
```
107   IF EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
108              WHERE l.ToolId = @ToolId AND l.ToolCavityId = @ToolCavityId AND sc.Code = N'Open')
...
116   BEGIN TRANSACTION;
117   EXEC Lots.DieCastLot_Mint ...
```
VERIFIED: the one-open-per-(tool,cavity) guard runs unlocked before the transaction, and there is no unique index enforcing it (Lots.Lot has UQ_Lot_LotName, IX_Lot_ToolId filtered ToolId NOT NULL, IX_Lot_ItemId, IX_Lot_CurrentLocationId, IX_Lot_Active, plus the 0118 filtered indexes; none on tool + cavity + status). LTT uniqueness is covered by UQ_Lot_LotName. The query itself is fine for performance (IX_Lot_ToolId seek).

INFERRED, not run: two terminals opening a basket for the same cavity with different LTTs at once could both succeed. Needs two operators on one press at the same moment, so low.

Proposed fix: repeat the guard inside the transaction with UPDLOCK/HOLDLOCK on the (ToolId, ToolCavityId) range, or take a per-cavity `sp_getapplock`. Result shape unchanged. Frequency: once per basket open, dozens per day.

## WATCH: Lots.Container_ListShipped (v1.1)

Quoted:
```
54    @FromEt DATE = NULL, @ToEt DATE = NULL, ...
134   WHERE c.ContainerStatusCodeId IN (2, 3)
135     AND c.CompletedAt IS NOT NULL
136     AND (@FromUtc IS NULL OR c.CompletedAt >= @FromUtc)
137     AND (@ToUtc   IS NULL OR c.CompletedAt <  @ToUtc)
```
VERIFIED: both date bounds default to NULL (unbounded), there is no index on `Lots.Container.CompletedAt`, and each qualifying container runs about 8 correlated seeks (tray sum, source-LOT union, label, rework, three history counts). The `OR @x IS NULL` pattern also prevents a seek on CompletedAt even if one existed.

INFERRED: I found no caller in `ignition/` (grep of Core scripts, Perspective views and named queries), so it is probably a report that passes dates, or unused. Cost is only a problem if it is run with NULL dates or a wide range.

Proposed fix, only if measurement shows it matters: an index on `Lots.Container (CompletedAt) WHERE ContainerStatusCodeId IN (2,3)` and splitting the range predicate so it can seek. Result unchanged. Frequency: ad hoc report.

---

## Notes (not flagged)

- `Lots.AimShipperIdPool` has no index on `ConsumedByContainerId`. Used by ContainerRework_Open/Get, ListVoided (per-row OUTER APPLY, up to 1000 voided rows), ListPendingValidation and `ContainerRework_Open`'s UPDATE. Pool is about one row per container, voided rows are rare, so I kept these OK.
- ContainerRework_MovePieces lock order: Lot (donor, UPDLOCK/HOLDLOCK) then ContainerTray then Container (destination) then IdentifierSequence 'Lot' then new Lot insert. Assembly_CompleteTray takes IdentifierSequence first, then the new Lot, then Container, then ContainerTray, then source Lot. The orders differ, but the rows are disjoint: the donor is a closed Manufactured tray LOT and the destination container is status 7, whereas CompleteTray works on Received-origin source LOTs and status-1 containers. No cycle traced.
- AimShipperIdPool_Topup's header says a duplicate is a "no-op success", but both the pre-check and the CATCH return Status 0. Behaviour, not performance; out of scope.

COUNTS: OK=36 WATCH=4 CANDIDATE=2
