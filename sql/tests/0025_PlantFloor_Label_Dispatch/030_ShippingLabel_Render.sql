-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql
-- Author:       Blue Ridge Automation
-- Description:  Brief D -- Lots.ufn_ShippingLabelZpl renders the container shipping
--               label from the active Container LabelTemplate: token substitution for
--               part number, description, quantity, D/C part level (the BOM
--               VersionNumber actually used to mint the container's trays, zero-padded
--               to 2 digits -- v1.1 2026-08-20, was a genealogy die-rank trace), MFG lot
--               (AIM serial) and the composed 16-char serial (13218001 supplier code +
--               last 8 of the AIM serial). Asserts ASCII-only and that no {tokens} leak
--               through.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql';
GO

-- ---- fixture cleanup (re-runnable; RND namespace) ----
DELETE FROM Lots.ContainerTray WHERE ClosureMethod = N'RND-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-RENDER');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RND%');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RND%');
DELETE FROM Lots.Lot  WHERE LotName LIKE N'RND%';
DELETE FROM Parts.Bom WHERE ParentItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-RENDER');
DELETE FROM Parts.Item WHERE PartNumber = N'PN-RENDER';
DELETE FROM Tools.Tool   WHERE Code = N'RND-DIE';
DELETE FROM Tools.DieRank WHERE Code = N'RND-A';
GO

-- ---- fixture ----
DECLARE @Rank BIGINT;
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'RND-A', N'RenderTrace A');
SET @Rank = SCOPE_IDENTITY();
DECLARE @Die BIGINT;
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), N'RND-DIE', N'RND Die', @Rank,
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
SET @Die = SCOPE_IDENTITY();

-- dedicated Item with known PartNumber/Description
DECLARE @Item BIGINT;
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId)
VALUES ((SELECT TOP 1 Id FROM Parts.ItemType ORDER BY Id), N'PN-RENDER', N'DESC-RENDER',
        (SELECT TOP 1 Id FROM Parts.Uom ORDER BY Id), 1);
SET @Item = SCOPE_IDENTITY();

-- published BOM version 3 -- the FG LOTs mint against this; {DcPartLevel} should
-- render it zero-padded ('03'), not whichever BOM version is currently active.
DECLARE @Bom BIGINT;
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
VALUES (@Item, 3, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, SYSUTCDATETIME());
SET @Bom = SCOPE_IDENTITY();

DECLARE @Loc     BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Cfg     BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id);
DECLARE @Good    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @OrigMfg BIGINT = (SELECT Id FROM Lots.LotOriginType  WHERE Code = N'Manufactured');

-- casting LOT (ToolId) -> FG LOT genealogy
DECLARE @CastLot BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedByUserId)
VALUES (N'RNDCAST1', @Item, @OrigMfg, @Good, 12, @Loc, @Die, 1);
SET @CastLot = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@CastLot, @CastLot, 0);
-- two FG LOTs (one per tray; UQ_ContainerTray_FinishedGoodLot is 1:1), both from the casting
DECLARE @FgLot1 BIGINT, @FgLot2 BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, BomId, CreatedByUserId)
VALUES (N'RNDFG1', @Item, @OrigMfg, @Good, 6, @Loc, @Bom, 1);
SET @FgLot1 = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@FgLot1, @FgLot1, 0), (@CastLot, @FgLot1, 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, BomId, CreatedByUserId)
VALUES (N'RNDFG2', @Item, @OrigMfg, @Good, 6, @Loc, @Bom, 1);
SET @FgLot2 = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@FgLot2, @FgLot2, 0), (@CastLot, @FgLot2, 1);

-- container + two closed trays (6 + 6 = 12)
DECLARE @Cont BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId)
VALUES (@Item, @Cfg, @Loc, 1);
SET @Cont = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@Cont, 1, 6, SYSUTCDATETIME(), 1, N'RND-TEST', @FgLot1),
       (@Cont, 2, 6, SYSUTCDATETIME(), 1, N'RND-TEST', @FgLot2);

-- ---- render ----
DECLARE @Zpl NVARCHAR(MAX) = Lots.ufn_ShippingLabelZpl(@Cont, N'AIM12345678');

-- ---- assert ----
DECLARE @HasPart NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%PN-RENDER%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] part number present', @Expected = N'1', @Actual = @HasPart;
DECLARE @HasDesc NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%DESC-RENDER%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] description present', @Expected = N'1', @Actual = @HasDesc;
DECLARE @HasQty NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%FD12^FS%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] quantity (12) present', @Expected = N'1', @Actual = @HasQty;
-- ^FD{value}^FS is ZPL's field-data start/stop delimiter -- anchoring on it (not a
-- bare '%03%') avoids a false-positive match against unrelated coordinates/font
-- codes elsewhere in the template, which is full of two-digit numbers.
DECLARE @HasLevel NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%^FD03^FS%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] dc part level (BOM version, zero-padded) present', @Expected = N'1', @Actual = @HasLevel;
DECLARE @HasMfgLot NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%AIM12345678%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] mfg lot (AIM serial) present', @Expected = N'1', @Actual = @HasMfgLot;
DECLARE @HasSerial NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%1321800112345678%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] composed serial 13218001+last8', @Expected = N'1', @Actual = @HasSerial;
DECLARE @NoTokens NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%{%}%' THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] no unresolved {tokens} remain', @Expected = N'1', @Actual = @NoTokens;

-- ASCII-only scan
DECLARE @NonAscii INT = 0, @i INT = 1, @len INT = LEN(@Zpl);
WHILE @i <= @len
BEGIN
    IF UNICODE(SUBSTRING(@Zpl, @i, 1)) > 127 SET @NonAscii = @NonAscii + 1;
    SET @i = @i + 1;
END
DECLARE @AsciiOk NVARCHAR(10) = CASE WHEN @NonAscii = 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Render] ASCII-only ZPL', @Expected = N'1', @Actual = @AsciiOk;
GO
EXEC test.EndTestFile;
GO
