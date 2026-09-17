-- =============================================
-- File:         0070_Cutover_EntryRoute/080_CutoverDestinations.sql
-- Description:  Where the cutover operator may count stock in.
--
--               The line itself is always offered. Beyond it, only locations
--               flagged IsCutoverDestination -- the warehouse and the two trim
--               stores -- NOT every IsStockLocation row, which would also offer
--               Shipping IN/OUT and two inspection points.
--
--               The flag is per-ROW, not per-type: WHSE and Shipping IN are
--               both SupportArea, so the type cannot discriminate.
--
--               THE DEFAULT (2026-09-17). With a part given, the default is the
--               trim store the part is eligible at, so depositing at the line
--               takes a deliberate pick. No part, or a part eligible at no trim
--               store, leaves the line as the default. When the "line" is itself
--               a cutover destination (the operator picked Warehouse or a trim
--               store as the source) it is its own default.
--
--               LABELS. Both trim stores are named 'Trim Storage' (the site
--               model is authoritative for Names), so the proc labels them by
--               what the floor calls them: Trim Shop 1 = Tumble, Trim Shop 2 =
--               Blast. Any other colliding name is still qualified by its parent.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/080_CutoverDestinations.sql';
GO

DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Whse  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');
DECLARE @T2    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM2');
DECLARE @T1S   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @T2S   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM2-STORE');

-- Two items with NO eligibility anywhere up either trim store's chain, so the
-- fixture row below is the only thing that can make one trim-eligible.
DECLARE @Free TABLE (Rn INT, Id BIGINT);
INSERT INTO @Free
SELECT TOP 2 ROW_NUMBER() OVER (ORDER BY i.Id), i.Id
FROM Parts.Item i
WHERE i.DeprecatedAt IS NULL
  AND NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e
                  WHERE e.ItemId = i.Id
                    AND (e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@T1S))
                      OR e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@T2S))))
ORDER BY i.Id;
DECLARE @ItemT2   BIGINT = (SELECT Id FROM @Free WHERE Rn = 1);  -- eligible at Trim Shop 2 only
DECLARE @ItemNone BIGINT = (SELECT Id FROM @Free WHERE Rn = 2);  -- eligible at neither

-- Eligibility at the SHOP tier, not the store: the proc must cascade.
INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt)
VALUES (@ItemT2, @T2, SYSUTCDATETIME());

CREATE TABLE #D (Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(400),
                 ParentName NVARCHAR(400), IsDefault BIT, DisplayName NVARCHAR(800));

INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;

-- (1) The line is offered, exactly once, and with no part it is the default.
DECLARE @a1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D WHERE Id = @Line);
EXEC test.Assert_IsEqual @TestName = N'[Dest] the line is offered exactly once',
    @Expected = N'1', @Actual = @a1;

DECLARE @a2 NVARCHAR(10) = (SELECT CAST(IsDefault AS NVARCHAR(10)) FROM #D WHERE Id = @Line);
EXEC test.Assert_IsEqual @TestName = N'[Dest] with no part the line is the default',
    @Expected = N'1', @Actual = @a2;

-- (2) The line sorts first.
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

-- (5) The trim stores carry their floor names.
DECLARE @a6 NVARCHAR(800) = (SELECT DisplayName FROM #D WHERE Code = N'TRIM1-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] Trim Shop 1 store is labelled Tumble',
    @Expected = N'Tumble Trim Storage', @Actual = @a6;
DECLARE @a6b NVARCHAR(800) = (SELECT DisplayName FROM #D WHERE Code = N'TRIM2-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] Trim Shop 2 store is labelled Blast',
    @Expected = N'Blast Trim Storage', @Actual = @a6b;

-- (6) A unique name is left alone -- no needless 'Madison Facility - Warehouse'.
DECLARE @a7 NVARCHAR(800) = (SELECT DisplayName FROM #D WHERE Code = N'WHSE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] a unique name is not qualified',
    @Expected = N'Warehouse', @Actual = @a7;

-- (7) A deprecated destination drops out.
UPDATE Location.Location SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @T2S;
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;
DECLARE @a8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D WHERE Id = @T2S);
EXEC test.Assert_IsEqual @TestName = N'[Dest] a deprecated destination drops out',
    @Expected = N'0', @Actual = @a8;
UPDATE Location.Location SET DeprecatedAt = NULL WHERE Id = @T2S;

-- (8) A NULL line still lists the destinations, with no line row.
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = NULL;
DECLARE @a10 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D);
EXEC test.Assert_IsEqual @TestName = N'[Dest] NULL line lists the three destinations only',
    @Expected = N'3', @Actual = @a10;

-- (9) A part eligible at a trim shop makes that shop's store the default,
--     and the line is no longer the default.
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line, @ItemId = @ItemT2;
DECLARE @a11 NVARCHAR(100) = (SELECT STRING_AGG(Code, N',') FROM #D WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[Dest] part eligible at Trim Shop 2 defaults to its store',
    @Expected = N'TRIM2-STORE', @Actual = @a11;

-- (10) A part eligible at no trim store leaves the line as the default.
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line, @ItemId = @ItemNone;
DECLARE @a12 NVARCHAR(100) = (SELECT STRING_AGG(Code, N',') FROM #D WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[Dest] part eligible at no trim store defaults to the line',
    @Expected = N'MA1-5GOF', @Actual = @a12;

-- (11) Picking the warehouse as the source: it is its own default, and the
--      part's trim eligibility does not override that.
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Whse, @ItemId = @ItemT2;
DECLARE @a13 NVARCHAR(100) = (SELECT STRING_AGG(Code, N',') FROM #D WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[Dest] warehouse as source is its own default',
    @Expected = N'WHSE', @Actual = @a13;
DECLARE @a14 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D WHERE Id = @Whse);
EXEC test.Assert_IsEqual @TestName = N'[Dest] warehouse as source is listed once',
    @Expected = N'1', @Actual = @a14;

-- (12) The source row carries the floor label too (the header reads it).
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @T1S;
DECLARE @a15 NVARCHAR(800) = (SELECT DisplayName FROM #D WHERE Id = @T1S);
EXEC test.Assert_IsEqual @TestName = N'[Dest] trim store as source keeps its floor label',
    @Expected = N'Tumble Trim Storage', @Actual = @a15;

DROP TABLE #D;
DELETE FROM Parts.ItemLocation WHERE ItemId = @ItemT2 AND LocationId = @T2;
GO

EXEC test.EndTestFile;
GO
