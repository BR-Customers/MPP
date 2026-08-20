-- =============================================
-- File:         0063_Crt_PartScoped/020_crt_for_mint.sql
-- Author:       Blue Ridge Automation
-- Description:  Lots.ufn_CrtForMint -- the single mint-time CRT decision
--               (design D1: part flag OR terminal switch OR CRT input LOT,
--               D2 propagation, D3 evaluated at mint time only).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/020_crt_for_mint.sql';
GO

-- -- Fixture --------------------------------------------------------------
DECLARE @ItemPlain BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemCrt   BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id <> @ItemPlain ORDER BY Id);
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @ItemPlain;
UPDATE Parts.Item SET CrtEnabled = 1 WHERE Id = @ItemCrt;

DECLARE @TermPlain BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @TermCrt BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.Id <> @TermPlain ORDER BY l.Id);

DECLARE @AdCrt BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition
    WHERE AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL);
DELETE FROM Location.LocationAttribute WHERE LocationId IN (@TermCrt, @TermPlain) AND LocationAttributeDefinitionId = @AdCrt;
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@TermCrt, @AdCrt, N'1');

-- A freshly-rebuilt test database seeds ZERO Lots.Lot rows (verified against
-- MPP_MES_Test_Crt), so the two input LOTs must be created here, not picked
-- from pre-existing data -- an empty Lots.Lot means @LotPlain/@LotCrt would
-- silently resolve to NULL and every propagation assertion would pass for
-- the wrong reason (STRING_SPLIT('', ',') on a NULL CSV).
DECLARE @App BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-CRTMINT-PLAIN', @ItemPlain, 1 /*Manufactured*/, 1 /*Good*/, 10, @TermPlain, @App, 0);
DECLARE @LotPlain BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-CRTMINT-CRT', @ItemPlain, 1 /*Manufactured*/, 1 /*Good*/, 10, @TermPlain, @App, 1);
DECLARE @LotCrt BIGINT = SCOPE_IDENTITY();

-- -- Assertions -------------------------------------------------------------
DECLARE @b BIT;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, NULL, NULL);
EXEC test.Assert_IsEqual @TestName = N'[ForMint] nothing set -> 0', @Expected = N'0', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemCrt, NULL, NULL);
EXEC test.Assert_IsEqual @TestName = N'[ForMint] part flag alone -> 1', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermCrt, NULL);
EXEC test.Assert_IsEqual @TestName = N'[ForMint] terminal switch alone -> 1', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermPlain, CAST(@LotCrt AS NVARCHAR(20)));
EXEC test.Assert_IsEqual @TestName = N'[ForMint] CRT input alone -> 1 (propagation)', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermPlain, CAST(@LotPlain AS NVARCHAR(20)));
EXEC test.Assert_IsEqual @TestName = N'[ForMint] clean input -> 0', @Expected = N'0', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermPlain,
    CAST(@LotPlain AS NVARCHAR(20)) + N',' + CAST(@LotCrt AS NVARCHAR(20)));
EXEC test.Assert_IsEqual @TestName = N'[ForMint] one CRT among several inputs -> 1', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, NULL, N'');
EXEC test.Assert_IsEqual @TestName = N'[ForMint] empty csv is not an error -> 0', @Expected = N'0', @Actual = @b;
GO
EXEC test.EndTestFile;
GO
