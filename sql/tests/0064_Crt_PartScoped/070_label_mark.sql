-- =============================================
-- File:         0064_Crt_PartScoped/070_label_mark.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-20
-- Description:  The CRT BANNER label (design D8, part-scoped CRT Task 6).
--
--               A CRT LOT's print emits the normal LTT ticket UNCHANGED plus a
--               SECOND, separate label that is just a large 'CRT' banner. A ZPL
--               stream may hold several ^XA..^XZ documents back to back and the
--               printer emits one label per document, so the banner is appended
--               to the rendered @Zpl -- one proc call, two physical labels, no
--               UI change. This REPLACES the old inline {CrtMark} token, which
--               had to be spliced into MPP's real label layouts; the banner
--               touches none of them.
--
--               THE LOAD-BEARING ASSERTION HERE IS THE BYTE-IDENTITY ONE: the
--               normal-label portion of a CRT print must match what a clean LOT
--               of the same part renders, modulo only the LOT name and the
--               print timestamp. That is the whole point of "print the label
--               like normal" -- if CRT ever injects a single byte into the
--               plant's real ticket layout, this fails.
--
--               Fixture notes:
--                 * Run-Tests.ps1 resets with -SkipDemoSeed, so Lots.Lot starts
--                   EMPTY and holds only what earlier test files created. This
--                   file INSERTs its own LOTs under names unique to it rather
--                   than borrowing an existing LOT.
--                 * The fixture LotNames deliberately avoid the substring 'CRT'
--                   -- {LotName} renders verbatim into the ZPL, so a name like
--                   'CRT070-...' would make the clean-label 'no CRT anywhere'
--                   assertion pass or fail on the NAME rather than on the
--                   banner under test.
--                 * Code-table Ids are resolved BY CODE, never hardcoded --
--                   'CrtBanner' is IDENTITY-assigned by migration 0066.
--                 * Lots.LotLabel_Print / _Reprint both return the FOUR-column
--                   status row (Status, Message, NewId, ZplContent); the
--                   INSERT-EXEC temp table matches that shape exactly. A wrong
--                   column list aborts the whole file with Msg 213, which
--                   surfaces as a runner ERROR, not a FAIL.
--                 * NORMALISATION for the byte-identity compare: each render's
--                   own LotName is replaced with '<LOT>' and the rendered
--                   {PrintedAt} value (a 19-char 'YYYY-MM-DD HH:MM:SS', matched
--                   by PATINDEX so it is template-agnostic) with '<TS>'. Those
--                   two are the only fields that legitimately differ between
--                   the two prints; masking them is what makes the comparison
--                   an assertion about CRT rather than about the clock.
--
--               Teardown deletes the LotLabel audit rows (LotLabel entity ->
--               Audit.OperationLog, per 0021/070), then the LotLabel rows, then
--               the two fixture LOTs.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0064_Crt_PartScoped/070_label_mark.sql';
GO

DECLARE @Item     BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @StartLoc BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @App      BIGINT = 1;
DECLARE @Mfg      BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Good     BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Primary  BIGINT = (SELECT Id FROM Lots.LabelTypeCode  WHERE Code = N'Primary');
DECLARE @Initial  BIGINT = (SELECT Id FROM Lots.PrintReasonCode WHERE Code = N'Initial');
DECLARE @Damaged  BIGINT = (SELECT Id FROM Lots.PrintReasonCode WHERE Code = N'ReprintDamaged');

-- The banner body is read from the table, not hardcoded here: the template is
-- DATA (migration 0066), so the test asserts the proc appends THE ACTIVE
-- TEMPLATE rather than re-stating a ZPL string that would drift from it.
DECLARE @Banner NVARCHAR(MAX) = (
    SELECT TOP 1 t.ZplBody
    FROM Lots.LabelTemplate t
    INNER JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
    WHERE c.Code = N'CrtBanner' AND t.DeprecatedAt IS NULL);

DECLARE @bannerPresent NVARCHAR(10) = CASE WHEN @Banner IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] an active CrtBanner template exists',
    @Expected = N'1', @Actual = @bannerPresent;

-- The banner is a standalone ZPL document carrying the word CRT and nothing
-- else of substance -- no LOT number, no part number, no barcode.
DECLARE @bannerShape NVARCHAR(10) =
    CASE WHEN ISNULL(@Banner, N'') LIKE N'^XA%'
          AND ISNULL(@Banner, N'') LIKE N'%^XZ'
          AND CHARINDEX(N'CRT', ISNULL(@Banner, N'')) > 0
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] CrtBanner template is one self-contained CRT document',
    @Expected = N'1', @Actual = @bannerShape;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'LBL070-TAGGED', @Item, @Mfg, @Good, 10, @StartLoc, @App, 1);
DECLARE @LotCrt BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'LBL070-CLEAN', @Item, @Mfg, @Good, 10, @StartLoc, @App, 0);
DECLARE @LotOk BIGINT = SCOPE_IDENTITY();

-- Lots.LotLabel_Print emits (Status, Message, NewId, ZplContent) -- verified
-- against the proc, whose header documents exactly that shape.
CREATE TABLE #z (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
DECLARE @zplCrt NVARCHAR(MAX), @zplOk NVARCHAR(MAX);

INSERT INTO #z EXEC Lots.LotLabel_Print
    @LotId = @LotCrt, @LabelTypeCodeId = @Primary, @PrintReasonCodeId = @Initial, @AppUserId = @App;
SELECT TOP 1 @zplCrt = ZplContent FROM #z;
DELETE FROM #z;
INSERT INTO #z EXEC Lots.LotLabel_Print
    @LotId = @LotOk, @LabelTypeCodeId = @Primary, @PrintReasonCodeId = @Initial, @AppUserId = @App;
SELECT TOP 1 @zplOk = ZplContent FROM #z;

-- ---- Document counts: a ZPL stream is one label per ^XA..^XZ pair ----
-- DATALENGTH (bytes), not LEN: LEN ignores trailing whitespace. '^XA' = 6 bytes NVARCHAR.
DECLARE @xaCrt INT = (DATALENGTH(ISNULL(@zplCrt, N'')) - DATALENGTH(REPLACE(ISNULL(@zplCrt, N''), N'^XA', N''))) / 6;
DECLARE @xaOk  INT = (DATALENGTH(ISNULL(@zplOk,  N'')) - DATALENGTH(REPLACE(ISNULL(@zplOk,  N''), N'^XA', N''))) / 6;
DECLARE @xaCrtStr NVARCHAR(10) = CAST(@xaCrt AS NVARCHAR(10));
DECLARE @xaOkStr  NVARCHAR(10) = CAST(@xaOk  AS NVARCHAR(10));

EXEC test.Assert_IsEqual @TestName = N'[Label] CRT lot print emits TWO ZPL documents',
    @Expected = N'2', @Actual = @xaCrtStr;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot print emits ONE ZPL document',
    @Expected = N'1', @Actual = @xaOkStr;

-- ---- The SECOND document is the banner, byte for byte ----
DECLARE @bannerBytes INT = DATALENGTH(ISNULL(@Banner, N'')) / 2;
DECLARE @crtTail NVARCHAR(MAX) = RIGHT(ISNULL(@zplCrt, N''), @bannerBytes);
EXEC test.Assert_IsEqual @TestName = N'[Label] CRT print ends with the active CrtBanner template',
    @Expected = @Banner, @Actual = @crtTail;

-- ---- Clean lot carries no CRT anywhere at all ----
DECLARE @markInClean NVARCHAR(10) =
    CASE WHEN CHARINDEX(N'CRT', ISNULL(@zplOk, N'')) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot print carries no CRT anywhere',
    @Expected = N'0', @Actual = @markInClean;

-- ---- THE POINT: the normal-label portion of a CRT print is byte-identical ----
-- Everything before the appended banner must match the clean lot's whole
-- render, modulo the two fields that legitimately differ: the LOT name and the
-- print timestamp. Both are masked below.
DECLARE @crtNormal NVARCHAR(MAX) =
    LEFT(ISNULL(@zplCrt, N''), (DATALENGTH(ISNULL(@zplCrt, N'')) / 2) - @bannerBytes);
DECLARE @okNormal  NVARCHAR(MAX) = ISNULL(@zplOk, N'');

SET @crtNormal = REPLACE(@crtNormal, N'LBL070-TAGGED', N'<LOT>');
SET @okNormal  = REPLACE(@okNormal,  N'LBL070-CLEAN',  N'<LOT>');

-- Mask every rendered {PrintedAt} ('YYYY-MM-DD HH:MM:SS', 19 chars). PATINDEX
-- keeps this template-agnostic; the loop terminates because '<TS>' has no digits.
-- NVARCHAR(100), not (60): the pattern below is 77 characters and a too-short
-- declaration truncates it mid-bracket, which silently matches NOTHING.
DECLARE @tsPat NVARCHAR(100) = N'%[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]%';
DECLARE @p INT = PATINDEX(@tsPat, @crtNormal);
WHILE @p > 0
BEGIN
    SET @crtNormal = STUFF(@crtNormal, @p, 19, N'<TS>');
    SET @p = PATINDEX(@tsPat, @crtNormal);
END
SET @p = PATINDEX(@tsPat, @okNormal);
WHILE @p > 0
BEGIN
    SET @okNormal = STUFF(@okNormal, @p, 19, N'<TS>');
    SET @p = PATINDEX(@tsPat, @okNormal);
END

EXEC test.Assert_IsEqual
    @TestName = N'[Label] CRT print normal label is byte-identical to a clean lot label',
    @Expected = @okNormal, @Actual = @crtNormal;

-- ---- No unsubstituted {Token} survives on either path ----
-- The templates are pure {Token} ZPL, so a surviving '{' can only be a missed
-- substitution -- which would print literally on a production ticket.
DECLARE @braceCrt NVARCHAR(10) =
    CASE WHEN CHARINDEX(N'{', ISNULL(@zplCrt, N'')) > 0 THEN N'1' ELSE N'0' END;
DECLARE @braceOk NVARCHAR(10) =
    CASE WHEN CHARINDEX(N'{', ISNULL(@zplOk, N'')) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] CRT print leaves no unsubstituted token',
    @Expected = N'0', @Actual = @braceCrt;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean print leaves no unsubstituted token',
    @Expected = N'0', @Actual = @braceOk;

-- ---- Reprint renders the same way (mirrors the inlined render in _Reprint) ----
DELETE FROM #z;
INSERT INTO #z EXEC Lots.LotLabel_Reprint
    @LotId = @LotCrt, @PrintReasonCodeId = @Damaged, @AppUserId = @App;
DECLARE @zplCrtRe NVARCHAR(MAX) = (SELECT TOP 1 ZplContent FROM #z);

DELETE FROM #z;
INSERT INTO #z EXEC Lots.LotLabel_Reprint
    @LotId = @LotOk, @PrintReasonCodeId = @Damaged, @AppUserId = @App;
DECLARE @zplOkRe NVARCHAR(MAX) = (SELECT TOP 1 ZplContent FROM #z);

DECLARE @xaCrtRe INT = (DATALENGTH(ISNULL(@zplCrtRe, N'')) - DATALENGTH(REPLACE(ISNULL(@zplCrtRe, N''), N'^XA', N''))) / 6;
DECLARE @xaOkRe  INT = (DATALENGTH(ISNULL(@zplOkRe,  N'')) - DATALENGTH(REPLACE(ISNULL(@zplOkRe,  N''), N'^XA', N''))) / 6;
DECLARE @xaCrtReStr NVARCHAR(10) = CAST(@xaCrtRe AS NVARCHAR(10));
DECLARE @xaOkReStr  NVARCHAR(10) = CAST(@xaOkRe  AS NVARCHAR(10));

EXEC test.Assert_IsEqual @TestName = N'[Label] CRT lot reprint emits TWO ZPL documents',
    @Expected = N'2', @Actual = @xaCrtReStr;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot reprint emits ONE ZPL document',
    @Expected = N'1', @Actual = @xaOkReStr;

DECLARE @crtReTail NVARCHAR(MAX) = RIGHT(ISNULL(@zplCrtRe, N''), @bannerBytes);
EXEC test.Assert_IsEqual @TestName = N'[Label] CRT reprint ends with the active CrtBanner template',
    @Expected = @Banner, @Actual = @crtReTail;

DECLARE @markInCleanRe NVARCHAR(10) =
    CASE WHEN CHARINDEX(N'CRT', ISNULL(@zplOkRe, N'')) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot reprint carries no CRT anywhere',
    @Expected = N'0', @Actual = @markInCleanRe;

DECLARE @braceCrtRe NVARCHAR(10) =
    CASE WHEN CHARINDEX(N'{', ISNULL(@zplCrtRe, N'')) > 0 THEN N'1' ELSE N'0' END;
DECLARE @braceOkRe NVARCHAR(10) =
    CASE WHEN CHARINDEX(N'{', ISNULL(@zplOkRe, N'')) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] CRT reprint leaves no unsubstituted token',
    @Expected = N'0', @Actual = @braceCrtRe;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean reprint leaves no unsubstituted token',
    @Expected = N'0', @Actual = @braceOkRe;

DROP TABLE #z;
GO

-- ---- Teardown: audit rows (LotLabel entity), then LotLabel rows, then the LOTs ----
DECLARE @LotCrt BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'LBL070-TAGGED');
DECLARE @LotOk  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'LBL070-CLEAN');
DECLARE @lblEntityId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'LotLabel');

DELETE FROM Audit.OperationLog
    WHERE LogEntityTypeId = @lblEntityId
      AND EntityId IN (SELECT Id FROM Lots.LotLabel WHERE LotId IN (@LotCrt, @LotOk));

DELETE FROM Lots.LotLabel WHERE LotId IN (@LotCrt, @LotOk);
DELETE FROM Lots.Lot WHERE Id IN (@LotCrt, @LotOk);
GO

EXEC test.EndTestFile;
GO
