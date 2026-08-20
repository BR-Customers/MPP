-- =============================================
-- File:         0063_Crt_PartScoped/040_propagation.sql
-- Author:       Blue Ridge Automation
-- Description:  CRT is stamped at every mint point and propagates from the
--               consumed inputs (design D2), evaluated at MINT TIME ONLY (D3).
--               Task 4 of the part-scoped CRT feature.
--
--               Fixture notes (deviations from the task brief, deliberate):
--                 * The brief picked "TOP 1 Component / TOP 1 SubAssembly" and a
--                   DieCastMachine location. Lots.Lot_Create validates ELIGIBILITY
--                   (Parts.v_EffectiveItemLocation) and, at a cell carrying an
--                   active Tools.ToolAssignment, REQUIRES a scanned LTT + Tool +
--                   Cavity (FDS-05-034) -- an arbitrary part/location pair fails
--                   those long before it reaches the CRT stamp. This file therefore
--                   uses the seeded 6NA chain at MA1-FP6NA (casting 12270-6NA ->
--                   sub-assembly 12270-6NA-M), the same fixture
--                   0056_CrtValidation/030_CompleteTray_marks_crt.sql relies on:
--                   both parts are eligible there, MaxLotSize is 12 (so 10 pieces
--                   fit), and the cell carries no tool assignment.
--                 * The brief used ONE 3-column #r temp table for Lot_Create,
--                   Lot_SetCrt and Lot_ClearCrt. Their result shapes differ
--                   (Lot_Create returns Status/Message/NewId/MintedLotName;
--                   Set/ClearCrt return Status/Message), and an INSERT-EXEC whose
--                   column count does not match aborts the whole file with Msg 213
--                   -- a runner ERROR, not a FAIL. One temp table per shape.
--
--               The point of assertion 2 is that the sub-assembly inherits CRT
--               from its INPUT, not from its own part -- 12270-6NA-M is left
--               UNFLAGGED throughout.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/040_propagation.sql';
GO

-- -- Fixture --------------------------------------------------------------
DECLARE @CastItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @SubItem  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @Loc      BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Origin   BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @App      BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');

UPDATE Parts.Item SET CrtEnabled = 1 WHERE Id = @CastItem;
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @SubItem;

CREATE TABLE #mint (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
CREATE TABLE #tag  (Status BIT, Message NVARCHAR(500));

-- 1. A LOT of a CrtEnabled part mints CRT-active.
INSERT INTO #mint EXEC Lots.Lot_Create @ItemId = @CastItem, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Loc, @PieceCount = 10, @AppUserId = @App;
DECLARE @CastLot BIGINT = (SELECT TOP 1 NewId FROM #mint);
DECLARE @castingCrt BIT = (SELECT CrtActive FROM Lots.Lot WHERE Id = @CastLot);
EXEC test.Assert_IsEqual @TestName = N'[Prop] casting of a CRT part mints CrtActive=1',
    @Expected = N'1', @Actual = @castingCrt;

-- 2. A mint that CONSUMES it inherits CRT even though @SubItem is NOT flagged (D2).
--    Exercised through the resolver directly so the test does not depend on
--    MachiningOut_Mint's full route/BOM preconditions.
DECLARE @subCrt BIT = (SELECT CrtActive FROM Lots.ufn_CrtForMint(
    @SubItem, NULL, CAST(@CastLot AS NVARCHAR(20))));
EXEC test.Assert_IsEqual @TestName = N'[Prop] sub-assembly from a CRT casting is CrtActive=1 (part not flagged)',
    @Expected = N'1', @Actual = @subCrt;

-- 3. Clearing the casting FIRST yields a CLEAN sub-assembly -- D2's release valve.
INSERT INTO #tag EXEC Lots.Lot_ClearCrt @LotId = @CastLot, @AppUserId = @App;
DECLARE @subAfterClear BIT = (SELECT CrtActive FROM Lots.ufn_CrtForMint(
    @SubItem, NULL, CAST(@CastLot AS NVARCHAR(20))));
EXEC test.Assert_IsEqual @TestName = N'[Prop] clearing the casting before minting yields a clean sub-assembly',
    @Expected = N'0', @Actual = @subAfterClear;

-- 4. Re-tag the casting, mint a real sub-assembly LOT from it, then clear the
--    casting AGAIN. The sub-assembly keeps its own tag -- D3, mint-time only.
DELETE FROM #tag;
INSERT INTO #tag EXEC Lots.Lot_SetCrt @LotId = @CastLot, @AppUserId = @App;
DELETE FROM #mint;
INSERT INTO #mint EXEC Lots.Lot_Create @ItemId = @SubItem, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Loc, @PieceCount = 10, @AppUserId = @App;
DECLARE @SubLot BIGINT = (SELECT TOP 1 NewId FROM #mint);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @SubLot;   -- stands in for the consuming mint
DELETE FROM #tag;
INSERT INTO #tag EXEC Lots.Lot_ClearCrt @LotId = @CastLot, @AppUserId = @App;
DECLARE @subStillCrt BIT = (SELECT CrtActive FROM Lots.Lot WHERE Id = @SubLot);
EXEC test.Assert_IsEqual @TestName = N'[Prop] clearing the casting later does NOT un-tag an existing sub-assembly',
    @Expected = N'1', @Actual = @subStillCrt;

-- 5. An UNFLAGGED part with NO terminal still mints clean -- the stamp is a
--    resolver decision, not an unconditional 1. Every Lot_Create call in this file
--    omits @TerminalLocationId, so arm 2 is inert here rather than merely "plain":
--    the real flagged-terminal case is 050_mint_procs.sql section E.
DELETE FROM #mint;
INSERT INTO #mint EXEC Lots.Lot_Create @ItemId = @SubItem, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Loc, @PieceCount = 10, @AppUserId = @App;
DECLARE @CleanLot BIGINT = (SELECT TOP 1 NewId FROM #mint);
DECLARE @cleanCrt BIT = (SELECT CrtActive FROM Lots.Lot WHERE Id = @CleanLot);
EXEC test.Assert_IsEqual @TestName = N'[Prop] unflagged part with no terminal mints CrtActive=0',
    @Expected = N'0', @Actual = @cleanCrt;

DROP TABLE #mint;
DROP TABLE #tag;

-- -- Teardown: leave the shared seeded parts unflagged for any later file ------
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id IN (@CastItem, @SubItem);
-- ... and leave no tagged LOT behind either. Assertion 4 hand-stamps @SubLot
-- CrtActive = 1 to stand in for a consuming mint; without this it would sit at
-- MA1-FP6NA permanently and seed any later file that consumes sub-assembly stock
-- from that cell (050_mint_procs.sql section D does exactly that).
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id IN (@CastLot, @SubLot, @CleanLot);
GO
EXEC test.EndTestFile;
GO
