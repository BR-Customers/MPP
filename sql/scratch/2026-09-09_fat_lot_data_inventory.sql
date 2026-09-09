-- =============================================
-- Script:      2026-09-09_fat_lot_data_inventory.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-09
-- Purpose:     READ-ONLY inventory of LOT content, run BEFORE deciding how to
--              clear or flag the FAT dummy data in MPP_MES_Prod.
--
--              *** THIS SCRIPT WRITES NOTHING. *** No INSERT/UPDATE/DELETE, no
--              DDL, no transaction. Safe to run against production as-is.
--
-- Why an inventory first:
--   Lots.Lot has NO soft-delete and NO test-data column -- LotStatusCode is
--   Good / Hold / Scrap / Closed / Open only. So "flag it" needs a new column,
--   and "delete it" has to walk every FK that points at Lots.Lot. Neither is
--   safe to write blind, and this is a Honda traceability database: deleting
--   genealogy is not a routine DELETE.
--
--   Section 1 discovers the real dependency graph from sys.foreign_keys rather
--   than a hand-maintained list, so it stays correct as the schema moves.
--   Section 2 characterises what is actually in prod, so the FAT rows can be
--   identified by evidence instead of assumption.
--
-- Usage:
--   sqlcmd -S 172.17.10.148 -U Ignition -P $pw -d MPP_MES_Prod -C -i <this file>
-- =============================================

-- sqlcmd defaults QUOTED_IDENTIFIER OFF. Lots.Lot carries a filtered index (B8),
-- and SQL Server refuses DML against a filtered index unless QUOTED_IDENTIFIER is
-- ON -- Msg 1934. Set it here so the script does not depend on the caller passing
-- sqlcmd's -I flag.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;

PRINT '';
PRINT '================================================================';
PRINT '  LOT CONTENT INVENTORY  ->  ' + DB_NAME() + '  on  ' + @@SERVERNAME;
PRINT '  READ-ONLY. Nothing is modified.';
PRINT '================================================================';
PRINT '';

-- =============================================
-- SECTION 1 - every table that references Lots.Lot, with its row count.
-- Ordered so the delete order is readable off the bottom of the list upward:
-- children first, Lots.Lot last. Self-references (ParentLotId) are flagged
-- because they have to be NULLed before the parent row can go.
-- =============================================
PRINT '--- 1. Tables referencing Lots.Lot -----------------------------';

DECLARE @deps TABLE (
    RefSchema   SYSNAME,
    RefTable    SYSNAME,
    RefColumn   SYSNAME,
    IsSelfRef   BIT,
    TotalRows   BIGINT NULL
);

INSERT INTO @deps (RefSchema, RefTable, RefColumn, IsSelfRef)
SELECT  s.name,
        t.name,
        c.name,
        CASE WHEN t.object_id = OBJECT_ID(N'Lots.Lot') THEN 1 ELSE 0 END
FROM    sys.foreign_keys fk
JOIN    sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN    sys.tables  t ON t.object_id = fk.parent_object_id
JOIN    sys.schemas s ON s.schema_id = t.schema_id
JOIN    sys.columns c ON c.object_id = fkc.parent_object_id
                     AND c.column_id = fkc.parent_column_id
WHERE   fk.referenced_object_id = OBJECT_ID(N'Lots.Lot');

-- Row counts, gathered one table at a time (sp_executesql, still read-only).
DECLARE @sch SYSNAME, @tbl SYSNAME, @col SYSNAME, @n BIGINT, @sql NVARCHAR(500);
DECLARE dep CURSOR LOCAL FAST_FORWARD FOR
    SELECT RefSchema, RefTable, RefColumn FROM @deps;
OPEN dep;
FETCH NEXT FROM dep INTO @sch, @tbl, @col;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @out = COUNT_BIG(*) FROM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl) + N';';
    EXEC sp_executesql @sql, N'@out BIGINT OUTPUT', @out = @n OUTPUT;
    UPDATE @deps SET TotalRows = @n
     WHERE RefSchema = @sch AND RefTable = @tbl AND RefColumn = @col;
    FETCH NEXT FROM dep INTO @sch, @tbl, @col;
END
CLOSE dep; DEALLOCATE dep;

SELECT  RefSchema + N'.' + RefTable AS ReferencingTable,
        RefColumn                   AS ViaColumn,
        CASE WHEN IsSelfRef = 1 THEN N'SELF-REF (NULL it first)' ELSE N'' END AS Note,
        TotalRows
FROM    @deps
ORDER BY TotalRows DESC, ReferencingTable;

-- =============================================
-- SECTION 2 - what LOT content actually exists.
-- =============================================
PRINT '';
PRINT '--- 2a. Totals -------------------------------------------------';

SELECT  COUNT(*)                        AS TotalLots,
        MIN(CreatedAt)                  AS EarliestCreatedUtc,
        MAX(CreatedAt)                  AS LatestCreatedUtc,
        COUNT(DISTINCT ItemId)          AS DistinctItems,
        COUNT(DISTINCT CreatedByUserId) AS DistinctCreators
FROM    Lots.Lot;

PRINT '';
PRINT '--- 2b. By calendar day (ET) - FAT days should stand out -------';

SELECT  CAST(CAST(l.CreatedAt AT TIME ZONE 'UTC'
                              AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE) AS CreatedDateEt,
        COUNT(*) AS Lots
FROM    Lots.Lot l
GROUP BY CAST(CAST(l.CreatedAt AT TIME ZONE 'UTC'
                                AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE)
ORDER BY CreatedDateEt;

PRINT '';
PRINT '--- 2c. By creating user - FAT accounts vs real operators ------';

SELECT  u.Initials,
        u.DisplayName,
        u.Pin,
        COUNT(*)          AS Lots,
        MIN(l.CreatedAt)  AS FirstUtc,
        MAX(l.CreatedAt)  AS LastUtc
FROM    Lots.Lot l
JOIN    Location.AppUser u ON u.Id = l.CreatedByUserId
GROUP BY u.Initials, u.DisplayName, u.Pin
ORDER BY Lots DESC;

PRINT '';
PRINT '--- 2d. By item + status --------------------------------------';

SELECT  i.PartNumber,
        i.Description,
        sc.Code   AS LotStatus,
        COUNT(*)  AS Lots
FROM    Lots.Lot l
JOIN    Parts.Item i         ON i.Id = l.ItemId
JOIN    Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
GROUP BY i.PartNumber, i.Description, sc.Code
ORDER BY Lots DESC;

PRINT '';
PRINT '--- 2e. Every LOT name (the naming pattern is the giveaway) ----';

SELECT  l.Id,
        l.LotName,
        i.PartNumber,
        sc.Code AS LotStatus,
        loc.Code AS CurrentLocation,
        l.PieceCount,
        u.Initials AS CreatedBy,
        CAST(l.CreatedAt AT TIME ZONE 'UTC'
                          AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedEt
FROM    Lots.Lot l
JOIN    Parts.Item i          ON i.Id  = l.ItemId
JOIN    Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
JOIN    Location.Location loc ON loc.Id = l.CurrentLocationId
JOIN    Location.AppUser u    ON u.Id  = l.CreatedByUserId
ORDER BY l.CreatedAt, l.Id;

PRINT '';
PRINT '--- 2f. Shipped anything? (matters most - shipping is external) ';

SELECT  COUNT(*) AS ShippingLabels,
        SUM(CASE WHEN sl.AimShipperId IS NOT NULL THEN 1 ELSE 0 END) AS WithAimShipperId
FROM    Lots.ShippingLabel sl;

PRINT '';
PRINT '================================================================';
PRINT '  END OF INVENTORY - nothing was modified.';
PRINT '================================================================';
GO
