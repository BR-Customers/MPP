-- =============================================
-- File:        0113_SuperLotVisibility/080_refusals.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 8 -- the seven CRT refusals name the open
--              super-lot: 'LOT x is marked CRT (super-lot CR000014) and cannot ...'.
--                A. Lots.Lot_MoveTo               B. Lots.Lot_MoveToValidated
--                C. Workorder.MachiningIn_RecordPick
--                D. Workorder.MachiningOut_Mint   E. Workorder.Assembly_ScanIn
--                F. Lots.Lot_Split                G. Lots.Lot_Merge (per named LOT)
--              Every section pairs a LOT that is in an OPEN super-lot (gets the run
--              number) with a CRT LOT that is in none -- tagged by hand, the way LOT
--              Detail tags one -- whose message must be EXACTLY today's text, with
--              no '(super-lot' fragment (Review Focus 5). Fixtures mirror
--              0064_Crt_PartScoped/050 + 060. LOTs named CRT080-%.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0113_SuperLotVisibility/080_refusals.sql';
GO
-- ---- clean slate: no super-lot rows left by an earlier file ----
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

-- =============================================
-- A. Lots.Lot_MoveTo
-- =============================================
DECLARE @App BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @ProdLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @StartLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 1 AND l.DeprecatedAt IS NULL AND l.Id <> @ProdLoc ORDER BY l.Id DESC);
DECLARE @n NVARCHAR(10) = CASE WHEN @App IS NOT NULL AND @Item IS NOT NULL AND @ProdLoc IS NOT NULL AND @StartLoc IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] A fixture resolved', @Expected = N'ok', @Actual = @n;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-MV-S', @Item, @Mfg, @Good, 10, 10, @StartLoc, @App, SYSUTCDATETIME(), 0);
DECLARE @LotS BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotS, @LotS, 0);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-MV-P', @Item, @Mfg, @Good, 10, 10, @StartLoc, @App, SYSUTCDATETIME(), 1);
DECLARE @LotP BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotP, @LotP, 0);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT @LotS AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'refusal A', @MembersJson = @j, @AppUserId = @App;
DECLARE @RN NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = (SELECT NewId FROM @o));
SET @n = CASE WHEN @RN IS NULL THEN N'missing' ELSE N'ok' END;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] A fixture: super-lot opened', @Expected = N'ok', @Actual = @n;

DECLARE @m TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @msg NVARCHAR(500), @exp NVARCHAR(500), @st NVARCHAR(10);
INSERT INTO @m EXEC Lots.Lot_MoveTo @LotId = @LotS, @ToLocationId = @ProdLoc, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @m;
SET @exp = N'LOT CRT080-MV-S is marked CRT (super-lot ' + @RN + N') and cannot be moved to a production location until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveTo: in a super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveTo: names the super-lot', @Expected = @exp, @Actual = @msg;
DELETE FROM @m;
INSERT INTO @m EXEC Lots.Lot_MoveTo @LotId = @LotP, @ToLocationId = @ProdLoc, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @m;
SET @exp = N'LOT CRT080-MV-P is marked CRT and cannot be moved to a production location until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveTo: CRT in no super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveTo: no super-lot = today''s exact text', @Expected = @exp, @Actual = @msg;
GO

-- =============================================
-- B. Lots.Lot_MoveToValidated
-- =============================================
DECLARE @App BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @ItemV BIGINT, @VProd BIGINT, @VSafe BIGINT;
;WITH Reach AS (
    SELECT eil.ItemId, l.Id AS LocationId, d.IsProductionDestination, d.Code AS DefCode
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    CROSS APPLY Location.ufn_AncestorLocationIds(l.Id) a
    INNER JOIN Parts.v_EffectiveItemLocation eil ON eil.LocationId = a.LocationId
    WHERE l.DeprecatedAt IS NULL
)
SELECT TOP 1 @ItemV = p.ItemId, @VProd = p.LocationId, @VSafe = s.LocationId
FROM Reach p
INNER JOIN Reach s ON s.ItemId = p.ItemId
INNER JOIN Parts.Item i ON i.Id = p.ItemId
WHERE p.IsProductionDestination = 1 AND s.IsProductionDestination = 0
  AND s.DefCode IN (N'InventoryLocation', N'InspectionStation') AND i.MaxParts IS NULL
ORDER BY p.ItemId, p.LocationId, s.LocationId;
DECLARE @n NVARCHAR(10) = CASE WHEN @ItemV IS NOT NULL AND @VProd IS NOT NULL AND @VSafe IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] B fixture resolved', @Expected = N'ok', @Actual = @n;
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-MVV-S', @ItemV, @Mfg, @Good, 5, 5, @VSafe, @App, SYSUTCDATETIME(), 0);
DECLARE @LotS BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotS, @LotS, 0);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-MVV-P', @ItemV, @Mfg, @Good, 5, 5, @VSafe, @App, SYSUTCDATETIME(), 1);
DECLARE @LotP BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotP, @LotP, 0);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT @LotS AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'refusal B', @MembersJson = @j, @AppUserId = @App;
DECLARE @RN NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = (SELECT NewId FROM @o));

DECLARE @m TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @msg NVARCHAR(500), @exp NVARCHAR(500), @st NVARCHAR(10);
INSERT INTO @m EXEC Lots.Lot_MoveToValidated @LotId = @LotS, @ToLocationId = @VProd, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @m;
SET @exp = N'LOT CRT080-MVV-S is marked CRT (super-lot ' + @RN + N') and cannot be moved to a production location until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveToValidated: in a super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveToValidated: names the super-lot', @Expected = @exp, @Actual = @msg;
DELETE FROM @m;
INSERT INTO @m EXEC Lots.Lot_MoveToValidated @LotId = @LotP, @ToLocationId = @VProd, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @m;
SET @exp = N'LOT CRT080-MVV-P is marked CRT and cannot be moved to a production location until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveToValidated: CRT in no super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_MoveToValidated: no super-lot = today''s exact text', @Expected = @exp, @Actual = @msg;
GO

-- =============================================
-- C. Workorder.MachiningIn_RecordPick
-- =============================================
DECLARE @App    BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Store  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @Term   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @n NVARCHAR(10) = CASE WHEN @Item IS NOT NULL AND @Line IS NOT NULL AND @Store IS NOT NULL AND @Term IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] C fixture resolved', @Expected = N'ok', @Actual = @n;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-MIN-S', @Item, @Origin, @Good, 40, 40, @Store, @App, SYSUTCDATETIME(), 0);
DECLARE @PickS BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@PickS, @PickS, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@PickS, NULL, @Store, @App, SYSUTCDATETIME());
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-MIN-P', @Item, @Origin, @Good, 40, 40, @Store, @App, SYSUTCDATETIME(), 1);
DECLARE @PickP BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@PickP, @PickP, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@PickP, NULL, @Store, @App, SYSUTCDATETIME());

INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT x.LotId, rs.OperationTemplateId, SYSUTCDATETIME(), 40, @App
FROM (SELECT @PickS AS LotId UNION ALL SELECT @PickP) x
CROSS JOIN Parts.RouteTemplate rt
INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'DieCast', N'TrimIn', N'TrimOut');

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT @PickS AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'refusal C', @MembersJson = @j, @AppUserId = @App;
DECLARE @RN NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = (SELECT NewId FROM @o));

DECLARE @p TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @msg NVARCHAR(500), @exp NVARCHAR(500), @st NVARCHAR(10);
INSERT INTO @p EXEC Workorder.MachiningIn_RecordPick @LotId = @PickS, @LineLocationId = @Line, @AppUserId = @App, @TerminalLocationId = @Term;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @p;
SET @exp = N'LOT CRT080-MIN-S is marked CRT (super-lot ' + @RN + N') and cannot be used until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningIn_RecordPick: in a super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningIn_RecordPick: names the super-lot', @Expected = @exp, @Actual = @msg;
DELETE FROM @p;
INSERT INTO @p EXEC Workorder.MachiningIn_RecordPick @LotId = @PickP, @LineLocationId = @Line, @AppUserId = @App, @TerminalLocationId = @Term;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @p;
SET @exp = N'LOT CRT080-MIN-P is marked CRT and cannot be used until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningIn_RecordPick: CRT in no super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningIn_RecordPick: no super-lot = today''s exact text', @Expected = @exp, @Actual = @msg;
GO

-- =============================================
-- D. Workorder.MachiningOut_Mint
-- =============================================
DECLARE @App      BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Casting  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Machined BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @Line     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @Origin   BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Uom      BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @GoodSt   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @ClosedSt BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id IN (@Casting, @Machined);
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Machined AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId = @Machined, @AppUserId = @App;
    DECLARE @Bom BIGINT = (SELECT NewId FROM @bc);
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId = @Bom, @ChildItemId = @Casting, @QtyPer = 1, @UomId = @Uom, @AppUserId = @App;
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id = @Bom, @AppUserId = @App;
END
UPDATE Lots.Lot SET LotStatusId = @ClosedSt WHERE ItemId = @Casting AND CurrentLocationId = @Line AND LotStatusId = @GoodSt;

DECLARE @cc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @mo TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @msg NVARCHAR(500), @exp NVARCHAR(500), @st NVARCHAR(10), @j NVARCHAR(MAX);

-- S: in a super-lot (opened while untagged, so the join tags it)
INSERT INTO @cc EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 4, @AppUserId = @App;
DECLARE @CastS BIGINT = (SELECT TOP 1 NewId FROM @cc);
DECLARE @CastSName NVARCHAR(50) = (SELECT TOP 1 MintedLotName FROM @cc);
DELETE FROM @cc;
SET @j = (SELECT @CastS AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'refusal D', @MembersJson = @j, @AppUserId = @App;
DECLARE @RN NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = (SELECT NewId FROM @o));
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @CastS, rs.OperationTemplateId, SYSUTCDATETIME(), 4, @App
FROM Parts.RouteTemplate rt INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rs.OperationTemplateId <> @MoTpl;

INSERT INTO @mo EXEC Workorder.MachiningOut_Mint @SourceLotId = @CastS, @OperationTemplateId = @MoTpl, @PieceCount = 4, @AppUserId = @App, @TerminalLocationId = @Line;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @mo;
SET @exp = N'LOT ' + @CastSName + N' is marked CRT (super-lot ' + @RN + N') and cannot be used until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningOut_Mint: in a super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningOut_Mint: names the super-lot', @Expected = @exp, @Actual = @msg;

-- P: CRT in no super-lot
UPDATE Lots.Lot SET LotStatusId = @ClosedSt WHERE ItemId = @Casting AND CurrentLocationId = @Line AND LotStatusId = @GoodSt;
INSERT INTO @cc EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 4, @AppUserId = @App;
DECLARE @CastP BIGINT = (SELECT TOP 1 NewId FROM @cc);
DECLARE @CastPName NVARCHAR(50) = (SELECT TOP 1 MintedLotName FROM @cc);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @CastP;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @CastP, rs.OperationTemplateId, SYSUTCDATETIME(), 4, @App
FROM Parts.RouteTemplate rt INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rs.OperationTemplateId <> @MoTpl;
DELETE FROM @mo;
INSERT INTO @mo EXEC Workorder.MachiningOut_Mint @SourceLotId = @CastP, @OperationTemplateId = @MoTpl, @PieceCount = 4, @AppUserId = @App, @TerminalLocationId = @Line;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @mo;
SET @exp = N'LOT ' + @CastPName + N' is marked CRT and cannot be used until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningOut_Mint: CRT in no super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] MachiningOut_Mint: no super-lot = today''s exact text', @Expected = @exp, @Actual = @msg;

UPDATE Lots.Lot SET CrtActive = 0 WHERE Id IN (@CastS, @CastP);
UPDATE Lots.Lot SET LotStatusId = @ClosedSt WHERE ItemId = @Casting AND CurrentLocationId = @Line AND LotStatusId = @GoodSt;
GO

-- =============================================
-- E. Workorder.Assembly_ScanIn
-- =============================================
DECLARE @App     BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @AsmItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @AsmCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @AsmFrom BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @AsmOrig BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @AsmGood BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @n NVARCHAR(10) = CASE WHEN @AsmItem IS NOT NULL AND @AsmCell IS NOT NULL AND @AsmFrom IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] E fixture resolved', @Expected = N'ok', @Actual = @n;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-AIN-S', @AsmItem, @AsmOrig, @AsmGood, 6, 6, @AsmFrom, @App, SYSUTCDATETIME(), 0);
DECLARE @AsmS BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@AsmS, @AsmS, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@AsmS, NULL, @AsmFrom, @App, SYSUTCDATETIME());
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT080-AIN-P', @AsmItem, @AsmOrig, @AsmGood, 6, 6, @AsmFrom, @App, SYSUTCDATETIME(), 1);
DECLARE @AsmP BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@AsmP, @AsmP, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@AsmP, NULL, @AsmFrom, @App, SYSUTCDATETIME());

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT @AsmS AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'refusal E', @MembersJson = @j, @AppUserId = @App;
DECLARE @RN NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = (SELECT NewId FROM @o));

DECLARE @a TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @msg NVARCHAR(500), @exp NVARCHAR(500), @st NVARCHAR(10);
INSERT INTO @a EXEC Workorder.Assembly_ScanIn @LotId = @AsmS, @CellLocationId = @AsmCell, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @a;
SET @exp = N'LOT CRT080-AIN-S is marked CRT (super-lot ' + @RN + N') and cannot be moved to a production location until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Assembly_ScanIn: in a super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Assembly_ScanIn: names the super-lot', @Expected = @exp, @Actual = @msg;
DELETE FROM @a;
INSERT INTO @a EXEC Workorder.Assembly_ScanIn @LotId = @AsmP, @CellLocationId = @AsmCell, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @a;
SET @exp = N'LOT CRT080-AIN-P is marked CRT and cannot be moved to a production location until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Assembly_ScanIn: CRT in no super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Assembly_ScanIn: no super-lot = today''s exact text', @Expected = @exp, @Actual = @msg;
GO

-- =============================================
-- F. Lots.Lot_Split   and   G. Lots.Lot_Merge
-- =============================================
DECLARE @App BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Parts.Item i ON i.Id = eil.ItemId
WHERE i.MaxLotSize IS NULL AND i.CrtEnabled = 0
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @n NVARCHAR(10) = CASE WHEN @ItemId IS NOT NULL AND @CellId IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] F/G fixture resolved', @Expected = N'ok', @Actual = @n;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @sp TABLE (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
DECLARE @mg TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @msg NVARCHAR(500), @exp NVARCHAR(500), @st NVARCHAR(10), @j NVARCHAR(MAX);

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId, @PieceCount = 20, @AppUserId = @App;
DECLARE @SpS BIGINT = (SELECT TOP 1 NewId FROM @cr); DECLARE @SpSName NVARCHAR(50) = (SELECT TOP 1 MintedLotName FROM @cr); DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId, @PieceCount = 20, @AppUserId = @App;
DECLARE @SpP BIGINT = (SELECT TOP 1 NewId FROM @cr); DECLARE @SpPName NVARCHAR(50) = (SELECT TOP 1 MintedLotName FROM @cr); DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId, @PieceCount = 20, @AppUserId = @App;
DECLARE @SpC BIGINT = (SELECT TOP 1 NewId FROM @cr);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @SpP;
SET @j = (SELECT @SpS AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'refusal F', @MembersJson = @j, @AppUserId = @App;
DECLARE @RN NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = (SELECT NewId FROM @o));
SET @n = CASE WHEN @RN IS NULL THEN N'missing' ELSE N'ok' END;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] F fixture: super-lot opened', @Expected = N'ok', @Actual = @n;

DECLARE @ChildJson NVARCHAR(MAX) =
    N'[{"pieceCount":10,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'},'
  + N' {"pieceCount":10,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'}]';
-- F
INSERT INTO @sp EXEC Lots.Lot_Split @ParentLotId = @SpS, @ChildrenJson = @ChildJson, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @sp;
SET @exp = N'LOT ' + @SpSName + N' is marked CRT (super-lot ' + @RN + N') and cannot be split until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Split: in a super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Split: names the super-lot', @Expected = @exp, @Actual = @msg;
DELETE FROM @sp;
INSERT INTO @sp EXEC Lots.Lot_Split @ParentLotId = @SpP, @ChildrenJson = @ChildJson, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @sp;
SET @exp = N'LOT ' + @SpPName + N' is marked CRT and cannot be split until Quality clears it.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Split: CRT in no super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Split: no super-lot = today''s exact text', @Expected = @exp, @Actual = @msg;

-- G: sources S (in super-lot), P (CRT, none), C (clean) -- only the tagged two are named
SET @j = N'[' + CAST(@SpS AS NVARCHAR(20)) + N',' + CAST(@SpP AS NVARCHAR(20)) + N',' + CAST(@SpC AS NVARCHAR(20)) + N']';
INSERT INTO @mg EXEC Lots.Lot_Merge @SourceLotIdsJson = @j, @OutputItemId = @ItemId, @OutputLocationId = @CellId, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @mg;
SET @exp = N'Merge refused: source LOT(s) marked CRT cannot be merged until Quality clears them: '
         + CASE WHEN @SpPName < @SpSName THEN @SpPName + N', ' + @SpSName + N' (super-lot ' + @RN + N')'
                ELSE @SpSName + N' (super-lot ' + @RN + N'), ' + @SpPName END + N'.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Merge: mixed sources are refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Merge: only the LOT in a super-lot carries the run number', @Expected = @exp, @Actual = @msg;
-- G2: the CRT LOT in no super-lot, with a clean one
SET @j = N'[' + CAST(@SpP AS NVARCHAR(20)) + N',' + CAST(@SpC AS NVARCHAR(20)) + N']';
DELETE FROM @mg;
INSERT INTO @mg EXEC Lots.Lot_Merge @SourceLotIdsJson = @j, @OutputItemId = @ItemId, @OutputLocationId = @CellId, @AppUserId = @App;
SELECT TOP 1 @st = CAST(Status AS NVARCHAR(10)), @msg = Message FROM @mg;
SET @exp = N'Merge refused: source LOT(s) marked CRT cannot be merged until Quality clears them: ' + @SpPName + N'.';
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Merge: CRT in no super-lot is refused', @Expected = N'0', @Actual = @st;
EXEC test.Assert_IsEqual @TestName = N'[Refusal] Lot_Merge: no super-lot = today''s exact text', @Expected = @exp, @Actual = @msg;
GO

-- ---- teardown: untag and close the LOTs, drop the super-lot rows ----
UPDATE Lots.Lot SET CrtActive = 0
WHERE LotName LIKE N'CRT080-%' OR Id IN (SELECT LotId FROM Quality.ControlledRunMember WHERE LotId IS NOT NULL);
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed')
WHERE LotName LIKE N'CRT080-%' OR Id IN (SELECT LotId FROM Quality.ControlledRunMember WHERE LotId IS NOT NULL);
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO
EXEC test.EndTestFile;
GO
