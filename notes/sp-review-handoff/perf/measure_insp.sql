SET NOCOUNT ON;
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
DECLARE @Parent  BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Station);
DECLARE @Site    BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE ParentLocationId IS NULL);

DECLARE @Cases TABLE (Seq INT, Loc BIGINT, Descend BIT, Label NVARCHAR(40));
INSERT @Cases VALUES (1, @Station, 0, N'station, exact'), (2, @Station, 1, N'station, +desc'),
                     (3, @Parent, 1, N'parent, +desc'), (4, @Site, 1, N'root, +desc');

DECLARE @Seq INT = 1, @Loc BIGINT, @D BIT, @Label NVARCHAR(40);
WHILE @Seq <= 4
BEGIN
    SELECT @Loc = Loc, @D = Descend, @Label = Label FROM @Cases WHERE Seq = @Seq;
    CREATE TABLE #R (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
        PieceCount INT, VendorLotNumber NVARCHAR(50), LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
        LatestInspectionResult NVARCHAR(20), LatestSampledAt DATETIME2(3), ArrivedAt DATETIME2(3), RowNo INT IDENTITY(1,1));
    PRINT '=== ' + @Label + ' (loc ' + CAST(@Loc AS VARCHAR(20)) + ') ===';
    SET STATISTICS IO ON;
    INSERT #R (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, VendorLotNumber, LotStatusId, LotStatusCode,
               LatestInspectionResult, LatestSampledAt, ArrivedAt)
    EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId = @Loc, @IncludeDescendants = @D;
    SET STATISTICS IO OFF;
    SELECT COUNT(*) AS Rows,
           CHECKSUM_AGG(CHECKSUM(RowNo, Id, LotName, ItemId, PieceCount, VendorLotNumber, LotStatusId,
                                 LatestInspectionResult, LatestSampledAt, ArrivedAt)) AS OrderedChecksum
    FROM #R;
    DROP TABLE #R;
    SET @Seq += 1;
END
