-- =============================================================================
-- 2026-11-20_packout_perf.sql  --  named pack-outs (0136): before/after cost of
-- the six readers it changes. READ-ONLY except Assembly_CompleteTray, which runs
-- inside BEGIN TRAN ... ROLLBACK.
--
-- Run against a THROWAWAY copy of the 5.5M-LOT bench (never MPP_MES_Dev, never
-- prod), once at the base branch's state ("before") and once after 0136 + this
-- branch's repeatables ("after"):
--   sqlcmd -S localhost -E -C -d MPP_MES_Bench_PO -I -i sql/scratch/2026-11-20_packout_perf.sql
--
-- Each case: one call under SET STATISTICS IO (per-table reads in the messages),
-- then 20 warm calls timed. A proc that has no @TerminalLocationId yet ("before")
-- is called without it.
-- Cases: two By Weight terminals of the bench -- OS-66V-TC-A100-T1 (the prod 66V
-- part, ~123k LOTs of the part) and MA2-6MAOP-AOUT.
-- =============================================================================
SET NOCOUNT ON;

DECLARE @Cases TABLE (Seq INT IDENTITY, TermCode NVARCHAR(50));
INSERT @Cases (TermCode) VALUES (N'OS-66V-TC-A100-T1'), (N'MA2-6MAOP-AOUT');

DECLARE @Procs TABLE (Seq INT IDENTITY, Name NVARCHAR(200), HasTerm BIT);
INSERT @Procs (Name, HasTerm)
SELECT v.Name, CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = OBJECT_ID(v.Name) AND p.name = N'@TerminalLocationId') THEN 1 ELSE 0 END
FROM (VALUES (N'Workorder.ScaleStation_GetRunningPart'), (N'Workorder.ScaleStation_ListEligibleParts'),
             (N'Parts.ContainerConfig_JudgeWeight'), (N'Workorder.Assembly_GetTraysRemaining'),
             (N'Parts.ContainerConfig_GetByItemAndMethod'), (N'Workorder.Assembly_CompleteTray')) v(Name);

DECLARE @c INT = 1, @p INT, @Term BIGINT, @Line BIGINT, @Item BIGINT, @TermCode NVARCHAR(50),
        @Name NVARCHAR(200), @HasTerm BIT, @Sql NVARCHAR(MAX), @Call NVARCHAR(MAX), @Ppt INT,
        @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,2), @sum DECIMAL(12,2), @r0 BIGINT, @r1 BIGINT;

WHILE @c <= (SELECT COUNT(*) FROM @Cases)
BEGIN
    SELECT @TermCode = TermCode FROM @Cases WHERE Seq = @c;
    SELECT @Term = Id, @Line = ParentLocationId FROM Location.Location WHERE Code = @TermCode;
    SELECT TOP 1 @Item = cc.ItemId FROM Parts.ContainerConfig cc
    JOIN Parts.ItemLocation il ON il.ItemId = cc.ItemId AND il.LocationId = @Line AND il.DeprecatedAt IS NULL
    WHERE cc.ClosureMethod = N'ByWeight' AND cc.DeprecatedAt IS NULL ORDER BY cc.ItemId;
    SELECT @Ppt = PartsPerTray FROM Parts.ContainerConfig WHERE ItemId = @Item AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL;
    PRINT CONCAT('##### terminal ', @TermCode, ' (', @Term, ') line ', @Line, ' item ', @Item, ' ppt ', @Ppt);

    SET @p = 1;
    WHILE @p <= (SELECT COUNT(*) FROM @Procs)
    BEGIN
        SELECT @Name = Name, @HasTerm = HasTerm FROM @Procs WHERE Seq = @p;
        SET @Call = CASE @Name
            WHEN N'Workorder.ScaleStation_GetRunningPart'    THEN N'EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @T'
            WHEN N'Workorder.ScaleStation_ListEligibleParts' THEN N'EXEC Workorder.ScaleStation_ListEligibleParts @TerminalLocationId = @T'
            WHEN N'Parts.ContainerConfig_JudgeWeight'        THEN N'EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @I, @ClosureMethod = N''ByWeight'', @Weight = 15.0'
                                                                 + CASE WHEN @HasTerm = 1 THEN N', @TerminalLocationId = @T' ELSE N'' END
            WHEN N'Workorder.Assembly_GetTraysRemaining'     THEN N'EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @L, @FinishedGoodItemId = @I, @ClosureMethod = N''ByWeight'''
                                                                 + CASE WHEN @HasTerm = 1 THEN N', @TerminalLocationId = @T' ELSE N'' END
            WHEN N'Parts.ContainerConfig_GetByItemAndMethod' THEN N'EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = @I, @ClosureMethod = N''ByWeight'''
                                                                 + CASE WHEN @HasTerm = 1 THEN N', @TerminalLocationId = @T' ELSE N'' END
            WHEN N'Workorder.Assembly_CompleteTray'          THEN N'BEGIN TRAN; EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I, @PieceCount = @P, @CellLocationId = @L, @ClosureMethod = N''ByWeight'', @AppUserId = 1, @TerminalLocationId = @T; ROLLBACK;'
        END;
        PRINT CONCAT('=== ', @Name, CASE WHEN @HasTerm = 1 THEN ' (with terminal)' ELSE '' END);
        SET STATISTICS IO ON;
        EXEC sp_executesql @Call, N'@T BIGINT, @L BIGINT, @I BIGINT, @P INT', @Term, @Line, @Item, @Ppt;
        SET STATISTICS IO OFF;
        SET @i = 0; SET @sum = 0;
        SET @r0 = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID);
        WHILE @i < 20
        BEGIN
            SET @t0 = SYSUTCDATETIME();
            EXEC sp_executesql @Call, N'@T BIGINT, @L BIGINT, @I BIGINT, @P INT', @Term, @Line, @Item, @Ppt;
            SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
            SET @sum += @ms; SET @i += 1;
        END
        SET @r1 = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID);
        PRINT CONCAT('RESULT|', @TermCode, '|', @Name, '|warm avg ms ', CAST(@sum / 20 AS DECIMAL(10,2)), '|logical reads per call ', (@r1 - @r0) / 20);
        SET @p += 1;
    END
    SET @c += 1;
END

-- Parallelism check: the highest DOP any statement of these procs last ran at
-- (the 2026-11-10 incident was a read going parallel). Expect 1 everywhere.
SELECT OBJECT_SCHEMA_NAME(st.objectid, st.dbid) + N'.' + OBJECT_NAME(st.objectid, st.dbid) AS ProcName,
       MAX(qs.last_dop) AS MaxLastDop, SUM(qs.execution_count) AS Execs
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE st.dbid = DB_ID()
  AND OBJECT_NAME(st.objectid, st.dbid) IN (N'ScaleStation_GetRunningPart', N'ScaleStation_ListEligibleParts',
        N'ContainerConfig_JudgeWeight', N'Assembly_GetTraysRemaining', N'ContainerConfig_GetByItemAndMethod', N'Assembly_CompleteTray')
GROUP BY st.objectid, st.dbid
ORDER BY ProcName;
