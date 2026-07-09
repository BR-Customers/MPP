/* ============================================================================
   emmd_discovery.sql  --  Phase 1: legacy EMMD schema discovery (READ ONLY)
   ----------------------------------------------------------------------------
   PURPOSE
     Enumerate the legacy Flexware "Manufacturing Director" EMMD database so we
     can decide what master/reference data to extract for seeding + validating
     the new Ignition/SQL Server MES model.

   HOW TO RUN
     1. Open in SSMS, connect to the legacy server.
     2. Confirm the USE statement below points at the legacy DB (default EMMD;
        change if the restored copy has another name).
     3. Execute the whole script.  It emits 5 labeled result grids (a "#n ..."
        marker column heads each one).  Copy each grid back verbatim.
     4. If grid #4 (column catalog) is huge, re-run with @CandidatesOnly = 1
        (see the toggle below) to restrict it to master/reference candidates.

   SAFETY
     100% read-only.  No writes, no temp objects left behind, no full-table
     scans for row counts (uses allocation stats).  SQL Server 2005 compatible.
   ============================================================================ */

USE EMMD;   -- <-- change if the legacy database has a different name
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;  -- never block the live legacy DB

/* ---- Toggle: set to 1 to restrict the column catalog (grid #4) to
        master/reference candidate tables only (smaller paste). ---- */
DECLARE @CandidatesOnly bit = 0;

/* Name patterns that hint at master/reference (product/part/bom/route/etc.).
   Reused by grids #3 and (optionally) #4. */
-- (patterns are applied inline below via the ufn-free LIKE list)

/* ============================================================================
   GRID #1  --  Context check: confirm we are on the right database/server
   ============================================================================ */
SELECT
    '#1 CONTEXT'                     AS Grid,
    DB_NAME()                        AS DatabaseName,
    @@SERVERNAME                     AS ServerName,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) AS ProductVersion,
    CAST(SERVERPROPERTY('Edition')        AS nvarchar(50)) AS Edition,
    (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) AS UserTableCount;

/* ============================================================================
   GRID #2  --  Table inventory: every user table + approx row count + #cols
   ----------------------------------------------------------------------------
   Row counts come from sys.dm_db_partition_stats (allocation metadata) so we
   never scan the big event/log tables.  Ordered biggest-first.
   ============================================================================ */
SELECT
    '#2 TABLES'                                  AS Grid,
    s.name                                       AS SchemaName,
    t.name                                       AS TableName,
    SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END) AS ApproxRows,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS ColumnCount,
    t.create_date                                AS CreatedUtc,
    t.modify_date                                AS ModifiedUtc
FROM sys.tables t
JOIN sys.schemas s               ON s.schema_id = t.schema_id
LEFT JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name, t.object_id, t.create_date, t.modify_date
ORDER BY ApproxRows DESC, s.name, t.name;

/* ============================================================================
   GRID #3  --  Master/reference candidates (priority domain), surfaced first
   ----------------------------------------------------------------------------
   Heuristic name match for product type / part / level / bom / route /
   operation / machine / type / spec definitions.
   ============================================================================ */
SELECT
    '#3 MASTER_CANDIDATES'                        AS Grid,
    s.name                                        AS SchemaName,
    t.name                                        AS TableName,
    SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END) AS ApproxRows,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS ColumnCount
FROM sys.tables t
JOIN sys.schemas s               ON s.schema_id = t.schema_id
LEFT JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND (
        t.name LIKE '%product%'   OR t.name LIKE '%part%'      OR t.name LIKE '%level%'
     OR t.name LIKE '%bom%'       OR t.name LIKE '%bill%'      OR t.name LIKE '%route%'
     OR t.name LIKE '%operation%' OR t.name LIKE '%process%'   OR t.name LIKE '%step%'
     OR t.name LIKE '%machine%'   OR t.name LIKE '%equipment%' OR t.name LIKE '%device%'
     OR t.name LIKE '%type%'      OR t.name LIKE '%model%'     OR t.name LIKE '%spec%'
     OR t.name LIKE '%item%'      OR t.name LIKE '%material%'  OR t.name LIKE '%component%'
      )
GROUP BY s.name, t.name, t.object_id
ORDER BY ApproxRows DESC, s.name, t.name;

/* ============================================================================
   GRID #4  --  Column catalog: per-table columns, datatype, nullability, PK
   ----------------------------------------------------------------------------
   This is what lets me write the phase-2 extract accurately.  If it is too big
   to paste, set @CandidatesOnly = 1 at the top and re-run.
   ============================================================================ */
SELECT
    '#4 COLUMNS'                                  AS Grid,
    s.name                                        AS SchemaName,
    t.name                                        AS TableName,
    c.column_id                                   AS Ord,
    c.name                                        AS ColumnName,
    ty.name
      + CASE
          WHEN ty.name IN ('varchar','nvarchar','char','nchar','varbinary','binary')
               THEN '(' + CASE WHEN c.max_length = -1 THEN 'max'
                               WHEN ty.name IN ('nvarchar','nchar')
                                    THEN CAST(c.max_length/2 AS varchar(10))
                               ELSE CAST(c.max_length AS varchar(10)) END + ')'
          WHEN ty.name IN ('decimal','numeric')
               THEN '(' + CAST(c.precision AS varchar(10)) + ',' + CAST(c.scale AS varchar(10)) + ')'
          ELSE ''
        END                                       AS DataType,
    CASE WHEN c.is_nullable = 1 THEN 'NULL' ELSE 'NOT NULL' END AS Nullable,
    CASE WHEN c.is_identity = 1 THEN 'IDENTITY' ELSE '' END     AS Identity_,
    CASE WHEN pk.column_id IS NOT NULL THEN 'PK' ELSE '' END    AS IsPK
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types  ty ON ty.user_type_id = c.user_type_id
LEFT JOIN (
        SELECT ic.object_id, ic.column_id
        FROM sys.indexes i
        JOIN sys.index_columns ic
             ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        WHERE i.is_primary_key = 1
     ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
WHERE t.is_ms_shipped = 0
  AND (
        @CandidatesOnly = 0
     OR t.name LIKE '%product%'   OR t.name LIKE '%part%'      OR t.name LIKE '%level%'
     OR t.name LIKE '%bom%'       OR t.name LIKE '%bill%'      OR t.name LIKE '%route%'
     OR t.name LIKE '%operation%' OR t.name LIKE '%process%'   OR t.name LIKE '%step%'
     OR t.name LIKE '%machine%'   OR t.name LIKE '%equipment%' OR t.name LIKE '%device%'
     OR t.name LIKE '%type%'      OR t.name LIKE '%model%'     OR t.name LIKE '%spec%'
     OR t.name LIKE '%item%'      OR t.name LIKE '%material%'  OR t.name LIKE '%component%'
      )
ORDER BY s.name, t.name, c.column_id;

/* ============================================================================
   GRID #5  --  Foreign keys: how the tables relate (parent -> child)
   ----------------------------------------------------------------------------
   Reveals the real product-type -> part -> bom -> route -> operation wiring.
   ============================================================================ */
SELECT
    '#5 FKS'                                       AS Grid,
    fk.name                                        AS ForeignKeyName,
    ps.name + '.' + pt.name                        AS ParentTable,
    pc.name                                        AS ParentColumn,
    rs.name + '.' + rt.name                        AS ReferencedTable,
    rc.name                                        AS ReferencedColumn
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.tables  pt ON pt.object_id = fk.parent_object_id
JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id     AND pc.column_id = fkc.parent_column_id
JOIN sys.tables  rt ON rt.object_id = fk.referenced_object_id
JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
ORDER BY ParentTable, ForeignKeyName, fkc.constraint_column_id;
GO
