# Required Supplier Lot on Purchased-Part Check-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An operator adding a box of purchased parts from the Line Inventory panel or the Cutover Scan screen must supply the supplier lot number, by scan or keyboard, or press **No lot on box**.

**Architecture:** The rule lives in `Lots.Lot_Create` behind two opt-in parameters (`@RequireVendorLot`, `@VendorLotAbsent`), so existing callers and tests are unaffected. Python entity scripts only carry the values and the flag. A new popup view `AddLotBox` replaces the numpad-only `AddLotQty` for both `+ LOT` and one-tap rows. Edits to existing views are handed to Designer.

**Tech Stack:** SQL Server 2022 (repeatable proc + `sqlcmd` test harness), Ignition 8.3 Perspective (file-based views, named queries, Jython 2.7 script modules).

**Spec:** `docs/superpowers/specs/2026-10-05-required-supplier-lot-on-purchased-parts-design.md`

## Global Constraints

- Branch `jacques/working`. Run `git fetch` and check `main` before starting. Stage **explicit paths only** (never `git add -A` / `-u`). No `Co-Authored-By` trailer.
- No versioned migration. `Lots.Lot.VendorLotNumber NVARCHAR(100) NULL` already exists.
- Stored marker for an absent supplier lot is exactly `NONE` (ASCII), defined **only** in the proc.
- Rejection message is exactly `Supplier lot number is required.`
- No `OUTPUT` parameters. Every rejecting validation runs **before** `BEGIN TRANSACTION` and ends with the four-column status row `Status, Message, NewId, MintedLotName`.
- `EXEC` arguments are literals or `@variables` only.
- No business rule in Python or in a binding. View-side checks are conveniences; the proc decides.
- **Never run `Run-Tests.ps1` against `MPP_MES_Dev`** -- it drops its target. It defaults to the throwaway `MPP_MES_Test`.
- Existing `view.json` files are **not** edited by file. New views are written as files (`view.json` + `resource.json`, scope `G`), then `.\scan.ps1`. Never `pull.ps1`.
- Event-script bodies start with a tab. `system.perspective.*` from an event needs `"scope": "G"`. Conditional flex children use `position.display`, not `meta.visible`. `bidirectional: true` goes **inside** the binding `config`.
- Mutations take `appUserId` from the caller: `BlueRidge.Common.Session.currentAppUserId(self.session)`.
- Out of scope: Inventory Manager receive form, Receiving Dock, reports, labels, back-fill.

## File Map

| File | Action | Responsibility |
|---|---|---|
| `sql/migrations/repeatable/R__Lots_Lot_Create.sql` | Modify | The rule: normalise, absent marker, required rejection |
| `sql/tests/0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql` | Create | Proves the rule |
| `ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql` + `resource.json` | Modify | Pass the two new parameters |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | Modify | `create`, `checkInBox`, `checkInAndNotify` carry the values |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py` | Modify | `addBox` requires; `setVendorLotAbsent` |
| `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json` | Modify | Declare `cutover.purchased.vendorLotAbsent` |
| `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AddLotBox/` | Create | The new popup |
| `notes/2026-10-05_supplier-lot-designer-handoff.md` | Create | Designer steps for `LineInventoryRow` + 3 Cutover views |

**Sequencing note.** `checkInBox` gains `requireVendorLot` defaulting to **False** in Task 2, so the existing `LineInventoryRow` / `AddLotQty` path keeps working on the shared gateway while the new popup is built. Task 6 flips the default to True after the Designer edit lands. Cutover Scan enforces as soon as Task 4 deploys (accepted in spec section 7).

---

### Task 1: `Lots.Lot_Create` requires a supplier lot on request

**Files:**
- Create: `sql/tests/0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql` (header lines 4-9, parameter list line 113, `@Params` lines 125-133, new block after line 206)

**Interfaces:**
- Produces: `Lots.Lot_Create` accepts `@RequireVendorLot BIT = 0` and `@VendorLotAbsent BIT = 0`. Result row unchanged: `Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50)`.

- [ ] **Step 1: Record the baseline assertion count**

Run from `sql/tests`:

```powershell
.\Run-Tests.ps1
```

Write down the `Total:` and `Failed:` numbers from the summary box. A later run that exits 1 with 0 failures means a file threw and every batch after it never ran, so the **Total** is what gets compared.

- [ ] **Step 2: Write the failing test**

Create `sql/tests/0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql`:

```sql
-- =============================================
-- File:         0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-05
-- Description:  Lots.Lot_Create v1.8 -- @RequireVendorLot / @VendorLotAbsent.
--               Both default 0, so a caller that passes neither behaves as
--               before. With @RequireVendorLot = 1 a missing or blank supplier
--               lot is rejected before any transaction opens. @VendorLotAbsent
--               = 1 stores the marker NONE, replacing anything supplied.
--               Fixture: a dedicated Item (P-REQVLOT) made eligible at cell
--               MA1-COMPBR-AOUT by a non-consumption-point ItemLocation row,
--               so neither quantity cap applies.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql';
GO

-- ---- cleanup (FK-safe: closure rows before LOTs) ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-REQVLOT');
IF @ItC IS NOT NULL
BEGIN
    DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @ItC;
    DELETE m  FROM Lots.LotMovement m  INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @ItC;
    DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @ItC;
    DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.ItemId = @ItC;
    DELETE FROM Lots.Lot WHERE ItemId = @ItC;
    DELETE FROM Parts.ItemLocation WHERE ItemId = @ItC;
END
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-REQVLOT')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (3, N'P-REQVLOT', N'Required supplier lot test item', 1, NULL, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-REQVLOT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
VALUES (@Item, @Cell, 0, @Now);
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
IF OBJECT_ID(N'tempdb..#VL') IS NOT NULL DROP TABLE #VL;
CREATE TABLE #VL (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
INSERT INTO #VL VALUES (N'ITEM', @Item), (N'CELL', @Cell), (N'RECV', @Received);
EXEC test.Assert_IsNotNull @TestName = N'[ReqVendorLot] fixture cell MA1-COMPBR-AOUT exists', @Value = @Cell;
GO

-- =============================================
-- Test 1: flag off, no supplier lot -> created, stored NULL (unchanged behaviour)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r1 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1;
DECLARE @ok1 BIT = (SELECT Status FROM @r1);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag off, no supplier lot: created', @Condition = @ok1;
DECLARE @v1 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r1 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] flag off, no supplier lot: stored NULL', @Expected = N'<null>', @Actual = @v1;
GO

-- =============================================
-- Test 2: flag on, no supplier lot -> REJECTED, nothing minted
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r2 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @RequireVendorLot = 1;
DECLARE @s2 BIT = (SELECT Status FROM @r2);
DECLARE @s2cond BIT = CASE WHEN @s2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on, no supplier lot: rejected (Status 0)', @Condition = @s2cond;
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @r2);
EXEC test.Assert_Contains @TestName = N'[ReqVendorLot] rejection names the supplier lot', @HaystackStr = @m2, @NeedleStr = N'Supplier lot number is required';
DECLARE @cnt2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Item);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] rejection minted nothing', @Expected = N'1', @Actual = @cnt2;
GO

-- =============================================
-- Test 3: flag on, whitespace-only supplier lot -> REJECTED
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r3 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'   ', @AppUserId = 1, @RequireVendorLot = 1;
DECLARE @s3 BIT = (SELECT Status FROM @r3);
DECLARE @s3cond BIT = CASE WHEN @s3 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on, whitespace only: rejected (Status 0)', @Condition = @s3cond;
DECLARE @cnt3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Item);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] whitespace rejection minted nothing', @Expected = N'1', @Actual = @cnt3;
GO

-- =============================================
-- Test 4: flag on, padded value -> created, stored trimmed
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r4 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'  AB-123 ', @AppUserId = 1, @RequireVendorLot = 1;
DECLARE @ok4 BIT = (SELECT Status FROM @r4);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on with a value: created', @Condition = @ok4;
DECLARE @v4 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r4 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] value stored trimmed', @Expected = N'AB-123', @Actual = @v4;
GO

-- =============================================
-- Test 5: flag on, absent, no value -> created, stored NONE
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r5 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @RequireVendorLot = 1, @VendorLotAbsent = 1;
DECLARE @ok5 BIT = (SELECT Status FROM @r5);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on, absent: created', @Condition = @ok5;
DECLARE @v5 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r5 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] absent stored as NONE', @Expected = N'NONE', @Actual = @v5;
GO

-- =============================================
-- Test 6: flag on, absent AND a value -> absent wins, stored NONE
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r6 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'ZZ-9', @AppUserId = 1, @RequireVendorLot = 1, @VendorLotAbsent = 1;
DECLARE @ok6 BIT = (SELECT Status FROM @r6);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] absent with a value: created', @Condition = @ok6;
DECLARE @v6 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r6 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] absent replaces a supplied value', @Expected = N'NONE', @Actual = @v6;
GO

-- =============================================
-- Test 7: flag off, absent -> stored NONE (absent does not depend on the flag)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r7 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r7 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @VendorLotAbsent = 1;
DECLARE @v7 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r7 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] flag off, absent: stored NONE', @Expected = N'NONE', @Actual = @v7;
GO

-- =============================================
-- Test 8: flag off, whitespace-only value -> created, stored NULL (not spaces)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r8 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r8 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'  ', @AppUserId = 1;
DECLARE @v8 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r8 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] flag off, whitespace only: stored NULL', @Expected = N'<null>', @Actual = @v8;
GO

-- ---- cleanup ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-REQVLOT');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @ItC;
DELETE m  FROM Lots.LotMovement m  INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @ItC;
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @ItC;
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.ItemId = @ItC;
DELETE FROM Lots.Lot WHERE ItemId = @ItC;
DELETE FROM Parts.ItemLocation WHERE ItemId = @ItC;
IF OBJECT_ID(N'tempdb..#VL') IS NOT NULL DROP TABLE #VL;
GO
```

The file records **16** assertions. If the `Parts.ItemLocation` insert is refused because `MaxQuantity` is required, add `MaxQuantity` with `NULL` to the column list; `IsConsumptionPoint = 0` must stay, because a consumption point would apply the quantity cap.

- [ ] **Step 3: Run it and confirm it fails for the right reason**

```powershell
.\Run-Tests.ps1 -Filter "043_Lot_Create_require_vendor_lot"
```

Expected: the file throws at Test 2 with `@RequireVendorLot is not a parameter for procedure Lot_Create`. Only the fixture assertion and Test 1's two assertions are recorded.

- [ ] **Step 4: Add the parameters to the proc**

In `sql/migrations/repeatable/R__Lots_Lot_Create.sql`, replace the last parameter line:

```sql
    @ProducedAtLocationId BIGINT      = NULL   -- cutover: the die cast machine off the tag (0082). NULL for every normal mint.
```

with:

```sql
    @ProducedAtLocationId BIGINT      = NULL,  -- cutover: the die cast machine off the tag (0082). NULL for every normal mint.
    @RequireVendorLot   BIT           = 0,     -- v1.8: 1 = reject when no supplier lot is supplied. Set by the operator check-in screens.
    @VendorLotAbsent    BIT           = 0      -- v1.8: 1 = the box carries no supplier lot; store the marker NONE.
```

- [ ] **Step 5: Add both to the failure-log parameter capture**

Replace:

```sql
               @ProducedAtLocationId AS ProducedAtLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```

with:

```sql
               @ProducedAtLocationId AS ProducedAtLocationId,
               @RequireVendorLot AS RequireVendorLot, @VendorLotAbsent AS VendorLotAbsent
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```

- [ ] **Step 6: Add the rule**

Insert this block immediately after the `AppUser not found.` validation block (it ends at the `END` on line 206) and before the comment `-- Die-cast-origin determination`. It must sit after the AppUser check because `Audit.Audit_LogFailure` has an FK on the user.

```sql
        -- ---- 2a. Supplier lot (v1.8) ----
        -- Normalised on every call: a whitespace-only value is no value.
        SET @VendorLotNumber = NULLIF(LTRIM(RTRIM(@VendorLotNumber)), N'');

        -- The box carries no supplier lot. The marker lives here and nowhere
        -- else, so a report can tell a recorded absence from a real number.
        -- It replaces anything supplied alongside it.
        IF @VendorLotAbsent = 1
            SET @VendorLotNumber = N'NONE';

        IF @RequireVendorLot = 1 AND @VendorLotNumber IS NULL
        BEGIN
            SET @Message = N'Supplier lot number is required.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

```

- [ ] **Step 7: Update the header**

Change `-- Modified:    2026-09-18` to `-- Modified:    2026-10-05` and `-- Version:     1.7` to `-- Version:     1.8`. Insert above the `v1.7` paragraph:

```sql
--              v1.8 (2026-10-05, Jacques): @RequireVendorLot + @VendorLotAbsent.
--              Both default 0, so every existing caller is unaffected. With
--              @RequireVendorLot = 1 a missing or blank supplier lot is
--              rejected BEFORE BEGIN TRANSACTION. @VendorLotAbsent = 1 stores
--              the marker NONE (the box has no supplier lot) and replaces any
--              value supplied with it. @VendorLotNumber is now trimmed on every
--              call and a whitespace-only value is stored as NULL.
--
```

- [ ] **Step 8: Run the new test**

```powershell
.\Run-Tests.ps1 -Filter "043_Lot_Create_require_vendor_lot"
```

Expected: `Total: 16`, `Failed: 0`.

- [ ] **Step 9: Run the full suite and compare the count**

```powershell
.\Run-Tests.ps1
```

Expected: `Failed:` unchanged from Step 1 and `Total:` equal to the Step 1 total **plus 16**. A smaller total means a file threw.

- [ ] **Step 10: Apply the proc to the dev database**

From the repo root. This alters one proc and touches no data.

```powershell
sqlcmd.exe -S localhost -d MPP_MES_Dev -i sql\migrations\repeatable\R__Lots_Lot_Create.sql -b -I -C
```

Expected: no output, exit code 0.

- [ ] **Step 11: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/tests/0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql
git commit -m "feat(lots): Lot_Create can require a supplier lot number"
```

---

### Task 2: Named query and entity script carry the two values

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` (`create` lines 36-76, `checkInBox` / `checkInAndNotify` lines 738-765)

**Interfaces:**
- Consumes: `Lots.Lot_Create @RequireVendorLot BIT, @VendorLotAbsent BIT` (Task 1).
- Produces:
  - `BlueRidge.Lots.Lot.create(data, appUserId, terminalLocationId, lotName)` reads `data["requireVendorLot"]` and `data["vendorLotAbsent"]` (truthy -> 1).
  - `BlueRidge.Lots.Lot.checkInBox(itemId, locationId, pieceCount, appUserId=None, terminalLocationId=None, vendorLotNumber=None, vendorLotAbsent=False, requireVendorLot=False)`
  - `BlueRidge.Lots.Lot.checkInAndNotify(itemId, locationId, pieceCount, description, appUserId=None, terminalLocationId=None, vendorLotNumber=None, vendorLotAbsent=False, requireVendorLot=False)` -> the `create()` status dict.

- [ ] **Step 1: Pass the parameters in the named query**

In `query.sql`, replace the last line:

```sql
    @ProducedAtLocationId = :producedAtLocationId
```

with:

```sql
    @ProducedAtLocationId = :producedAtLocationId,
    @RequireVendorLot   = :requireVendorLot,
    @VendorLotAbsent    = :vendorLotAbsent
```

- [ ] **Step 2: Declare them in `resource.json`**

Append to the `parameters` array, after the `producedAtLocationId` entry. `sqlType: 2` is the same integer type `depositToStorage` uses for its BIT.

```json
      {
        "type": "Parameter",
        "identifier": "requireVendorLot",
        "sqlType": 2
      },
      {
        "type": "Parameter",
        "identifier": "vendorLotAbsent",
        "sqlType": 2
      }
```

Leave `type` as `Query` (the proc returns a status row).

- [ ] **Step 3: Send them from `create()`**

In `code.py`, in the `params` dict of `create`, after the `"producedAtLocationId"` entry add:

```python
        # v1.8: the operator check-in screens require a supplier lot. Absent =
        # the box carries none and the proc stores its own marker. 0/1 -> BIT.
        "requireVendorLot":   1 if d.get("requireVendorLot") else 0,
        "vendorLotAbsent":    1 if d.get("vendorLotAbsent") else 0,
```

Add `requireVendorLot, vendorLotAbsent` to the field list in the docstring.

- [ ] **Step 4: Replace `checkInBox` and `checkInAndNotify`**

```python
def checkInBox(itemId, locationId, pieceCount, appUserId=None, terminalLocationId=None,
               vendorLotNumber=None, vendorLotAbsent=False, requireVendorLot=False):
    """Create one Received LOT of pieceCount at locationId (one box = one LOT).
       Thin wrapper over create(); Lot_Create's eligibility and cap gates apply.
       vendorLotNumber is the supplier's lot off the box; vendorLotAbsent means
       the box carries none. requireVendorLot asks the PROC to refuse a box
       with neither -- this function decides nothing itself.
       Returns the create() status dict."""
    data = {
        "itemId":            _u(itemId),
        "lotOriginTypeId":   getOriginTypeIdByCode("Received"),
        "currentLocationId": _u(locationId),
        "pieceCount":        _u(pieceCount),
        "vendorLotNumber":   _u(vendorLotNumber),
        "vendorLotAbsent":   bool(_u(vendorLotAbsent)),
        "requireVendorLot":  bool(_u(requireVendorLot)),
    }
    return create(data, appUserId, terminalLocationId)


def checkInAndNotify(itemId, locationId, pieceCount, description, appUserId=None, terminalLocationId=None,
                     vendorLotNumber=None, vendorLotAbsent=False, requireVendorLot=False):
    """Perspective-session helper for the Line Inventory add popups:
       check in one box, toast the outcome, raise the CRT notice, and tell the
       page to refresh. Callers pass the session's app user id and the terminal id.
       Returns the create() status dict."""
    res = checkInBox(itemId, locationId, pieceCount, appUserId, terminalLocationId,
                     vendorLotNumber, vendorLotAbsent, requireVendorLot)
    lotText = "no supplier lot" if vendorLotAbsent else ("supplier lot %s" % vendorLotNumber if vendorLotNumber else "")
    body = "LOT %s - %s - %s pcs" % ((res or {}).get("MintedLotName") or "",
                                     description or "", _thousands(pieceCount))
    if lotText:
        body = "%s - %s" % (body, lotText)
    BlueRidge.Common.Ui.notifyResult(res, "Box checked in", body)
    if res and res.get("Status"):
        BlueRidge.Common.Ui.crtNotice(crtNamesFor([res.get("NewId")]))
        system.perspective.sendMessage("inventoryChanged",
                                       payload={"lotId": res.get("NewId")}, scope="page")
    return res
```

- [ ] **Step 5: Scan and verify from the Script Console**

```powershell
.\scan.ps1
```

In Designer's Script Console (Core project), using a purchased item id and line location id that the Line Inventory panel currently lists (read them from `lots/Lot_GetLineInventorySummary` or the panel's row params):

```python
r = BlueRidge.Lots.Lot.checkInBox(ITEM_ID, LINE_LOCATION_ID, 1, 1, None, None, False, True)
print r
```

Expected: `Status` 0 and `Message` `Supplier lot number is required.` Nothing is created. Then confirm the default still works for the existing buttons: open a terminal's Line Inventory panel and add a box with the existing `+ LOT` popup; it succeeds as before.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql ignition/projects/Core/ignition/named-query/lots/Lot_Create/resource.json ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py
git commit -m "feat(ignition): check-in carries the supplier lot to Lot_Create"
```

---

### Task 3: The `AddLotBox` popup

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AddLotBox/view.json`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AddLotBox/resource.json`

**Interfaces:**
- Consumes: `BlueRidge.Lots.Lot.checkInAndNotify(...)` (Task 2); `BlueRidge.Common.Session.currentAppUserId(session)`; embedded views `BlueRidge/Components/PlantFloor/Keyboard` and `.../Numpad`, each taking `params.messageName` and sending page-scoped `{action, key}` where `action` is `key`, `space`, `backspace`, `clear` or `enter`.
- Produces: a view opened as popup id `mpp-add-lot-box` with params `itemId`, `description`, `locationId`, `boxQuantity` (null when the part has no box quantity).

Reference for the focus-tracking + embedded-keyboard pattern: `Components/Popups/RegisterOperator/view.json`.

- [ ] **Step 1: Write `resource.json`**

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
    "lastModificationSignature": "",
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-10-05T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Write `view.json`**

```json
{
  "custom": {
    "vendorLot": "",
    "absent": false,
    "qty": "",
    "activeField": "lot",
    "busyUntil": 0
  },
  "params": {
    "description": "",
    "itemId": null,
    "locationId": null,
    "boxQuantity": null
  },
  "propConfig": {
    "params.description": {"paramDirection": "input"},
    "params.itemId": {"paramDirection": "input"},
    "params.locationId": {"paramDirection": "input"},
    "params.boxQuantity": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {"height": 740, "width": 840}
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"gap": "10px", "padding": "16px", "classes": "pf-inv-panel"}
    },
    "events": {
      "system": {
        "onStartup": {
          "type": "script",
          "scope": "G",
          "config": {
            "script": "\tbq = self.view.params.boxQuantity\n\tif bq is not None:\n\t\ttry:\n\t\t\tself.view.custom.qty = \"%d\" % int(bq)\n\t\texcept:\n\t\t\tself.view.custom.qty = \"\"\n\ttry:\n\t\tself.getChild(\"LotRow\").getChild(\"LotInput\").focus()\n\texcept:\n\t\tpass"
          }
        }
      }
    },
    "scripts": {
      "customMethods": [
        {
          "name": "submit",
          "params": [],
          "script": "\tnowMs = system.date.toMillis(system.date.now())\n\tif nowMs < (self.view.custom.busyUntil or 0):\n\t\treturn\n\tlot = (\"%s\" % (self.view.custom.vendorLot or \"\")).strip()\n\tabsent = bool(self.view.custom.absent) and lot == \"\"\n\tif lot == \"\" and not absent:\n\t\tself.view.custom.activeField = \"lot\"\n\t\tBlueRidge.Common.Notify.toast(\"Supplier lot required\", \"Scan or type the supplier lot, or tap No lot on box.\", \"warning\")\n\t\treturn\n\traw = (\"%s\" % (self.view.custom.qty or \"\")).strip()\n\tif not raw.isdigit() or int(raw) <= 0:\n\t\tself.view.custom.activeField = \"qty\"\n\t\tBlueRidge.Common.Notify.toast(\"Quantity required\", \"Enter how many pieces are in the box.\", \"warning\")\n\t\treturn\n\t# double-tap guard: the button stays disabled for 2 s\n\tself.view.custom.busyUntil = nowMs + 2000\n\ttermId = None\n\ttry:\n\t\ttermId = self.session.custom.terminal.terminalLocationId\n\texcept:\n\t\ttermId = None\n\tappUserId = BlueRidge.Common.Session.currentAppUserId(self.session)\n\tres = BlueRidge.Lots.Lot.checkInAndNotify(self.view.params.itemId, self.view.params.locationId, int(raw), self.view.params.description, appUserId, termId, lot or None, absent, True)\n\tif res and res.get(\"Status\"):\n\t\tsystem.perspective.closePopup(\"mpp-add-lot-box\")"
        }
      ],
      "extensionFunctions": null,
      "messageHandlers": [
        {
          "messageType": "addLotBoxLotKey",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\ta = payload.get(\"action\") if payload else None\n\tv = self.view.custom.vendorLot or \"\"\n\tif a == \"key\" or a == \"space\":\n\t\tif len(v) < 100:\n\t\t\tself.view.custom.vendorLot = v + (\"%s\" % payload.get(\"key\"))\n\t\t\tself.view.custom.absent = False\n\telif a == \"backspace\":\n\t\tself.view.custom.vendorLot = v[:-1]\n\telif a == \"clear\":\n\t\tself.view.custom.vendorLot = \"\"\n\telif a == \"enter\":\n\t\tself.view.custom.activeField = \"qty\""
        },
        {
          "messageType": "addLotBoxQtyKey",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\ta = payload.get(\"action\") if payload else None\n\tq = self.view.custom.qty or \"\"\n\tif a == \"key\":\n\t\tif len(q) < 6:\n\t\t\tself.view.custom.qty = q + (\"%s\" % payload.get(\"key\"))\n\telif a == \"backspace\":\n\t\tself.view.custom.qty = q[:-1]\n\telif a == \"clear\":\n\t\tself.view.custom.qty = \"\"\n\telif a == \"enter\":\n\t\tself.submit()"
        }
      ]
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": {"name": "Title"},
        "position": {"shrink": 0},
        "props": {"text": "Add LOT", "style": {"classes": "pf-inv-title"}}
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "Part"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-sub"}},
        "propConfig": {
          "props.text": {"binding": {"type": "expr", "config": {"expression": "{view.params.description}"}}}
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "LotRow"},
        "position": {"basis": "52px", "shrink": 0},
        "props": {"alignItems": "center", "style": {"gap": "10px"}},
        "children": [
          {
            "type": "ia.display.label",
            "meta": {"name": "LotCaption"},
            "position": {"basis": "130px", "shrink": 0},
            "props": {"text": "Supplier lot", "style": {"classes": "pf-inv-sub"}}
          },
          {
            "type": "ia.input.text-field",
            "meta": {"name": "LotInput"},
            "position": {"basis": "0", "grow": 1},
            "props": {
              "deferUpdates": false,
              "style": {"fontSize": "22px", "padding": "6px 12px", "height": "48px"}
            },
            "propConfig": {
              "props.text": {
                "binding": {"type": "property", "config": {"path": "view.custom.vendorLot", "bidirectional": true}}
              },
              "props.placeholder": {
                "binding": {"type": "expr", "config": {"expression": "if({view.custom.absent} && len(trim({view.custom.vendorLot})) = 0, \"No lot on box\", \"Scan or type the supplier lot\")"}}
              },
              "props.style.border": {
                "binding": {"type": "expr", "config": {"expression": "if({view.custom.activeField} = \"lot\", \"2px solid var(--mpp-text-accent)\", \"1px solid var(--mpp-border-subtle)\")"}}
              }
            },
            "events": {
              "dom": {
                "onFocus": {
                  "type": "script",
                  "scope": "G",
                  "config": {"script": "\tself.view.custom.activeField = \"lot\""}
                },
                "onKeyDown": {
                  "type": "script",
                  "scope": "G",
                  "config": {"script": "\tif event.key == \"Enter\":\n\t\tself.view.custom.activeField = \"qty\""}
                }
              }
            }
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "NoLot"},
            "position": {"basis": "170px", "shrink": 0},
            "props": {"text": "No lot on box", "style": {"minHeight": "48px"}},
            "propConfig": {
              "props.style.classes": {
                "binding": {"type": "expr", "config": {"expression": "if({view.custom.absent} && len(trim({view.custom.vendorLot})) = 0, \"pf-btn pf-btn-primary\", \"pf-btn pf-btn-secondary\")"}}
              }
            },
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tself.view.custom.vendorLot = \"\"\n\tself.view.custom.absent = True\n\tself.view.custom.activeField = \"qty\""}}}}
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "QtyRow"},
        "position": {"basis": "52px", "shrink": 0},
        "props": {"alignItems": "center", "style": {"gap": "10px"}},
        "children": [
          {
            "type": "ia.display.label",
            "meta": {"name": "QtyCaption"},
            "position": {"basis": "130px", "shrink": 0},
            "props": {"text": "Quantity", "style": {"classes": "pf-inv-sub"}}
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "QtyDisplay"},
            "position": {"basis": "0", "grow": 1},
            "props": {"style": {"classes": "pf-inv-qty", "fontSize": "30px", "padding": "6px 12px", "cursor": "pointer"}},
            "propConfig": {
              "props.text": {"binding": {"type": "expr", "config": {"expression": "if(len({view.custom.qty}) = 0, \"0\", {view.custom.qty})"}}},
              "props.style.border": {
                "binding": {"type": "expr", "config": {"expression": "if({view.custom.activeField} = \"qty\", \"2px solid var(--mpp-text-accent)\", \"1px solid var(--mpp-border-subtle)\")"}}
              }
            },
            "events": {
              "dom": {
                "onClick": {
                  "type": "script",
                  "scope": "G",
                  "config": {"script": "\tself.view.custom.activeField = \"qty\""}
                }
              }
            }
          }
        ]
      },
      {
        "type": "ia.display.view",
        "meta": {"name": "KeyboardHost"},
        "position": {"basis": "424px", "shrink": 0},
        "props": {
          "path": "BlueRidge/Components/PlantFloor/Keyboard",
          "params": {"messageName": "addLotBoxLotKey"}
        },
        "propConfig": {
          "position.display": {"binding": {"type": "expr", "config": {"expression": "{view.custom.activeField} = \"lot\""}}}
        }
      },
      {
        "type": "ia.display.view",
        "meta": {"name": "NumpadHost"},
        "position": {"basis": "424px", "shrink": 0},
        "props": {
          "path": "BlueRidge/Components/PlantFloor/Numpad",
          "params": {"messageName": "addLotBoxQtyKey"}
        },
        "propConfig": {
          "position.display": {"binding": {"type": "expr", "config": {"expression": "{view.custom.activeField} = \"qty\""}}}
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "Buttons"},
        "position": {"shrink": 0},
        "props": {"style": {"gap": "10px"}},
        "children": [
          {
            "type": "ia.input.button",
            "meta": {"name": "Cancel"},
            "position": {"basis": "0", "grow": 1},
            "props": {"text": "Cancel", "style": {"classes": "pf-btn pf-btn-secondary", "minHeight": "44px"}},
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tsystem.perspective.closePopup(\"mpp-add-lot-box\")"}}}}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "Add"},
            "position": {"basis": "0", "grow": 1},
            "props": {"style": {"classes": "pf-btn pf-btn-primary", "minHeight": "44px"}},
            "propConfig": {
              "props.text": {"binding": {"type": "expr", "config": {"expression": "\"Add \" + if(len({view.custom.qty}) = 0, \"0\", {view.custom.qty}) + \" pcs\""}}},
              "props.enabled": {"binding": {"type": "expr", "config": {"expression": "toMillis(now(500)) > {view.custom.busyUntil} && (len(trim({view.custom.vendorLot})) > 0 || {view.custom.absent}) && toInt({view.custom.qty}, 0) > 0"}}}
            },
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tself.view.rootContainer.submit()"}}}}
          }
        ]
      }
    ]
  }
}
```

Notes for the implementer:
- Both keypad hosts use a 424 px basis so the popup does not change height when the keypad swaps (the keyboard's own content is 350 px and centres).
- "Absent" only counts while the supplier lot is blank. A wedge scan types straight into `LotInput` without passing through the message handler, so every place that reads `absent` also checks the text is empty (`submit`, the placeholder, the button highlight). That is why no change-script is needed to clear it.
- The Add button's `enabled` expression is a convenience. The proc refuses a box with no supplier lot regardless.

- [ ] **Step 3: Validate the JSON and scan**

```powershell
python -c "import json,sys; json.load(open(r'ignition\projects\MPP\com.inductiveautomation.perspective\views\BlueRidge\Components\PlantFloor\AddLotBox\view.json', encoding='utf-8')); print('ok')"
.\scan.ps1
```

Expected: `ok`, and the scan reports success. Confirm the file has no BOM and every `events` entry has a `scope` key (a missing one leaves the view stuck on "loading").

- [ ] **Step 4: Open the popup without touching the row view**

Nothing opens this popup until the Task 5 Designer edit, so exercise it in Designer's preview mode with the view params set by hand (do not save the view afterwards):

- `itemId` and `locationId` from a Line Inventory row, `description` any text, `boxQuantity` `2500`.

Check, in order:

1. Quantity shows `2500`; the supplier lot field is highlighted and the QWERTY keyboard is showing; Add is disabled.
2. Type `AB12` on the on-screen keyboard: the field shows `AB12`; Add becomes enabled.
3. Press Enter on the on-screen keyboard: the numpad replaces the keyboard and the quantity is highlighted.
4. Tap the supplier lot field: the keyboard returns.
5. Clear the field, tap **No lot on box**: the placeholder reads `No lot on box`, the button turns primary, the numpad shows, Add is enabled.
6. With a `boxQuantity` of null the quantity starts at `0` and Add stays disabled until a quantity is keyed.

If a view renders as a Component Error, read the gateway `wrapper.log` for the GSON path before changing anything.

- [ ] **Step 5: Verify a real add in SQL**

Confirm the write in the database rather than from the screen. In the same Designer preview, add one box with supplier lot `AB12` and one with **No lot on box** (these create real LOTs in `MPP_MES_Dev`; note their names so they can be closed afterwards):

```sql
SELECT TOP 2 l.LotName, l.PieceCount, l.VendorLotNumber
FROM Lots.Lot l
ORDER BY l.Id DESC;
```

Expected: one row with `VendorLotNumber = 'AB12'` and one with `NONE`.

- [ ] **Step 6: Commit**

Check `git diff --stat` first: the view must contain no live data rows.

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AddLotBox/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AddLotBox/resource.json
git commit -m "feat(ignition): Add LOT popup captures the supplier lot"
```

---

### Task 4: Cutover Scan requires the supplier lot

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py` (`_EMPTY` lines 205-206, `addBox` lines 565-610)
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json` (`custom.cutover.purchased`)

**Interfaces:**
- Consumes: `BlueRidge.Lots.Lot.create(data, ...)` reading `requireVendorLot` / `vendorLotAbsent` (Task 2).
- Produces: `BlueRidge.Cutover.Scan.setVendorLotAbsent(session)` -> `{Status, Message}`; session state key `session.custom.cutover.purchased.vendorLotAbsent` (bool).

- [ ] **Step 1: Declare the session property**

In `props.json`, in `custom.cutover.purchased`, add the key after `vendorLot`:

```json
      "purchased": {
        "itemId": null,
        "partDescription": "",
        "partNumber": "",
        "qty": "",
        "vendorLot": "",
        "vendorLotAbsent": false
      },
```

- [ ] **Step 2: Add the key to the empty shape**

In `code.py`, replace:

```python
    "purchased": {"partNumber": "", "partDescription": "", "itemId": None,
                  "qty": "", "vendorLot": ""},
```

with:

```python
    "purchased": {"partNumber": "", "partDescription": "", "itemId": None,
                  "qty": "", "vendorLot": "", "vendorLotAbsent": False},
```

- [ ] **Step 3: Require it in `addBox`**

Replace the `create` call in `addBox`:

```python
    res = BlueRidge.Lots.Lot.create({
        "itemId": itemId,
        "lotOriginTypeId": BlueRidge.Lots.Lot.getOriginTypeIdByCode("Received"),
        "currentLocationId": s.get("destinationLocationId"),
        "pieceCount": qty,
        "vendorLotNumber": (p.get("vendorLot") or "").strip() or None,
    }, appUserId, terminalLocationId)
```

with:

```python
    # The supplier lot is required here; the PROC refuses a box with neither a
    # lot nor the explicit "no lot on box" answer. Absent only counts while the
    # field is blank -- a lot typed or scanned after the button wins.
    vendorLot = (p.get("vendorLot") or "").strip()
    res = BlueRidge.Lots.Lot.create({
        "itemId": itemId,
        "lotOriginTypeId": BlueRidge.Lots.Lot.getOriginTypeIdByCode("Received"),
        "currentLocationId": s.get("destinationLocationId"),
        "pieceCount": qty,
        "vendorLotNumber": vendorLot or None,
        "vendorLotAbsent": bool(p.get("vendorLotAbsent")) and vendorLot == "",
        "requireVendorLot": True,
    }, appUserId, terminalLocationId)
```

And replace the reset of `st["purchased"]` further down in the same function:

```python
    st["purchased"] = {"partNumber": "", "partDescription": "", "itemId": None,
                       "qty": "", "vendorLot": ""}
```

with:

```python
    st["purchased"] = dict(_EMPTY["purchased"])
```

Update the `addBox` docstring's second sentence to: `The supplier lot is required: it goes to VendorLotNumber, or the box is marked as carrying none.`

- [ ] **Step 4: Add `setVendorLotAbsent`**

Insert directly after `addBox`:

```python
@_guard
def setVendorLotAbsent(session):
    """The operator's explicit 'No lot on box' answer for a purchased box.
       Clears any typed supplier lot and flags the absence; addBox passes the
       flag and the proc stores its marker. Returns {Status, Message}."""
    st = getState(session)
    st["purchased"]["vendorLot"] = ""
    st["purchased"]["vendorLotAbsent"] = True
    _write(st, session)
    return {"Status": 1, "Message": "Marked: no lot on box."}
```

- [ ] **Step 5: Scan and verify**

```powershell
.\scan.ps1
```

On the Cutover Scan screen, enter a purchased part and quantity with the supplier lot blank and add the box. Expected: an error toast with body `Supplier lot number is required.` and no new row in the list. Enter a supplier lot and add again: it succeeds, and

```sql
SELECT TOP 1 LotName, VendorLotNumber FROM Lots.Lot ORDER BY Id DESC;
```

shows the value typed.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json
git commit -m "feat(cutover): a purchased box needs a supplier lot"
```

---

### Task 5: Designer handoff note

**Files:**
- Create: `notes/2026-10-05_supplier-lot-designer-handoff.md`

**Interfaces:**
- Consumes: popup view path `BlueRidge/Components/PlantFloor/AddLotBox`, popup id `mpp-add-lot-box` (Task 3); `BlueRidge.Cutover.Scan.setVendorLotAbsent(session)` (Task 4).

- [ ] **Step 1: Write the note**

````markdown
# Supplier lot -- Designer handoff (2026-10-05)

Four existing views need a change that has to be made in Designer, not by
file edit. Spec: `docs/superpowers/specs/2026-10-05-required-supplier-lot-on-purchased-parts-design.md`.

Close and reopen Designer after `.\scan.ps1` so it has the new `AddLotBox`
view and the updated scripts before starting.

## 1. `Components/PlantFloor/LineInventoryRow` -- AddButton

`root > Slot > AddButton`, event `onActionPerformed`. Replace the whole
script with this (the body starts with a tab in the saved file; Designer
adds it):

```python
nowMs = system.date.toMillis(system.date.now())
if nowMs < (self.view.custom.busyUntil or 0):
	return
mode = self.view.params.addLotMode
if mode != "AskQty" and mode != "OneTap":
	return
# Every add goes through the popup so the supplier lot is captured. A part
# with a box quantity opens with that quantity already filled in.
boxQty = self.view.params.boxQuantity if mode == "OneTap" else None
system.perspective.openPopup("mpp-add-lot-box", "BlueRidge/Components/PlantFloor/AddLotBox", params={"itemId": self.view.params.itemId, "description": self.view.params.description, "locationId": self.view.params.locationId, "boxQuantity": boxQty}, modal=True, showCloseIcon=True)
```

Check: tapping `+ LOT` and tapping a `+2,500` style button both open the
new popup; the second opens with 2500 in Quantity.

## 2. Cutover Scan -- Tablet, Phone, Desktop

`Views/ShopFloor/_CutoverScan/{Tablet,Phone,Desktop}`, the purchased-box
form. In each:

1. Supplier lot field (bound to `session.custom.cutover.purchased.vendorLot`):
   bind `props.placeholder` to the expression

   ```
   if({session.custom.cutover.purchased.vendorLotAbsent} && len(trim({session.custom.cutover.purchased.vendorLot})) = 0, "No lot on box", "Supplier lot (required)")
   ```

2. Add a button beside it, text `No lot on box`, classes
   `pf-btn pf-btn-secondary`, `onActionPerformed` (scope Gateway):

   ```python
   BlueRidge.Cutover.Scan.setVendorLotAbsent(self.session)
   ```

Check on each: with the field blank, Add Box is refused with "Supplier lot
number is required."; after `No lot on box`, the placeholder changes and
Add Box succeeds; the new LOT's `VendorLotNumber` is `NONE`.

## After saving

Run `git diff --stat` before committing. A view saved while it was showing
live data embeds the rows; if any of the four diffs is large, clear the
runtime data and save again.

Then tell Claude the Designer edits are in, so Task 6 of the plan (making
the supplier lot unconditional on the Line Inventory path) can run.
````

- [ ] **Step 2: Commit**

```bash
git add notes/2026-10-05_supplier-lot-designer-handoff.md
git commit -m "docs(notes): Designer handoff for the supplier lot views"
```

- [ ] **Step 3: Stop for the Designer edits**

Tasks 1-5 are complete and safe on the shared gateway. Task 6 must not start until Jacques confirms the `LineInventoryRow` edit is saved, because it makes the old one-tap path fail.

---

### Task 6: Make the Line Inventory requirement unconditional

**Precondition:** the `LineInventoryRow` Designer edit from Task 5 is saved and committed.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` (`checkInBox`, `checkInAndNotify` signatures)
- Modify: `PROJECT_STATUS.md` (append-only entry)

**Interfaces:**
- Produces: `checkInBox(..., requireVendorLot=True)` and `checkInAndNotify(..., requireVendorLot=True)`. Same positions, default flipped.

- [ ] **Step 1: Confirm nothing still uses the old path**

```bash
git grep -n "AddLotQty\|checkInAndNotify" -- ignition/projects
```

Expected: the only view calling `checkInAndNotify` besides the retired `AddLotQty/view.json` is `AddLotBox/view.json`, and no view opens `AddLotQty`. If `LineInventoryRow/view.json` still calls `checkInAndNotify` or opens `AddLotQty`, stop: the Designer edit is not in.

- [ ] **Step 2: Flip the default**

In both `checkInBox` and `checkInAndNotify`, change `requireVendorLot=False` to `requireVendorLot=True`. In the `checkInBox` docstring replace the sentence beginning `requireVendorLot asks the PROC` with:

```python
       requireVendorLot defaults True: a box checked in at a line needs a
       supplier lot or the explicit absent answer, and the PROC enforces it.
```

- [ ] **Step 3: Scan and verify**

```powershell
.\scan.ps1
```

On a line terminal: add one box through `+ LOT` and one through a one-tap button, each with a supplier lot. Both succeed. Then:

```sql
SELECT TOP 2 LotName, PieceCount, VendorLotNumber FROM Lots.Lot ORDER BY Id DESC;
```

Expected: both rows carry the supplier lot entered.

- [ ] **Step 4: Record it in `PROJECT_STATUS.md`**

Append (do not rewrite existing entries) under the recent-changes section:

```markdown
- **2026-10-05 -- Supplier lot required on purchased-part check-in.** `Lots.Lot_Create` v1.8 adds `@RequireVendorLot` / `@VendorLotAbsent` (no migration). Line Inventory adds (both `+ LOT` and one-tap) go through the new `AddLotBox` popup; Cutover Scan's box entry requires it too. **No lot on box** stores `NONE`. Inventory Manager and Receiving Dock are unchanged (still optional). `AddLotQty` is unused and can be deleted in a cleanup. Spec: `docs/superpowers/specs/2026-10-05-required-supplier-lot-on-purchased-parts-design.md`.
```

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py PROJECT_STATUS.md
git commit -m "feat(ignition): a line check-in always needs a supplier lot"
```

---

## Production note

Not part of this plan. When this goes to prod it ships as a normal release (preview, rehearsal, fingerprint-guarded execute, scoped exports, runbook). The scoped export must carry the Core script module, the `Lot_Create` named query, `AddLotBox`, `LineInventoryRow`, the three Cutover views and the session props **together**: the Task 6 script with the old `LineInventoryRow` refuses every one-tap add.
