-- =============================================
-- File:         0067_Lot_SearchAdvanced/060_cutover_machine.sql
-- Description:  A cutover LOT is findable by its die cast machine.
--
--               LOT Search resolves the origin machine through
--               Workorder.DieCastContribution -- the per-shift rows stamped at
--               the press. A cutover LOT has none: it is migrated stock whose
--               machine was read off the paper tag into
--               Lots.Lot.ProducedAtLocationId (migration 0082).
--
--               Both the FILTER and the DISPLAYED column must consider it, or
--               the captured machine is invisible on the one screen that asks
--               the question. Contribution rows still take precedence where a
--               LOT has both.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/060_cutover_machine.sql';
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

-- Pre-flight: fixed LOT name, so a failed run can strand it.
DECLARE @Stale TABLE (Id BIGINT);
INSERT INTO @Stale SELECT Id FROM Lots.Lot WHERE LotName = N'ZZCM-0001';
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId  IN (SELECT Id FROM @Stale)
                                        OR DescendantLotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.Lot                WHERE Id IN (SELECT Id FROM @Stale);
DELETE FROM Location.Location WHERE Code = N'ZZCM-M01';

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
VALUES (@MachDef, @Facility, N'Machine 77', N'ZZCM-M01', 977, SYSUTCDATETIME());
DECLARE @Mach BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZCM-M01');

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityCode NVARCHAR(4), OriginMachineName NVARCHAR(200),
    TotalCount INT
);

-- Fixture: a cutover-style LOT -- ProducedAtLocationId set, and deliberately NO
-- Workorder.DieCastContribution rows, exactly as addBasket creates it.
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 40, @AppUserId = @U,
    @LotName = N'ZZCM-0001', @ProducedAtLocationId = @Mach;
DECLARE @Lot BIGINT = (SELECT NewId FROM #C);
DECLARE @e0 NVARCHAR(20) = CAST(@Lot AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[CutoverMachine] fixture LOT created', @Value = @e0;

-- Guard the premise: the fixture really has no contribution rows.
DECLARE @e1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM Workorder.DieCastContribution WHERE LotId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] cutover LOT has no DieCastContribution rows',
    @Expected = N'0', @Actual = @e1;

-- (1) The machine FILTER finds it.
DELETE FROM #LS;
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @MachineLocationId = @Mach;
DECLARE @e2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #LS WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] machine filter finds the cutover LOT',
    @Expected = N'1', @Actual = @e2;

-- (2) The DISPLAYED column names the machine, not blank.
DECLARE @e3 NVARCHAR(200) = (SELECT OriginMachineName FROM #LS WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] origin machine column shows the recorded machine',
    @Expected = N'Machine 77', @Actual = @e3;

-- (3) Filtering by a DIFFERENT machine must not return it.
DECLARE @Other BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                         INNER JOIN Location.LocationTypeDefinition d
                                 ON d.Id = l.LocationTypeDefinitionId
                         WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL
                           AND l.Id <> @Mach ORDER BY l.Id);
DELETE FROM #LS;
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @MachineLocationId = @Other;
DECLARE @e4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #LS WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] another machine does not match it',
    @Expected = N'0', @Actual = @e4;

-- (4) A LOT with neither source must never match -- the new OR must not widen
--     the filter into "everything".
DELETE FROM #LS;
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @MachineLocationId = @Mach;
DECLARE @e5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #LS ls
                            INNER JOIN Lots.Lot l2 ON l2.Id = ls.Id
                            WHERE l2.ProducedAtLocationId IS NULL
                              AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastContribution d2
                                              WHERE d2.LotId = l2.Id AND d2.CellLocationId = @Mach));
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] LOTs with no machine at all never match',
    @Expected = N'0', @Actual = @e5;

DROP TABLE #C; DROP TABLE #LS;

-- Teardown: closure before LOTs, LOTs before the machine they reference.
DELETE FROM Lots.LotEventLog        WHERE LotId = @Lot;
DELETE FROM Lots.LotMovement        WHERE LotId = @Lot;
DELETE FROM Lots.LotStatusHistory   WHERE LotId = @Lot;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @Lot OR DescendantLotId = @Lot;
DELETE FROM Lots.Lot                WHERE Id = @Lot;
DELETE FROM Location.Location WHERE Code = N'ZZCM-M01';
GO

EXEC test.EndTestFile;
GO
