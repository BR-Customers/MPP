-- =============================================
-- File:         0063_Crt_PartScoped/070_label_mark.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-20
-- Description:  The {CrtMark} label token (design D8, part-scoped CRT Task 6).
--               A CRT LOT's printed LTT carries a visible 'CRT' mark; a clean
--               LOT's carries none. One token in the EXISTING label templates
--               (Primary/Master/Void), not separate CRT template variants --
--               labels are ZPL with {Token} substitution, so one template per
--               label type means no duplication and no drift.
--
--               THE MOST IMPORTANT ASSERTION HERE IS THE NEGATIVE ONE: a clean
--               LOT's rendered ZPL must contain NEITHER a literal unsubstituted
--               {CrtMark} token NOR the word CRT. Every template runs through
--               the same substitution regardless of CRT state, so the token
--               must always be replaced -- with the mark when CrtActive = 1,
--               and with an empty string when it is 0. A missed substitution
--               prints a literal {CrtMark} on a production ticket.
--
--               Fixture notes:
--                 * Run-Tests.ps1 resets with -SkipDemoSeed, so Lots.Lot starts
--                   EMPTY and holds only what earlier test files created. This
--                   file INSERTs its own LOTs under names unique to it
--                   (CRT070-*) rather than borrowing an existing LOT.
--                 * Lots.LotLabel_Print requires @LabelTypeCodeId AND
--                   @PrintReasonCodeId (both NOT NULL, no default) -- verified
--                   against the proc signature. Primary = 1, Initial reason = 1
--                   (mirrors 0021/070's Test 1 fixture).
--                 * Lots.LotLabel_Print / _Reprint both return the FOUR-column
--                   status row (Status, Message, NewId, ZplContent); the
--                   INSERT-EXEC temp table matches that shape exactly. A wrong
--                   column list aborts the whole file with Msg 213, which
--                   surfaces as a runner ERROR, not a FAIL.
--                 * test.Assert_Contains takes @HaystackStr / @NeedleStr, not
--                   @Expected / @Actual.
--
--               Teardown deletes the LotLabel audit rows (LotLabel entity ->
--               Audit.OperationLog, per 0021/070), then the LotLabel rows, then
--               the two fixture LOTs.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/070_label_mark.sql';
GO

DECLARE @Item     BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @StartLoc BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @App      BIGINT = 1;
DECLARE @Mfg      BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Good     BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');

-- NOTE: the fixture LotName deliberately avoids the substring 'CRT' -- it is
-- rendered verbatim into the ZPL via the {LotName} token, so a name like
-- 'CRT070-...' would make the clean-label 'no CRT anywhere' assertion below
-- pass or fail on the NAME rather than on the {CrtMark} substitution under
-- test. LBL070-TAGGED / LBL070-CLEAN keep this file's fixtures identifiable
-- without contaminating that check.
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
    @LotId = @LotCrt, @LabelTypeCodeId = 1, @PrintReasonCodeId = 1, @AppUserId = @App;
SELECT TOP 1 @zplCrt = ZplContent FROM #z;
DELETE FROM #z;
INSERT INTO #z EXEC Lots.LotLabel_Print
    @LotId = @LotOk, @LabelTypeCodeId = 1, @PrintReasonCodeId = 1, @AppUserId = @App;
SELECT TOP 1 @zplOk = ZplContent FROM #z;

EXEC test.Assert_Contains @TestName = N'[Label] CRT lot renders the mark',
    @HaystackStr = @zplCrt, @NeedleStr = N'CRT';

DECLARE @tokenLeft INT =
    CASE WHEN CHARINDEX(N'{CrtMark}', ISNULL(@zplOk, N'')) > 0 THEN 1 ELSE 0 END;
DECLARE @tokenLeftStr NVARCHAR(10) = CAST(@tokenLeft AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot leaves no unsubstituted token',
    @Expected = N'0', @Actual = @tokenLeftStr;

DECLARE @markInClean INT =
    CASE WHEN CHARINDEX(N'CRT', ISNULL(@zplOk, N'')) > 0 THEN 1 ELSE 0 END;
DECLARE @markInCleanStr NVARCHAR(10) = CAST(@markInClean AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot carries no CRT mark',
    @Expected = N'0', @Actual = @markInCleanStr;

-- Reprint path renders the same way (mirrors the inlined render in _Reprint).
DELETE FROM #z;
INSERT INTO #z EXEC Lots.LotLabel_Reprint
    @LotId = @LotCrt, @PrintReasonCodeId = 2, @AppUserId = @App;
DECLARE @zplCrtReprint NVARCHAR(MAX) = (SELECT TOP 1 ZplContent FROM #z);
EXEC test.Assert_Contains @TestName = N'[Label] reprint of a CRT lot still renders the mark',
    @HaystackStr = @zplCrtReprint, @NeedleStr = N'CRT';

DELETE FROM #z;
INSERT INTO #z EXEC Lots.LotLabel_Reprint
    @LotId = @LotOk, @PrintReasonCodeId = 2, @AppUserId = @App;
DECLARE @zplOkReprint NVARCHAR(MAX) = (SELECT TOP 1 ZplContent FROM #z);
DECLARE @reprintTokenLeft INT =
    CASE WHEN CHARINDEX(N'{CrtMark}', ISNULL(@zplOkReprint, N'')) > 0 THEN 1 ELSE 0 END;
DECLARE @reprintTokenLeftStr NVARCHAR(10) = CAST(@reprintTokenLeft AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Label] reprint of a clean lot leaves no unsubstituted token',
    @Expected = N'0', @Actual = @reprintTokenLeftStr;

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
