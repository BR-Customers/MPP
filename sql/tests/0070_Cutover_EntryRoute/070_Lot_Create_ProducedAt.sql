-- =============================================
-- File:         0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql
-- Description:  Lot_Create's @ProducedAtLocationId -- the die cast machine the
--               cutover operator read off the paper tag.
--
--               The parameter defaults NULL so every existing caller (die cast
--               mint, machining/assembly mints, every other test file) is
--               unaffected; the omitted case is asserted here explicitly.
--
--               Validation is deliberately NARROW: active, and a die cast
--               machine. It does NOT re-check eligibility, because the picker's
--               fallback list is by definition ineligible -- gating on
--               eligibility would reject exactly the picks the fallback exists
--               to allow.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql';
GO

DECLARE @U      BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MachDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @Facility BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                            INNER JOIN Location.LocationTypeDefinition d
                                    ON d.Id = l.LocationTypeDefinitionId
                            WHERE d.Code = N'Facility' AND l.DeprecatedAt IS NULL
                            ORDER BY l.Id);

-- Pre-flight: this file uses fixed LOT names, so a failed run can strand them.
DECLARE @Stale TABLE (Id BIGINT);
INSERT INTO @Stale SELECT Id FROM Lots.Lot WHERE LotName IN (N'ZZPA-0001', N'ZZPA-0002');
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId  IN (SELECT Id FROM @Stale)
                                        OR DescendantLotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.Lot                WHERE Id IN (SELECT Id FROM @Stale);

DELETE FROM Location.Location WHERE Code = N'ZZPA-M01';
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
VALUES (@MachDef, @Facility, N'Machine 99', N'ZZPA-M01', 990, SYSUTCDATETIME());
DECLARE @Mach BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZPA-M01');

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- (1) A valid die cast machine is accepted and written.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @LotName = N'ZZPA-0001', @ProducedAtLocationId = @Mach;
DECLARE @Lot1 BIGINT = (SELECT NewId FROM #C);
DECLARE @d1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] valid die cast machine accepted',
    @Expected = N'1', @Actual = @d1;

DECLARE @d2 NVARCHAR(20) = (SELECT CAST(ProducedAtLocationId AS NVARCHAR(20))
                            FROM Lots.Lot WHERE Id = @Lot1);
DECLARE @d2e NVARCHAR(20) = CAST(@Mach AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] machine written to the LOT',
    @Expected = @d2e, @Actual = @d2;

-- (2) The LotCreated event JSON carries a resolved-name ProducedAt object.
DECLARE @Json NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Lots.LotEventLog
                               WHERE LotId = @Lot1 ORDER BY Id);
DECLARE @d3 NVARCHAR(100) = JSON_VALUE(@Json, N'$.ProducedAt.Code');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] event JSON carries the machine code',
    @Expected = N'ZZPA-M01', @Actual = @d3;

DECLARE @d4 NVARCHAR(200) = JSON_VALUE(@Json, N'$.ProducedAt.Name');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] event JSON carries the machine name',
    @Expected = N'Machine 99', @Actual = @d4;

-- (3) The audit Description names the machine, beside the existing tool clause.
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Lots.LotEventLog
                               WHERE LotId = @Lot1 ORDER BY Id);
EXEC test.Assert_Contains @TestName = N'[ProducedAt] audit description names the machine',
    @HaystackStr = @Desc, @NeedleStr = N'Machine 99';

-- (4) Omitted (the default) leaves the column NULL and the JSON key absent.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @LotName = N'ZZPA-0002';
DECLARE @Lot2 BIGINT = (SELECT NewId FROM #C);
DECLARE @d5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] omitted parameter still creates',
    @Expected = N'1', @Actual = @d5;

DECLARE @d6 NVARCHAR(20) = (SELECT CAST(ProducedAtLocationId AS NVARCHAR(20))
                            FROM Lots.Lot WHERE Id = @Lot2);
EXEC test.Assert_IsNull @TestName = N'[ProducedAt] omitted leaves the column NULL', @Value = @d6;

DECLARE @Json2 NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Lots.LotEventLog
                                WHERE LotId = @Lot2 ORDER BY Id);
DECLARE @d7 NVARCHAR(100) = JSON_VALUE(@Json2, N'$.ProducedAt.Code');
EXEC test.Assert_IsNull @TestName = N'[ProducedAt] omitted writes no ProducedAt key', @Value = @d7;

-- (5) A location that is not a die cast machine is rejected, and no LOT is made.
DECLARE @BeforeCount INT = (SELECT COUNT(*) FROM Lots.Lot);
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @ProducedAtLocationId = @Line;      -- a production LINE, not a machine
DECLARE @d8 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] non-machine location rejected',
    @Expected = N'0', @Actual = @d8;

DECLARE @d9 NVARCHAR(500) = (SELECT Message FROM #C);
EXEC test.Assert_Contains @TestName = N'[ProducedAt] rejection message names the rule',
    @HaystackStr = @d9, @NeedleStr = N'die cast machine';

DECLARE @d10 NVARCHAR(10) = (SELECT CAST(COUNT(*) - @BeforeCount AS NVARCHAR(10)) FROM Lots.Lot);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] rejection creates no LOT',
    @Expected = N'0', @Actual = @d10;

-- (6) A deprecated machine is rejected.
UPDATE Location.Location SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @Mach;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @ProducedAtLocationId = @Mach;
DECLARE @d11 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] deprecated machine rejected',
    @Expected = N'0', @Actual = @d11;
UPDATE Location.Location SET DeprecatedAt = NULL WHERE Id = @Mach;

DROP TABLE #C;

-- Teardown. LotGenealogyClosure BEFORE the LOTs (Msg 547 otherwise), and the
-- LOTs before the machine they reference.
DELETE FROM Lots.LotEventLog WHERE LotId IN (@Lot1, @Lot2);
DELETE FROM Lots.LotMovement WHERE LotId IN (@Lot1, @Lot2);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (@Lot1, @Lot2);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (@Lot1, @Lot2)
                                        OR DescendantLotId IN (@Lot1, @Lot2);
DELETE FROM Lots.Lot WHERE Id IN (@Lot1, @Lot2);
DELETE FROM Location.Location WHERE Code = N'ZZPA-M01';
GO

EXEC test.EndTestFile;
GO
