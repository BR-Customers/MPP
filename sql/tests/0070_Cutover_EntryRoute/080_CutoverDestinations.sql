-- =============================================
-- File:         0070_Cutover_EntryRoute/080_CutoverDestinations.sql
-- Description:  Where the cutover operator may count stock in.
--
--               The line itself is always offered and is the default (today's
--               behaviour, unchanged if the operator ignores the control).
--               Beyond it, only locations flagged IsCutoverDestination -- the
--               warehouse and the two trim stores -- NOT every
--               IsStockLocation row, which would also offer Shipping IN/OUT
--               and two inspection points.
--
--               The flag is per-ROW, not per-type: WHSE and Shipping IN are
--               both SupportArea, so the type cannot discriminate.
--
--               Both trim stores are named 'Trim Storage'. The proc qualifies
--               a colliding name with its parent and leaves a unique name
--               alone, so the operator never sees the same label twice.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/080_CutoverDestinations.sql';
GO

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');

CREATE TABLE #D (Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(200),
                 ParentName NVARCHAR(200), IsDefault BIT, DisplayName NVARCHAR(400));

INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;

-- (1) The line is offered, exactly once, and is the default.
DECLARE @a1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D WHERE Id = @Line);
EXEC test.Assert_IsEqual @TestName = N'[Dest] the line is offered exactly once',
    @Expected = N'1', @Actual = @a1;

DECLARE @a2 NVARCHAR(10) = (SELECT CAST(IsDefault AS NVARCHAR(10)) FROM #D WHERE Id = @Line);
EXEC test.Assert_IsEqual @TestName = N'[Dest] the line is the default',
    @Expected = N'1', @Actual = @a2;

-- (2) The line sorts first -- it is what the operator wants nine times in ten.
DECLARE @a3 NVARCHAR(20) = (SELECT TOP 1 CAST(Id AS NVARCHAR(20)) FROM #D);
DECLARE @a3e NVARCHAR(20) = CAST(@Line AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Dest] the line sorts first',
    @Expected = @a3e, @Actual = @a3;

-- (3) The three flagged destinations are offered.
DECLARE @a4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D
                            WHERE Code IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE'));
EXEC test.Assert_IsEqual @TestName = N'[Dest] warehouse and both trim stores are offered',
    @Expected = N'3', @Actual = @a4;

-- (4) Shipping and inspection are NOT offered, though they are IsStockLocation.
DECLARE @a5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D
                            WHERE Code IN (N'SHIPIN', N'SHIPOUT', N'INSP-SORT'));
EXEC test.Assert_IsEqual @TestName = N'[Dest] shipping and inspection are not offered',
    @Expected = N'0', @Actual = @a5;

-- (5) A colliding name is qualified by its parent.
DECLARE @a6 NVARCHAR(400) = (SELECT DisplayName FROM #D WHERE Code = N'TRIM1-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] colliding name is qualified by its parent',
    @Expected = N'Trim Shop 1 - Trim Storage', @Actual = @a6;

-- (6) A unique name is left alone -- no needless 'Madison Facility - Warehouse'.
DECLARE @a7 NVARCHAR(400) = (SELECT DisplayName FROM #D WHERE Code = N'WHSE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] a unique name is not qualified',
    @Expected = N'Warehouse', @Actual = @a7;

-- (7) A deprecated destination drops out.
UPDATE Location.Location SET DeprecatedAt = SYSUTCDATETIME() WHERE Code = N'TRIM2-STORE';
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;
DECLARE @a8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D WHERE Code = N'TRIM2-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] a deprecated destination drops out',
    @Expected = N'0', @Actual = @a8;
UPDATE Location.Location SET DeprecatedAt = NULL WHERE Code = N'TRIM2-STORE';

-- (8) With TRIM2 gone, TRIM1's name no longer collides -- and un-qualifies.
--     Guards the window function against being a static prefix.
UPDATE Location.Location SET DeprecatedAt = SYSUTCDATETIME() WHERE Code = N'TRIM2-STORE';
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;
DECLARE @a9 NVARCHAR(400) = (SELECT DisplayName FROM #D WHERE Code = N'TRIM1-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] name qualification is dynamic, not a fixed prefix',
    @Expected = N'Trim Storage', @Actual = @a9;
UPDATE Location.Location SET DeprecatedAt = NULL WHERE Code = N'TRIM2-STORE';

-- (9) A NULL line still lists the destinations, with no line row.
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = NULL;
DECLARE @a10 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D);
EXEC test.Assert_IsEqual @TestName = N'[Dest] NULL line lists the three destinations only',
    @Expected = N'3', @Actual = @a10;

DROP TABLE #D;
GO

EXEC test.EndTestFile;
GO
