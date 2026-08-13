# Label / Print Subsystem Implementation Plan (Brief D)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the container shipping label DB-template-driven + Honda-complete, persist rendered ZPL on the `ShippingLabel` row, and give print dispatch a gateway-async 3×-retry lifecycle with a stranded-print sweep and terminal banner. Closes FAT-ENV-170, FAT-LBL-050, FAT-LBL-060, FAT-LBL-150.

**Architecture:** Port the real legacy Honda container ZPL (`zebraPrinter/Label Template - Container.zpl`) into a `Lots.LabelTemplate` row (existing `Container` label type) with `{Placeholder}` tokens. A pure SQL scalar function renders it (die rank resolved by genealogy trace); `Container_Complete` renders + persists `ZplContent` in its existing transaction. Python dispatch reads the persisted ZPL, retries 3× in gateway-async scope, and marks outcome; a gateway timer sweep re-dispatches strands and broadcasts a failure banner.

**Tech Stack:** SQL Server 2022 (procs/scalar UDFs, repeatable + versioned migrations), Ignition 8.3 Perspective (file-based views, Core Jython script modules, Named Queries), the project's `test.*` SQL test harness, `scan.ps1` gateway sync.

## Global Constraints

- Branch `jacques/working`. **Explicit-path `git add` only** — never `-A`/`-u` (shared tree with other agents' uncommitted files). No `Co-Authored-By` trailer.
- Migration number **`0054`** (versioned). `0053` is taken (Brief A). Confirm `0054` free before applying.
- **ASCII-only ZPL** — byte-scan any seed string; no em-dash/middot/non-ASCII.
- **FDS-11-011:** no `OUTPUT` params; every mutation proc ends with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`; read procs return one result set (empty = not found); audit writers emit no result set. Status-row-returning NQ → `type:"Query"`; silent/read NQ → default. All rejecting validations run **before** `BEGIN TRANSACTION`.
- **No business logic in Python** — token resolution, die-rank trace, serial composition all live in SQL. Python is thin transport/orchestration.
- **Timestamps:** stored UTC, displayed ET via `... AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'`.
- **Gateway timers must never throw:** guard with `except (Exception, java.lang.Exception)`.
- **Gateway→session sendMessage** needs explicit sessionId+pageId (no broadcast from gateway scope).
- Run `.\scan.ps1` after ANY Ignition resource change. Ignition view.json + scan is single-lane (only one agent edits a view + scans at a time).
- ALL Named Queries live in the **Core** project only.
- Validate on a throwaway DB (e.g. `MPP_MES_LabelPrint`) via the reset flow — never reset `MPP_MES_Dev`.

**Reference impls to mirror (read before starting):** `sql/migrations/repeatable/R__Lots_LotLabel_Print.sql` (render+token pattern), `R__Lots_Container_Complete.sql` (the proc we extend), `R__Lots_ShippingLabel_Reprint.sql`, `R__Lots_Lot_GetGenealogyTree.sql` (closure walk), `ignition/projects/Core/.../Lots/AimPoolGateway/code.py` (timer-tick + alarm idiom), `sql/tests/0025_PlantFloor_Label_Dispatch/020_LotLabel_RecordDispatch.sql` (test pattern).

---

## File Structure

**SQL — versioned**
- `sql/migrations/versioned/0054_shipping_label_zpl_and_template.sql` — `ADD ZplContent` + seed the Container `LabelTemplate` (ported ZPL) + `SchemaVersion` row.

**SQL — repeatable (procs/functions)**
- `R__Tools_ufn_ContainerOriginDieRankCode.sql` — die-rank genealogy resolver (scalar UDF).
- `R__Lots_ufn_ShippingLabelZpl.sql` — ZPL render (scalar UDF; resolves template + all tokens).
- `R__Lots_Container_Complete.sql` — MODIFY: render + persist `ZplContent` in the txn.
- `R__Lots_ShippingLabel_Reprint.sql` — MODIFY: persist re-rendered `ZplContent` on reprint.
- `R__Lots_ShippingLabel_MarkDispatch.sql` — NEW mutation: PrintedAt / PrintFailedAt / attempts / error.
- `R__Lots_ShippingLabel_GetStranded.sql` — NEW read: sweep candidates.
- `R__Lots_ShippingLabel_GetForBanner.sql` — NEW read: failed-unacked rows + terminal.
- `R__Lots_ShippingLabel_AckBanner.sql` — NEW mutation: set `BannerAcknowledgedAt`.
- `R__Lots_ShippingLabel_GetById.sql` — NEW read: one row incl `ZplContent`, endpoint context.

**Named Queries (Core)**
- `lots/ShippingLabel_MarkDispatch` (Query), `lots/ShippingLabel_GetStranded` (read), `lots/ShippingLabel_GetForBanner` (read), `lots/ShippingLabel_AckBanner` (Query), `lots/ShippingLabel_GetById` (read).

**Ignition Python (Core)**
- `Lots/ShippingDispatcher/code.py` — MODIFY: remove hardcoded render; async 3× dispatch of persisted ZPL + mark.
- `Lots/PrintFailureGateway/code.py` — MODIFY: implement `sweepTick`/`broadcastTick`.
- `Workorder/Assembly/code.py` — MODIFY: `completeBoxToPrinter` passes `ShippingLabelId`.

**Perspective (MPP)**
- `Components/PlantFloor/PrintFailureBanner/` — NEW component (banner) on the shipping/dock surface.

**Tests**
- `sql/tests/0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql`
- `sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_DieRankTrace.sql`
- `sql/tests/0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql`

---

## The ported ZPL template (used in Task 1)

Flattened single-pass port of the legacy container label — same `^FO`/`^A0R`/`^GB` geometry, Flexware `<<…:{0}>>` merge fields replaced by `{Placeholder}` tokens. ASCII-only.

```
^XA
^A0R,24,26^FO740,20^FDPART NO. (P)^FS
^A0R,86,86^FO690,200^FD{PartNumber}^FS
^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS
^FO660,1100^BXR,5,200,,,,^FD{DataMatrix}^FS
^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS
^A0R,72,72^FO480,70^FD{PartNumberExt}^FS
^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS
^A0R,24,24^FO550,670^FDDESCRIPTION^FS
^A0R,45,36^FO500,670^FD{Description}^FS
^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS
^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS
^A0R,24,24^FO460,1070^FDMFG DATE^FS
^A0R,45,36^FO410,1070^FD{MfgDate}^FS
^A0R,24,24^FO460,940^FDAUDIT^FS
^A0R,45,36^FO420,940^FD{Auditor}^FS
^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS
^A0R,72,72^FO300,70^FD{DcPartLevel}^FS
^A0R^FO230,70^BY3^B3,,75,N,^FD{DcPartLevel}^FS
^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS
^A0R,72,72^FO240,720^FD{Quantity}^FS
^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS
^A0R,24,24^FO190,20^FDSERIAL (1S)^FS
^A0R,72,72^FO140,200^FD{Serial}^FS
^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS
^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS
^A0R,24,24^FO20,220^FD{Coo}^FS
^FO580,10^GB0,1300,3^FS
^FO490,650^GB0,905,3^FS
^FO400,10^GB0,1300,3^FS
^FO220,10^GB0,1300,3^FS
^FO220,650^GB360,0,3^FS
^PQ2
^XZ
```

Token → source: `{PartNumber}`←Item.PartNumber · `{Description}`←Item.Description · `{MfgLotNumber}`←AimShipperId · `{MfgDate}`←Container.CompletedAt (ET, M/dd/yy) · `{DcPartLevel}`←die-rank trace · `{Quantity}`←SUM(closed tray PartsClosedCount) · `{Serial}`←`13218001`+last-8-of-AimShipperId · `{Coo}`←`USA` · `{PartNumberExt}`,`{DataMatrix}`,`{Auditor}`← blank by design.

---

## Task 1: Migration 0054 — ZplContent column + Container template seed

**Files:**
- Create: `sql/migrations/versioned/0054_shipping_label_zpl_and_template.sql`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql` (schema-existence asserts; render asserts added in Task 3)

**Interfaces:**
- Produces: column `Lots.ShippingLabel.ZplContent NVARCHAR(MAX) NULL`; one active `Lots.LabelTemplate` row where `LabelTypeCodeId = (Code='Container')` with `ZplBody` = the ported ZPL.

- [ ] **Step 1: Confirm the migration number is free**

Run: `ls sql/migrations/versioned/ | grep 0054`
Expected: no output (0054 not taken). If taken, use the next free number and note it in the file + this plan.

- [ ] **Step 2: Write the migration**

Create `sql/migrations/versioned/0054_shipping_label_zpl_and_template.sql`:

```sql
-- ============================================================
-- Versioned: 0054_shipping_label_zpl_and_template.sql
-- Brief D (FAT-LBL-050/060): shipping label onto the LabelTemplate pattern.
--   1. ADD Lots.ShippingLabel.ZplContent (rendered payload persistence, LBL-060).
--   2. Seed one active Lots.LabelTemplate for the existing 'Container' LabelTypeCode,
--      ported ASCII ZPL from the real legacy Honda container label with {Placeholder}
--      tokens (LBL-050). Idempotent; ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF COL_LENGTH(N'Lots.ShippingLabel', N'ZplContent') IS NULL
    ALTER TABLE Lots.ShippingLabel ADD ZplContent NVARCHAR(MAX) NULL;
GO

DECLARE @ContainerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');

IF @ContainerTypeId IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM Lots.LabelTemplate WHERE LabelTypeCodeId = @ContainerTypeId AND DeprecatedAt IS NULL)
BEGIN
    DECLARE @Zpl NVARCHAR(MAX) =
N'^XA
^A0R,24,26^FO740,20^FDPART NO. (P)^FS
^A0R,86,86^FO690,200^FD{PartNumber}^FS
^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS
^FO660,1100^BXR,5,200,,,,^FD{DataMatrix}^FS
^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS
^A0R,72,72^FO480,70^FD{PartNumberExt}^FS
^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS
^A0R,24,24^FO550,670^FDDESCRIPTION^FS
^A0R,45,36^FO500,670^FD{Description}^FS
^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS
^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS
^A0R,24,24^FO460,1070^FDMFG DATE^FS
^A0R,45,36^FO410,1070^FD{MfgDate}^FS
^A0R,24,24^FO460,940^FDAUDIT^FS
^A0R,45,36^FO420,940^FD{Auditor}^FS
^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS
^A0R,72,72^FO300,70^FD{DcPartLevel}^FS
^A0R^FO230,70^BY3^B3,,75,N,^FD{DcPartLevel}^FS
^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS
^A0R,72,72^FO240,720^FD{Quantity}^FS
^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS
^A0R,24,24^FO190,20^FDSERIAL (1S)^FS
^A0R,72,72^FO140,200^FD{Serial}^FS
^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS
^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS
^A0R,24,24^FO20,220^FD{Coo}^FS
^FO580,10^GB0,1300,3^FS
^FO490,650^GB0,905,3^FS
^FO400,10^GB0,1300,3^FS
^FO220,10^GB0,1300,3^FS
^FO220,650^GB360,0,3^FS
^PQ2
^XZ';
    INSERT INTO Lots.LabelTemplate (LabelTypeCodeId, ZplBody) VALUES (@ContainerTypeId, @Zpl);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE ScriptName = N'0054_shipping_label_zpl_and_template.sql')
    INSERT INTO dbo.SchemaVersion (ScriptName, Description)
    VALUES (N'0054_shipping_label_zpl_and_template.sql',
            N'Brief D: add Lots.ShippingLabel.ZplContent + seed active Container LabelTemplate (ported Honda ZPL, {Placeholder} tokens).');
GO
PRINT 'Migration 0054 (shipping label ZplContent + Container template) applied.';
```

> Verify the `SchemaVersion` insert shape against an existing versioned migration (e.g. `0052`/`0053`) — match its exact columns (`ScriptName`/`Description` or `Version`/`AppliedAt`) before running.

- [ ] **Step 3: Byte-scan the migration for non-ASCII**

Run: `python -c "d=open(r'sql/migrations/versioned/0054_shipping_label_zpl_and_template.sql','rb').read(); bad=[(i,b) for i,b in enumerate(d) if b>127]; print('NON-ASCII:', bad[:10] if bad else 'none')"`
Expected: `NON-ASCII: none`

- [ ] **Step 4: Apply the migration to a throwaway DB + verify**

Reset/create `MPP_MES_LabelPrint` per `sql_version_control_guide.md`, apply migrations through 0054, then:
Run (sqlcmd): `SELECT COL_LENGTH('Lots.ShippingLabel','ZplContent') AS ColLen, (SELECT COUNT(*) FROM Lots.LabelTemplate lt JOIN Lots.LabelTypeCode c ON c.Id=lt.LabelTypeCodeId WHERE c.Code='Container' AND lt.DeprecatedAt IS NULL) AS ActiveContainerTemplates;`
Expected: `ColLen` non-null (a number), `ActiveContainerTemplates = 1`.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0054_shipping_label_zpl_and_template.sql
git commit -m "feat(label): 0054 add ShippingLabel.ZplContent + seed Container LabelTemplate (ported Honda ZPL)"
```

---

## Task 2: Die-rank genealogy resolver `Tools.ufn_ContainerOriginDieRankCode`

**Files:**
- Create: `sql/migrations/repeatable/R__Tools_ufn_ContainerOriginDieRankCode.sql`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_DieRankTrace.sql`

**Interfaces:**
- Produces: `Tools.ufn_ContainerOriginDieRankCode(@ContainerId BIGINT) RETURNS NVARCHAR(20)` — the `DieRank.Code` of the origin casting for the container's first closed tray; `N''` when unresolved.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_DieRankTrace.sql`. Build a genealogy fixture: a die (Tool with a DieRank), a casting LOT with that `ToolId`, an FG LOT with a closure ancestor edge to the casting, a Container + closed ContainerTray whose `FinishedGoodLotId` = the FG LOT. Then assert the resolver returns the die's rank code, and returns `''` for a container with no die-rank ancestor.

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/040_ShippingLabel_DieRankTrace.sql';
GO
-- fixture cleanup (namespaced by a marker so we only touch our rows)
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE CurrentLocationId IS NOT NULL AND Id IN (SELECT ContainerId FROM Lots.ContainerTray WHERE ClosureMethod = N'DRT-TEST'));
-- (full cleanup written to match whatever helper rows the fixture inserts)
GO

-- ---- fixture ----
DECLARE @Rank BIGINT;
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'DRT-A', N'DieRankTrace A');
SET @Rank = SCOPE_IDENTITY();
DECLARE @Die BIGINT;
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id), N'DRT-DIE', N'DRT Die', @Rank,
        (SELECT TOP 1 Id FROM Tools.ToolStatusCode ORDER BY Id), 1);
SET @Die = SCOPE_IDENTITY();

DECLARE @Loc BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ItemCast BIGINT = (SELECT TOP 1 Id FROM Parts.Item ORDER BY Id);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- casting LOT carrying ToolId (the die)
DECLARE @CastLot BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedByUserId, CreatedAt)
VALUES (N'DRTCAST1', @ItemCast, @OriginMfg, (SELECT TOP 1 Id FROM Lots.LotStatus ORDER BY Id), 10, @Loc, @Die, 1, SYSUTCDATETIME());
SET @CastLot = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@CastLot, @CastLot, 0);

-- FG LOT + closure ancestor edge from casting
DECLARE @FgLot BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'DRTFG1', @ItemCast, @OriginMfg, (SELECT TOP 1 Id FROM Lots.LotStatus ORDER BY Id), 10, @Loc, 1, SYSUTCDATETIME());
SET @FgLot = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@FgLot, @FgLot, 0), (@CastLot, @FgLot, 1);

-- container + closed tray linking the FG LOT
DECLARE @Cont BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@ItemCast, (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id), @Loc, 1, 1);
SET @Cont = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@Cont, 1, 10, SYSUTCDATETIME(), 1, N'DRT-TEST', @FgLot);

-- ---- assert ----
DECLARE @Got NVARCHAR(20) = Tools.ufn_ContainerOriginDieRankCode(@Cont);
EXEC test.Assert_IsEqual @TestName = N'[DieRank] container resolves origin casting die rank', @Expected = N'DRT-A', @Actual = @Got;

DECLARE @Empty NVARCHAR(20);
DECLARE @Cont2 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@ItemCast, (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id), @Loc, 1, 1);
SET @Cont2 = SCOPE_IDENTITY();
SET @Empty = Tools.ufn_ContainerOriginDieRankCode(@Cont2);
EXEC test.Assert_IsEqual @TestName = N'[DieRank] no die-rank ancestor -> blank', @Expected = N'', @Actual = @Empty;
GO
EXEC test.EndTestFile;
GO
```

> Adjust the exact fixture column names/lookup codes (`LotStatus`, `LotOriginType.Code='Manufactured'`, `ContainerConfig`, `ToolType`, `ToolStatusCode`) to whatever the schema actually uses — verify each `SELECT TOP 1 … / WHERE Code=…` resolves non-null on the test DB before asserting. Add matching cleanup at top so the file is re-runnable.

- [ ] **Step 2: Run the test — verify it fails**

Run the project SQL test harness for file `040_ShippingLabel_DieRankTrace.sql`.
Expected: FAIL — `Tools.ufn_ContainerOriginDieRankCode` does not exist.

- [ ] **Step 3: Write the resolver**

Create `sql/migrations/repeatable/R__Tools_ufn_ContainerOriginDieRankCode.sql`:

```sql
-- ============================================================
-- Repeatable: R__Tools_ufn_ContainerOriginDieRankCode.sql
-- Brief D: resolve the "D/C PART LEVEL" (die rank) for a container's shipping
--   label by genealogy trace. Representative rule: the container's FIRST closed
--   tray (MIN TrayPosition) -> its FinishedGoodLotId -> closure ancestors ->
--   deepest ancestor LOT carrying a ToolId (the die-cast origin) -> Tool.DieRankId
--   -> DieRank.Code. Returns N'' when unresolved (label still prints).
-- ============================================================
CREATE OR ALTER FUNCTION Tools.ufn_ContainerOriginDieRankCode (@ContainerId BIGINT)
RETURNS NVARCHAR(20)
AS
BEGIN
    DECLARE @FgLot BIGINT;
    SELECT TOP 1 @FgLot = t.FinishedGoodLotId
    FROM Lots.ContainerTray t
    WHERE t.ContainerId = @ContainerId
      AND t.ClosedAt IS NOT NULL
      AND t.FinishedGoodLotId IS NOT NULL
    ORDER BY t.TrayPosition;

    IF @FgLot IS NULL
        RETURN N'';

    DECLARE @Code NVARCHAR(20);
    SELECT TOP 1 @Code = dr.Code
    FROM Lots.LotGenealogyClosure c
    INNER JOIN Lots.Lot   l  ON l.Id = c.AncestorLotId
    INNER JOIN Tools.Tool tl ON tl.Id = l.ToolId
    INNER JOIN Tools.DieRank dr ON dr.Id = tl.DieRankId
    WHERE c.DescendantLotId = @FgLot
      AND l.ToolId IS NOT NULL
    ORDER BY c.Depth DESC;   -- deepest ancestor = the die-cast origin

    RETURN ISNULL(@Code, N'');
END;
GO
```

- [ ] **Step 4: Apply + run the test — verify it passes**

Apply the repeatable to `MPP_MES_LabelPrint`, run file `040`.
Expected: both asserts PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_ufn_ContainerOriginDieRankCode.sql sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_DieRankTrace.sql
git commit -m "feat(label): Tools.ufn_ContainerOriginDieRankCode die-rank genealogy resolver + test"
```

---

## Task 3: ZPL render function `Lots.ufn_ShippingLabelZpl`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_ShippingLabelZpl.sql`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql`

**Interfaces:**
- Consumes: `Tools.ufn_ContainerOriginDieRankCode(@ContainerId)` (Task 2); the active Container `LabelTemplate.ZplBody` (Task 1).
- Produces: `Lots.ufn_ShippingLabelZpl(@ContainerId BIGINT, @AimShipperId NVARCHAR(50)) RETURNS NVARCHAR(MAX)` — the fully-substituted ASCII ZPL (all tokens replaced; unresolved-source tokens → `''`).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql`. Build a container with a known Item (PartNumber, Description) + closed trays (quantity) + a die-rank genealogy (reuse Task 2's fixture shape), then assert the rendered ZPL contains each resolved value and the composed serial, and is ASCII-only.

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql';
GO
-- ... build container @Cont (Item with PartNumber 'PN-RENDER'/Description 'DESC-RENDER'),
--     two closed trays PartsClosedCount 6+6 = 12, die-rank 'DRT-A' via genealogy ...

DECLARE @Zpl NVARCHAR(MAX) = Lots.ufn_ShippingLabelZpl(@Cont, N'AIM12345678');

DECLARE @HasPart NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%PN-RENDER%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] part number present', @Expected = N'1', @Actual = @HasPart;
DECLARE @HasDesc NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%DESC-RENDER%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] description present', @Expected = N'1', @Actual = @HasDesc;
DECLARE @HasQty NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%FD12^FS%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] quantity present', @Expected = N'1', @Actual = @HasQty;
DECLARE @HasLevel NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%DRT-A%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] dc part level present', @Expected = N'1', @Actual = @HasLevel;
DECLARE @HasMfgLot NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%AIM12345678%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] mfg lot (AIM serial) present', @Expected = N'1', @Actual = @HasMfgLot;
DECLARE @HasSerial NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%1321800112345678%' THEN N'1' ELSE N'0' END;  -- 13218001 + last8 of AIM12345678
EXEC test.Assert_IsEqual @TestName = N'[Render] composed serial 13218001+last8', @Expected = N'1', @Actual = @HasSerial;
DECLARE @NoTokens NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%{%}%' THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] no unresolved {tokens} remain', @Expected = N'1', @Actual = @NoTokens;
-- ASCII-only: any char > 127?
DECLARE @NonAscii INT = 0, @i INT = 1, @len INT = LEN(@Zpl);
WHILE @i <= @len BEGIN IF UNICODE(SUBSTRING(@Zpl,@i,1)) > 127 SET @NonAscii = @NonAscii + 1; SET @i = @i + 1; END
DECLARE @AsciiOk NVARCHAR(10) = CASE WHEN @NonAscii = 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] ASCII-only', @Expected = N'1', @Actual = @AsciiOk;
GO
EXEC test.EndTestFile;
GO
```

> `%FD12^FS%` asserts the quantity text field; adjust if the token position differs. `LEN` may trim trailing spaces — acceptable for the ASCII scan here.

- [ ] **Step 2: Run the test — verify it fails**

Expected: FAIL — `Lots.ufn_ShippingLabelZpl` does not exist.

- [ ] **Step 3: Write the render function**

Create `sql/migrations/repeatable/R__Lots_ufn_ShippingLabelZpl.sql`:

```sql
-- ============================================================
-- Repeatable: R__Lots_ufn_ShippingLabelZpl.sql
-- Brief D: render the container shipping label ZPL. Resolves the ACTIVE Container
--   LabelTemplate.ZplBody and substitutes {Placeholder} tokens from the container +
--   its Item + genealogy die rank + composed serial. Pure/deterministic (no side
--   effects) so both Container_Complete and ShippingLabel_Reprint call it inside
--   their transactions. Unresolved-source tokens render as ''.
--   Serial = '13218001' (fixed supplier code) + last 8 of the AIM serial.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_ShippingLabelZpl (@ContainerId BIGINT, @AimShipperId NVARCHAR(50))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @ContainerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
    DECLARE @Zpl NVARCHAR(MAX) =
        (SELECT TOP 1 ZplBody FROM Lots.LabelTemplate
         WHERE LabelTypeCodeId = @ContainerTypeId AND DeprecatedAt IS NULL);
    IF @Zpl IS NULL
        RETURN N'';

    DECLARE @ItemId BIGINT, @CompletedAt DATETIME2(3);
    SELECT @ItemId = ItemId, @CompletedAt = CompletedAt FROM Lots.Container WHERE Id = @ContainerId;

    DECLARE @PartNumber  NVARCHAR(50)  = ISNULL((SELECT PartNumber  FROM Parts.Item WHERE Id = @ItemId), N'');
    DECLARE @Description  NVARCHAR(500) = ISNULL((SELECT Description FROM Parts.Item WHERE Id = @ItemId), N'');
    DECLARE @Qty         INT           = ISNULL((SELECT SUM(PartsClosedCount) FROM Lots.ContainerTray
                                                 WHERE ContainerId = @ContainerId AND ClosedAt IS NOT NULL), 0);
    DECLARE @DcPartLevel NVARCHAR(20)  = Tools.ufn_ContainerOriginDieRankCode(@ContainerId);
    DECLARE @Aim         NVARCHAR(50)  = ISNULL(@AimShipperId, N'');
    DECLARE @Serial      NVARCHAR(16)  = N'13218001' + RIGHT(@Aim, 8);
    DECLARE @MfgDate     NVARCHAR(20)  =
        CASE WHEN @CompletedAt IS NULL THEN N''
             ELSE FORMAT(CAST(@CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), N'M/dd/yy') END;

    SET @Zpl = REPLACE(@Zpl, N'{PartNumber}',    @PartNumber);
    SET @Zpl = REPLACE(@Zpl, N'{Description}',   @Description);
    SET @Zpl = REPLACE(@Zpl, N'{MfgLotNumber}',  @Aim);
    SET @Zpl = REPLACE(@Zpl, N'{MfgDate}',       @MfgDate);
    SET @Zpl = REPLACE(@Zpl, N'{DcPartLevel}',   @DcPartLevel);
    SET @Zpl = REPLACE(@Zpl, N'{Quantity}',      CAST(@Qty AS NVARCHAR(20)));
    SET @Zpl = REPLACE(@Zpl, N'{Serial}',        @Serial);
    SET @Zpl = REPLACE(@Zpl, N'{Coo}',           N'USA');
    -- blank-by-design fields
    SET @Zpl = REPLACE(@Zpl, N'{PartNumberExt}', N'');
    SET @Zpl = REPLACE(@Zpl, N'{DataMatrix}',    N'');
    SET @Zpl = REPLACE(@Zpl, N'{Auditor}',       N'');

    RETURN @Zpl;
END;
GO
```

- [ ] **Step 4: Apply + run — verify PASS**

Expected: all `030` asserts PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_ShippingLabelZpl.sql sql/tests/0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql
git commit -m "feat(label): Lots.ufn_ShippingLabelZpl render function + token/serial/ascii tests"
```

---

## Task 4: `Container_Complete` renders + persists ZplContent

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Container_Complete.sql` (the mutation block around the `INSERT INTO Lots.ShippingLabel`, ~lines 129–157)
- Test: extend `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/030_Container_Ship.sql` OR add `sql/tests/0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql` (persistence assert)

**Interfaces:**
- Consumes: `Lots.ufn_ShippingLabelZpl(@ContainerId, @AimShipperId)` (Task 3).
- Produces: `Lots.ShippingLabel.ZplContent` populated on the row inserted by `Container_Complete`. No signature change; return shape unchanged (`Status, Message, ShippingLabelId, AimShipperId`).

- [ ] **Step 1: Write the failing test**

Add to the lifecycle test: complete a container (with a resolvable Item + closed trays), then assert its newest `ShippingLabel.ZplContent` is non-null and contains the Item's PartNumber.

```sql
-- after a successful Container_Complete producing @ShippingLabelId:
DECLARE @Zpl NVARCHAR(MAX) = (SELECT ZplContent FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId);
DECLARE @Persisted NVARCHAR(10) = CASE WHEN @Zpl IS NOT NULL AND LEN(@Zpl) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Complete] ShippingLabel.ZplContent persisted', @Expected = N'1', @Actual = @Persisted;
```

- [ ] **Step 2: Run — verify it fails**

Expected: FAIL — `ZplContent` is NULL (render not yet wired).

- [ ] **Step 3: Wire the render into the mutation**

In `R__Lots_Container_Complete.sql`, immediately **before** the `INSERT INTO Lots.ShippingLabel` (inside the open transaction, after `@AimShipperId` is set), add:

```sql
        DECLARE @ShipZpl NVARCHAR(MAX) = Lots.ufn_ShippingLabelZpl(@ContainerId, @AimShipperId);
```

Then change the insert to persist it:

```sql
        INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, TerminalLocationId, ZplContent)
        VALUES (@ContainerId, @AimShipperId, @LabelTypeId, 1, @AppUserId, @TerminalLocationId, @ShipZpl);
```

(No other changes — the render is deterministic; a missing template yields `''`, which is harmless. Do not add a rejecting validation here; the migration seed guarantees a template exists.)

- [ ] **Step 4: Apply + run — verify PASS**

Expected: persistence assert PASS; existing `030_Container_Ship` asserts still PASS (no regression).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Container_Complete.sql sql/tests/0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql
git commit -m "feat(label): Container_Complete renders + persists ShippingLabel.ZplContent (LBL-060)"
```

---

## Task 5: `ShippingLabel_Reprint` re-renders ZplContent

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_ShippingLabel_Reprint.sql` (the `INSERT INTO Lots.ShippingLabel`, ~line 46)
- Test: extend `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/080_ShippingLabel_Void_Reprint.sql`

**Interfaces:**
- Consumes: `Lots.ufn_ShippingLabelZpl` (Task 3).
- Produces: reprint rows carry a freshly-rendered `ZplContent`.

- [ ] **Step 1: Write the failing test**

In `080_ShippingLabel_Void_Reprint.sql`, after a reprint, assert the new row's `ZplContent` is non-null.

```sql
DECLARE @RZpl NVARCHAR(MAX) = (SELECT ZplContent FROM Lots.ShippingLabel WHERE Id = @ReprintId);
DECLARE @ROk NVARCHAR(10) = CASE WHEN @RZpl IS NOT NULL AND LEN(@RZpl) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Reprint] re-rendered ZplContent persisted', @Expected = N'1', @Actual = @ROk;
```

- [ ] **Step 2: Run — verify it fails.** Expected: FAIL (ZplContent NULL on reprint row).

- [ ] **Step 3: Wire the render.** In `R__Lots_ShippingLabel_Reprint.sql`, before the `BEGIN TRANSACTION` add `DECLARE @ShipZpl NVARCHAR(MAX) = Lots.ufn_ShippingLabelZpl(@ContainerId, @AimShipperId);` (both variables are already selected from the source row at lines 34–35), and add `ZplContent` to the insert column list + `@ShipZpl` to VALUES.

- [ ] **Step 4: Apply + run — verify PASS.**

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ShippingLabel_Reprint.sql sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/080_ShippingLabel_Void_Reprint.sql
git commit -m "feat(label): ShippingLabel_Reprint re-renders ZplContent"
```

---

## Task 6: `ShippingLabel_MarkDispatch` mutation + NQ

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ShippingLabel_MarkDispatch.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_MarkDispatch/query.sql` + `resource.json`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql` (extend)

**Interfaces:**
- Produces: `Lots.ShippingLabel_MarkDispatch @ShippingLabelId, @Success BIT, @ErrorText NVARCHAR(500)=NULL, @MaxAttempts INT=3` → status row. On `@Success=1`: set `PrintedAt=SYSUTCDATETIME()`, `PrintAttempts+=1`, `LastPrintAttemptAt`. On `@Success=0`: `PrintAttempts+=1`, `LastPrintAttemptAt`, `LastPrintError=@ErrorText`, and if `PrintAttempts >= @MaxAttempts` set `PrintFailedAt`.

- [ ] **Step 1: Write the failing test** (append to `050`): mark success → PrintedAt set, PrintAttempts=1; mark failure twice with MaxAttempts=2 → PrintFailedAt set, LastPrintError present; bad id → Status 0.

```sql
-- success
CREATE TABLE #M1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #M1 EXEC Lots.ShippingLabel_MarkDispatch @ShippingLabelId = @ShippingLabelId, @Success = 1;
DROP TABLE #M1;
DECLARE @Pr NVARCHAR(10) = (SELECT CASE WHEN PrintedAt IS NOT NULL THEN N'1' ELSE N'0' END FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId);
EXEC test.Assert_IsEqual @TestName = N'[Mark] success sets PrintedAt', @Expected = N'1', @Actual = @Pr;
-- failure x2 with MaxAttempts 2 on a fresh row @SL2
CREATE TABLE #M2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #M2 EXEC Lots.ShippingLabel_MarkDispatch @ShippingLabelId = @SL2, @Success = 0, @ErrorText = N'conn refused', @MaxAttempts = 2;
INSERT INTO #M2 EXEC Lots.ShippingLabel_MarkDispatch @ShippingLabelId = @SL2, @Success = 0, @ErrorText = N'conn refused', @MaxAttempts = 2;
DROP TABLE #M2;
DECLARE @Fail NVARCHAR(10) = (SELECT CASE WHEN PrintFailedAt IS NOT NULL THEN N'1' ELSE N'0' END FROM Lots.ShippingLabel WHERE Id = @SL2);
EXEC test.Assert_IsEqual @TestName = N'[Mark] attempts exhausted sets PrintFailedAt', @Expected = N'1', @Actual = @Fail;
```

- [ ] **Step 2: Run — verify it fails.** Expected: proc missing.

- [ ] **Step 3: Write the proc.** Create `R__Lots_ShippingLabel_MarkDispatch.sql` (validations before txn; single status row; audits `ShippingLabelDispatched` best-effort — confirm the LogEventType code exists or reuse an existing shipping event code; if none, omit the audit call rather than invent a code):

```sql
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_MarkDispatch
    @ShippingLabelId BIGINT,
    @Success         BIT,
    @ErrorText       NVARCHAR(500) = NULL,
    @MaxAttempts     INT = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    BEGIN TRY
        IF @ShippingLabelId IS NULL OR @Success IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShippingLabelId, Success).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF NOT EXISTS (SELECT 1 FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId)
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        BEGIN TRANSACTION;
        UPDATE Lots.ShippingLabel
        SET PrintAttempts      = PrintAttempts + 1,
            LastPrintAttemptAt = SYSUTCDATETIME(),
            PrintedAt          = CASE WHEN @Success = 1 THEN SYSUTCDATETIME() ELSE PrintedAt END,
            LastPrintError     = CASE WHEN @Success = 1 THEN NULL ELSE @ErrorText END,
            PrintFailedAt      = CASE WHEN @Success = 0 AND (PrintAttempts + 1) >= @MaxAttempts
                                      THEN SYSUTCDATETIME() ELSE PrintFailedAt END
        WHERE Id = @ShippingLabelId;
        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = CASE WHEN @Success = 1 THEN N'Dispatch recorded (printed).' ELSE N'Dispatch failure recorded.' END;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status = 0; SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Create the NQ.** `named-query/lots/ShippingLabel_MarkDispatch/query.sql`:

```sql
EXEC Lots.ShippingLabel_MarkDispatch
    @ShippingLabelId = :shippingLabelId,
    @Success         = :success,
    @ErrorText       = :errorText,
    @MaxAttempts     = :maxAttempts
```

`resource.json` — clone `ShippingLabel_Reprint`'s (scope `DG`, `type:"Query"`, database `MPP`) with parameters: `shippingLabelId` (sqlType 3), `success` (sqlType -7 BIT), `errorText` (sqlType 7), `maxAttempts` (sqlType 3). Verify the BIT sqlType code against another BIT NQ in the repo before finalizing.

- [ ] **Step 5: Apply + run — verify PASS. Commit.**

```bash
git add sql/migrations/repeatable/R__Lots_ShippingLabel_MarkDispatch.sql ignition/projects/Core/ignition/named-query/lots/ShippingLabel_MarkDispatch/ sql/tests/0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql
git commit -m "feat(label): ShippingLabel_MarkDispatch lifecycle proc + NQ + tests"
```

---

## Task 7: `ShippingLabel_GetStranded` + `_GetForBanner` + `_AckBanner` + `_GetById` reads/mutation

**Files:**
- Create: `R__Lots_ShippingLabel_GetStranded.sql`, `R__Lots_ShippingLabel_GetForBanner.sql`, `R__Lots_ShippingLabel_AckBanner.sql`, `R__Lots_ShippingLabel_GetById.sql`
- Create NQs (Core): `lots/ShippingLabel_GetStranded`, `lots/ShippingLabel_GetForBanner`, `lots/ShippingLabel_AckBanner`, `lots/ShippingLabel_GetById`
- Test: extend `050_ShippingLabel_Lifecycle.sql`

**Interfaces:**
- Produces:
  - `Lots.ShippingLabel_GetStranded` (no params) → rows `Id, ContainerId, AimShipperId, TerminalLocationId, ZplContent, PrintAttempts` where `PrintedAt IS NULL AND PrintFailedAt IS NULL AND CreatedAt < DATEADD(SECOND,-60,SYSUTCDATETIME())`.
  - `Lots.ShippingLabel_GetForBanner` (no params) → `Id, ContainerId, TerminalLocationId, AimShipperId, LastPrintError` where `PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`.
  - `Lots.ShippingLabel_AckBanner @ShippingLabelId` → status row; sets `BannerAcknowledgedAt`.
  - `Lots.ShippingLabel_GetById @ShippingLabelId` → single-row read incl `ZplContent`.

- [ ] **Step 1: Write the failing tests** (append to `050`): insert rows in each state, assert `GetStranded`/`GetForBanner` include/exclude correctly (INSERT-EXEC into temp tables matching the SELECT shape, then COUNT), and `AckBanner` clears a banner row.

```sql
CREATE TABLE #S (Id BIGINT, ContainerId BIGINT, AimShipperId NVARCHAR(50), TerminalLocationId BIGINT, ZplContent NVARCHAR(MAX), PrintAttempts INT);
INSERT INTO #S EXEC Lots.ShippingLabel_GetStranded;
DECLARE @StrandHit NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #S WHERE Id = @StrandedId) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Stranded] old unprinted row returned', @Expected = N'1', @Actual = @StrandHit;
DECLARE @FreshMiss NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #S WHERE Id = @FreshId) THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Stranded] fresh (<60s) row excluded', @Expected = N'1', @Actual = @FreshMiss;
DROP TABLE #S;
```

> To make a row "old", set `CreatedAt` back with an explicit `UPDATE Lots.ShippingLabel SET CreatedAt = DATEADD(MINUTE,-5,SYSUTCDATETIME()) WHERE Id=@StrandedId` in the fixture.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Write the four procs.** Reads return one result set, empty = none (no status row). `AckBanner` is a status-row mutation (validations before txn). Example — `GetStranded`:

```sql
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetStranded
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ContainerId, AimShipperId, TerminalLocationId, ZplContent, PrintAttempts
    FROM Lots.ShippingLabel
    WHERE PrintedAt IS NULL AND PrintFailedAt IS NULL
      AND CreatedAt < DATEADD(SECOND, -60, SYSUTCDATETIME());
END;
GO
```

`GetForBanner` mirrors it with the banner predicate + columns. `GetById` selects the full row (incl `ZplContent`) by `@ShippingLabelId`. `AckBanner`:

```sql
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_AckBanner @ShippingLabelId BIGINT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    BEGIN TRY
        IF @ShippingLabelId IS NULL OR NOT EXISTS (SELECT 1 FROM Lots.ShippingLabel WHERE Id=@ShippingLabelId)
        BEGIN SET @Message = N'Shipping label not found.'; SELECT @Status AS Status, @Message AS Message; RETURN; END
        BEGIN TRANSACTION;
        UPDATE Lots.ShippingLabel SET BannerAcknowledgedAt = SYSUTCDATETIME() WHERE Id = @ShippingLabelId;
        COMMIT TRANSACTION;
        SET @Status = 1; SET @Message = N'Banner acknowledged.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: '+LEFT(@ErrMsg,400);
        SELECT @Status AS Status, @Message AS Message; RAISERROR(@ErrMsg,@ErrSev,@ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Create the NQs** (Core). `GetStranded`/`GetForBanner` = no params, default type (read). `GetById` = one param `shippingLabelId` (sqlType 3), read. `AckBanner` = one param, `type:"Query"`.

- [ ] **Step 5: Apply + run — verify PASS. Commit** (all four procs + NQs + test).

```bash
git add sql/migrations/repeatable/R__Lots_ShippingLabel_GetStranded.sql sql/migrations/repeatable/R__Lots_ShippingLabel_GetForBanner.sql sql/migrations/repeatable/R__Lots_ShippingLabel_AckBanner.sql sql/migrations/repeatable/R__Lots_ShippingLabel_GetById.sql ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetStranded/ ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetForBanner/ ignition/projects/Core/ignition/named-query/lots/ShippingLabel_AckBanner/ ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetById/ sql/tests/0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql
git commit -m "feat(label): ShippingLabel stranded/banner/ack/getById reads + NQs + tests"
```

---

## Task 8: `ShippingDispatcher` — async 3× dispatch of persisted ZPL + mark

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py`

**Interfaces:**
- Consumes: `lots/ShippingLabel_GetById` (persisted `ZplContent` + endpoint context), `lots/ShippingLabel_MarkDispatch`.
- Produces: `dispatch(shippingLabelId=None, aimShipperId=None, terminalLocationId=None, printerLocationId=None)` → immediate `{Status, Message}` ("printing…"); the actual 3× socket dispatch + `MarkDispatch` run in a gateway-async worker. Back-compat: if only `aimShipperId` is given, resolve the newest unprinted ShippingLabel for that shipper.

- [ ] **Step 1: Rewrite `dispatch` + add async worker.** Remove `_renderZpl` (rendering now lives in SQL). Keep `_dispatchZpl`, `_logDispatch`, `_sessionPrinter`, `_DEFAULT_PORT` etc. Add:

```python
_MAX_ATTEMPTS = 3
_BACKOFF_MS = 2000

def _resolveShippingLabel(shippingLabelId, aimShipperId):
    """Return the ShippingLabel row (with ZplContent) to dispatch."""
    if shippingLabelId is not None:
        rows = BlueRidge.Common.Db.execList("lots/ShippingLabel_GetById",
                                            {"shippingLabelId": shippingLabelId}) or []
        return rows[0] if rows else None
    # back-compat: newest unprinted row for this AIM shipper
    if aimShipperId is not None:
        for r in (BlueRidge.Common.Db.execList("lots/ShippingLabel_GetForBanner") or []):
            pass  # not used; explicit fetch below
    return None

def _resolveEndpoint(row, terminalLocationId, printerLocationId):
    pid = BlueRidge.Common.Util.extractQualifiedValues(printerLocationId)
    if pid is not None:
        printer = BlueRidge.Location.Printer.getById(pid) or {}
        return (printer.get("endpoint") or printer.get("Endpoint") or "").strip()
    printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    if not endpoint and terminalLocationId is not None:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId) or {}
        endpoint = (printer.get("endpoint") or "").strip()
    return endpoint

def _dispatchWorker(shippingLabelId, endpoint, zpl):
    """Gateway-async: 3 attempts w/ backoff, log each, mark outcome. Never throws."""
    import time
    outcome = {"ok": False, "error": "not attempted"}
    for attempt in range(_MAX_ATTEMPTS):
        outcome = _dispatchZpl(endpoint, zpl)
        _logDispatch(endpoint, zpl, outcome)
        if outcome.get("ok"):
            break
        if attempt < _MAX_ATTEMPTS - 1:
            time.sleep(_BACKOFF_MS / 1000.0)
    try:
        BlueRidge.Common.Db.execMutation("lots/ShippingLabel_MarkDispatch", {
            "shippingLabelId": shippingLabelId,
            "success": 1 if outcome.get("ok") else 0,
            "errorText": None if outcome.get("ok") else (outcome.get("error") or "unknown"),
            "maxAttempts": _MAX_ATTEMPTS,
        })
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("MarkDispatch failed: %s" % str(e), level="debug")

def dispatch(shippingLabelId=None, aimShipperId=None, terminalLocationId=None, printerLocationId=None):
    sid = BlueRidge.Common.Util.extractQualifiedValues(shippingLabelId)
    row = _resolveShippingLabel(sid, aimShipperId)
    if not row:
        return {"Status": 0, "Message": "Shipping label not found for dispatch."}
    sid = row.get("Id")
    zpl = row.get("ZplContent") or ""
    if not zpl:
        return {"Status": 0, "Message": "Shipping label has no rendered ZPL."}
    endpoint = _resolveEndpoint(row, terminalLocationId, printerLocationId)
    if not endpoint:
        return {"Status": 0, "Message": "No printer endpoint resolved for this label."}
    system.util.invokeAsynchronous(lambda: _dispatchWorker(sid, endpoint, zpl))
    return {"Status": 1, "Message": "Shipping label sent to printer."}
```

> Add `from java.lang import Exception as _JEx` or `import java.lang` at top for the guard; match the module's existing import style. Implement the `aimShipperId` back-compat fetch with a dedicated read if `completeBoxToPrinter` still passes an AIM id — simplest is to always pass `shippingLabelId` (Task 9), making the AIM path rarely used.

- [ ] **Step 2: Scan + smoke.** Run `.\scan.ps1`. Because there is no dev Zebra, `_dispatchZpl` fails fast → the worker marks failure after 3 attempts. Verify via SQL that a completed container's ShippingLabel accrues `PrintAttempts=3` + `PrintFailedAt` (transport SIM). Do NOT rely on the in-app browser to fire the real print (memory `feedback_ignition_browser_input_commit`).

- [ ] **Step 3: Commit.**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py
git commit -m "feat(label): ShippingDispatcher async 3x dispatch of persisted ZPL + MarkDispatch"
```

---

## Task 9: `completeBoxToPrinter` passes ShippingLabelId

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py:248-254`

- [ ] **Step 1: Update the call.** `Container.complete` returns `ShippingLabelId`; pass it to `dispatch`:

```python
    sl = res.get("ShippingLabelId")
    disp = BlueRidge.Lots.ShippingDispatcher.dispatch(
        shippingLabelId=sl, terminalLocationId=terminalLocationId, printerLocationId=printerLocationId)
```

Confirm `Container.complete`'s Python wrapper surfaces `ShippingLabelId` in its return dict; if it returns only `{Status, Message, AimShipperId}`, add `ShippingLabelId` to that wrapper's projection (the proc already returns the column).

- [ ] **Step 2: Scan + verify** the completed-box flow still returns Status 1 with the "printing" message (async). Commit.

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py
git commit -m "feat(label): completeBoxToPrinter dispatches by ShippingLabelId"
```

---

## Task 10: `PrintFailureGateway` sweep + broadcast

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/PrintFailureGateway/code.py`

**Interfaces:**
- Consumes: `lots/ShippingLabel_GetStranded`, `lots/ShippingLabel_GetForBanner`, `ShippingDispatcher.dispatch`.

- [ ] **Step 1: Implement the ticks** (mirror `AimPoolGateway` guard style; never throw):

```python
import java.lang

_STRAND_ALARM_THRESHOLD = 5

def sweepTick():
    try:
        stranded = BlueRidge.Common.Db.execList("lots/ShippingLabel_GetStranded") or []
        for row in stranded:
            BlueRidge.Lots.ShippingDispatcher.dispatch(
                shippingLabelId=row.get("Id"),
                terminalLocationId=row.get("TerminalLocationId"))
        if len(stranded) > _STRAND_ALARM_THRESHOLD:
            BlueRidge.Common.Util.log(
                "print sweep: %d stranded shipping labels (supervisor/IT alarm)" % len(stranded))
            # fire the same session-alarm channel AimPoolGateway.alarmTick uses
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("sweepTick failed: %s" % str(e), level="debug")

def broadcastTick():
    try:
        failed = BlueRidge.Common.Db.execList("lots/ShippingLabel_GetForBanner") or []
        if not failed:
            return
        sessions = system.perspective.getSessionInfo() or []
        for row in failed:
            payload = {
                "shippingLabelId": row.get("Id"),
                "containerId":     row.get("ContainerId"),
                "terminalLocationId": row.get("TerminalLocationId"),
                "error":           row.get("LastPrintError"),
            }
            for s in sessions:
                sid = s.get("id") if hasattr(s, "get") else s["id"]
                for pid in (s.get("pageIds") or []):
                    system.perspective.sendMessage(
                        "print-failure-alert", payload=payload,
                        scope="page", sessionId=sid, pageId=pid)
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("broadcastTick failed: %s" % str(e), level="debug")
```

> Match the exact `getSessionInfo()` row accessors + `sendMessage` signature to the working AIM/gateway examples (memory `feedback_ignition_gateway_sendmessage_needs_session_page`). The gateway timers that call these ticks already exist.

- [ ] **Step 2: Scan.** Confirm no wrapper.log errors on tick. With a SIM-failed label present, confirm a `print-failure-alert` is sent (log the send). Commit.

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/PrintFailureGateway/code.py
git commit -m "feat(label): PrintFailureGateway sweep re-dispatch + failure-banner broadcast"
```

---

## Task 11: `PrintFailureBanner` Perspective component

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/PrintFailureBanner/{view.json,resource.json}`
- Modify: the shipping/dock surface view to embed it (single-lane view edit).

**Interfaces:**
- Consumes: `'print-failure-alert'` page-scoped message; `lots/ShippingLabel_AckBanner`, `lots/ShippingLabel_Reprint`.

- [ ] **Step 1: Author the banner view** (NEW view — safe to file-edit, no Designer cache). A message handler on `'print-failure-alert'` filters `payload.terminalLocationId` against `session.custom.terminal` and appends to a `view.custom.alerts` list; render a warning bar per alert with the container + error, a **Dismiss** button (→ `ShippingLabel_AckBanner`, then drop from the list) and a **Reprint** button (→ `Shipping.reprint`). Follow `ignition-context-pack/02` + `07` and the toast/message-scope memories. Pre-declare `view.custom.alerts` with a `[]` default (predeclare-bound-custom-props rule).

- [ ] **Step 2: Embed** the banner on the shipping/dock view (top region). Add `resource.json` for the new view folder (`scope "G"`, `files:["view.json"]`) — required or "View Not Found".

- [ ] **Step 3: Scan + render-verify.** Run `.\scan.ps1`; open the surface in the in-app browser to confirm the banner renders without Component Error (render-verify only — input commits aren't reliable in the in-app browser). Commit.

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/PrintFailureBanner/ <the-edited-shipping-view>
git commit -m "feat(label): PrintFailureBanner terminal component + dock embed"
```

---

## Task 12: Full regression, scan, code review, FAT update

- [ ] **Step 1: Run the entire SQL test suite** against a fresh `MPP_MES_LabelPrint` (reset → migrate → run all `test.*`). Expected: all green, exit 0. Investigate any red before proceeding (memory `feedback_runtests_exit1_zero_failures`: exit 1 with 0 failures usually = a teardown FK order issue).

- [ ] **Step 2: Run `.\scan.ps1`** once more; confirm zero wrapper.log errors for the new NQs/scripts/views.

- [ ] **Step 3: `superpowers:requesting-code-review`** on the branch diff.

- [ ] **Step 4: Update the FAT workbook** `docs/fat/MPP_MES_FAT_practice.xlsx` — mark ENV-170, LBL-050, LBL-060, LBL-150 Result with evidence (persisted ZPL sample, lifecycle test names). Note the FN3 2D DataMatrix + PART NO. EXT (C) as blank-by-design (not defects).

- [ ] **Step 5: Final commit** of the FAT workbook (explicit path).

```bash
git add docs/fat/MPP_MES_FAT_practice.xlsx
git commit -m "docs(fat): Brief D label/print (ENV-170, LBL-050/060/150) evidence"
```

---

## Self-review notes (spec coverage)

- LBL-050 (Honda content) → Tasks 1 (template port), 2 (die rank), 3 (render). ✅
- LBL-060 (ZPL persistence) → Tasks 1 (column), 4 (complete), 5 (reprint). ✅
- ENV-170 / LBL-150 (async + retry + sweep + banner) → Tasks 6 (mark), 7 (reads), 8 (async 3×), 10 (sweep/broadcast), 11 (banner). ✅
- Serial `13218001`+AIM, die-rank representative rule, ASCII-only → Task 3 asserts. ✅
- Blank-by-design FN3/C-ext/Auditor → Task 3 render. ✅
- FDS-11-011 / no-Python-logic / timers-never-throw → enforced per task + Global Constraints. ✅
```
