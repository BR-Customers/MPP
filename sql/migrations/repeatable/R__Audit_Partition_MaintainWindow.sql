-- ============================================================
-- Repeatable:  R__Audit_Partition_MaintainWindow.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-06-09
-- Version:     1.0
--
-- Description:
--   OI-35 B2 monthly partition sliding-window maintenance. Testable now,
--   Gateway-callable later (the follow-on PartitionMaintenance Gateway
--   timer is a thin caller of this proc — Cross-Cutting B4: Gateway
--   scripts never execute raw DML).
--
--   On each call (for a given @AsOfUtc):
--     1. SPLIT  — ensure the boundary for the month AFTER @AsOfUtc exists
--                 on pf_MonthlyUtc (idempotent; global, affects every
--                 table on ps_MonthlyUtc).
--     2. TRUNCATE — for each table registered in Audit.PartitionRetention,
--                 empty every partition whose entire month is older than
--                 that table's retention window
--                 (cutoff C = first-of-month(@AsOfUtc) - retentionMonths;
--                 truncate partitions whose UPPER boundary <= C), via
--                 TRUNCATE ... WITH (PARTITIONS(n)).
--     3. MERGE  — collapse the now-empty leading boundaries that are
--                 strictly below the MINIMUM cutoff across all registered
--                 tables (MERGE is global on the function, so it is only
--                 safe below the longest-retention table's cutoff).
--
--   Only tables registered in Audit.PartitionRetention are purged. This
--   is deliberate: partition-level TRUNCATE is rejected on any table
--   referenced by a FOREIGN KEY (e.g. ProductionEventValue -> ProductionEvent),
--   so a blind "all tables on the scheme" purge would fail. The catalog
--   also carries each table's retention class (7-yr=84 / Honda 20-yr=240).
--
-- Parameters:
--   @AsOfUtc            DATETIME2(3)  - "now" for the window math. Explicit
--                                       (not GETDATE) so tests are deterministic.
--   @AppUserId          BIGINT = NULL - attribution; defaults to bootstrap (1).
--   @TerminalLocationId BIGINT = NULL - context for the OperationLog row.
--   @RetentionMonths    INT    = NULL - GLOBAL override applied to every
--                                       registered table (tests pass a small
--                                       number); NULL = use each table's class.
--
-- Result set (no OUTPUT params, FDS-11-011):
--   SELECT @Status AS Status, @Message AS Message;
--
-- Idempotency:
--   Re-running with the same @AsOfUtc is a no-op (boundary already present;
--   purged partitions already empty/merged). No explicit transaction — the
--   DDL steps auto-commit and the proc is safely re-runnable.
--
-- Change Log:
--   2026-06-09 - 1.0 - Initial version (Arc 2 Phase 1 Task A).
-- ============================================================
CREATE OR ALTER PROCEDURE Audit.Partition_MaintainWindow
    @AsOfUtc            DATETIME2(3),
    @AppUserId          BIGINT = NULL,
    @TerminalLocationId BIGINT = NULL,
    @RetentionMonths    INT    = NULL   -- NULL = per-table class; tests pass a small number
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status   BIT            = 1;
    DECLARE @Message  NVARCHAR(500)  = N'OK';
    DECLARE @ProcName NVARCHAR(200)  = N'Audit.Partition_MaintainWindow';
    DECLARE @Params   NVARCHAR(MAX)  =
        (SELECT @AsOfUtc AS AsOfUtc, @RetentionMonths AS RetentionMonths
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Splits INT = 0, @Truncations INT = 0, @Merges INT = 0;
    DECLARE @AppUserIdEff BIGINT = ISNULL(@AppUserId, 1);   -- bootstrap user when unattended

    BEGIN TRY
        -- ============================================================
        -- 1. SPLIT — ensure the boundary for the month AFTER @AsOfUtc exists
        -- ============================================================
        DECLARE @FirstOfMonth DATETIME2(3) = DATEFROMPARTS(YEAR(@AsOfUtc), MONTH(@AsOfUtc), 1);
        DECLARE @NextBoundary DATETIME2(3) = DATEADD(MONTH, 1, @FirstOfMonth);

        IF NOT EXISTS (
            SELECT 1
            FROM sys.partition_range_values prv
            JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
            WHERE pf.name = N'pf_MonthlyUtc'
              AND CAST(prv.value AS DATETIME2(3)) = @NextBoundary)
        BEGIN
            ALTER PARTITION SCHEME ps_MonthlyUtc NEXT USED [PRIMARY];
            ALTER PARTITION FUNCTION pf_MonthlyUtc() SPLIT RANGE (@NextBoundary);
            SET @Splits = 1;
        END

        -- ============================================================
        -- 2/3. Per-table purge (TRUNCATE) + global MERGE of empty leading boundaries
        -- ============================================================
        -- Registered, actually-partitioned tables + their effective cutoff.
        DECLARE @Tables TABLE (
            ObjectId    INT          NOT NULL,
            SchemaName  SYSNAME      NOT NULL,
            TableName   SYSNAME      NOT NULL,
            Cutoff      DATETIME2(3) NOT NULL
        );

        INSERT INTO @Tables (ObjectId, SchemaName, TableName, Cutoff)
        SELECT t.object_id, s.name, t.name,
               DATEADD(MONTH, -COALESCE(@RetentionMonths, pr.RetentionMonths), @FirstOfMonth)
        FROM Audit.PartitionRetention pr
        JOIN sys.schemas s ON s.name = pr.SchemaName
        JOIN sys.tables  t ON t.schema_id = s.schema_id AND t.name = pr.TableName
        WHERE EXISTS (
            SELECT 1
            FROM sys.indexes i
            JOIN sys.partition_schemes  psc ON psc.data_space_id = i.data_space_id
            JOIN sys.partition_functions pf ON pf.function_id = psc.function_id
            WHERE i.object_id = t.object_id AND i.index_id IN (0, 1)
              AND pf.name = N'pf_MonthlyUtc');

        -- Worklist: partitions to truncate (UPPER boundary <= that table's cutoff).
        -- For RANGE RIGHT, partition_number p has its upper boundary at boundary_id = p.
        DECLARE @Trunc TABLE (
            SchemaName      SYSNAME NOT NULL,
            TableName       SYSNAME NOT NULL,
            PartitionNumber INT     NOT NULL
        );

        INSERT INTO @Trunc (SchemaName, TableName, PartitionNumber)
        SELECT tb.SchemaName, tb.TableName, p.partition_number
        FROM @Tables tb
        JOIN sys.indexes i             ON i.object_id = tb.ObjectId AND i.index_id IN (0, 1)
        JOIN sys.partitions p          ON p.object_id = tb.ObjectId AND p.index_id = i.index_id
        JOIN sys.partition_schemes  psc ON psc.data_space_id = i.data_space_id
        JOIN sys.partition_functions pf ON pf.function_id = psc.function_id
        JOIN sys.partition_range_values prv
             ON prv.function_id = pf.function_id AND prv.boundary_id = p.partition_number
        WHERE pf.name = N'pf_MonthlyUtc'
          AND CAST(prv.value AS DATETIME2(3)) <= tb.Cutoff;

        -- Execute truncations (resolve partition numbers BEFORE any MERGE renumbers them).
        DECLARE @sn SYSNAME, @tn SYSNAME, @pn INT, @sql NVARCHAR(MAX);
        DECLARE trunc_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT SchemaName, TableName, PartitionNumber FROM @Trunc ORDER BY SchemaName, TableName, PartitionNumber;
        OPEN trunc_cur;
        FETCH NEXT FROM trunc_cur INTO @sn, @tn, @pn;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'TRUNCATE TABLE ' + QUOTENAME(@sn) + N'.' + QUOTENAME(@tn)
                     + N' WITH (PARTITIONS(' + CAST(@pn AS NVARCHAR(10)) + N'));';
            EXEC sys.sp_executesql @sql;
            SET @Truncations += 1;
            FETCH NEXT FROM trunc_cur INTO @sn, @tn, @pn;
        END
        CLOSE trunc_cur;
        DEALLOCATE trunc_cur;

        -- MERGE the empty leading boundaries strictly below the MINIMUM cutoff
        -- (global op — only safe below the longest-retention table's cutoff).
        DECLARE @MergeCutoff DATETIME2(3) = (SELECT MIN(Cutoff) FROM @Tables);
        IF @MergeCutoff IS NOT NULL
        BEGIN
            DECLARE @Boundary DATETIME2(3);
            DECLARE merge_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT CAST(prv.value AS DATETIME2(3))
                FROM sys.partition_range_values prv
                JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
                WHERE pf.name = N'pf_MonthlyUtc'
                  AND CAST(prv.value AS DATETIME2(3)) < @MergeCutoff
                ORDER BY prv.value ASC;
            OPEN merge_cur;
            FETCH NEXT FROM merge_cur INTO @Boundary;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                ALTER PARTITION FUNCTION pf_MonthlyUtc() MERGE RANGE (@Boundary);
                SET @Merges += 1;
                FETCH NEXT FROM merge_cur INTO @Boundary;
            END
            CLOSE merge_cur;
            DEALLOCATE merge_cur;
        END

        SET @Message = N'Partition window maintained as of ' + CONVERT(NVARCHAR(23), @AsOfUtc, 121)
                     + N' (splits=' + CAST(@Splits AS NVARCHAR(10))
                     + N', truncations=' + CAST(@Truncations AS NVARCHAR(10))
                     + N', merges=' + CAST(@Merges AS NVARCHAR(10)) + N').';

        -- Success audit (summary row). OperationLog.UserId is nullable but we
        -- attribute to bootstrap when unattended.
        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserIdEff,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Partition',
            @EntityId           = NULL,
            @LogEventTypeCode   = N'PartitionMaintained',
            @LogSeverityCode    = N'Info',
            @Description        = @Message,
            @OldValue           = NULL,
            @NewValue           = @Params;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();

        -- Clean up any open cursors left by a mid-loop failure.
        IF CURSOR_STATUS('local', 'trunc_cur') >= 0 BEGIN CLOSE trunc_cur; DEALLOCATE trunc_cur; END
        IF CURSOR_STATUS('local', 'merge_cur') >= 0 BEGIN CLOSE merge_cur; DEALLOCATE merge_cur; END

        SET @Status  = 0;
        SET @Message = LEFT(@ErrMsg, 500);

        -- Failure audit (FailureLog.AppUserId is NOT NULL -> bootstrap when unattended).
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserIdEff,
                @LogEntityTypeCode   = N'Partition',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'PartitionMaintenanceFailed',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow — do not mask the original error.
        END CATCH

        RAISERROR(@ErrMsg, 16, 1);
    END CATCH

    SELECT @Status AS Status, @Message AS Message;
END;
GO
