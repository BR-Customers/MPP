# Trim OUT Multi-Reason Scrap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Trim OUT operator record zero-or-more defect-coded scrap lines (reason + quantity) against the LOT being trimmed out, writing one `Workorder.RejectEvent` row per line and decrementing the LOT once by the sum — atomically inside `Workorder.TrimOut_Record`.

**Architecture:** Extend the existing `Workorder.TrimOut_Record` proc: replace the scalar `@ScrapCount INT` with `@ScrapLinesJson NVARCHAR(MAX)` (`[{defectCodeId,quantity},…]`), parse it with `OPENJSON`, validate pre-transaction, and inside the existing transaction insert the RejectEvent rows and decrement `Lot.PieceCount`/`InventoryAvailable` by the aggregate. Mirrors `Workorder.DieCastShiftOutput_Record`'s inline reject inserts. The NQ + entity script swap the param; `TrimBody` replaces the single "Scrap count" field with a dynamic add-line scrap-reason repeater backed by a new `ScrapLineRow` component.

**Tech Stack:** SQL Server 2022 (T-SQL repeatable proc + tSQLt-style test harness), Ignition 8.3 Perspective (file-based views, Named Queries, Jython entity scripts).

## Global Constraints

- Approved spec: `docs/superpowers/specs/2026-08-05-trim-out-multi-reason-scrap-design.md` (FAT #2). Depends on FAT #1 (defect codes scoped by `OperationCategory` — shipped).
- **Atomic, in-proc** — reject inserts + decrement happen inside `TrimOut_Record`'s existing transaction. Do NOT call `RejectEvent_Record` per line (double-decrements).
- **One aggregate decrement** — `Lot.PieceCount`/`InventoryAvailable` drop once by `Σ quantity`, never per-line.
- `RejectEvent.ProductionEventId` = **NULL** for Trim scrap (attribution is by `LotId` + Trim OUT context; consistent with die-cast rejects + FAT #20 NULL-by-design).
- FDS-11-011: no OUTPUT params; every exit path ends `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. All rejecting validations run BEFORE `BEGIN TRANSACTION` (Msg-3915); CATCH is the only ROLLBACK site.
- Audit Description convention (`SUBJECT · CATEGORY · ACTION`, `Audit.ufn_MidDot()`, `Audit.ufn_TruncateActivity`).
- No business logic in Python (validation mirrors live server-side in the proc; the view's client-side checks are UX only).
- Reason list scoped to Trim: `getForDropdown(0, "TrimOut")` → Trim category (codes 140–145) + plant-wide. (`Parts.OperationType.Code='TrimOut'` → `OperationCategory` "Trim", verified.)
- Ignition edit rules: existing `view.json` edits only while **Designer is closed**; run `.\scan.ps1` after any Ignition resource change; commit to `jacques/working`; stage explicit paths; no `Co-Authored-By` trailer.
- Validate SQL on a throwaway DB (e.g. `MPP_MES_TrimScrap`), never reset `MPP_MES_Dev`.

---

### Task 1: `TrimOut_Record` proc — `@ScrapLinesJson` + inline RejectEvents (TDD)

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql`

**Interfaces:**
- Produces: `Workorder.TrimOut_Record(@ParentLotId BIGINT, @OperationTemplateId BIGINT, @ShotCount INT=NULL, @ScrapLinesJson NVARCHAR(MAX)=NULL, @DestinationCellLocationId BIGINT=NULL, @SourceLocationId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT=NULL)` → single result set `(Status BIT, Message NVARCHAR, NewId BIGINT)`; `NewId` = the closing `ProductionEvent.Id`. `@ScrapLinesJson` shape: `[{"defectCodeId":<bigint>,"quantity":<int>},…]`.
- Consumes: `Workorder.RejectEvent` (cols `ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt`), `Quality.DefectCode(Id, DeprecatedAt)`.

- [ ] **Step 1: Write the failing tests** — append these five blocks to `050_TrimOut_Record_validation.sql`, immediately BEFORE the final `-- ---- cleanup ----` block. They fix the `LotName LIKE 'MESL%'` fixture so the existing cleanup covers them.

```sql
-- =============================================
-- Test 7: multi-line scrap -> N RejectEvent rows + PieceCount decremented by Σqty (once)
-- =============================================
DECLARE @Area7 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press7 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv7 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot7 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
-- two ACTIVE Trim-category defect codes (140-145 band); resolve by Code to stay data-stable
DECLARE @D1 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'140' AND DeprecatedAt IS NULL);
DECLARE @D2 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'141' AND DeprecatedAt IS NULL);
DECLARE @L7 BIGINT;
CREATE TABLE #C7 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C7 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv7, @CurrentLocationId = @Press7, @PieceCount = 20, @AppUserId = 1;
SELECT @L7 = NewId FROM #C7; DROP TABLE #C7;
DECLARE @RejBefore7 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L7);
DECLARE @Json7 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D1 AS NVARCHAR(20)) + N',"quantity":3},{"defectCodeId":' + CAST(@D2 AS NVARCHAR(20)) + N',"quantity":2}]';
DECLARE @S7 BIT;
CREATE TABLE #T7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T7 EXEC Workorder.TrimOut_Record @ParentLotId = @L7, @OperationTemplateId = @Ot7, @ShotCount = 15, @ScrapLinesJson = @Json7, @SourceLocationId = @Area7, @AppUserId = 1;
SELECT @S7 = Status FROM #T7; DROP TABLE #T7;
DECLARE @S7Str NVARCHAR(10) = CAST(@S7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] multi-line scrap succeeds', @Expected = N'1', @Actual = @S7Str;
DECLARE @RejNew7 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L7) - @RejBefore7;
DECLARE @RejNew7Str NVARCHAR(10) = CAST(@RejNew7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] two RejectEvent rows written', @Expected = N'2', @Actual = @RejNew7Str;
DECLARE @PC7 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @L7);
DECLARE @PC7Str NVARCHAR(10) = CAST(@PC7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] PieceCount decremented by Σqty once (20-5=15)', @Expected = N'15', @Actual = @PC7Str;
DECLARE @PENull7 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L7 AND ProductionEventId IS NOT NULL);
DECLARE @PENull7Str NVARCHAR(10) = CAST(@PENull7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] reject rows have NULL ProductionEventId (by design)', @Expected = N'0', @Actual = @PENull7Str;
GO

-- =============================================
-- Test 8: invalid/deprecated defectCodeId in a line -> Status 0, nothing written
-- =============================================
DECLARE @Area8 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press8 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv8 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot8 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L8 BIGINT;
CREATE TABLE #C8 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C8 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv8, @CurrentLocationId = @Press8, @PieceCount = 20, @AppUserId = 1;
SELECT @L8 = NewId FROM #C8; DROP TABLE #C8;
DECLARE @BadJson8 NVARCHAR(MAX) = N'[{"defectCodeId":99999999,"quantity":2}]';
DECLARE @S8 BIT, @M8 NVARCHAR(500);
CREATE TABLE #T8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T8 EXEC Workorder.TrimOut_Record @ParentLotId = @L8, @OperationTemplateId = @Ot8, @ShotCount = 18, @ScrapLinesJson = @BadJson8, @SourceLocationId = @Area8, @AppUserId = 1;
SELECT @S8 = Status, @M8 = Message FROM #T8; DROP TABLE #T8;
DECLARE @S8Str NVARCHAR(10) = CAST(@S8 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] invalid defect code rejected (Status 0)', @Expected = N'0', @Actual = @S8Str;
EXEC test.Assert_Contains @TestName = N'[TrimOutScrap] invalid-defect message', @HaystackStr = @M8, @NeedleStr = N'invalid or deprecated';
DECLARE @PC8 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @L8);
DECLARE @PC8Str NVARCHAR(10) = CAST(@PC8 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] no decrement on rejected scrap', @Expected = N'20', @Actual = @PC8Str;
GO

-- =============================================
-- Test 9: shots + Σscrap > PieceCount -> reject; boundary (= PieceCount) passes
-- =============================================
DECLARE @Area9 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press9 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv9 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot9 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @D9 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'140' AND DeprecatedAt IS NULL);
DECLARE @L9 BIGINT;
CREATE TABLE #C9 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C9 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv9, @CurrentLocationId = @Press9, @PieceCount = 20, @AppUserId = 1;
SELECT @L9 = NewId FROM #C9; DROP TABLE #C9;
-- shots 19 + scrap 2 = 21 > 20 -> reject
DECLARE @OverJson9 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D9 AS NVARCHAR(20)) + N',"quantity":2}]';
DECLARE @S9a BIT;
CREATE TABLE #T9a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T9a EXEC Workorder.TrimOut_Record @ParentLotId = @L9, @OperationTemplateId = @Ot9, @ShotCount = 19, @ScrapLinesJson = @OverJson9, @SourceLocationId = @Area9, @AppUserId = 1;
SELECT @S9a = Status FROM #T9a; DROP TABLE #T9a;
DECLARE @S9aStr NVARCHAR(10) = CAST(@S9a AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] shots+scrap over piece count rejected', @Expected = N'0', @Actual = @S9aStr;
-- boundary: shots 18 + scrap 2 = 20 = PieceCount -> passes
DECLARE @S9b BIT;
CREATE TABLE #T9b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T9b EXEC Workorder.TrimOut_Record @ParentLotId = @L9, @OperationTemplateId = @Ot9, @ShotCount = 18, @ScrapLinesJson = @OverJson9, @SourceLocationId = @Area9, @AppUserId = 1;
SELECT @S9b = Status FROM #T9b; DROP TABLE #T9b;
DECLARE @S9bStr NVARCHAR(10) = CAST(@S9b AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] shots+scrap = piece count boundary passes', @Expected = N'1', @Actual = @S9bStr;
GO

-- =============================================
-- Test 10: empty/absent @ScrapLinesJson -> success, 0 rejects, no decrement (scrap-free Trim OUT)
-- =============================================
DECLARE @Area10 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press10 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv10 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot10 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L10 BIGINT;
CREATE TABLE #C10 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C10 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv10, @CurrentLocationId = @Press10, @PieceCount = 20, @AppUserId = 1;
SELECT @L10 = NewId FROM #C10; DROP TABLE #C10;
DECLARE @RejBefore10 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L10);
DECLARE @S10 BIT;
CREATE TABLE #T10 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T10 EXEC Workorder.TrimOut_Record @ParentLotId = @L10, @OperationTemplateId = @Ot10, @ShotCount = 20, @ScrapLinesJson = NULL, @SourceLocationId = @Area10, @AppUserId = 1;
SELECT @S10 = Status FROM #T10; DROP TABLE #T10;
DECLARE @S10Str NVARCHAR(10) = CAST(@S10 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] scrap-free Trim OUT succeeds', @Expected = N'1', @Actual = @S10Str;
DECLARE @RejNew10 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L10) - @RejBefore10;
DECLARE @RejNew10Str NVARCHAR(10) = CAST(@RejNew10 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] scrap-free writes zero rejects', @Expected = N'0', @Actual = @RejNew10Str;
DECLARE @PC10 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @L10);
DECLARE @PC10Str NVARCHAR(10) = CAST(@PC10 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] scrap-free leaves PieceCount unchanged', @Expected = N'20', @Actual = @PC10Str;
GO

-- =============================================
-- Test 11: non-positive quantity in a line -> reject
-- =============================================
DECLARE @Area11 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press11 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv11 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot11 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @D11 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'140' AND DeprecatedAt IS NULL);
DECLARE @L11 BIGINT;
CREATE TABLE #C11 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C11 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv11, @CurrentLocationId = @Press11, @PieceCount = 20, @AppUserId = 1;
SELECT @L11 = NewId FROM #C11; DROP TABLE #C11;
DECLARE @ZeroJson11 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D11 AS NVARCHAR(20)) + N',"quantity":0}]';
DECLARE @S11 BIT, @M11 NVARCHAR(500);
CREATE TABLE #T11 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T11 EXEC Workorder.TrimOut_Record @ParentLotId = @L11, @OperationTemplateId = @Ot11, @ShotCount = 20, @ScrapLinesJson = @ZeroJson11, @SourceLocationId = @Area11, @AppUserId = 1;
SELECT @S11 = Status, @M11 = Message FROM #T11; DROP TABLE #T11;
DECLARE @S11Str NVARCHAR(10) = CAST(@S11 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] non-positive scrap quantity rejected', @Expected = N'0', @Actual = @S11Str;
EXEC test.Assert_Contains @TestName = N'[TrimOutScrap] positive-quantity message', @HaystackStr = @M11, @NeedleStr = N'quantity must be positive';
GO
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (throwaway DB):
```bash
powershell.exe -ExecutionPolicy Bypass -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_TrimScrap -Force
sqlcmd -S localhost -d MPP_MES_TrimScrap -E -C -b -I -i "sql/tests/0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql"
```
Expected: FAIL — `@ScrapLinesJson` is not a parameter of `TrimOut_Record` yet (Msg 8144 "too many arguments" / parameter not found).

- [ ] **Step 3: Rewrite the proc** — apply these edits to `sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql`.

**3a. Signature** — replace the `@ScrapCount` param line:
```sql
    @ScrapCount                INT    = NULL,
```
with
```sql
    @ScrapLinesJson            NVARCHAR(MAX) = NULL,   -- [{"defectCodeId":<bigint>,"quantity":<int>}, ...]
```

**3b. `@Params` audit JSON** — replace `@ScrapCount AS ScrapCount,` with:
```sql
               LEFT(@ScrapLinesJson, 2000) AS ScrapLinesJson,
```

**3c. Parse + derive @ScrapTotal** — immediately after the `-- ---- 1. Required parameters ----` block's `END`, add:
```sql
        -- ---- 1b. Parse scrap lines + derive total (pre-txn) ----
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) <> 1
        BEGIN
            SET @Message = N'ScrapLinesJson is not valid JSON.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @Scrap TABLE (DefectCodeId BIGINT, Quantity INT);
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1
            INSERT INTO @Scrap (DefectCodeId, Quantity)
            SELECT j.defectCodeId, j.quantity
            FROM OPENJSON(@ScrapLinesJson)
                 WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') j;

        DECLARE @ScrapTotal INT = ISNULL((SELECT SUM(Quantity) FROM @Scrap), 0);

        -- every scrap line quantity must be positive
        IF EXISTS (SELECT 1 FROM @Scrap WHERE Quantity IS NULL OR Quantity <= 0)
        BEGIN
            SET @Message = N'Each scrap line quantity must be positive.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- every scrap defect code must exist and be active (reject cleanly here
        -- rather than hit the RejectEvent FK mid-transaction; mirrors
        -- DieCastShiftOutput_Record's pre-txn DefectCode check)
        IF EXISTS (
            SELECT 1 FROM @Scrap s
            WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc
                              WHERE dc.Id = s.DefectCodeId AND dc.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more scrap defect codes are invalid or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```

**3d. Counter sanity (guard 6)** — replace the whole `-- ---- 6. Counter sanity ...` `IF` block with a ShotCount-only check (scrap negativity is now covered by the per-line positive check in 1b):
```sql
        -- ---- 6. Counter sanity (ShotCount non-negative when supplied) ----
        IF (@ShotCount IS NOT NULL AND @ShotCount < 0)
        BEGIN
            SET @Message = N'ShotCount cannot be negative.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```

**3e. Combined cap (guard 6b)** — in the `-- ---- 6b. COMBINED counts ...` block, replace `ISNULL(@ScrapCount, 0)` (both the `IF` condition and the message concat) with `@ScrapTotal`:
```sql
        IF @LotPieceCount IS NOT NULL
           AND (ISNULL(@ShotCount, 0) + @ScrapTotal) > @LotPieceCount
        BEGIN
            SET @Message = N'ShotCount ' + ISNULL(CAST(@ShotCount AS NVARCHAR(20)), N'0')
                         + N' + Scrap ' + CAST(@ScrapTotal AS NVARCHAR(20))
                         + N' exceeds the LOT piece count ' + CAST(@LotPieceCount AS NVARCHAR(20)) + N'.';
```
(keep the rest of the block — Audit_LogFailure + SELECT + RETURN — unchanged.)

**3f. D1 monotonic (guard 7)** — DELETE the entire second monotonic block (the one that reads `IF @PrevScrap IS NOT NULL AND @ScrapCount IS NOT NULL AND @ScrapCount < @PrevScrap …`). Keep `@PrevShot`/`@ShotCount` block. The `SELECT TOP 1 @PrevShot = pe.ShotCount, @PrevScrap = pe.ScrapCount` line may stay (harmless) or drop `@PrevScrap`; leaving it is fine.

**3g. Checkpoint insert (mutation a)** — in the `INSERT INTO Workorder.ProductionEvent (… ShotCount, ScrapCount, …) VALUES (…, @ShotCount, @ScrapCount, …)`, change `@ScrapCount` to `@ScrapTotal`.

**3h. Reject inserts** — immediately after `SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);`, add:
```sql
        -- Inline defect-coded scrap rows (mirror DieCastShiftOutput_Record). One
        -- RejectEvent per line; ProductionEventId NULL by design (attribution is
        -- by LotId + Trim OUT context). The aggregate LOT decrement is in the
        -- move UPDATE below (NOT per-line -- avoids double-decrement).
        IF EXISTS (SELECT 1 FROM @Scrap)
            INSERT INTO Workorder.RejectEvent
                (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt)
            SELECT NULL, @ParentLotId, s.DefectCodeId, s.Quantity, NULL, N'Trim OUT scrap', @AppUserId, SYSUTCDATETIME()
            FROM @Scrap s;
```

**3i. Move decrement (mutation b)** — in the `UPDATE Lots.Lot SET … PieceCount = PieceCount - ISNULL(@ScrapCount, 0), InventoryAvailable = InventoryAvailable - ISNULL(@ScrapCount, 0), …`, change both `ISNULL(@ScrapCount, 0)` to `@ScrapTotal`.

**3j. Audit activity (mutation c)** — in `@ActivityRaw`, replace the scrap fragment `N', Scrap=' + ISNULL(CAST(@ScrapCount AS NVARCHAR(20)), N'-')` with:
```sql
            + N', Scrap=' + CAST(@ScrapTotal AS NVARCHAR(20))
            + N' (' + CAST((SELECT COUNT(*) FROM @Scrap) AS NVARCHAR(10)) + N' reason'
            + CASE WHEN (SELECT COUNT(*) FROM @Scrap) = 1 THEN N'' ELSE N's' END + N')'
```

**3k. Header** — bump the header to `Version: 1.3` and add a changelog line:
```sql
--              v1.3 (2026-08-06, FAT #2): @ScrapCount -> @ScrapLinesJson. Scrap is
--                  now defect-coded: one Workorder.RejectEvent row per line
--                  (ProductionEventId NULL), LOT decremented once by Σquantity.
--                  Pre-txn: valid JSON, every quantity > 0, every DefectCodeId
--                  active. ScrapCount monotonic guard dropped (per-event model).
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
powershell.exe -ExecutionPolicy Bypass -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_TrimScrap -Force
sqlcmd -S localhost -d MPP_MES_TrimScrap -E -C -b -I -i "sql/tests/0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql"
```
Expected: PASS — all existing Trim OUT tests plus the five new `[TrimOutScrap]` assertions green. (Reset re-applies the repeatable proc.)

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql sql/tests/0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql
git commit -m "feat(trim): defect-coded scrap on Trim OUT — @ScrapLinesJson + inline RejectEvents (#2)"
```

---

### Task 2: NQ + entity script — swap `scrapCount` → `scrapLinesJson`

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/workorder/TrimOut_Record/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/workorder/TrimOut_Record/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/TrimOut/code.py`

**Interfaces:**
- Consumes: `Workorder.TrimOut_Record(@ScrapLinesJson NVARCHAR(MAX))` from Task 1.
- Produces: `BlueRidge.Workorder.TrimOut.record(data, appUserId, terminalLocationId)` where `data["scrapLines"]` is a list of `{defectCodeId, quantity}`; the wrapper `jsonEncode`s it to `:scrapLinesJson`. `data["scrapCount"]` is no longer read.

- [ ] **Step 1: Edit the NQ query.sql** — replace the `@ScrapCount = :scrapCount,` line with:
```sql
    @ScrapLinesJson            = :scrapLinesJson,
```

- [ ] **Step 2: Edit the NQ resource.json** — replace the `scrapCount` parameter object:
```json
      { "type": "Parameter", "identifier": "scrapCount", "sqlType": 2 },
```
with (sqlType 7 = String, matching `DieCastShiftOutput_Record`'s `linesJson`):
```json
      { "type": "Parameter", "identifier": "scrapLinesJson", "sqlType": 7 },
```

- [ ] **Step 3: Edit the entity script** — in `BlueRidge.Workorder.TrimOut.record`, replace the `"scrapCount": d.get("scrapCount"),` params line with:
```python
        "scrapLinesJson":            system.util.jsonEncode(_u(d.get("scrapLines")) or []),
```
and update the docstring's param list from `shotCount, scrapCount,` to `shotCount, scrapLines (list of {defectCodeId, quantity}),`.

- [ ] **Step 4: Scan + verify the NQ loads**

```bash
powershell.exe -ExecutionPolicy Bypass -File ./scan.ps1
```
Then check the gateway log has no "Named query not found" / parse error for `workorder/TrimOut_Record`:
```bash
grep -iE "TrimOut_Record|named query" "C:/Program Files/Inductive Automation/Ignition/logs/wrapper.log" | tail -5
```
Expected: no errors referencing `TrimOut_Record`.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/workorder/TrimOut_Record/query.sql ignition/projects/Core/ignition/named-query/workorder/TrimOut_Record/resource.json ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/TrimOut/code.py
git commit -m "feat(trim): TrimOut NQ + entity script pass scrapLines JSON (#2)"
```

---

### Task 3: New `ScrapLineRow` Perspective component

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow/view.json`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow/resource.json`

**Interfaces:**
- Produces: an embeddable row view. Params (all `paramDirection: "input"`): `index` (int), `defectCodeId` (BIGINT|null), `quantity` (string), `defectOptions` (list of `{label,value}`). Emits **page-scoped** messages: `trimScrapLineChanged` `{index, defectCodeId, quantity}` and `trimScrapLineRemoved` `{index}`.
- Consumes: nothing from the DB (options are passed in from the parent — one query, not one-per-row).

- [ ] **Step 1: Create `resource.json`**

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "view.json"
  ],
  "attributes": {
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-08-06T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create `view.json`** — a flex row: reason dropdown + qty field + remove button. Mirrors `DieCastEntry/CavityLotRow`'s `ScrapDefect1` dropdown + a trash button. Uses `mpp/delete` icon (verify it exists in `ignition/icons/mpp/mpp.svg`; if not, use `mpp/close`).

```json
{
  "custom": {},
  "params": {
    "index": 0,
    "defectCodeId": null,
    "quantity": "",
    "defectOptions": []
  },
  "propConfig": {
    "params.index": { "paramDirection": "input" },
    "params.defectCodeId": { "paramDirection": "input" },
    "params.quantity": { "paramDirection": "input" },
    "params.defectOptions": { "paramDirection": "input" }
  },
  "props": { "defaultSize": { "height": 44, "width": 600 } },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": { "alignItems": "center", "style": { "gap": "8px" } },
    "children": [
      {
        "type": "ia.input.dropdown",
        "meta": { "name": "ReasonDropdown" },
        "position": { "basis": "0", "grow": 1, "shrink": 1 },
        "props": {
          "placeholder": { "text": "Scrap reason" },
          "style": { "classes": "pf-field-input", "minWidth": "160px" }
        },
        "propConfig": {
          "props.options": { "binding": { "type": "property", "config": { "path": "view.params.defectOptions" } } },
          "props.value": { "binding": { "type": "property", "config": { "path": "view.params.defectCodeId" } } }
        },
        "events": {
          "component": {
            "onActionPerformed": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"trimScrapLineChanged\", payload={\"index\": self.view.params.index, \"defectCodeId\": self.props.value, \"quantity\": self.getSibling(\"QtyInput\").props.text}, scope=\"page\")"
              }
            }
          }
        }
      },
      {
        "type": "ia.input.text-field",
        "meta": { "name": "QtyInput" },
        "position": { "basis": "90px", "shrink": 0 },
        "props": {
          "deferUpdates": false,
          "placeholder": "qty",
          "style": { "classes": "pf-field-input" }
        },
        "propConfig": {
          "props.text": { "binding": { "type": "property", "config": { "path": "view.params.quantity" } } }
        },
        "events": {
          "component": {
            "onActionPerformed": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"trimScrapLineChanged\", payload={\"index\": self.view.params.index, \"defectCodeId\": self.getSibling(\"ReasonDropdown\").props.value, \"quantity\": self.props.text}, scope=\"page\")"
              }
            }
          }
        }
      },
      {
        "type": "ia.input.button",
        "meta": { "name": "RemoveButton" },
        "position": { "basis": "44px", "shrink": 0 },
        "props": {
          "text": "",
          "image": { "icon": { "path": "mpp/delete", "color": "var(--mpp-state-bad-fg)" } },
          "style": { "classes": "pf-btn pf-btn-secondary" }
        },
        "events": {
          "component": {
            "onActionPerformed": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"trimScrapLineRemoved\", payload={\"index\": self.view.params.index}, scope=\"page\")"
              }
            }
          }
        }
      }
    ]
  }
}
```

> Note on `deferUpdates: false`: the qty field commits per keystroke, so `getSibling("QtyInput").props.text` read from the dropdown's handler is current (avoids the blur-commit race fixed in `aa2c5ded`). The text-field's own `onActionPerformed` fires on Enter/blur — acceptable because the parent recomputes on every message and `submitTrimOut` re-reads the whole array.

- [ ] **Step 3: Scan + verify the view loads**

```bash
powershell.exe -ExecutionPolicy Bypass -File ./scan.ps1
grep -iE "ScrapLineRow|deserial|View Not Found" "C:/Program Files/Inductive Automation/Ignition/logs/wrapper.log" | tail -5
```
Expected: no deserialization / not-found errors for `ScrapLineRow`.

- [ ] **Step 4: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow/view.json" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow/resource.json"
git commit -m "feat(trim): ScrapLineRow component — reason + qty + remove (#2)"
```

---

### Task 4: `TrimBody` — dynamic scrap-lines section

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TrimBody/view.json`

**Interfaces:**
- Consumes: `ScrapLineRow` (Task 3) messages `trimScrapLineChanged`/`trimScrapLineRemoved`; `BlueRidge.Workorder.TrimOut.record` (Task 2) with `data["scrapLines"]`.
- Produces: nothing downstream.

> **PRE-REQ: Designer must be CLOSED for TrimBody** (file-edit boundary — else its cache races the disk). Only one agent edits views + runs `scan.ps1` at a time.

- [ ] **Step 1: Custom props + bindings** — in `view.custom`, remove `"scrapCount": null` and add:
```json
    "scrapLines": [],
    "defectOptions": []
```
Keep `shotCount`, `lotPieceCount`. In `propConfig`, **remove** the `custom.scrapCount` `onChange` block, and **add** a binding for `defectOptions`:
```json
    "custom.defectOptions": {
      "binding": {
        "type": "expr",
        "config": { "expression": "runScript(\"BlueRidge.Quality.DefectCode.getForDropdown\", 0, \"TrimOut\")" }
      }
    }
```

- [ ] **Step 2: Replace the scrap UI** — replace the `ScrapField` flex container (the one holding `ScrapLabel` + `ScrapCountInput`, ~lines 875–914) with a scrap-lines block: a header label, a flex **repeater** over `scrapLines`, and an **Add** button. The repeater's `props.path` is `BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow`; its `props.instances` is a Script transform on `view.custom.scrapLines` that stamps `index` + `defectOptions` onto each row:

Repeater component:
```json
{
  "type": "ia.display.flex-repeater",
  "meta": { "name": "ScrapRepeater" },
  "position": { "basis": "auto", "shrink": 0 },
  "props": { "direction": "column", "path": "BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow", "style": { "gap": "6px" } },
  "propConfig": {
    "props.instances": {
      "binding": {
        "type": "property",
        "config": { "path": "view.custom.scrapLines" },
        "transforms": [
          {
            "type": "script",
            "code": "\trows = BlueRidge.Common.Util.extractQualifiedValues(value) or []\n\topts = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.defectOptions) or []\n\tout = []\n\tfor i, r in enumerate(rows):\n\t\tr = r or {}\n\t\tout.append({\"index\": i, \"defectCodeId\": r.get(\"defectCodeId\"), \"quantity\": r.get(\"quantity\") or \"\", \"defectOptions\": opts})\n\treturn out"
          }
        ]
      }
    }
  }
}
```

Add button (sibling, after the repeater):
```json
{
  "type": "ia.input.button",
  "meta": { "name": "AddScrapButton" },
  "position": { "basis": "auto", "shrink": 0 },
  "props": { "text": "+ Add scrap reason", "style": { "classes": "pf-btn pf-btn-secondary" } },
  "events": { "component": { "onActionPerformed": { "type": "script", "scope": "G", "config": { "script": "\tself.view.rootContainer.addScrapLine()" } } } }
}
```

Keep the existing **Good** display (whatever shows `view.custom.shotCount`) and the helper text; update the helper text to `"Scrap cannot exceed the LOT's pieces; scrap is deducted from the LOT."`.

- [ ] **Step 3: Parent customMethods** — add four methods to `root.scripts.customMethods` (alongside `submitTrimOut`):

`addScrapLine`:
```python
	rows = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.scrapLines) or []
	rows = list(rows)
	rows.append({"defectCodeId": None, "quantity": ""})
	self.view.custom.scrapLines = rows
```

`recomputeGood`:
```python
	lp = self.view.custom.lotPieceCount
	rows = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.scrapLines) or []
	total = 0
	for r in rows:
		try:
			total += int((r or {}).get("quantity") or 0)
		except (ValueError, TypeError):
			pass
	if lp is None:
		self.view.custom.shotCount = None
	else:
		self.view.custom.shotCount = max(0, int(lp) - total)
```

`onTrimScrapLineChanged` (page message handler — see Step 4 wiring):
```python
	idx = payload.get("index")
	rows = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.scrapLines) or []
	rows = list(rows)
	if idx is None or idx < 0 or idx >= len(rows):
		return
	rows[idx] = {"defectCodeId": payload.get("defectCodeId"), "quantity": payload.get("quantity") or ""}
	self.view.custom.scrapLines = rows
	self.recomputeGood()
```

`onTrimScrapLineRemoved`:
```python
	idx = payload.get("index")
	rows = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.scrapLines) or []
	rows = list(rows)
	if idx is None or idx < 0 or idx >= len(rows):
		return
	del rows[idx]
	self.view.custom.scrapLines = rows
	self.recomputeGood()
```

- [ ] **Step 4: Wire the message handlers** — add two message handlers to the view's `root` `events` (Message events, page scope): `trimScrapLineChanged` → `self.view.rootContainer.onTrimScrapLineChanged(payload)`; `trimScrapLineRemoved` → `self.view.rootContainer.onTrimScrapLineRemoved(payload)`. (Perspective message handlers live under the component's `events.message` with `pageScope: true`; mirror an existing page-scoped handler in this view.)

- [ ] **Step 5: Rewrite `submitTrimOut`** — replace the method body so it builds `scrapLines`, validates, and passes them (derives good exactly as before):
```python
	lotId = self.view.custom.activeLotId
	if lotId is None:
		BlueRidge.Common.Notify.toast("No LOT", "Scan or select a LOT before recording Trim OUT.", "warning")
		return
	operationTemplateId = BlueRidge.Parts.OperationTemplate.getActiveTemplateIdForLot(lotId, "TrimOut")
	if operationTemplateId is None:
		BlueRidge.Common.Notify.toast("Template missing", "No active 'TrimOut' operation template is published.", "error")
		return
	rows = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.scrapLines) or []
	scrapLines = []
	total = 0
	for r in rows:
		r = r or {}
		d = r.get("defectCodeId")
		q = BlueRidge.Common.Util.toIntOrNone(r.get("quantity"))
		if d is None and not q:
			continue  # skip a blank row
		if not q or q <= 0 or d is None:
			BlueRidge.Common.Notify.toast("Incomplete scrap line", "Each scrap line needs a reason and a positive quantity.", "warning")
			return
		scrapLines.append({"defectCodeId": d, "quantity": q})
		total += q
	lp = BlueRidge.Common.Util.toIntOrNone(self.view.custom.lotPieceCount) or 0
	if total > lp:
		BlueRidge.Common.Notify.toast("Too much scrap", "Scrap (%d) exceeds the LOT's pieces (%d)." % (total, lp), "warning")
		return
	good = max(0, lp - total)
	data = {
		"parentLotId": lotId,
		"operationTemplateId": operationTemplateId,
		"shotCount": good,
		"scrapLines": scrapLines,
		"destinationCellLocationId": None,
		"sourceLocationId": self.session.custom.terminal.zoneLocationId,
	}
	res = BlueRidge.Workorder.TrimOut.record(data, self.session.custom.appUserId, (self.session.custom.terminal.terminalLocationId if self.session.custom.terminal else None))
	BlueRidge.Common.Ui.notifyResult(res, "Trim OUT recorded")
	if res.get("Status"):
		self.view.custom.activeLotId = None
		self.view.custom.activeLotName = None
		self.view.custom.outScan = ""
		self.view.custom.shotCount = None
		self.view.custom.lotPieceCount = None
		self.view.custom.scrapLines = []
		self.view.custom.refreshToken = (self.view.custom.refreshToken or 0) + 1
```
Also update the two LOT-load handlers (`outScan` submit + `trimRowSelected`) that currently set `self.view.custom.scrapCount = None` to set `self.view.custom.scrapLines = []` instead.

- [ ] **Step 6: Scan + verify**

```bash
powershell.exe -ExecutionPolicy Bypass -File ./scan.ps1
grep -iE "TrimBody|deserial|View Not Found|Component Error" "C:/Program Files/Inductive Automation/Ignition/logs/wrapper.log" | tail -8
```
Expected: no errors. Load the Trim OUT screen: the reason dropdown lists only Trim (140–145) + plant-wide codes; "+ Add scrap reason" adds a row; entering qty drops Good live; remove works.

- [ ] **Step 7: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TrimBody/view.json"
git commit -m "feat(trim): TrimBody dynamic scrap-reason lines (repeater + add/remove + good-derive) (#2)"
```

---

### Task 5: End-to-end verification

**Files:** none (verification + any fixups).

- [ ] **Step 1: Full SQL suite on a throwaway DB**

```bash
powershell.exe -ExecutionPolicy Bypass -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_TrimScrap -Force -RunTests
```
Expected: exit 0, `050_TrimOut_Record_validation.sql` green (including the five `[TrimOutScrap]` tests). If exit 1 with 0 failures, check for a cleanup FK/sqlcmd error (see `feedback_runtests_exit1_zero_failures`).

- [ ] **Step 2: Live smoke on `MPP_MES_Dev`** (via the gateway) — Trim OUT a scanned LOT with two scrap reasons, then confirm in the DB:
```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -s "|" -Q "SET NOCOUNT ON; SELECT TOP 5 re.LotId, re.DefectCodeId, re.Quantity, re.ProductionEventId, re.Remarks FROM Workorder.RejectEvent re ORDER BY re.Id DESC;"
```
Expected: two fresh rows with `Remarks = 'Trim OUT scrap'`, `ProductionEventId` NULL, correct quantities; the LOT's `PieceCount` reduced by their sum and now sitting in Trim Storage.

- [ ] **Step 3: Dropdown scope check** — on the Trim OUT screen the reason dropdown shows only Trim (140–145) + plant-wide, NOT die-cast/machining codes.

- [ ] **Step 4: Push**

```bash
git push origin jacques/working
```

- [ ] **Step 5: Mark the spec/FAT item done** — update `docs/handoffs/2026-08-05-fat-remaining-handoffs.md` (or the current FAT status note) marking FAT #2 implemented, and commit.

---

## Self-Review Notes

- **Spec coverage:** proc `@ScrapLinesJson` + parse/validate/inline-reject/aggregate-decrement (Task 1) ✓; NQ+script swap (Task 2) ✓; dynamic multi-line UI scoped to `TrimOut` (Tasks 3–4) ✓; all five spec test cases (Task 1 tests 7–11) ✓; verification incl. dropdown scope (Task 5) ✓.
- **Decision locked (spec left to build time):** `RejectEvent.ProductionEventId = NULL` — documented in the proc comment + asserted in test 7.
- **Type consistency:** `data["scrapLines"]` = list of `{defectCodeId, quantity}` everywhere (view → entity script → `jsonEncode` → `@ScrapLinesJson` → `OPENJSON $.defectCodeId/$.quantity`); messages `trimScrapLineChanged {index, defectCodeId, quantity}` / `trimScrapLineRemoved {index}` consistent across `ScrapLineRow` (emit) and `TrimBody` (handle).
- **Open verification item for the implementer:** confirm the `mpp/delete` icon exists in `ignition/icons/mpp/mpp.svg` (Task 3 Step 2); fall back to `mpp/close` if not.
