-- ============================================================
-- Migration:   0089_item_type_cutover_reclassify.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-16
-- Description: One-off cutover correction of Parts.Item.ItemTypeId, so M&A
--              inventory screens can tell a casting from a bought part by
--              type alone.
--
--              WHAT WAS WRONG. The part-list load typed every non-FG,
--              non-SubAssembly part 'Component' -- castings and purchased
--              pins/bolts/O-rings alike. FDS-03-002 already draws the line:
--                Component   = manufactured intermediate (the casting)
--                PassThrough = vendor-supplied, not manufactured by MPP
--              and no item used PassThrough. How a part enters inventory at
--              M&A differs completely between the two (a casting arrives as a
--              manufactured LOT off its own route; a bought part is received),
--              so the screens need the distinction.
--
--              EVIDENCE (sql/scratch/2026-09-16_item_type_classification_check.sql,
--              run against MPP_MES_Prod 2026-09-16): of 104 Component items,
--              68 carry a DieCast route step and 36 carry no route at all.
--              The LOT record agrees independently -- the 68 hold 168 LOTs,
--              every one Manufactured; the 36 hold 5, every one Received --
--              and no part without a cast route sits on a die cavity.
--
--              WHAT THIS DOES.
--                * 33 purchased parts: Component -> PassThrough.
--                * 1223A-6B2 -A000 '6B2 Cam Rocker Set': Component ->
--                  FinishedGood (per Jacques 2026-09-16; it has a published BOM
--                  of its own and no route).
--              One Audit.ConfigLog row per changed item, in the ConfigLog
--              Description convention, attributed to System Bootstrap
--              (AppUser 1), because no person performs a migration.
--
--              WHY A MIGRATION AND NOT A PROC. Parts.Item_Update deliberately
--              refuses to change ItemTypeId, and this is a cutover correction,
--              not a capability: there is intentionally no permanent path to
--              retype an item. The audit rows are written here, in the same
--              deploy transaction as the UPDATE, so the change is explained.
--
--              DELIBERATELY NOT IN SCOPE.
--                * 92900-0614-1B '6x14 Stud Bolt' -- looks like a duplicate of
--                  92900-06014-1B; left as Component pending that decision.
--                * 90701-5RO-3000 (letter O) -- deprecated typo of
--                  90701-5R0-3000 (zero); left as it is.
--                * The 68 castings -- already Component, nothing to do.
--
--              GUARDS (all raise, and the deploy transaction rolls back):
--                * a listed part is neither its From nor its To type -- it
--                  was retyped by hand since the evidence was read;
--                * a part headed for PassThrough has a DieCast route step, a
--                  Manufactured LOT, or an active die cavity -- the evidence
--                  no longer holds;
--                * a part headed for FinishedGood has any LOT.
--
--              ENVIRONMENTS. Keyed on PartNumber, never Id. A listed part
--              absent from the target is skipped and counted (a fresh
--              Reset/test database has no items when migrations run; the
--              seeds type those parts correctly themselves). A part already
--              at its To type is skipped, so a re-run is a no-op.
-- ============================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @Plan TABLE (
    PartNumber NVARCHAR(50) NOT NULL PRIMARY KEY,
    FromType   NVARCHAR(30) NOT NULL,
    ToType     NVARCHAR(30) NOT NULL
);

INSERT INTO @Plan (PartNumber, FromType, ToType) VALUES
    (N'146465GO A000',     N'Component', N'PassThrough'),   -- Thrust Washer
    (N'15123-PCX-0030-H1', N'Component', N'PassThrough'),   -- 18x13 Dowel Pin
    (N'19300-6CA-A010-M2', N'Component', N'PassThrough'),   -- Thermostat
    (N'19305-5K0-A000',    N'Component', N'PassThrough'),   -- Rubber, Thermo MTG
    (N'19517-PD6-3000',    N'Component', N'PassThrough'),   -- Joint Tube
    (N'21001 pin',         N'Component', N'PassThrough'),   -- Pin 21001
    (N'900009-R70-A000',   N'Component', N'PassThrough'),   -- Drain Plug Bolt
    (N'90004PE2 0050',     N'Component', N'PassThrough'),   -- Sealing Bolt
    (N'90009-R70-A000',    N'Component', N'PassThrough'),   -- 14mm Bolt Plug
    (N'90009-RDJ-A000',    N'Component', N'PassThrough'),   -- 14mm Bolt Plug
    (N'90015-PH1-0130',    N'Component', N'PassThrough'),   -- M22 Stud / Oil Filter Holder
    (N'90701-5A2-A000',    N'Component', N'PassThrough'),   -- 9x14 Dowel Pin
    (N'90701-5GO -A000',   N'Component', N'PassThrough'),   -- 10x10 Dowel Pin (deprecated)
    (N'90701-5R0-3000',    N'Component', N'PassThrough'),   -- Dowel Pin 9x10 (purchased)
    (N'91302-RZP-0000',    N'Component', N'PassThrough'),   -- 23x2.3 O-ring
    (N'92900-06012-0B',    N'Component', N'PassThrough'),   -- 6x12 Stud Bolt
    (N'92900-06014-1B',    N'Component', N'PassThrough'),   -- Stud Bolt 6x14 (purchased)
    (N'92900-06050-0B',    N'Component', N'PassThrough'),   -- 6x50 Stud Bolt
    (N'94109-14000',       N'Component', N'PassThrough'),   -- 14mm Drain Plug Washer
    (N'94301-08100',       N'Component', N'PassThrough'),   -- Dowel Pin 8x10 (purchased)
    (N'94301-08140',       N'Component', N'PassThrough'),   -- 8x14 Dowel Pin
    (N'94301-10120',       N'Component', N'PassThrough'),   -- 10x12 Dowel Pin
    (N'94301-12160',       N'Component', N'PassThrough'),   -- 12x16 Dowel Pin
    (N'95701-06020-08',    N'Component', N'PassThrough'),   -- 6x20 Flange Bolt
    (N'96211-09000',       N'Component', N'PassThrough'),   -- Steel Ball
    (N'P146125GO A000',    N'Component', N'PassThrough'),   -- Ex A Rocker Arm Assembly
    (N'P146145GO A000',    N'Component', N'PassThrough'),   -- Ex B Rocker Arm Assembly
    (N'P146205GO A000',    N'Component', N'PassThrough'),   -- In Rocker Arm Assembly
    (N'P146245GO A000',    N'Component', N'PassThrough'),   -- Ex A Rocker Arm Assembly
    (N'P146275GO A000',    N'Component', N'PassThrough'),   -- Ex B Rocker Arm Assembly
    (N'P146405GO A000',    N'Component', N'PassThrough'),   -- In Rocker Arm Assembly
    (N'P146455GO A000',    N'Component', N'PassThrough'),   -- Ex Rocker Arm Spring
    (N'P90002-5GO-A000',   N'Component', N'PassThrough'),   -- Flange Bolt
    (N'1223A-6B2 -A000',   N'Component', N'FinishedGood');  -- 6B2 Cam Rocker Set

-- ---- 1. Resolve. Every Plan row, with what the target holds for it.
DECLARE @Work TABLE (
    PartNumber  NVARCHAR(50) NOT NULL PRIMARY KEY,
    ItemId      BIGINT       NULL,
    CurTypeId   BIGINT       NULL,
    CurCode     NVARCHAR(30) NULL,
    FromTypeId  BIGINT       NOT NULL,
    ToTypeId    BIGINT       NOT NULL,
    ToCode      NVARCHAR(30) NOT NULL
);

INSERT INTO @Work (PartNumber, ItemId, CurTypeId, CurCode, FromTypeId, ToTypeId, ToCode)
SELECT  p.PartNumber, i.Id, i.ItemTypeId, cur.Code, ft.Id, tt.Id, tt.Code
FROM    @Plan p
JOIN    Parts.ItemType ft ON ft.Code = p.FromType
JOIN    Parts.ItemType tt ON tt.Code = p.ToType
LEFT JOIN Parts.Item i     ON i.PartNumber = p.PartNumber
LEFT JOIN Parts.ItemType cur ON cur.Id = i.ItemTypeId;

IF (SELECT COUNT(*) FROM @Work) <> (SELECT COUNT(*) FROM @Plan)
BEGIN
    RAISERROR(N'0089: an ItemType code in the plan does not exist on the target (Component / PassThrough / FinishedGood).', 16, 1);
    RETURN;
END

-- ---- 2. Guards. Each names the first offending part so the reader can act.
DECLARE @Bad NVARCHAR(50);

SELECT TOP 1 @Bad = PartNumber FROM @Work
WHERE ItemId IS NOT NULL AND CurTypeId NOT IN (FromTypeId, ToTypeId)
ORDER BY PartNumber;
IF @Bad IS NOT NULL
BEGIN
    RAISERROR(N'0089: part %s is neither its expected From nor To type -- it was retyped since the evidence was read. Re-run the classification check.', 16, 1, @Bad);
    RETURN;
END

SELECT TOP 1 @Bad = w.PartNumber FROM @Work w
WHERE w.ItemId IS NOT NULL AND w.ToCode = N'PassThrough'
  AND (   EXISTS (SELECT 1 FROM Parts.RouteTemplate rt
                  JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
                  JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
                  JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
                  WHERE rt.ItemId = w.ItemId AND oty.Code = N'DieCast')
       OR EXISTS (SELECT 1 FROM Lots.Lot l
                  JOIN Lots.LotOriginType lo ON lo.Id = l.LotOriginTypeId
                  WHERE l.ItemId = w.ItemId AND lo.Code = N'Manufactured')
       OR EXISTS (SELECT 1 FROM Tools.ToolCavity tc
                  WHERE tc.ItemId = w.ItemId AND tc.DeprecatedAt IS NULL))
ORDER BY w.PartNumber;
IF @Bad IS NOT NULL
BEGIN
    RAISERROR(N'0089: part %s is listed as purchased but now has a DieCast route, a Manufactured LOT, or a die cavity. Remove it from the plan or fix the data.', 16, 1, @Bad);
    RETURN;
END

SELECT TOP 1 @Bad = w.PartNumber FROM @Work w
WHERE w.ItemId IS NOT NULL AND w.ToCode = N'FinishedGood' AND w.CurTypeId <> w.ToTypeId
  AND EXISTS (SELECT 1 FROM Lots.Lot l WHERE l.ItemId = w.ItemId)
ORDER BY w.PartNumber;
IF @Bad IS NOT NULL
BEGIN
    RAISERROR(N'0089: part %s would become a Finished Good but already has LOTs. Decide what those LOTs are before retyping.', 16, 1, @Bad);
    RETURN;
END

-- ---- 3. Apply, one item at a time, each with its audit row.
DECLARE @Absent  INT = (SELECT COUNT(*) FROM @Work WHERE ItemId IS NULL);
DECLARE @Already INT = (SELECT COUNT(*) FROM @Work WHERE ItemId IS NOT NULL AND CurTypeId = ToTypeId);
DECLARE @Changed INT = 0;

DECLARE @SystemUserId BIGINT = 1;   -- System Bootstrap (migration 0001)
DECLARE @Arrow        NVARCHAR(3) = NCHAR(8594);
DECLARE @ItemId BIGINT, @PartNumber NVARCHAR(50), @FromTypeId BIGINT, @ToTypeId BIGINT;
DECLARE @OldValue NVARCHAR(MAX), @NewValue NVARCHAR(MAX), @Activity NVARCHAR(500);

WHILE 1 = 1
BEGIN
    SELECT TOP 1 @ItemId = ItemId, @PartNumber = PartNumber,
                 @FromTypeId = CurTypeId, @ToTypeId = ToTypeId
    FROM   @Work
    WHERE  ItemId IS NOT NULL AND CurTypeId <> ToTypeId
    ORDER BY PartNumber;
    IF @@ROWCOUNT = 0 BREAK;

    SET @OldValue = (SELECT JSON_QUERY((SELECT t.Id, t.Code, t.Name FROM Parts.ItemType t WHERE t.Id = @FromTypeId
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemType
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    SET @NewValue = (SELECT JSON_QUERY((SELECT t.Id, t.Code, t.Name FROM Parts.ItemType t WHERE t.Id = @ToTypeId
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemType
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    SET @Activity = Audit.ufn_TruncateActivity(
          @PartNumber + N' ' + Audit.ufn_MidDot() + N' Identity ' + Audit.ufn_MidDot()
        + N' Updated ItemType '
        + (SELECT Name FROM Parts.ItemType WHERE Id = @FromTypeId) + @Arrow
        + (SELECT Name FROM Parts.ItemType WHERE Id = @ToTypeId)
        + N' (cutover reclassification, migration 0089)');

    UPDATE Parts.Item
       SET ItemTypeId      = @ToTypeId,
           UpdatedAt       = SYSUTCDATETIME(),
           UpdatedByUserId = @SystemUserId
     WHERE Id = @ItemId;

    EXEC Audit.Audit_LogConfigChange
        @AppUserId         = @SystemUserId,
        @LogEntityTypeCode = N'Item',
        @EntityId          = @ItemId,
        @LogEventTypeCode  = N'Updated',
        @LogSeverityCode   = N'Info',
        @Description       = @Activity,
        @OldValue          = @OldValue,
        @NewValue          = @NewValue;

    UPDATE @Work SET CurTypeId = @ToTypeId WHERE ItemId = @ItemId;
    SET @Changed += 1;
END

PRINT '0089: retyped ' + CAST(@Changed AS NVARCHAR(10)) + ' item(s); '
    + CAST(@Already AS NVARCHAR(10)) + ' already at target type; '
    + CAST(@Absent  AS NVARCHAR(10)) + ' listed part(s) not present on this database.';
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0089_item_type_cutover_reclassify')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0089_item_type_cutover_reclassify',
            N'Cutover correction: 33 purchased parts Component -> PassThrough (FDS-03-002: vendor-supplied), and 1223A-6B2 -A000 Cam Rocker Set Component -> FinishedGood. Keyed on PartNumber, guarded against the classification evidence (no DieCast route, Manufactured LOT or die cavity on a PassThrough part), one Audit.ConfigLog row per item attributed to System Bootstrap. No permanent retype path is added.');
GO
PRINT 'Migration 0089 (item_type_cutover_reclassify) applied.';
GO
