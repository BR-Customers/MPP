# Review report: c_Quality_01 (Quality schema, second half)

All 45 files read in full (the first ~20 header-comment lines of 10 of the long config-editor procs were skipped; all code was read).
Read-only. No CANDIDATEs: nothing here is a plant-floor polled read of Lots.Lot / LotMovement of the 0118 shape. The Reject_* procs and the
Hold reads are on-demand report / operator-screen reads. Five WATCH items below, all Low risk.

Facts verified in `sql/migrations/versioned/` (grep, not assumed):
- `Workorder.RejectEvent` is partitioned on `RecordedAt` (`ps_MonthlyUtc`); clustered `CIX_RejectEvent_LotRecordedAt (LotId, RecordedAt)` (0020, rebuilt 0084).
  Nonclustered: `IX_RejectEvent_DefectCodeId (DefectCodeId, RecordedAt)`, `_ProductionEventId`, `_TerminalLocationId`, `_ShiftCavity`, `_Reconciliation`.
  There is NO index with `ItemId` as a key (0084 added the column + FK only).
- `Workorder.DieCastContribution`: `IX_DieCastContribution_Lot (LotId)` (0045); no index on `EventAt` (only the filtered `_Cell (CellLocationId, EventAt)`).
- `Workorder.ProductionEvent`: clustered `CIX_ProductionEvent_LotEventAt (LotId, EventAt)` on `ps_MonthlyUtc(EventAt)`.
- `Lots.Lot` indexes: `IX_Lot_ItemId`, `IX_Lot_CurrentLocationId`, `IX_Lot_ToolId`(filtered), `IX_Lot_Active`(filtered), `IX_Lot_NotClosed_*` (0118), `IX_Lot_ShiftId`. None on `CreatedAt`.
- `Quality.HoldEvent`: `UX_HoldEvent_OneOpenPerLot (LotId) WHERE ReleasedAt IS NULL AND LotId IS NOT NULL` and `..._OneOpenPerContainer` (0029).
- `QualitySample (LotId, SampledAt)`, `QualityResult (QualitySampleId)`, `QualityAttachment (QualitySampleId)`, `QualitySpecAttribute (QualitySpecVersionId)`, `ContainerTray (FinishedGoodLotId)` unique filtered, `SerializedPart (ProducingLotId)`, `ContainerSerial (ContainerId)`, `ContainerSerialHistory (OldContainerId)/(NewContainerId)` all exist.
- Callers: the five Reject_* procs are called only by `tools/build_aggregate_reports.py` (Reporting Module reports, each with `@FromEt = ?, @ToEt = ?` report parameters). No named query in `ignition/` references them. They run on demand when a user opens a report.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| R__Quality_HoldTypeCode_List | OK | L | read; nothing to change | n/a |
| R__Quality_Hold_GetOpenByContainer | OK | L | read; nothing to change (seek on filtered-unique open-hold index) | n/a |
| R__Quality_Hold_GetOpenByLot | OK | L | read; nothing to change (seek on filtered-unique open-hold index) | n/a |
| R__Quality_Hold_ListAssociatedContainers | OK | L | read; nothing to change (all lookups index-backed) | n/a |
| R__Quality_Hold_ListByContainer | OK | L | read; nothing to change (HoldEvent is tiny, no non-filtered ContainerId index but irrelevant at volume) | n/a |
| R__Quality_Hold_ListOpen | OK | L | read; nothing to change (open set is small; LIKE '%..%' over it is harmless) | n/a |
| R__Quality_Hold_ListOpenForReport | OK | L | read; nothing to change | n/a |
| R__Quality_Hold_Place | WATCH | L | LOT status read unlocked before txn, written as OldStatusId into history; later used by Hold_Release to restore | Yes |
| R__Quality_Hold_Release | OK | L | read; nothing to change | n/a |
| R__Quality_InspectionResultCode_Get | OK | L | read; nothing to change | n/a |
| R__Quality_InspectionResultCode_List | OK | L | read; nothing to change | n/a |
| R__Quality_QualityAttachment_Add | OK | L | read; nothing to change | n/a |
| R__Quality_QualityAttachment_ListBySample | OK | L | read; nothing to change | n/a |
| R__Quality_QualityResult_ListBySample | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySample_ListByLot | OK | L | read; nothing to change (seeks IX_QualitySample_LotId_SampledAt, per-sample result count via IX_QualityResult_QualitySampleId) | n/a |
| R__Quality_QualitySample_Record | OK | L | read; nothing to change (all validation pre-txn, inserts only Quality rows, only reads Lots.Lot by PK) | n/a |
| R__Quality_QualitySpecAttribute_Add | OK | L | read; nothing to change (MAX+1 SortOrder on a config table, admin only) | n/a |
| R__Quality_QualitySpecAttribute_ListByVersion | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecAttribute_MoveDown | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecAttribute_MoveUp | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecAttribute_Remove | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecAttribute_Update | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_Create | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_CreateNewVersion | OK | L | read; nothing to change (MAX+1 VersionNumber on a config table, admin only) | n/a |
| R__Quality_QualitySpecVersion_Deprecate | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_DiscardDraft | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_Get | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_GetActiveForSpec | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_ListBySpec | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_Publish | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpecVersion_SaveDraft | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpec_Create | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpec_Deprecate | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpec_Get | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpec_List | OK | L | read; nothing to change | n/a |
| R__Quality_QualitySpec_Update | OK | L | read; nothing to change | n/a |
| R__Quality_Reject_GetNonRejectScrap | OK | L | read; nothing to change (few IsNonRejectScrap codes, seeks IX_RejectEvent_DefectCodeId with the date bound) | n/a |
| R__Quality_Reject_GetPartMatrix | OK | L | read; nothing to change (one aggregate over the date window; inherent to the report, partition-pruned by RecordedAt) | n/a |
| R__Quality_Reject_GetPartMatrixByParty | WATCH | L | child query run once per part: no RejectEvent(ItemId) index, so each call scans the RejectEvent window | Yes |
| R__Quality_Reject_GetPartMatrixDefects | WATCH | L | child query run once per part: same missing RejectEvent(ItemId) index | Yes |
| R__Quality_Reject_GetPlantSummary | WATCH | L | `@MachAsmGood` scans the whole Lots.Lot heap filtered on CreatedAt (no index) | Yes |
| R__Quality_Reject_SearchDetail | WATCH | L | `COUNT(*) OVER()` + TOP forces the whole window; OUTER APPLY per row; dates default NULL (all history) | Yes |
| R__Quality_SampleTriggerCode_Get | OK | L | read; nothing to change | n/a |
| R__Quality_SampleTriggerCode_List | OK | L | read; nothing to change | n/a |
| R__Quality_SignatureMeaning_Get | OK | L | read; nothing to change | n/a |

## WATCH details

### R__Quality_Reject_GetPlantSummary (WATCH, L)
```
83    DECLARE @MachAsmGood BIGINT = (
84        SELECT ISNULL(SUM(CAST(l.PieceCount AS BIGINT)), 0)
85        FROM Lots.Lot l
86        INNER JOIN Parts.Item     i  ON i.Id  = l.ItemId
87        INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
88        WHERE it.Code = N'FinishedGood'
89          AND (@FromUtc IS NULL OR l.CreatedAt >= @FromUtc)
90          AND (@ToUtc   IS NULL OR l.CreatedAt <  @ToUtc));
```
- VERIFIED: `Lots.Lot` has no index on `CreatedAt` (full list of its indexes in 0020/0117/0118 above); the table is a heap. The `(@FromUtc IS NULL OR ...)` form also stops the optimizer using a range seek even if one existed (no OPTION (RECOMPILE)).
- INFERRED, not run: the plan is a heap scan of ~41k rows. Same shape as the 0118 incident (scan of the Lots.Lot heap under READ COMMITTED), but this is a one-shot report, not a terminal poll, and I have not traced any deadlock with it.
- Also `@TrimGood` (lines 71-79) walks `ProductionEvent` for the window and PK-seeks `Lots.Lot` per row; fine when the window is bounded.
- Fix (if a plan shows a scan): resolve FinishedGood item ids first (config table), then seek `IX_Lot_ItemId`; or add a `Lots.Lot (CreatedAt) INCLUDE (ItemId, PieceCount)` index in a new migration. Same rows and sums.
- Callers: the Plant Summary report only (`tools/build_aggregate_reports.py` line 207), on demand, a few times a day at most. The report always passes dates.

### R__Quality_Reject_GetPartMatrixByParty (WATCH, L)
```
77          WHERE re.ItemId = @ItemId
78            AND dc.IsNonRejectScrap = 0
79            AND (@FromUtc IS NULL OR re.RecordedAt >= @FromUtc)
```
- VERIFIED: no index has `ItemId` as a key on `Workorder.RejectEvent` (index list above). The date predicate still gives partition elimination on `RecordedAt`, so each call reads the rows of the window, not the whole table (when the report passes dates).
- INFERRED: the Reporting Module runs this once per row returned by `Reject_GetPartMatrix` (the header says so), so the cost is parts-in-window x rejects-in-window. The `DieCastGood` / `TrimGood` / `MachAsmGood` lookups are per-part and use `IX_Lot_ItemId` / `IX_DieCastContribution_Lot` / the ProductionEvent clustered key, so they are cheap.
- Fix: new migration adding `IX_RejectEvent_ItemId (ItemId, RecordedAt) ON ps_MonthlyUtc(RecordedAt)` (same pattern as the other RejectEvent indexes). No proc change, identical result set.
- Callers: Part Matrix report only (`build_aggregate_reports.py` line 255), on demand.

### R__Quality_Reject_GetPartMatrixDefects (WATCH, L)
```
52    WHERE re.ItemId = @ItemId
53      AND (@FromUtc IS NULL OR re.RecordedAt >= @FromUtc)
```
- Same finding and same fix as `GetPartMatrixByParty` (the one new index covers both). One proc, one per-part call from the same report (`build_aggregate_reports.py` line 257).

### R__Quality_Reject_SearchDetail (WATCH, L)
```
31    @FromEt           DATE          = NULL,
...
55    SELECT TOP (@LimitRows)
...
69        COUNT(*) OVER()      AS TotalCount
...
77    OUTER APPLY (
81        SELECT TOP (1) ss.Name AS ScheduleName
82        FROM Workorder.DieCastContribution dcc
...
85        WHERE dcc.LotId = re.LotId
86        ORDER BY dcc.EventAt DESC, dcc.Id DESC
87    ) sh
```
- VERIFIED: `IX_DieCastContribution_Lot (LotId)` exists (0045), so the apply is a seek + key lookup (for `EventAt`) + top-1 sort per row. `RejectEvent.LotId` is nullable, so lot-free rows match nothing and are cheap.
- INFERRED, not run: `COUNT(*) OVER()` needs the whole filtered set before `TOP`, so the apply probably runs for every row in the window, not for 1000. With `@FromEt`/`@ToEt` left NULL (the default) that is all of RejectEvent history. The report passes dates (verified in the script; I did not verify the report parameters are mandatory).
- Fix (keeps columns, order, rows): none needed unless a plan shows it is slow. If it is, compute the shift name only for the TOP rows (apply after the TOP in a derived table) and keep `TotalCount` in the inner query.
- Callers: Reject detail report only (`build_aggregate_reports.py` line 180), on demand.

### R__Quality_Hold_Place (WATCH, L)
```
60    SELECT @CurrentLotStatus = LotStatusId FROM Lots.Lot WHERE Id = @LotId;
...
111            UPDATE Lots.Lot SET LotStatusId = 2 WHERE Id = @LotId;  -- 2 = Hold (BlocksProduction=1)
112            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, ...
113            VALUES (@LotId, @CurrentLotStatus, 2, ...
```
- VERIFIED: the status is read at line 60 with no UPDLOCK/HOLDLOCK and outside the transaction (txn starts line 103), then written as `OldStatusId`. `Hold_Release` (lines 75-77) restores the LOT to the `OldStatusId` of the latest Hold transition, so a stale value would be restored later.
- INFERRED: only matters if another proc changes `LotStatusId` in the window between line 60 and 111 (for example a release or a quality status change on the same LOT). Rare, operator-driven, one row; not a deadlock shape (single-row PK update on `Lots.Lot`, no scans).
- The open-hold check-then-insert (lines 67 and 85) is also unlocked, but it is backstopped by the filtered unique indexes `UX_HoldEvent_OneOpenPerLot` / `_PerContainer` (verified in 0029). A race loses cleanly with a unique-violation error through the CATCH, not duplicate data; only the message is less friendly.
- Fix: capture the old status atomically in the UPDATE (`UPDATE Lots.Lot SET LotStatusId = 2 OUTPUT deleted.LotStatusId INTO @old WHERE Id = @LotId`) and use that for the history row. No change to the status row returned.
- Callers: Hold Management screen (`BlueRidge.Quality.Hold`), operator action, rare.

COUNTS: OK=40 WATCH=5 CANDIDATE=0
