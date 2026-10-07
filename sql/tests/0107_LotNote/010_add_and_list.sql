-- =============================================
-- File:         0107_LotNote/010_add_and_list.sql
-- Author:       Blue Ridge Automation
-- Description:  Lots.LotNote_Add + Lots.LotNote_ListByLot (migration 0107).
--
--               Covers: the happy path, the LOT snapshot the proc stamps
--               itself, every rejection, the "context never fails a note"
--               rule (malformed JSON is wrapped, not refused), and newest-
--               first ordering on the read.
--
--               Run-Tests.ps1 resets to a schema-only database, so the file
--               builds its own LOT fixture and tears it down. Fixture mirrors
--               0067_Lot_SearchAdvanced/010_filters.sql.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0107_LotNote/010_add_and_list.sql';
GO

IF OBJECT_ID(N'tempdb..#NF') IS NOT NULL DROP TABLE #NF;
CREATE TABLE #NF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);

IF OBJECT_ID(N'tempdb..#NR') IS NOT NULL DROP TABLE #NR;
CREATE TABLE #NR (Status BIT, Message NVARCHAR(500), NewId BIGINT);

IF OBJECT_ID(N'tempdb..#NL') IS NOT NULL DROP TABLE #NL;
CREATE TABLE #NL (
    Id BIGINT, LotId BIGINT, NoteText NVARCHAR(1000), CreatedAt DATETIME2(3),
    AppUserId BIGINT, ByInitials NVARCHAR(10), ByDisplayName NVARCHAR(200),
    WasElevated BIT, TerminalLocationId BIGINT, TerminalName NVARCHAR(200),
    TerminalZoneName NVARCHAR(200), LotStatusCode NVARCHAR(50),
    LotLocationName NVARCHAR(200), LotPieceCount INT,
    Seq INT IDENTITY(1,1)
);
GO

-- ---- Fixture: two LOTs at an eligible cell (one stays note-less) ----
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT;

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 30, @AppUserId = 1,
    @VendorLotNumber = N'VND-NOTE-001';
INSERT INTO #NF (Tag, Val) SELECT N'Lot1', NewId FROM @cr;
DELETE FROM @cr;

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 40, @AppUserId = 1,
    @VendorLotNumber = N'VND-NOTE-002';
INSERT INTO #NF (Tag, Val) SELECT N'Lot2', NewId FROM @cr;

INSERT INTO #NF (Tag, Val) VALUES (N'CellA', @CellA);
GO

-- ---- Assertions ----
DECLARE @n INT, @s NVARCHAR(MAX);
DECLARE @Lot1  BIGINT = (SELECT Val FROM #NF WHERE Tag = N'Lot1');
DECLARE @Lot2  BIGINT = (SELECT Val FROM #NF WHERE Tag = N'Lot2');
DECLARE @CellA BIGINT = (SELECT Val FROM #NF WHERE Tag = N'CellA');
DECLARE @NoteId BIGINT;

-- 1. Happy path.
INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = N'  Basket looks short.  ',
    @AppUserId = 1, @TerminalLocationId = @CellA, @WasElevated = 1,
    @ContextJson = N'{"page":"/shop-floor/lot-detail/1","elevated":true}';
SELECT @n = COUNT(*) FROM #NR WHERE Status = 1 AND NewId IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] add returns Status 1 and a NewId',
    @Expected = N'1', @Actual = @n;
SELECT @NoteId = NewId FROM #NR;
DELETE FROM #NR;

-- 2. Text is trimmed; attribution columns land as passed.
SELECT @n = COUNT(*) FROM Lots.LotNote
WHERE Id = @NoteId AND NoteText = N'Basket looks short.' AND AppUserId = 1
  AND TerminalLocationId = @CellA AND WasElevated = 1;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] text trimmed; user, terminal and elevation stored',
    @Expected = N'1', @Actual = @n;

-- 3. The proc stamps the LOT snapshot itself.
SELECT @n = COUNT(*) FROM Lots.LotNote n
INNER JOIN Lots.Lot l ON l.Id = n.LotId
WHERE n.Id = @NoteId AND n.LotStatusId = l.LotStatusId
  AND n.LotLocationId = l.CurrentLocationId AND n.LotPieceCount = 30;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] snapshot carries the LOT status, location and piece count',
    @Expected = N'1', @Actual = @n;

-- 4. Valid context JSON is stored verbatim.
SELECT @s = JSON_VALUE(ContextJson, N'$.page') FROM Lots.LotNote WHERE Id = @NoteId;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] valid ContextJson stored as given',
    @Expected = N'/shop-floor/lot-detail/1', @Actual = @s;

-- 5. Malformed context does NOT fail the note; it is wrapped.
INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = N'Second note',
    @AppUserId = 1, @ContextJson = N'this is {not json';
SELECT @n = COUNT(*) FROM #NR WHERE Status = 1;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] malformed ContextJson still adds the note',
    @Expected = N'1', @Actual = @n;
SELECT @s = JSON_VALUE(ContextJson, N'$.Unparsed') FROM Lots.LotNote WHERE Id = (SELECT NewId FROM #NR);
EXEC test.Assert_IsEqual @TestName = N'[LotNote] malformed ContextJson is wrapped as Unparsed',
    @Expected = N'this is {not json', @Actual = @s;
DELETE FROM #NR;

-- 6. Defaults: no terminal, not elevated, no context.
INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = N'Third note', @AppUserId = 1;
SELECT @n = COUNT(*) FROM Lots.LotNote n
WHERE n.Id = (SELECT NewId FROM #NR) AND n.TerminalLocationId IS NULL
  AND n.WasElevated = 0 AND n.ContextJson IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] optional parameters default to NULL / not elevated',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

-- 7. Blank text is rejected.
INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = N'    ', @AppUserId = 1;
SELECT @n = COUNT(*) FROM #NR WHERE Status = 0 AND NewId IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] blank note rejected',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

-- 8. Over-long text is rejected, not truncated.
DECLARE @Long NVARCHAR(MAX) = REPLICATE(CAST(N'x' AS NVARCHAR(MAX)), 1001);
INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = @Long, @AppUserId = 1;
SELECT @n = COUNT(*) FROM #NR WHERE Status = 0 AND Message LIKE N'%too long%';
EXEC test.Assert_IsEqual @TestName = N'[LotNote] 1001-character note rejected, not truncated',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

-- 9. Exactly 1000 characters is accepted.
DECLARE @Max NVARCHAR(MAX) = REPLICATE(CAST(N'y' AS NVARCHAR(MAX)), 1000);
INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = @Max, @AppUserId = 1;
SELECT @n = COUNT(*) FROM #NR WHERE Status = 1;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] 1000-character note accepted',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

-- 10. Unknown LOT, unknown user, unknown terminal, missing user.
INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = -1, @NoteText = N'x', @AppUserId = 1;
SELECT @n = COUNT(*) FROM #NR WHERE Status = 0 AND Message = N'LOT not found.';
EXEC test.Assert_IsEqual @TestName = N'[LotNote] unknown LOT rejected',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = N'x', @AppUserId = -1;
SELECT @n = COUNT(*) FROM #NR WHERE Status = 0 AND Message = N'User not found.';
EXEC test.Assert_IsEqual @TestName = N'[LotNote] unknown user rejected',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = N'x', @AppUserId = 1,
    @TerminalLocationId = -1;
SELECT @n = COUNT(*) FROM #NR WHERE Status = 0 AND Message = N'Terminal location not found.';
EXEC test.Assert_IsEqual @TestName = N'[LotNote] unknown terminal rejected',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

INSERT INTO #NR EXEC Lots.LotNote_Add @LotId = @Lot1, @NoteText = N'x', @AppUserId = NULL;
SELECT @n = COUNT(*) FROM #NR WHERE Status = 0;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] missing user rejected (no write credited to nobody)',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NR;

-- 11. Rejections wrote nothing: Lot1 holds exactly the four accepted notes.
SELECT @n = COUNT(*) FROM Lots.LotNote WHERE LotId = @Lot1;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] only accepted notes were written',
    @Expected = N'4', @Actual = @n;

-- 12. Read: all four, newest first, with resolved names.
INSERT INTO #NL (Id, LotId, NoteText, CreatedAt, AppUserId, ByInitials, ByDisplayName,
                 WasElevated, TerminalLocationId, TerminalName, TerminalZoneName,
                 LotStatusCode, LotLocationName, LotPieceCount)
EXEC Lots.LotNote_ListByLot @LotId = @Lot1;
SELECT @n = COUNT(*) FROM #NL;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] list returns every note on the LOT',
    @Expected = N'4', @Actual = @n;

SELECT @n = COUNT(*) FROM #NL a
INNER JOIN #NL b ON b.Seq = a.Seq + 1
WHERE a.Id < b.Id;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] list is newest first',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM #NL
WHERE Id = @NoteId AND TerminalName IS NOT NULL AND LotStatusCode IS NOT NULL
  AND LotLocationName IS NOT NULL AND ByDisplayName IS NOT NULL AND LotPieceCount = 30;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] list resolves terminal, status, location and author',
    @Expected = N'1', @Actual = @n;
DELETE FROM #NL;

-- 13. A LOT with no notes reads empty, and notes do not leak across LOTs.
INSERT INTO #NL (Id, LotId, NoteText, CreatedAt, AppUserId, ByInitials, ByDisplayName,
                 WasElevated, TerminalLocationId, TerminalName, TerminalZoneName,
                 LotStatusCode, LotLocationName, LotPieceCount)
EXEC Lots.LotNote_ListByLot @LotId = @Lot2;
SELECT @n = COUNT(*) FROM #NL;
EXEC test.Assert_IsEqual @TestName = N'[LotNote] a LOT with no notes returns an empty set',
    @Expected = N'0', @Actual = @n;
GO

-- ---- Teardown (notes, then closure, BEFORE the LOTs) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Val FROM #NF WHERE Tag IN (N'Lot1', N'Lot2');

DELETE FROM Lots.LotNote WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy
WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot              WHERE Id    IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#NL') IS NOT NULL DROP TABLE #NL;
IF OBJECT_ID(N'tempdb..#NR') IS NOT NULL DROP TABLE #NR;
IF OBJECT_ID(N'tempdb..#NF') IS NOT NULL DROP TABLE #NF;
GO
