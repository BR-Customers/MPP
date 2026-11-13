SET NOCOUNT ON;
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @P1 BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Cell);
DECLARE @P2 BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @P1);
DECLARE @Site BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE ParentLocationId IS NULL);

DECLARE @Cases TABLE (Seq INT, Loc BIGINT, Descend BIT, Label NVARCHAR(40));
INSERT @Cases VALUES (1, @Cell, 0, N'cell, exact'), (2, @Cell, 1, N'cell, +desc'), (3, @P2, 1, N'grandparent, +desc'), (4, @Site, 1, N'root, +desc');

DECLARE @Seq INT = 1, @Loc BIGINT, @D BIT, @Label NVARCHAR(40);
WHILE @Seq <= 4
BEGIN
    SELECT @Loc = Loc, @D = Descend, @Label = Label FROM @Cases WHERE Seq = @Seq;
    CREATE TABLE #R (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50),
        ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
        LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(30), NextSequenceNumber INT, RowNo INT IDENTITY(1,1));
    PRINT '=== ' + @Label + ' (loc ' + CAST(@Loc AS VARCHAR(20)) + ') ===';
    SET STATISTICS IO ON; SET STATISTICS TIME ON;
    INSERT #R (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode,
               LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
    EXEC Lots.Lot_GetComponentsAtCell @CellLocationId = @Loc, @IncludeDescendants = @D;
    SET STATISTICS IO OFF; SET STATISTICS TIME OFF;
    -- order-sensitive fingerprint: rows AND their order must match between versions
    SELECT COUNT(*) AS Rows,
           CHECKSUM_AGG(CHECKSUM(RowNo, Id, LotName, ItemId, PieceCount, LotStatusId, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)) AS OrderedChecksum
    FROM #R;
    DROP TABLE #R;
    SET @Seq += 1;
END
