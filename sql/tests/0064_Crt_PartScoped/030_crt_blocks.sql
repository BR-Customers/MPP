-- =============================================
-- File:         0064_Crt_PartScoped/030_crt_blocks.sql
-- Author:       Blue Ridge Automation
-- Description:  Lots.ufn_CrtBlocksAdvance / Lots.ufn_CrtBlocksMoveTo -- the
--               CRT enforcement guards (design D4, D5). Task 3 of the
--               part-scoped CRT feature.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0064_Crt_PartScoped/030_crt_blocks.sql';
GO

-- -- Fixture --------------------------------------------------------------
-- Run-Tests.ps1 resets with -SkipDemoSeed, so Lots.Lot starts EMPTY and is
-- then filled by whatever earlier test files happened to create. Never grab
-- an arbitrary existing LOT: its status, hold state and location are another
-- test's business, and a guard test that passes because the LOT was already
-- closed proves nothing. INSERT our own, as 020_crt_for_mint.sql does.
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @StartLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL ORDER BY l.Id);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-CRTBLK-CRT', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 1);
DECLARE @LotCrt BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-CRTBLK-OK', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 0);
DECLARE @LotOk BIGINT = SCOPE_IDENTITY();

DECLARE @ProdLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @SafeLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 0 AND d.Code IN (N'InventoryLocation', N'InspectionStation', N'Receiving')
      AND l.DeprecatedAt IS NULL ORDER BY l.Id);

-- -- Assertions -------------------------------------------------------------
DECLARE @b BIT;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksAdvance(@LotCrt);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] CRT lot blocks advance', @Expected = N'1', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksAdvance(@LotOk);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] clean lot does not block advance', @Expected = N'0', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksAdvance(-1);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] nonexistent lot does not block advance', @Expected = N'0', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotCrt, @ProdLoc);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] CRT lot blocked moving to production', @Expected = N'1', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotCrt, @SafeLoc);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] CRT lot ALLOWED moving to inspection/inventory (D5)', @Expected = N'0', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotOk, @ProdLoc);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] clean lot moves to production freely', @Expected = N'0', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksMoveTo(-1, @ProdLoc);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] nonexistent lot does not block move', @Expected = N'0', @Actual = @b;
GO
EXEC test.EndTestFile;
GO
