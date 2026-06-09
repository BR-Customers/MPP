-- =============================================
-- File:         0020_PlantFloor_Foundation/035_IdentifierSequence.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Lots.IdentifierSequence_Next (B6, row-locked,
--               gap-free minting). Asserts: formatted-string shape for
--               MESL{0:D7} and MESI{0:D7}; strictly-increasing consecutive
--               calls; unknown @Code raises; rollover breach at EndingValue
--               raises.
--
--               Pre-conditions:
--                 - Migration 0020 applied (IdentifierSequence seeded
--                   Lot=MESL@3000000, SerializedItem=MESI@3000000)
--                 - Lots.IdentifierSequence_Next deployed
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/035_IdentifierSequence.sql';
GO

-- =============================================
-- Test 1: Lot sequence returns a correctly-formatted MESL string
--   Seed LastValue = 3,000,000 -> first mint = MESL3000001 (7-wide pad).
-- =============================================
DECLARE @V NVARCHAR(50);
CREATE TABLE #M1 (Value NVARCHAR(50));
INSERT INTO #M1 EXEC Lots.IdentifierSequence_Next @Code = N'Lot';
SELECT @V = Value FROM #M1;
DROP TABLE #M1;

EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqLot] First mint is MESL3000001',
    @Expected = N'MESL3000001',
    @Actual   = @V;
GO

-- =============================================
-- Test 2: Consecutive calls strictly increase (gap-free +1)
-- =============================================
DECLARE @V2 NVARCHAR(50), @V3 NVARCHAR(50);
CREATE TABLE #M2 (Value NVARCHAR(50));
INSERT INTO #M2 EXEC Lots.IdentifierSequence_Next @Code = N'Lot';
SELECT @V2 = Value FROM #M2;
DROP TABLE #M2;

CREATE TABLE #M3 (Value NVARCHAR(50));
INSERT INTO #M3 EXEC Lots.IdentifierSequence_Next @Code = N'Lot';
SELECT @V3 = Value FROM #M3;
DROP TABLE #M3;

EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqLot] Second call mints MESL3000002',
    @Expected = N'MESL3000002',
    @Actual   = @V2;
EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqLot] Third call mints MESL3000003',
    @Expected = N'MESL3000003',
    @Actual   = @V3;
GO

-- =============================================
-- Test 3: SerializedItem sequence formats with the MESI prefix
-- =============================================
DECLARE @VI NVARCHAR(50);
CREATE TABLE #M4 (Value NVARCHAR(50));
INSERT INTO #M4 EXEC Lots.IdentifierSequence_Next @Code = N'SerializedItem';
SELECT @VI = Value FROM #M4;
DROP TABLE #M4;

EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqItem] First MESI mint is MESI3000001',
    @Expected = N'MESI3000001',
    @Actual   = @VI;
GO

-- =============================================
-- Test 4: LastValue persisted (table reflects the mint)
-- =============================================
DECLARE @Last BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @LastStr NVARCHAR(20) = CAST(@Last AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqLot] LastValue persisted at 3000003 after 3 mints',
    @Expected = N'3000003',
    @Actual   = @LastStr;
GO

-- =============================================
-- Test 5: Unknown @Code raises (no row minted)
-- =============================================
DECLARE @Raised NVARCHAR(1) = N'0';
BEGIN TRY
    CREATE TABLE #M5 (Value NVARCHAR(50));
    INSERT INTO #M5 EXEC Lots.IdentifierSequence_Next @Code = N'NoSuchCode';
    DROP TABLE #M5;
END TRY
BEGIN CATCH
    SET @Raised = N'1';
    IF OBJECT_ID('tempdb..#M5') IS NOT NULL DROP TABLE #M5;
END CATCH
EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqUnknown] Unknown @Code raises',
    @Expected = N'1',
    @Actual   = @Raised;
GO

-- =============================================
-- Test 6: Rollover breach at EndingValue raises and does not advance
--   Park a throwaway sequence at its EndingValue, then mint -> raise.
-- =============================================
IF NOT EXISTS (SELECT 1 FROM Lots.IdentifierSequence WHERE Code = N'TEST-ROLLOVER')
    INSERT INTO Lots.IdentifierSequence (Code, Name, FormatString, StartingValue, EndingValue, LastValue)
    VALUES (N'TEST-ROLLOVER', N'Rollover test', N'TST{0:D4}', 1, 9999, 9999);

DECLARE @RaisedR NVARCHAR(1) = N'0';
BEGIN TRY
    CREATE TABLE #M6 (Value NVARCHAR(50));
    INSERT INTO #M6 EXEC Lots.IdentifierSequence_Next @Code = N'TEST-ROLLOVER';
    DROP TABLE #M6;
END TRY
BEGIN CATCH
    SET @RaisedR = N'1';
    IF OBJECT_ID('tempdb..#M6') IS NOT NULL DROP TABLE #M6;
END CATCH
EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqRollover] Mint past EndingValue raises',
    @Expected = N'1',
    @Actual   = @RaisedR;

-- LastValue must NOT have advanced past EndingValue (the UPDATE rolls back on raise)
DECLARE @RollLast BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'TEST-ROLLOVER');
DECLARE @RollStr NVARCHAR(20) = CAST(@RollLast AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[IdSeqRollover] LastValue not advanced past EndingValue',
    @Expected = N'9999',
    @Actual   = @RollStr;

-- cleanup
DELETE FROM Lots.IdentifierSequence WHERE Code = N'TEST-ROLLOVER';
GO

EXEC test.EndTestFile;
GO
