# LTT as LOT Identity (Die Cast & Machining OUT) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a LOT's scannable identity (`Lots.Lot.LotName`) equal the physical LTT at birth — Die Cast adopts the operator-scanned external LTT; Machining OUT derives `<sourceLTT>-NN` and auto-prints its label.

**Architecture:** Single identity column stays (`LotName` = the LTT); no schema change. Die-cast births route the scanned LTT through `Lot_Create`'s existing `@LotName` hook, now format-validated + required for die-cast origin. Machining-OUT mint stops sequence-minting and derives a `-NN` sublot suffix (mirroring `Lot_Split`), then the Python mint wrapper auto-prints the label.

**Tech Stack:** SQL Server 2022 stored procs + scalar functions (repeatable migrations `sql/migrations/repeatable/R__*.sql`), tSQL test harness (`sql/tests/`, `.\Run-Tests.ps1`), Ignition Perspective (Jython 2 Core scripts + `view.json`).

## Global Constraints

- Mutation procs use the status-row pattern (`SELECT @Status, @Message, @NewId[, @MintedLotName]`); **no OUTPUT params** (FDS-11-011).
- In procs captured via INSERT-EXEC, **all rejecting validations run BEFORE `BEGIN TRANSACTION`**; the CATCH is the only legal ROLLBACK site; **`RAISERROR` not `THROW`** in CATCH.
- **ASCII-only** in SQL string literals (no em-dash / middle-dot bytes).
- **No business/domain logic in Python** — format/checksum rules live in SQL.
- **Existing `view.json` edits go through Ignition Designer**, not file edits (GSON unicode-escape + Designer-cache race). New files (functions, tests) are file-authored.
- Scalar functions are named `R__<Schema>_ufn_<Name>.sql` (e.g. `R__Audit_ufn_MidDot.sql`).
- After editing any Core Python script, run `.\scan.ps1` to push it to the gateway.

---

### Task 1: `Lots.ufn_IsValidExternalLtt` scalar function

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_IsValidExternalLtt.sql`
- Test: `sql/tests/0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql`

**Interfaces:**
- Produces: `Lots.ufn_IsValidExternalLtt(@Ltt NVARCHAR(50)) RETURNS BIT` — `1` when `@Ltt` is a valid external Die Cast LTT (exactly 9 numeric digits; checksum stubbed), else `0`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql`:

```sql
-- =============================================
-- File:         0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql
-- Description:  Lots.ufn_IsValidExternalLtt - external Die Cast LTT format rule
--               (exactly 9 numeric digits; checksum stubbed as valid for now).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql';
GO

DECLARE @v9   NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'123456789') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] 9 digits valid', @Expected = N'1', @Actual = @v9;

DECLARE @v8   NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'12345678') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] 8 digits invalid', @Expected = N'0', @Actual = @v8;

DECLARE @v10  NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'1234567890') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] 10 digits invalid', @Expected = N'0', @Actual = @v10;

DECLARE @valp NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'12345678A') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] non-digit invalid', @Expected = N'0', @Actual = @valp;

DECLARE @vnl  NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] NULL invalid', @Expected = N'0', @Actual = @vnl;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `.\Run-Tests.ps1`
Expected: FAIL — the run errors on `031_ufn_IsValidExternalLtt.sql` because `Lots.ufn_IsValidExternalLtt` does not exist (invalid object name).

- [ ] **Step 3: Write the function**

Create `sql/migrations/repeatable/R__Lots_ufn_IsValidExternalLtt.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_ufn_IsValidExternalLtt.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0 (2026-07-20)
-- Description: External Die Cast LTT format rule. LTTs are bulk pre-printed by an
--              external scheduler; the MES adopts the scanned value verbatim as
--              Lots.Lot.LotName. This function is the format gate: exactly 9 numeric
--              digits. A check-digit/checksum is expected but not yet confirmed
--              (spec 2026-07-20 open item) -- the checksum stub below returns valid,
--              so the real rule drops in here with no caller churn.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_IsValidExternalLtt (@Ltt NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @Ok BIT = 0;
    -- Exactly 9 characters, each a digit 0-9 (LIKE with 9 [0-9] classes is anchored
    -- both ends -> matches iff the string is exactly 9 digits).
    IF @Ltt LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        SET @Ok = 1;
    -- CHECKSUM STUB: when the external LTT check-digit algorithm is confirmed, add the
    -- validation here (set @Ok = 0 on a checksum failure). Currently a no-op.
    RETURN @Ok;
END;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `.\Run-Tests.ps1`
Expected: PASS — all 5 `[LTT]` assertions pass; overall run reports 0 failures.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_IsValidExternalLtt.sql sql/tests/0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql
git commit -m "feat(sql): Lots.ufn_IsValidExternalLtt - 9-digit external LTT format gate"
```

---

### Task 2: `Lot_Create` — die-cast requires + format-validates the external LTT

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql` (move `@CellHasActiveTool` earlier; extend the `@LotName` validation block)
- Modify: `sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql` (D2 tests 5–7 must now supply a valid LTT; add die-cast LTT tests + teardown)

**Interfaces:**
- Consumes: `Lots.ufn_IsValidExternalLtt(@Ltt)` (Task 1).
- Produces: `Lots.Lot_Create` — for die-cast-origin creates (`@CellHasActiveTool = 1`, i.e. `Manufactured` origin + an active `ToolAssignment` on the cell), `@LotName` is **required** and must satisfy `ufn_IsValidExternalLtt`; non-die-cast origins keep today's optional/unvalidated `@LotName` behavior. Result shape unchanged: `Status, Message, NewId, MintedLotName`.

- [ ] **Step 1: Update existing D2 tests to supply a valid LTT + extend teardown, and add the new die-cast LTT tests**

In `sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql`:

(a) In **both** teardown blocks (the one after `BeginTestFile` and the one before `EndTestFile`), extend each of the five `Lots.*` delete predicates so the new 9-digit test LTTs are cleaned. Change every occurrence of:

```sql
WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%'
```
to:
```sql
WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%' OR LotName LIKE N'90000%'
```
(and the matching `AncestorLotId IN (SELECT Id ... WHERE LotName LIKE ... OR LotName LIKE N'90000%')` closure delete.)

(b) **Test 5** — add `@LotName=N'900000005'` to the EXEC (die-cast origin now requires an LTT):

```sql
INSERT INTO #C5 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=NULL, @CavityNote=N'C3', @LotName=N'900000005';
```

(c) **Test 6** — add `@LotName=N'900000006'` so the create reaches (and is rejected by) the cavity rule rather than the LTT rule:

```sql
INSERT INTO #C6 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=NULL, @CavityNote=NULL, @LotName=N'900000006';
```

(d) **Test 7** — add `@LotName=N'900000007'`:

```sql
INSERT INTO #C7 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=@CavId, @LotName=N'900000007';
```

(e) Append the new die-cast LTT tests immediately before the final teardown block:

```sql
-- =============================================
-- Test 8: die-cast (Manufactured + active tool) + valid 9-digit LTT
--         -> Status=1, LotName stored verbatim, sequence NOT advanced
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DECLARE @CavId BIGINT = (SELECT TOP 1 tc.Id FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.ToolId = @ToolId AND sc.Code = N'Active' ORDER BY tc.Id);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @S8 BIT, @Minted8 NVARCHAR(50);
CREATE TABLE #C8 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C8 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=@CavId, @LotName=N'900000008';
SELECT @S8 = Status, @Minted8 = MintedLotName FROM #C8; DROP TABLE #C8;
DECLARE @SeqAfter BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
EXEC test.Assert_IsEqual @TestName = N'[LC][LTT] die-cast + valid LTT accepted', @Expected = N'1', @Actual = CAST(@S8 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC][LTT] LotName stored verbatim', @Expected = N'900000008', @Actual = @Minted8;
EXEC test.Assert_IsEqual @TestName = N'[LC][LTT] valid LTT does NOT advance sequence', @Expected = N'0', @Actual = CAST(@SeqAfter - @SeqBefore AS NVARCHAR(10));
GO

-- =============================================
-- Test 9: die-cast + malformed LTT (5 digits) -> Status=0
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DECLARE @CavId BIGINT = (SELECT TOP 1 tc.Id FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.ToolId = @ToolId AND sc.Code = N'Active' ORDER BY tc.Id);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @S9 BIT;
CREATE TABLE #C9 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C9 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=@CavId, @LotName=N'12345';
SELECT @S9 = Status FROM #C9; DROP TABLE #C9;
EXEC test.Assert_IsEqual @TestName = N'[LC][LTT] die-cast + malformed LTT rejected', @Expected = N'0', @Actual = CAST(@S9 AS NVARCHAR(10));
GO

-- =============================================
-- Test 10: die-cast + NULL LTT -> Status=0 (die-cast requires a scanned LTT)
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DECLARE @CavId BIGINT = (SELECT TOP 1 tc.Id FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.ToolId = @ToolId AND sc.Code = N'Active' ORDER BY tc.Id);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @S10 BIT;
CREATE TABLE #C10 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C10 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=@CavId;
SELECT @S10 = Status FROM #C10; DROP TABLE #C10;
EXEC test.Assert_IsEqual @TestName = N'[LC][LTT] die-cast + NULL LTT rejected', @Expected = N'0', @Actual = CAST(@S10 AS NVARCHAR(10));
GO
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `.\Run-Tests.ps1`
Expected: FAIL — `[LC][LTT] die-cast + valid LTT accepted` fails (die-cast currently ignores `@LotName` format and still mints/accepts, but Test 8 asserts the *supplied* name is stored — it is, so this may pass; the decisive failures are Tests 9 and 10: today a malformed/NULL LTT on a die-cast create is **accepted** → Status `1` ≠ expected `0`).

- [ ] **Step 3: Move `@CellHasActiveTool` earlier in `Lot_Create`**

In `sql/migrations/repeatable/R__Lots_Lot_Create.sql`, **delete** the declaration currently at the die-cast section (the block beginning `DECLARE @CellHasActiveTool BIT =` through its `THEN 1 ELSE 0 END;`, just before `IF @CellHasActiveTool = 1`):

```sql
        DECLARE @CellHasActiveTool BIT =
            CASE WHEN @LotOriginTypeId = @ManufacturedOriginId
                   AND EXISTS (SELECT 1 FROM Tools.ToolAssignment
                               WHERE CellLocationId = @CurrentLocationId AND ReleasedAt IS NULL)
                 THEN 1 ELSE 0 END;

```

Then **insert** that same declaration immediately after the AppUser FK-resolution block (right after its closing `END`, before the `-- ---- 2b. D4` comment):

```sql
        -- Die-cast-origin determination (needed by the LTT rule below AND the
        -- Tool/Cavity rule later): Manufactured origin AND an active ToolAssignment
        -- on the cell.
        DECLARE @CellHasActiveTool BIT =
            CASE WHEN @LotOriginTypeId = @ManufacturedOriginId
                   AND EXISTS (SELECT 1 FROM Tools.ToolAssignment
                               WHERE CellLocationId = @CurrentLocationId AND ReleasedAt IS NULL)
                 THEN 1 ELSE 0 END;

```

- [ ] **Step 4: Add the required + format checks to the `@LotName` block**

In the `-- ---- 2b. D4:` section, **replace** the opening of the `@LotName` handling — from `IF @LotName IS NOT NULL` up to and including the blank-check `END` — with the version below (adds the die-cast "required" gate before it, and the die-cast format gate after the blank check). Locate this existing code:

```sql
        IF @LotName IS NOT NULL
        BEGIN
            SET @LotName = LTRIM(RTRIM(@LotName));
            IF @LotName = N''
            BEGIN
                SET @Message = N'LotName cannot be blank.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
```

and replace it with:

```sql
        -- Die-cast births carry the operator-scanned external LTT (bulk pre-printed by
        -- the external scheduler). It is REQUIRED and format-validated for die-cast
        -- origin; other origins keep the optional/unvalidated behavior.
        IF @CellHasActiveTool = 1 AND @LotName IS NULL
        BEGIN
            SET @Message = N'Die-cast LOT requires a scanned LTT.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        IF @LotName IS NOT NULL
        BEGIN
            SET @LotName = LTRIM(RTRIM(@LotName));
            IF @LotName = N''
            BEGIN
                SET @Message = N'LotName cannot be blank.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
            -- Die-cast LTT must match the external format (9 numeric digits; checksum).
            IF @CellHasActiveTool = 1 AND Lots.ufn_IsValidExternalLtt(@LotName) = 0
            BEGIN
                SET @Message = N'LTT must be 9 digits.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
```

(The existing uniqueness pre-check `IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @LotName)` and the closing `END` of the block are left unchanged, directly after this.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `.\Run-Tests.ps1`
Expected: PASS — Tests 8/9/10 pass; the amended Tests 5/6/7 still pass; Tests 1–4 (Received-origin, non-die-cast) unaffected; overall run reports 0 failures.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql
git commit -m "feat(sql): Lot_Create requires + format-validates external LTT for die-cast origin"
```

---

### Task 3: `MachiningOut_Mint` — derive `<sourceLTT>-NN` instead of sequence-minting

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql` (replace the inline `IdentifierSequence 'Lot'` mint with suffix derivation)
- Modify: `sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql` (assert the derived sublot names)

**Interfaces:**
- Produces: `Workorder.MachiningOut_Mint` — the minted SubAssembly LOT's `LotName` is `<sourceCastingLotName>-NN` (2-digit, zero-padded, next ordinal across existing `<src>-NN` children); the `'Lot'` counter is not advanced. All consumption / genealogy / close behavior unchanged.

- [ ] **Step 1: Add sublot-name assertions to the machining test**

In `sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql`, after the existing block that mints 10 pieces and sets `@MachLot` (right after the `[MoMint] mint succeeds` assertion and `DECLARE @MachLot BIGINT = (SELECT NewId FROM @m);`), insert:

```sql
-- Sublot name is derived from the casting LTT + '-01' (first child of this casting).
DECLARE @castName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @CastLot);
DECLARE @machName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @MachLot);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] first sublot name is <casting>-01', @Expected = @castName + N'-01', @Actual = @machName;
DECLARE @seqBeforeMint BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
```

Then, after the existing `-- Mint the remaining 14 -> casting closes.` block (after its `INSERT INTO @m EXEC Workorder.MachiningOut_Mint ... @PieceCount = 14 ...`), insert:

```sql
-- Second child of the same casting -> '-02'; counter still not advanced by the mint.
DECLARE @machLot2 BIGINT = (SELECT NewId FROM @m);
DECLARE @machName2 NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @machLot2);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] second sublot name is <casting>-02', @Expected = @castName + N'-02', @Actual = @machName2;
DECLARE @seqAfterMint BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
EXEC test.Assert_IsEqual @TestName = N'[MoMint] mint does not advance Lot counter', @Expected = N'0', @Actual = CAST(@seqAfterMint - @seqBeforeMint AS NVARCHAR(10));
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `.\Run-Tests.ps1`
Expected: FAIL — `[MoMint] first sublot name is <casting>-01` fails because the mint currently produces a `MESL…` name, not `<casting>-01`.

- [ ] **Step 3: Replace the inline mint with suffix derivation**

In `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql`:

(a) In the DECLARE section near the top, **remove** the now-unused sequence locals (`@SeqLast`, `@SeqEnd`, `@SeqFormat`, `@SeqPrefix`, `@SeqPad`) from this line and keep `@MintedName`:

Change:
```sql
    DECLARE @MintedName NVARCHAR(50), @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT;
```
to:
```sql
    DECLARE @MintedName NVARCHAR(50), @NextOrd INT;
```

(b) Replace the entire **B1 mint block** — from the comment `-- B1. Mint the SubAssembly LOT (mirror R__Lots_Lot_Create inline IdentifierSequence 'Lot').` through the line that sets `@MintedName = CASE WHEN @SeqPad IS NULL ...` (i.e. the 8 lines that read the sequence, update it, and format the name) — with the derivation below. Keep the `INSERT INTO Lots.Lot (...) VALUES (@MintedName, ...)` that follows it unchanged:

```sql
        -- B1. Derive the SubAssembly LOT name as a '-NN' sublot of the source casting
        -- (legacy convention: <sourceLTT>-01, -02, ...). Serialize concurrent mints of
        -- THIS casting by re-reading the source row under UPDLOCK,HOLDLOCK before
        -- probing the ordinal (mirrors Lots.Lot_Split's suffix allocation). The 'Lot'
        -- counter is NOT advanced -- machined identity is parent-derived, not minted.
        DECLARE @Ignore BIGINT;
        SELECT @Ignore = l.Id
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.Id = @SourceLotId;

        SET @NextOrd = ISNULL((
            SELECT MAX(TRY_CAST(RIGHT(LotName, 2) AS INT))
            FROM Lots.Lot
            WHERE LotName LIKE @SrcName + N'-[0-9][0-9]'
        ), 0) + 1;

        IF @NextOrd > 99
            RAISERROR(N'Casting already has 99 machined sublots.', 16, 1);

        SET @MintedName = @SrcName + N'-' + RIGHT(N'0' + CAST(@NextOrd AS NVARCHAR(2)), 2);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `.\Run-Tests.ps1`
Expected: PASS — `[MoMint] first sublot name is <casting>-01`, `[MoMint] second sublot name is <casting>-02`, and `[MoMint] mint does not advance Lot counter` all pass; the pre-existing MoMint assertions (item, piece count, genealogy, consumption, close) still pass; overall run reports 0 failures.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql
git commit -m "feat(sql): MachiningOut_Mint derives <sourceLTT>-NN sublot name (no counter mint)"
```

---

### Task 4: Auto-print the machined sublot's LTT label

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py` (add auto-print after a successful mint)

**Interfaces:**
- Consumes: `Workorder.MachiningOut_Mint` result `{Status, Message, NewId}` (Task 3); `BlueRidge.Lots.LotLabel.printLabel(data, appUserId, terminalLocationId)` where `data` carries `{"lotId": <id>}` (label type defaults to `Primary`, reason to `Initial`).
- Produces: `BlueRidge.Workorder.Machining.mint(...)` still returns the mint result unchanged; on success it additionally dispatches an LTT label for the new sublot (a print failure is logged + surfaced but never discards the mint result).

- [ ] **Step 1: Add the auto-print tail to `mint()`**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py`, add the LotLabel import near the top (with the existing imports):

```python
import BlueRidge.Lots.LotLabel
```

Then, in `mint(...)`, replace the final line:

```python
    return BlueRidge.Common.Db.execMutation("workorder/MachiningOut_Mint", params)
```

with:

```python
    result = BlueRidge.Common.Db.execMutation("workorder/MachiningOut_Mint", params)
    # Auto-print the new sublot's LTT label so the basket is scannable downstream.
    # A print failure must not lose the committed mint -- log + toast, return the mint.
    if result and result.get("Status") and result.get("NewId"):
        try:
            BlueRidge.Lots.LotLabel.printLabel(
                {"lotId": result.get("NewId")}, appUserId, terminalLocationId)
        except Exception as e:
            BlueRidge.Common.Util.log("MachiningOut sublot label print failed: %s" % e)
            BlueRidge.Common.Notify.toast(
                "Label not printed",
                "The machined LOT was created but its LTT label did not print. Reprint from the LOT.",
                "warning")
    return result
```

Add the `Notify` import if not already present at the top of the module:

```python
import BlueRidge.Common.Notify
```

- [ ] **Step 2: Push the script to the gateway**

Run: `.\scan.ps1`
Expected: JSON response with `scanActive` — no error.

- [ ] **Step 3: Verify in the app (manual — no SQL test covers the Python path)**

At a Machining-OUT terminal in the running app, mint a machined LOT from a casting. Confirm: (a) a LTT label prints on the session's Zebra with the `<sourceLTT>-NN` barcode, and (b) the mint still succeeds and the toast shows success. Then confirm the new LOT scans at a downstream MovementScan by its `<sourceLTT>-NN` value.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py
git commit -m "feat(ignition): auto-print LTT label after Machining OUT mint"
```

---

### Task 5: DieCastBody — send the scanned LTT into `Lot_Create` (Designer edit)

**Files:**
- Modify (in Designer): `ignition/projects/MPP/.../ShopFloor/DieCastBody/view.json` — the `submitCreate` customMethod

**Interfaces:**
- Consumes: `BlueRidge.Lots.Lot.create(data, appUserId, terminalLocationId, lotName, cavityNote)` — the 4th positional arg is `lotName`; `Lot_Create` now requires + validates it for die-cast origin (Task 2).

- [ ] **Step 1: Edit `submitCreate` in Designer**

Open the `DieCastBody` view in Ignition Designer → root → `scripts.customMethods` → `submitCreate`. Make two edits:

1. Change the create call from:
```python
	result = BlueRidge.Lots.Lot.create(data, appUserId, termId, None, cavityNote)
```
to (pass the scanned LTT as `lotName`):
```python
	result = BlueRidge.Lots.Lot.create(data, appUserId, termId, draft.get("scannedLtt"), cavityNote)
```

2. Delete the now-dead post-success mismatch block (there is no separate minted name to compare against anymore):
```python
		minted = result.get("MintedLotName")
		scanned = draft.get("scannedLtt")
		if scanned and minted and scanned != minted:
			BlueRidge.Common.Notify.toast("LTT mismatch", "Scanned %s but minted %s" % (scanned, minted), "warning")
```
Keep the surrounding lines that set `activeLotId`, `peersThisSession`, `selectedLotId`, `activeLotName`, and `refreshToken`. Where those lines reference `minted`, replace `minted` with `result.get("MintedLotName")` (which now echoes the scanned LTT). Specifically the peers append and `activeLotName` assignment:
```python
		peers.append({"peer": {"Cavity": (toolCavityId if toolCavityId is not None else cavityNote), "LotName": result.get("MintedLotName"), "PieceCount": data.get("pieceCount"), "LotId": result.get("NewId")}})
		...
		self.view.custom.activeLotName = result.get("MintedLotName")
```

Save the view in Designer (this pushes it to the gateway).

- [ ] **Step 2: Verify in the app (manual)**

At a Die-Cast terminal: with no LTT scanned, attempt to create a LOT → expect a rejection toast ("Die-cast LOT requires a scanned LTT."). Scan/enter an invalid value (e.g. `12345`) → expect "LTT must be 9 digits." Enter a valid 9-digit LTT → expect success, and confirm the created LOT's name in the peers list / LOT detail equals the scanned 9-digit value (not a `MESL…`). Confirm the same LTT then scans at MovementScan.

- [ ] **Step 3: Commit the Designer-written view change**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/DieCastBody/view.json
git commit -m "feat(ignition): DieCastBody sends scanned LTT into Lot_Create (die-cast identity)"
```

---

### Task 6: Seed + full-suite regression sweep

**Files:**
- Modify (if needed): `sql/scratch/seed_demo.sql` and any other seed/scratch script that creates a die-cast (Manufactured-origin, tool-mounted cell) LOT without an LTT.

**Interfaces:**
- Consumes: the die-cast LTT requirement from Task 2.

- [ ] **Step 1: Find die-cast LOT creations in seed/scratch that now need an LTT**

Run: `grep -rn "Lot_Create" sql/scratch/ ; grep -rn "Lots.Lot.create" ignition/`
Inspect each hit: any create using the `Manufactured` origin at a cell with an active tool (a die-cast birth) must now pass a valid 9-digit `@LotName` / `lotName`. Add distinct 9-digit values (e.g. `100000001`, `100000002`, …) to those calls. Non-die-cast creations (Received origin, or Manufactured with no mounted tool) need no change.

- [ ] **Step 2: Re-run the full test suite**

Run: `.\Run-Tests.ps1`
Expected: PASS — 0 failures. If the runner exits 1 with 0 reported failures, a file threw (often a teardown FK-order issue on the new 9-digit LTTs) — check the `Lots.Lot` teardown predicates include `OR LotName LIKE N'90000%'` and, in any touched fixture, delete LOTs before Tools.

- [ ] **Step 3: Re-seed the demo dataset and smoke it (if seed changed)**

If `seed_demo.sql` (or a `.\Seed-Demo.ps1` script) was changed, re-run it against `MPP_MES_Dev` and confirm die-cast LOTs are created with their 9-digit LTT names.

- [ ] **Step 4: Commit**

```bash
git add sql/scratch/seed_demo.sql
git commit -m "chore(sql): seed die-cast LOTs with valid 9-digit LTTs"
```

---

## Self-Review

**Spec coverage:**
- §3 identity model (single `LotName`, three shapes) → Tasks 2 (die-cast shape), 3 (machining shape); Assembly untouched. ✓
- §4.1 `ufn_IsValidExternalLtt` (9-digit + checksum stub) → Task 1. ✓
- §4.2 origin-aware required + format-validated `@LotName` → Task 2. ✓
- §4.3 DieCastBody wiring (pass `scannedLtt`, drop mismatch toast) → Task 5. ✓
- §5.1 `MachiningOut_Mint` `-NN` derivation (mirror `Lot_Split`, no counter mint) → Task 3. ✓
- §5.2 auto-print sublot label in Core Python → Task 4. ✓
- §6 testing (die-cast accept/reject, machining `-01`/`-02`, counter untouched, regression updates) → Tasks 1–3 tests + Task 6 sweep. ✓
- §7 verify-points: die-cast discriminator = `@CellHasActiveTool` (confirmed in code); machining caller = `BlueRidge.Workorder.Machining.mint` (confirmed); `Lot_Split` suffix pattern transplant (Task 3). ✓
- §8 checksum open item → Task 1 stub with a marked insertion point. ✓

**Placeholder scan:** No "TBD/TODO" in code steps; the only stub is the checksum, which is spec-sanctioned and explicitly marked. ✓

**Type consistency:** `Lots.ufn_IsValidExternalLtt(@Ltt NVARCHAR(50)) RETURNS BIT` used identically in Task 1 (def) and Task 2 (call); `printLabel({"lotId": ...}, appUserId, terminalLocationId)` matches the signature read from `LotLabel/code.py`; `create(data, appUserId, terminalLocationId, lotName, cavityNote)` positional order matches the existing `submitCreate` call. ✓

## Revision History

| Date | Change | Author |
|---|---|---|
| 2026-07-20 | Initial implementation plan (6 tasks) derived from the 2026-07-20 design spec. | Blue Ridge Automation |
