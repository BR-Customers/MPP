# Review: c_Quality_00 (44 procs, Quality schema: controlled runs / super-lots, defect codes, code tables)

All 44 files read in full (plus the inline TVFs they call: `Quality.ufn_ControlledRunMemberState`, `ufn_ControlledRunMemberResults`,
`ufn_ControlledRunMembershipsForLot`, `ufn_ControlledRunMembershipState`, `ufn_OpenControlledRunForLot`, `ufn_ControlledRunCloseCheck`,
`ufn_ControlledRunResolveMembers`, `ufn_ControlledRunWindowConflict`). All of those TVFs are inline (no multi-statement TVFs).

Context verified while reviewing:
- `Quality.ControlledRunMember` indexes (0109): PK, `UX_ControlledRunMember_OpenLot (LotId) WHERE EndedAt IS NULL AND LotId IS NOT NULL`,
  `UX_ControlledRunMember_OpenContainer (ContainerId) WHERE EndedAt IS NULL ...`, `IX_ControlledRunMember_Run (ControlledRunId, EndedAt)`.
  No other migration adds an index on it (grepped all of `versioned/`). So there is NO index that serves "all memberships of LotId X including ended ones".
- `Lots.Lot` indexes available: `IX_Lot_ItemId`, `IX_Lot_CurrentLocationId`, `IX_Lot_NotClosed_Location/Item` (0118). No index on `CrtActive`.
- No `READ_COMMITTED_SNAPSHOT` anywhere in `sql/` (grepped), so reads under default READ COMMITTED take S locks.
- `Audit.OperationLog` has `IX_OperationLog_EntityType (LogEntityTypeId, EntityId, LoggedAt DESC)` re-created aligned in 0020 (so `ControlledRun_ListHistory` seeks).
- `Workorder.RejectEvent (TerminalLocationId, RecordedAt)` index exists (0067) so `DefectCode_ListRankedForLocation` seeks.
- `ControlledRunResult` has `IX_ControlledRunResult_Member`; `ControlledRunDeviation` has `IX_ControlledRunDeviation_Run`; `LotRework`, `ContainerRework`, `VendorReturn.ControlledRunResultId` all indexed.
- Super-lot volume is low (an exceptional quality case; tens per year). Nothing in this batch touches the queue-read hot path, and none of these procs
  scans `Lots.LotMovement`. The only plant-floor-polled reads are `ControlledRun_GetOpenSummary` (30 s, Supervisor Dashboard) and `ControlledRun_GetOpenByMember` /
  `ControlledRun_ListByLot` (LOT Detail load). All three are bounded by small tables.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| R__Quality_ControlledRunDeviation_ListByRun | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRunDeviation_Raise | OK | L | read; nothing to change (sequence row is UPDLOCK/HOLDLOCK; audit loop is per-member but runs once per deviation) | n/a |
| R__Quality_ControlledRunLabel_Print | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRunResult_ListByRun | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRunResult_Record | WATCH | L | Lots.Lot X-lock then ControlledRunResult insert: opposite order to Release (Result range lock then Lots.Lot); cursor locks LOTs in entry order | yes (lock order only) |
| R__Quality_ControlledRunResult_Void | WATCH | L | member-ended / release state checked before BEGIN TRAN, UPDATE does not re-assert it (integrity race with Release, not a perf issue) | yes |
| R__Quality_ControlledRun_AddMembers | OK | L | read; nothing to change (its cost lives in ApplyMembersInternal, which is the WATCH) | n/a |
| R__Quality_ControlledRun_ApplyMembersInternal | WATCH | M | UPDATE Lots.Lot driven by `l.Id IN (...) OR l.Id IN (...)` on a heap, no seek guaranteed; audit cursors run while X locks are held | yes |
| R__Quality_ControlledRun_Cancel | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_Close | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_Get | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_GetByNumber | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_GetOpenByMember | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_GetOpenSummary | OK | L | read; nothing to change (polled 30 s, but only open super-lots x their members, PK seeks into Lots.Lot) | n/a |
| R__Quality_ControlledRun_List | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ListByLot | OK | L | read; nothing to change (single LOT; same unindexed-history note as ListMarkers, harmless for one call) | n/a |
| R__Quality_ControlledRun_ListHistory | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ListMarkers | WATCH | L | per-node `CROSS APPLY ufn_ControlledRunMembershipsForLot` has no index for ended memberships, so each node scans ControlledRunMember | yes |
| R__Quality_ControlledRun_ListMemberOrigin | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ListMemberResults | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ListMemberRework | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ListMembers | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ListSignatures | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_LogMemberLotEventsInternal | OK | L | read; nothing to change (per-LOT cursor is forced by the per-row Audit_LogOperation EXEC; noted under Release/ApplyMembers) | n/a |
| R__Quality_ControlledRun_Open | WATCH | L | window-conflict check-then-insert outside the transaction, no unique index backs it | yes |
| R__Quality_ControlledRun_PreviewSelection | WATCH | L | item+time scan of every LOT ever made of the part (non-covering IX_Lot_ItemId, RID lookups); calls ufn_ControlledRunResolveMembers with an OR-shaped open-member probe | yes |
| R__Quality_ControlledRun_Release | WATCH | M | same OR-of-IN UPDATE on Lots.Lot as ApplyMembersInternal; X locks on up to hundreds of Lots.Lot rows held across per-LOT audit cursors | yes |
| R__Quality_ControlledRun_RemoveMember | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ReportMembers | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_ReportOutcomes | OK | L | read; nothing to change | n/a |
| R__Quality_ControlledRun_SetAutoJoin | WATCH | L | window-conflict check-then-update outside the transaction (same as Open) | yes |
| R__Quality_ControlledRun_SyncAutoJoin | OK | L | read; nothing to change (loops open super-lots, a handful; the work is in SyncInternal) | n/a |
| R__Quality_ControlledRun_SyncInternal | WATCH | M | 60 s timer (ships disabled): per open run reads every LOT of the item via IX_Lot_ItemId + RID lookups, with an OR on location; runs forever for any run whose window was ever opened | yes |
| R__Quality_Crt_FlagMissedInspection | OK | L | read; nothing to change | n/a |
| R__Quality_Crt_GetRequiredInspections | WATCH | L | location-scoped read of Lots.Lot via IX_Lot_CurrentLocationId + status code-table join (shape (c) of the incident); no view calls it today | yes |
| R__Quality_DefectCode_Create | OK | L | read; nothing to change | n/a |
| R__Quality_DefectCode_Deprecate | OK | L | read; nothing to change | n/a |
| R__Quality_DefectCode_Get | OK | L | read; nothing to change | n/a |
| R__Quality_DefectCode_List | OK | L | read; nothing to change (OR on a small config table) | n/a |
| R__Quality_DefectCode_ListRankedForLocation | OK | L | read; nothing to change | n/a |
| R__Quality_DefectCode_Update | OK | L | read; nothing to change | n/a |
| R__Quality_DispositionCode_Get | OK | L | read; nothing to change | n/a |
| R__Quality_DispositionCode_List | OK | L | read; nothing to change | n/a |
| R__Quality_HoldTypeCode_Get | OK | L | read; nothing to change | n/a |

## WATCH details

### Quality.ControlledRun_ApplyMembersInternal (WATCH, M)
```
 71    UPDATE l
 72    SET CrtActive = 1, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
 74    FROM Lots.Lot l
 75    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
 76    WHERE l.CrtActive = 0
 77      AND ( (sc.Code <> N'Closed' AND l.Id IN (SELECT LotId FROM @M WHERE LotId IS NOT NULL))
 78         OR l.Id IN (SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t
 79                     WHERE t.ContainerId IN (SELECT ContainerId FROM @M WHERE ContainerId IS NOT NULL)) );
```
- VERIFIED: `Lots.Lot` is a heap with a nonclustered PK on Id; nothing indexes `CrtActive`; there is no READ_COMMITTED_SNAPSHOT in `sql/`.
- INFERRED, not run: two `IN (subquery)` terms joined by OR cannot be turned into two seeks on `l.Id` by the usual semi-join rewrite; the common plan is a
  scan of Lots.Lot (~41k rows) with probe columns, taking U locks as it goes, inside an open transaction. This is the same shape as the catch-all OR in the
  incident, and Open / AddMembers / SyncInternal all call this helper in a transaction. Table variables carry no statistics, so the estimate will be 1 row,
  which makes a seek plausible; only a plan can say.
- Also verified: lines 104-124 and (via `LogMemberLotEventsInternal`) 128-133 run one `Audit_LogOperation` per tagged LOT while the X locks from line 71 are held,
  so a super-lot of a few hundred LOTs keeps those Lots.Lot rows locked for the length of that loop. A per-row audit EXEC cannot be made set-based.
- Proposed fix (needs plan first): resolve the target ids into a table variable first (`INSERT ... SELECT Id FROM @M UNION SELECT FinishedGoodLotId ...`),
  then `UPDATE l ... FROM @Targets x JOIN Lots.Lot l ON l.Id = x.Id WHERE l.CrtActive = 0 AND (...)`. Same rows updated, same `@Tagged` output, same result set.
- Callers / frequency: `ControlledRun_Open`, `_AddMembers`, `_SyncInternal` (SQL only). Open and AddMembers are supervisor actions, a few per month;
  SyncInternal calls it only when it found new tagged material. Rare.

### Quality.ControlledRun_Release (WATCH, M)
```
172        UPDATE l
173        SET CrtActive = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
175        FROM Lots.Lot l
176        WHERE l.CrtActive = 1
177          AND ( l.Id IN (SELECT LotId FROM @T WHERE LotId IS NOT NULL)
178             OR l.Id IN (SELECT ct.FinishedGoodLotId FROM Lots.ContainerTray ct
179                         WHERE ct.ContainerId IN (SELECT ContainerId FROM @T WHERE ContainerId IS NOT NULL)) );
```
- Same predicate shape and same inference as ApplyMembersInternal (verified text, plan not run). Additionally lines 182-202 (per-LOT audit cursor) and 268-280
  (per-text-group cursor calling `LogMemberLotEventsInternal`, which itself loops per LOT) run inside the transaction, so X locks on the cleared LOT rows are held
  across all of that audit work.
- Lock order (verified from text): Release first takes `UPDLOCK, HOLDLOCK` key-range locks on `ControlledRunResult` for the members (lines 159-162), then updates
  `Lots.Lot` (172). `ControlledRunResult_Record` does the opposite: updates `Lots.Lot` (253-262, 367-378), then inserts into `ControlledRunResult` (336). Same member
  being released while an inspector records a scrap/return against it is the only trigger. Same shape as a classic order inversion; not traced or reproduced.
- Proposed fix: same "resolve target Ids into a table variable, then seek" rewrite for the UPDATE. For the lock order, take the `Lots.Lot` rows (UPDLOCK by Id list)
  before the result-range lock, or leave it and accept the rare retry; Release already has a `SUPERLOT_RACE` catch path.
- Callers / frequency: Sign-off tab on the super-lot page (`ControlledRunSignOff`), a supervisor action; a few per month.

### Quality.ControlledRun_SyncInternal (WATCH, M)
```
 69    IF @ItemId IS NOT NULL AND (@AutoJoin = 1 OR @EndedAt IS NOT NULL)
 76        SELECT @Json = (
 77            SELECT l.Id AS lotId
 78            FROM Lots.Lot l
 79            WHERE l.ItemId = @ItemId
 80              AND l.CrtActive = 1
 81              AND l.CreatedAt >= @OpenedAt
 82              AND (@EndedAt IS NULL OR l.CreatedAt < @EndedAt)
 83              AND (@LocationId IS NULL OR l.CreatedAtTerminalId IN (SELECT Id FROM Descendants))
```
- VERIFIED: `IX_Lot_ItemId (ItemId)` is the only index that can serve the `ItemId` predicate (the filtered `IX_Lot_NotClosed_Item` cannot, because a Closed tray LOT
  can legitimately still be CrtActive and be wanted here). `CrtActive` and `CreatedAt` are not in it, so each call does one RID lookup per LOT ever made of the part
  (closed LOTs included) on a heap. VERIFIED: the condition at line 69 stays true for any OPEN run whose window was ever enabled, so a run left open after its window
  ended is re-read every tick until it is closed. The `@LocationId IS NULL OR ... IN (SELECT Id FROM Descendants)` term is also a catch-all OR, but on a small recursive
  set.
- INFERRED: with a few hundred to a few thousand LOTs per part this is a few thousand RID lookups per run per minute, not a stall by itself. It is a WATCH because it
  is the only unbounded-by-time read in the batch that is meant to run on a timer.
- Proposed fix: a small filtered index `Lots.Lot (ItemId, CreatedAt) INCLUDE (CreatedAtTerminalId) WHERE CrtActive = 1` (new numbered migration, goes in the same PR as the
  proc change if any). The proc text then needs no change; same rows.
- Callers / frequency: `ControlledRun_SyncAutoJoin` (`@Id = NULL`, all open runs) from gateway timer `ControlledRunSyncTimer`, 60 s, `enabled: false` in the repo
  (`ignition/projects/MPP/ignition/timer/ControlledRunSyncTimer/resource.json`; "enable per gateway", so production state is unknown); also `ControlledRun_Close`,
  `_Cancel`, `_SetAutoJoin` (rare supervisor actions).

### Quality.ControlledRunResult_Record (WATCH, L)
```
238        DECLARE scrap_cur CURSOR LOCAL FAST_FORWARD FOR
239            SELECT e.Seq, e.LotId, e.Quantity, e.DefectCodeId, e.Remarks
240            FROM @E e WHERE e.DispositionCode = N'Scrap' AND e.LotId IS NOT NULL ORDER BY e.Seq;
...
253            UPDATE l ... FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) WHERE l.Id = @LotId AND l.LotStatusId NOT IN (...)
```
- VERIFIED from text: each LOT is locked by a keyed seek (Id), so no scan problem. LOTs are visited in entry order (`ORDER BY e.Seq`), not LotId order, and the
  transaction holds those X locks through per-entry audit EXECs (lines 290, 322, 411, 443, 474, 495). Two concurrent Record calls touching the same two LOTs in opposite order,
  or Record vs Release (see above), could deadlock. Not traced.
- Proposed fix: order both cursors by `e.LotId, e.Seq` (cursor order only; row effects identical), leaving the per-row audit as is.
- Callers / frequency: super-lot Results tab, inspection entry; occasional (a few per super-lot).

### Quality.ControlledRunResult_Void (WATCH, L)
```
 81        IF @Reject IS NULL AND @MemberEndedAt IS NOT NULL ... (read at lines 56-62, before BEGIN TRANSACTION at 104)
106        UPDATE Quality.ControlledRunResult SET VoidedAt = ... WHERE Id = @ResultId AND VoidedAt IS NULL AND NOT EXISTS (vendor return)
```
- VERIFIED from text: "member still in the super-lot" and "run still open" are evaluated outside the transaction and the UPDATE does not re-assert them. Release holds
  UPDLOCK on the member's result rows until it commits, so a Void that started earlier simply waits and then voids a result that was part of a signed release.
  This is a check-then-write integrity gap, not a performance issue; it needs a Void and a Release on the same member at the same moment.
- Proposed fix: add `AND EXISTS (SELECT 1 FROM Quality.ControlledRunMember m WHERE m.Id = ControlledRunMemberId AND m.EndedAt IS NULL)` to the UPDATE (the existing
  `@@ROWCOUNT = 0` RAISERROR already covers it). Only changes behaviour inside the race window.
- Callers / frequency: Results tab "void" action, rare.

### Quality.ControlledRun_Open and Quality.ControlledRun_SetAutoJoin (WATCH, L)
```
Open 158-171:     IF @AutoJoinEnabled = 1 SELECT @Conflict = RunNumber FROM Quality.ufn_ControlledRunWindowConflict(...)   -- before BEGIN TRANSACTION at 208
SetAutoJoin 119-132: same check, UPDATE at 141
```
- VERIFIED: the "one open window per part/line" rule is a check-then-write with no lock and no unique index (`IX_ControlledRun_AutoJoin` is non-unique). Two supervisors
  opening/resuming a window for the same part within the same instant could both pass. Inferred, not reproduced. The member-level races in these procs ARE protected
  (unique filtered indexes + `SUPERLOT_RACE` count checks).
- Proposed fix: take `UPDLOCK, HOLDLOCK` on the conflict read inside the transaction, or serialise on an app lock for the part. Rule enforcement unchanged.
- Callers / frequency: a few per month. Low value; listed because the brief asks for check-then-insert races.

### Quality.ControlledRun_PreviewSelection (WATCH, L)
```
 58        FROM Lots.Lot l
 59        WHERE l.ItemId = @ItemId
 60          AND l.CreatedAt >= @FromUtc AND l.CreatedAt <= @ToUtc
 61          AND (@LocationId IS NULL OR l.CreatedAtTerminalId IN (SELECT Id FROM Descendants))
```
- VERIFIED: only `IX_Lot_ItemId` can seek on `ItemId`; `CreatedAt` needs an RID lookup per LOT of the part, closed LOTs included (they must be, they are shown as ineligible).
  The result feeds `ufn_ControlledRunResolveMembers`, whose `om` probe (lines 88-94 of that function) is an `OR` across `ContainerId`/`LotId` against the open-member
  table, so each candidate cannot use the two filtered unique indexes and scans the open members. That function is outside this batch; flagged here because this proc, Open, AddMembers and ApplyMembers all evaluate it (Open evaluates it three times).
- INFERRED: candidates x open members is small today (open super-lots are few). Becomes noticeable only with a long time window on a high-volume part and many open super-lots.
- Proposed fix: none needed now; if measured slow, split the probe into two `UNION ALL` branches in the function so each uses its filtered index. Result set unchanged.
- Callers / frequency: Popups/ControlledRunNew preview, a supervisor action, rare.

### Quality.ControlledRun_ListMarkers (WATCH, L)
```
 53    WITH Raw AS (
 54        SELECT CAST(N'Lot' AS NVARCHAR(10)) AS NodeKind, l.Id AS NodeId, ...
 56        FROM @Lots l
 57        CROSS APPLY Quality.ufn_ControlledRunMembershipsForLot(l.Id) f
```
- VERIFIED: the function (`R__Quality_ufn_zz_ControlledRunMembershipsForLot.sql` line 29, `WHERE m.LotId = @LotId`) asks for ALL memberships of a LOT, ended ones included, and the only
  `LotId` indexes on `ControlledRunMember` are filtered to `EndedAt IS NULL`. So each node in the walk scans `ControlledRunMember` (or its clustered PK). Table is small (members of
  super-lots), so this is a low multiplier: node count x a scan of a few thousand narrow rows.
- Proposed fix: a non-filtered `IX_ControlledRunMember_Lot (LotId) INCLUDE (ControlledRunId, AddedAt, EndedAt)` in a new migration; no proc text change, same rows.
  `ControlledRun_ListByLot` (one LOT per call) benefits equally but does not need it on its own.
- Callers / frequency: Genealogy Viewer, once per LOT walk (one call, comma-separated ids) via `BlueRidge.Quality.ControlledRun.markLotNodes`. User-initiated, not polled.

### Quality.Crt_GetRequiredInspections (WATCH, L)
```
 42    FROM Lots.Lot l
 43    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
 ...
 57    WHERE l.CrtActive = 1
 58      AND sc.Code <> N'Closed'
 59      AND l.CurrentLocationId IN (SELECT Id FROM Descendants)
```
- VERIFIED: filters open LOTs through a code-table join (shape (c) of the incident), so it cannot use `IX_Lot_NotClosed_Location`; it seeks `IX_Lot_CurrentLocationId`, which
  also holds every closed LOT that ever sat at the location, then RID-looks-up each to test `CrtActive`/status. Per-LOT `QualitySample` probes use `IX_QualitySample_LotId_SampledAt`
  (verified, fine). No catch-all OR, no LotMovement.
- VERIFIED: grepped `ignition/` for callers: only the Core script `BlueRidge.Quality.Crt.getRequiredInspections` and its named query; no view.json calls it, so it is not on any
  screen today. If it is wired to a polled terminal view it becomes the same family as `Lot_GetWipQueueByLocation`.
- Proposed fix (if/when wired up): copy the v3.3 pattern: resolve the location scope into a table variable, drive from `IX_Lot_NotClosed_Location` with the literal `l.LotStatusId <> 4`,
  then check `CrtActive` and join `LotStatusCode` for the code only. Same rows and order (ORDER BY clause kept).
- Callers / frequency: none found in views; frequency would be terminal-refresh if added.

COUNTS: OK=34 WATCH=10 CANDIDATE=0
