-- =============================================
-- File:         0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql
-- Description:  Which die cast machines the cutover scan offers for a part.
--
--               EXACT match at the machine tier, deliberately NOT the
--               Parts.v_EffectiveItemLocation ancestor cascade: eligibility is
--               recorded mostly at the Area and Line tiers, so the cascade
--               returns the same 11 machines for every part in the plant and
--               filters nothing. The machine-tier rows are the deliberate
--               signal.
--
--               A part with NO machine-tier row falls back to every active die
--               cast machine (IsEligible = 0 on each), so the operator can
--               always record what the paper tag says.
--
--               This file builds its own area + machines so it is
--               order-independent inside the suite.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql';
GO

-- Resolve an item that provably carries NO die-cast-machine eligibility row,
-- rather than naming one. The fallback assertions below are only meaningful if
-- the item's ONLY machine-tier rows are the ones this file creates, and the
-- seeded plant maps several real parts to real machines.
DECLARE @Item BIGINT = (
    SELECT TOP 1 i.Id FROM Parts.Item i
    WHERE i.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      INNER JOIN Location.Location l ON l.Id = il.LocationId
                      INNER JOIN Location.LocationTypeDefinition d
                              ON d.Id = l.LocationTypeDefinitionId
                      WHERE il.ItemId = i.Id AND il.DeprecatedAt IS NULL
                        AND d.Code = N'DieCastMachine')
    ORDER BY i.Id);

DECLARE @AreaDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');
DECLARE @MachDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @Facility BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                            INNER JOIN Location.LocationTypeDefinition d
                                    ON d.Id = l.LocationTypeDefinitionId
                            WHERE d.Code = N'Facility' AND l.DeprecatedAt IS NULL
                            ORDER BY l.Id);

-- Pre-flight: clear this file's fixtures from any earlier failed run.
DELETE il FROM Parts.ItemLocation il
INNER JOIN Location.Location l ON l.Id = il.LocationId
WHERE l.Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code = N'ZZDC-AREA';

-- Fixture: one area with three machines. M01 + M02 are eligible for the item;
-- M03 is not. A fourth machine is created deprecated to prove exclusion.
DECLARE @Area BIGINT;
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
VALUES (@AreaDef, @Facility, N'ZZ Die Cast Fixture', N'ZZDC-AREA', 900, SYSUTCDATETIME());
SET @Area = SCOPE_IDENTITY();

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt, DeprecatedAt)
VALUES (@MachDef, @Area, N'Machine 01', N'ZZDC-M01', 901, SYSUTCDATETIME(), NULL),
       (@MachDef, @Area, N'Machine 02', N'ZZDC-M02', 902, SYSUTCDATETIME(), NULL),
       (@MachDef, @Area, N'Machine 03', N'ZZDC-M03', 903, SYSUTCDATETIME(), SYSUTCDATETIME());

DECLARE @M01 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZDC-M01');
DECLARE @M02 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZDC-M02');
DECLARE @M03 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZDC-M03');

INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt)
VALUES (@Item, @M01, SYSUTCDATETIME()),
       (@Item, @M02, SYSUTCDATETIME()),
       (@Item, @M03, SYSUTCDATETIME());   -- deprecated machine: must not appear

CREATE TABLE #M (Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(200),
                 AreaCode NVARCHAR(100), AreaName NVARCHAR(200), IsEligible BIT);

-- (1) An item with machine-tier rows gets exactly those machines.
DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @Item;
DECLARE @c1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #M WHERE Code LIKE N'ZZDC-%');
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] eligible item gets its two machines',
    @Expected = N'2', @Actual = @c1;

-- (2) A deprecated machine is excluded even though it has an eligibility row.
DECLARE @c2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #M WHERE Id = @M03);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] deprecated machine excluded',
    @Expected = N'0', @Actual = @c2;

-- (3) Every row of a shortlist is flagged eligible.
DECLARE @c3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #M WHERE Code LIKE N'ZZDC-%' AND IsEligible = 0);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] shortlist rows carry IsEligible = 1',
    @Expected = N'0', @Actual = @c3;

-- (4) The area is resolved for the label -- machine Names collide across areas
--     (four 'Machine 01's in the real plant), so the area is what disambiguates.
DECLARE @c4 NVARCHAR(200) = (SELECT AreaName FROM #M WHERE Id = @M01);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] area name resolved for the label',
    @Expected = N'ZZ Die Cast Fixture', @Actual = @c4;

-- (5) Ordering is (AreaCode, Code) -- not Name, which is ambiguous.
DECLARE @c5 NVARCHAR(100) = (SELECT STRING_AGG(Code, N',') WITHIN GROUP (ORDER BY AreaCode, Code)
                             FROM #M WHERE Code LIKE N'ZZDC-%');
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] ordered by area then code',
    @Expected = N'ZZDC-M01,ZZDC-M02', @Actual = @c5;

-- (6) Fallback: an item with NO machine-tier row gets EVERY active machine.
DECLARE @TotalActive NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL);

DELETE FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId IN (@M01, @M02, @M03);

DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @Item;
DECLARE @c6 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] no machine-tier row falls back to all machines',
    @Expected = @TotalActive, @Actual = @c6;

-- (7) Fallback rows are flagged so a caller can tell a shortlist from a fallback.
DECLARE @c7 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M WHERE IsEligible = 1);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] fallback rows carry IsEligible = 0',
    @Expected = N'0', @Actual = @c7;

-- (8) NULL item is the fallback branch too (first paint, before a part is picked).
DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = NULL;
DECLARE @c8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] NULL item returns all machines',
    @Expected = @TotalActive, @Actual = @c8;

-- (9) A deprecated ItemLocation row does not make its machine eligible.
INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, DeprecatedAt)
VALUES (@Item, @M01, SYSUTCDATETIME(), SYSUTCDATETIME());
DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @Item;
DECLARE @c9 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] deprecated eligibility row does not shortlist',
    @Expected = @TotalActive, @Actual = @c9;

DROP TABLE #M;

-- Teardown: eligibility rows before locations (FK), children before parent.
DELETE il FROM Parts.ItemLocation il
INNER JOIN Location.Location l ON l.Id = il.LocationId
WHERE l.Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code = N'ZZDC-AREA';
GO

EXEC test.EndTestFile;
GO
