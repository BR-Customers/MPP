-- =============================================
-- File:         0134_ScaleDigi/030_part_code.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-20
-- Description:
--   Learned scale codes (migration 0135, spec 2026-11-19 section 13):
--   Workorder.ScalePartCode_Resolve (exact part number first, then this
--   terminal's learned code, with an Eligible flag), learning on
--   ScalePendingPress_Complete v1.1 (new, replaced, unchanged, empty code),
--   ScalePartCode_ListForTerminal and ScalePartCode_Deprecate.
--   Reuses the TST-SS-* fixture from 0113_ScaleStation/020.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0134_ScaleDigi/030_part_code.sql';
GO

CREATE TABLE #S (Status BIT, Message NVARCHAR(500), NewId BIGINT NULL);
CREATE TABLE #S2 (Status BIT, Message NVARCHAR(500));
CREATE TABLE #R (ItemId BIGINT, PartNumber NVARCHAR(50), Source NVARCHAR(20), Eligible BIT);
CREATE TABLE #L (Id BIGINT, ScalePartCode NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500),
                 LearnedAtEt DATETIME2(3), LearnedBy NVARCHAR(100));
GO

-- Stock so FG-A and FG-B are eligible at TST-SS-AOUT (the 0113/040 setup).
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
-- Only ADD stock: earlier files leave LOTs with genealogy at this line, which a
-- DELETE would trip over (LotGenealogyClosure FK). Extra stock is harmless here.
DELETE FROM Workorder.ScalePartCode WHERE TerminalLocationId = @Term;
DELETE FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @Term;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSPC-' + RIGHT(i.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Good, 10, 10, @Line, 1
FROM Parts.Item i WHERE i.PartNumber IN (N'TST-SS-C1', N'TST-SS-C2', N'TST-SS-P1', N'TST-SS-P2', N'TST-SS-P3');
GO

-- ==== exact part number ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScalePartCode_Resolve @TerminalLocationId = @Term, @ScalePartCode = N' TST-SS-FG-A ';
DECLARE @R NVARCHAR(100) = (SELECT CONCAT(PartNumber, N'|', Source, N'|', CAST(Eligible AS NVARCHAR(1))) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Code] exact part number (trimmed) resolves, eligible', @Expected = N'TST-SS-FG-A|PartNumber|1', @Actual = @R;

DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScalePartCode_Resolve @TerminalLocationId = @Term, @ScalePartCode = N'66VT';
DECLARE @N NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Code] unknown code resolves to nothing', @Expected = N'0', @Actual = @N;
GO

-- ==== learn on pick ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DECLARE @Before BIGINT = ISNULL((SELECT MAX(Id) FROM Audit.OperationLog), 0);
DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = 15.5, @Uom = N'LB', @ScalePartCode = N'66VT', @AppUserId = 1;
DECLARE @Id BIGINT = (SELECT NewId FROM #S);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Claim @Id = @Id, @AppUserId = 1;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Complete @Id = @Id, @ItemId = @A, @FinishedGoodLotId = NULL, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Code] complete -> Status 1', @Expected = N'1', @Actual = @St;
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScalePartCode_Resolve @TerminalLocationId = @Term, @ScalePartCode = N'66VT';
DECLARE @R NVARCHAR(100) = (SELECT CONCAT(PartNumber, N'|', Source, N'|', CAST(Eligible AS NVARCHAR(1))) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Code] the pick taught 66VT -> FG-A', @Expected = N'TST-SS-FG-A|Learned|1', @Actual = @R;
DECLARE @Aud NVARCHAR(500) = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
                              WHERE ol.Id > @Before AND et.Code = N'ScalePartCodeLearned' ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[Code] learning audited with code and part', @HaystackStr = @Aud, @NeedleStr = N'[66VT] -> TST-SS-FG-A';

-- another terminal does not see it (per scale)
DECLARE @Other BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL AND Id <> @Term ORDER BY Id);
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScalePartCode_Resolve @TerminalLocationId = @Other, @ScalePartCode = N'66VT';
DECLARE @N NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Code] a learned code belongs to its own scale only', @Expected = N'0', @Actual = @N;
GO

-- ==== same part again: unchanged; another part: replaced ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-B');
DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = 15.5, @Uom = N'LB', @ScalePartCode = N'66VT', @AppUserId = 1;
DECLARE @Id BIGINT = (SELECT NewId FROM #S);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Claim @Id = @Id, @AppUserId = 1;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Complete @Id = @Id, @ItemId = @A, @FinishedGoodLotId = NULL, @AppUserId = 1;
DECLARE @Rows NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Workorder.ScalePartCode WHERE TerminalLocationId = @Term AND ScalePartCode = N'66VT');
EXEC test.Assert_IsEqual @TestName = N'[Code] the same pick again adds no row', @Expected = N'1', @Actual = @Rows;

DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = 15.5, @Uom = N'LB', @ScalePartCode = N'66VT', @AppUserId = 1;
SET @Id = (SELECT NewId FROM #S);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Claim @Id = @Id, @AppUserId = 1;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Complete @Id = @Id, @ItemId = @B, @FinishedGoodLotId = NULL, @AppUserId = 1;
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScalePartCode_Resolve @TerminalLocationId = @Term, @ScalePartCode = N'66VT';
DECLARE @R NVARCHAR(100) = (SELECT CONCAT(PartNumber, N'|', Source) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Code] a different pick replaces the mapping', @Expected = N'TST-SS-FG-B|Learned', @Actual = @R;
DECLARE @Act NVARCHAR(10) = (SELECT CONCAT(SUM(CASE WHEN DeprecatedAt IS NULL THEN 1 ELSE 0 END), N'/', COUNT(*))
                             FROM Workorder.ScalePartCode WHERE TerminalLocationId = @Term AND ScalePartCode = N'66VT');
EXEC test.Assert_IsEqual @TestName = N'[Code] one active mapping, the old one kept deprecated', @Expected = N'1/2', @Actual = @Act;
GO

-- ==== empty code is never learned ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = 15.5, @Uom = N'LB', @ScalePartCode = N'', @AppUserId = 1;
DECLARE @Id BIGINT = (SELECT NewId FROM #S);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Claim @Id = @Id, @AppUserId = 1;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Complete @Id = @Id, @ItemId = @A, @FinishedGoodLotId = NULL, @AppUserId = 1;
DECLARE @N NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Workorder.ScalePartCode WHERE TerminalLocationId = @Term AND ScalePartCode = N'');
EXEC test.Assert_IsEqual @TestName = N'[Code] an empty code is never learned', @Expected = N'0', @Actual = @N;
GO

-- ==== list ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #L; INSERT INTO #L EXEC Workorder.ScalePartCode_ListForTerminal @TerminalLocationId = @Term;
DECLARE @R NVARCHAR(100) = (SELECT STRING_AGG(CONCAT(ScalePartCode, N'->', PartNumber), N',') FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[Code] list shows the active mapping only', @Expected = N'66VT->TST-SS-FG-B', @Actual = @R;
GO

-- ==== learned part no longer eligible (no By Weight pack-out): Eligible 0 ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-B');
DECLARE @Cc TABLE (Id BIGINT);
UPDATE Parts.ContainerConfig SET DeprecatedAt = SYSUTCDATETIME() OUTPUT inserted.Id INTO @Cc
WHERE ItemId = @B AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL;
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScalePartCode_Resolve @TerminalLocationId = @Term, @ScalePartCode = N'66VT';
DECLARE @R NVARCHAR(100) = (SELECT CONCAT(PartNumber, N'|', CAST(Eligible AS NVARCHAR(1))) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Code] learned part that cannot run here resolves, not eligible', @Expected = N'TST-SS-FG-B|0', @Actual = @R;
UPDATE Parts.ContainerConfig SET DeprecatedAt = NULL WHERE Id IN (SELECT Id FROM @Cc);
GO

-- ==== remove ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @MapId BIGINT = (SELECT Id FROM Workorder.ScalePartCode WHERE TerminalLocationId = @Term AND ScalePartCode = N'66VT' AND DeprecatedAt IS NULL);
DECLARE @Before BIGINT = ISNULL((SELECT MAX(Id) FROM Audit.OperationLog), 0);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePartCode_Deprecate @Id = @MapId, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Code] remove -> Status 1', @Expected = N'1', @Actual = @St;
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScalePartCode_Resolve @TerminalLocationId = @Term, @ScalePartCode = N'66VT';
DECLARE @N NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Code] a removed code resolves to nothing', @Expected = N'0', @Actual = @N;
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
                             WHERE ol.Id > @Before AND et.Code = N'ScalePartCodeRemoved');
EXEC test.Assert_IsEqual @TestName = N'[Code] remove audited', @Expected = N'1', @Actual = @Aud;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePartCode_Deprecate @Id = @MapId, @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Code] removing twice refused', @Expected = N'0', @Actual = @St;

DELETE FROM Workorder.ScalePartCode WHERE TerminalLocationId = @Term;
DELETE FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @Term;
DELETE FROM Lots.Lot WHERE LotName LIKE N'TSPC-%';
GO

EXEC test.EndTestFile;
GO
