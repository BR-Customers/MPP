-- ============================================================
-- Piece 5 walkthrough fixture for MPP_MES_Dev (test data, safe to delete).
-- Drives everything through the real procs as SYS (AppUser 1):
--   WALK-P5-RW : received 12232-59B-0000 LOT, first-pass trim 95 + 5 scrap,
--                then a supervisor-override move back into TRIM1 (rework OPEN)
--   WALK-P5-R1 : received LOT of 91302-RZP-0000, 50 pcs, 10 marked for return
-- Both join super-lot CR000001 (the existing walkthrough super-lot).
-- Remove with 2026-10-20_piece5_walkthrough_cleanup.sql.
-- ============================================================
SET NOCOUNT ON;
DECLARE @App   BIGINT = 1;
DECLARE @Sup   BIGINT = 2;
DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @Dest  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Rt    BIGINT = (SELECT TOP 1 Id FROM Parts.RouteTemplate WHERE ItemId = @Item AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
DECLARE @Safe  BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE l.DeprecatedAt IS NULL AND d.IsProductionDestination = 0 AND l.Id <> @Dest
      AND EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(l.Id) a
                  JOIN Parts.v_EffectiveItemLocation e ON e.LocationId = a.LocationId AND e.ItemId = @Item)
    ORDER BY l.Id);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Defect BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @otIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimIn');
DECLARE @otOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimOut');
DECLARE @Scrap5 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":5}]';
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @Mv TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Te TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @Log TABLE (Step NVARCHAR(60), Status BIT, Message NVARCHAR(500));
DECLARE @Run BIGINT = (SELECT Id FROM Quality.ControlledRun WHERE RunNumber = N'CR000001');

IF @Item IS NULL OR @Dest IS NULL OR @Safe IS NULL OR @otIn IS NULL OR @otOut IS NULL OR @Run IS NULL
BEGIN
    SELECT N'fixture prerequisites missing' AS Problem, @Item AS Item, @Dest AS Dest, @Safe AS Safe, @otIn AS otIn, @otOut AS otOut, @Run AS Run;
    RETURN;
END

-- ---- WALK-P5-RW: first-pass trim, then the rework move ----
DECLARE @RW BIGINT;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 100, @AppUserId = @App, @LotName = N'WALK-P5-RW';
SELECT @RW = NewId FROM @Lc; INSERT INTO @Log SELECT N'create WALK-P5-RW', Status, Message FROM @Lc; DELETE FROM @Lc;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @RW, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
INSERT INTO @Log SELECT N'first move into trim', Status, Message FROM @Mv; DELETE FROM @Mv;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @RW, @OperationTemplateId = @otIn, @AppUserId = @App;
INSERT INTO @Log SELECT N'first TrimIn checkpoint', Status, Message FROM @Te; DELETE FROM @Te;
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @RW, @OperationTemplateId = @otOut, @ShotCount = 95, @ScrapLinesJson = @Scrap5, @SourceLocationId = @Dest, @AppUserId = @App;
INSERT INTO @Log SELECT N'first Trim OUT 95 + 5 scrap', Status, Message FROM @Te; DELETE FROM @Te;
-- keep the first pass clearly before the rework (same-millisecond edge)
UPDATE Workorder.ProductionEvent SET EventAt = DATEADD(MINUTE, -5, EventAt) WHERE LotId = @RW;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @RW, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
INSERT INTO @Log SELECT N'override move back into trim (rework)', Status, Message FROM @Mv; DELETE FROM @Mv;

-- ---- WALK-P5-R1: a received LOT with a return marked ----
DECLARE @Item2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'91302-RZP-0000');
DECLARE @Loc2  BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE LotName = N'MESL3000162');
DECLARE @R1 BIGINT;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item2, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Loc2, @PieceCount = 50, @AppUserId = @App, @LotName = N'WALK-P5-R1', @VendorLotNumber = N'WALK-VENDOR-01';
SELECT @R1 = NewId FROM @Lc; INSERT INTO @Log SELECT N'create WALK-P5-R1', Status, Message FROM @Lc; DELETE FROM @Lc;
INSERT INTO @Te EXEC Lots.VendorReturn_Mark @LotId = @R1, @Quantity = 10, @Remarks = N'WALKTHROUGH - porosity, vendor notified', @AppUserId = @App;
INSERT INTO @Log SELECT N'mark 10 for return', Status, Message FROM @Te; DELETE FROM @Te;

-- ---- both join CR000001 ----
DECLARE @j NVARCHAR(MAX) = (SELECT v.lotId FROM (VALUES (@RW), (@R1)) v(lotId) FOR JSON PATH);
INSERT INTO @Mv EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
INSERT INTO @Log SELECT N'add both to CR000001', Status, Message FROM @Mv; DELETE FROM @Mv;

SELECT Step, Status, Message FROM @Log;
SELECT l.LotName, l.PieceCount, l.InventoryAvailable, np.OperationTypeCode AS NextStep,
       (SELECT COUNT(*) FROM Lots.ufn_OpenLotRework(l.Id)) AS OpenRework
FROM Lots.Lot l OUTER APPLY Lots.ufn_NextPendingRouteStep(l.Id) np
WHERE l.LotName LIKE N'WALK-P5-%';
