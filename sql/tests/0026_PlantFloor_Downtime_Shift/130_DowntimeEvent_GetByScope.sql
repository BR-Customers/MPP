-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/130_DowntimeEvent_GetByScope.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Pins what Oee.DowntimeEvent_GetByScope returns, and migration
--               0127's index (stored-procedure review: v1.2 replaced the
--               catch-all WHERE that scanned the whole table with seeks; the
--               result set must not change). Behaviour pinned:
--                 * scope = the location, plus its subtree when
--                   @IncludeDescendants = 1; never a location outside it
--                 * @ShiftId given: that shift's events only (open, closed,
--                   voided -- voided ones flagged)
--                 * @ShiftId NULL: the current open shift's events PLUS every
--                   event still open and not voided from any shift
--                 * no shift open and none passed: every event in scope
--                 * order StartedAt DESC, then Id DESC on a tie
--               Fixture: a parent location P with two children C1, C2, and an
--               unrelated location X; events inserted directly (Remarks
--               'test 130') so the read is tested in isolation.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/130_DowntimeEvent_GetByScope.sql';
GO

-- ---- cleanup from an aborted earlier run ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks = N'test 130';
DELETE FROM Oee.Shift WHERE Remarks = N'test 130';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'test 130 schedule';
IF OBJECT_ID(N'tempdb..#Gbs') IS NOT NULL DROP TABLE #Gbs;
CREATE TABLE #Gbs (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

-- ---- fixture ----
-- P: the lowest-Id non-root location with at least two children, none of P / children
-- holding an open downtime event (the one-open-per-location index).
DECLARE @P BIGINT = (
    SELECT TOP 1 p.Id
    FROM Location.Location p
    WHERE p.ParentLocationId IS NOT NULL
      AND (SELECT COUNT(*) FROM Location.Location c WHERE c.ParentLocationId = p.Id) >= 2
      AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeEvent d
                      WHERE d.EndedAt IS NULL
                        AND (d.LocationId = p.Id
                             OR d.LocationId IN (SELECT c.Id FROM Location.Location c WHERE c.ParentLocationId = p.Id)))
    ORDER BY p.Id);
DECLARE @C1 BIGINT = (SELECT MIN(Id) FROM Location.Location WHERE ParentLocationId = @P);
DECLARE @C2 BIGINT = (SELECT MIN(Id) FROM Location.Location WHERE ParentLocationId = @P AND Id > @C1);
-- X: P's parent -- outside P's subtree by construction.
DECLARE @X BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @P);
INSERT INTO #Gbs (Tag, Val) VALUES (N'P', @P), (N'C1', @C1), (N'C2', @C2), (N'X', @X);

INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedAt, CreatedByUserId)
VALUES (N'test 130 schedule', '07:00', '15:00', 127, '2026-01-01', SYSUTCDATETIME(), 1);
DECLARE @Sched BIGINT = SCOPE_IDENTITY();
INSERT INTO #Gbs (Tag, Val) VALUES (N'SCHED', @Sched);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-01-10 07:00', '2026-01-10 15:00', N'test 130');
INSERT INTO #Gbs (Tag, Val) VALUES (N'OLD', SCOPE_IDENTITY());
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-01-09 07:00', '2026-01-09 15:00', N'test 130');
INSERT INTO #Gbs (Tag, Val) VALUES (N'OLD2', SCOPE_IDENTITY());
IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL)
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
    VALUES (@Sched, SYSUTCDATETIME(), NULL, N'test 130');
INSERT INTO #Gbs (Tag, Val)
SELECT TOP 1 N'CUR', Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC;
GO

DECLARE @P BIGINT  = (SELECT Val FROM #Gbs WHERE Tag = N'P');
DECLARE @C1 BIGINT = (SELECT Val FROM #Gbs WHERE Tag = N'C1');
DECLARE @C2 BIGINT = (SELECT Val FROM #Gbs WHERE Tag = N'C2');
DECLARE @X BIGINT  = (SELECT Val FROM #Gbs WHERE Tag = N'X');
DECLARE @Cur BIGINT  = (SELECT Val FROM #Gbs WHERE Tag = N'CUR');
DECLARE @Old BIGINT  = (SELECT Val FROM #Gbs WHERE Tag = N'OLD');
DECLARE @Old2 BIGINT = (SELECT Val FROM #Gbs WHERE Tag = N'OLD2');
DECLARE @Src BIGINT  = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

-- Tag   Loc  Shift  State            StartedAt (UTC)
-- E1    C1   CUR    closed           2030-01-01 10:00   (tie with E2: higher Id first)
-- E2    C2   CUR    closed           2030-01-01 10:00
-- E3    P    CUR    closed, voided   2030-01-01 09:00
-- E9    P    CUR    open             2030-01-01 11:00
-- E4    C1   OLD    open             2026-01-10 08:00   (open from an earlier shift)
-- E5    C2   OLD    open, voided     2026-01-10 09:00   (voided: not carried forward)
-- E6    C1   OLD    closed           2026-01-10 10:00
-- E8    C2   OLD2   closed           2026-01-09 08:00
-- E7    X    CUR    closed           2030-01-01 12:00   (out of scope: never returned)
DECLARE @t TABLE (Tag NVARCHAR(20), Loc BIGINT, Sh BIGINT, St DATETIME2(3), En DATETIME2(3), Vo DATETIME2(3), Ord INT);
INSERT INTO @t VALUES
    (N'E1', @C1, @Cur,  '2030-01-01 10:00', '2030-01-01 10:20', NULL, 1),
    (N'E2', @C2, @Cur,  '2030-01-01 10:00', '2030-01-01 10:30', NULL, 2),
    (N'E3', @P,  @Cur,  '2030-01-01 09:00', '2030-01-01 09:10', '2030-01-01 09:30', 3),
    (N'E9', @P,  @Cur,  '2030-01-01 11:00', NULL, NULL, 4),
    (N'E4', @C1, @Old,  '2026-01-10 08:00', NULL, NULL, 5),
    (N'E5', @C2, @Old,  '2026-01-10 09:00', NULL, '2026-01-10 09:05', 6),
    (N'E6', @C1, @Old,  '2026-01-10 10:00', '2026-01-10 10:15', NULL, 7),
    (N'E8', @C2, @Old2, '2026-01-09 08:00', '2026-01-09 08:40', NULL, 8),
    (N'E7', @X,  @Cur,  '2030-01-01 12:00', '2030-01-01 12:05', NULL, 9);
DECLARE @i INT = 1, @tag NVARCHAR(20);
WHILE @i <= 9
BEGIN
    INSERT INTO Oee.DowntimeEvent (LocationId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, AppUserId, Remarks,
                                   VoidedAt, VoidedByUserId, VoidReason)
    SELECT Loc, Sh, St, En, @Src, 1, N'test 130', Vo, CASE WHEN Vo IS NULL THEN NULL ELSE 1 END,
           CASE WHEN Vo IS NULL THEN NULL ELSE N'test 130 void' END
    FROM @t WHERE Ord = @i;
    SET @tag = (SELECT Tag FROM @t WHERE Ord = @i);
    INSERT INTO #Gbs (Tag, Val) VALUES (@tag, SCOPE_IDENTITY());
    SET @i += 1;
END
GO

-- ---- the reads ----
IF OBJECT_ID(N'tempdb..#Gr') IS NOT NULL DROP TABLE #Gr;
CREATE TABLE #Gr (RowNo INT IDENTITY(1,1), DowntimeEventId BIGINT, LocationId BIGINT, LocationCode NVARCHAR(100), ScopeLocationId BIGINT,
    DowntimeReasonCodeId BIGINT, ReasonCode NVARCHAR(100), ReasonDescription NVARCHAR(500), SourceCode NVARCHAR(100),
    StartedAtEt DATETIME2(3), EndedAtEt DATETIME2(3), DurationMinutes INT, IsApproximate BIT, Remarks NVARCHAR(500),
    AppUserId BIGINT, OperatorInitials NVARCHAR(50), IsOpen BIT, IsVoided BIT, VoidReason NVARCHAR(500));
GO

DECLARE @P BIGINT  = (SELECT Val FROM #Gbs WHERE Tag = N'P');
DECLARE @C1 BIGINT = (SELECT Val FROM #Gbs WHERE Tag = N'C1');
DECLARE @Old BIGINT = (SELECT Val FROM #Gbs WHERE Tag = N'OLD');
DECLARE @S NVARCHAR(400);

-- 1. current-shift view of the subtree (the 30 s header poll)
TRUNCATE TABLE #Gr;
INSERT INTO #Gr (DowntimeEventId, LocationId, LocationCode, ScopeLocationId, DowntimeReasonCodeId, ReasonCode, ReasonDescription, SourceCode, StartedAtEt, EndedAtEt, DurationMinutes, IsApproximate, Remarks, AppUserId, OperatorInitials, IsOpen, IsVoided, VoidReason)
EXEC Oee.DowntimeEvent_GetByScope @ScopeLocationId = @P, @IncludeDescendants = 1, @ShiftId = NULL;
SET @S = ISNULL((SELECT STRING_AGG(g.Tag, N',') WITHIN GROUP (ORDER BY r.RowNo)
                 FROM #Gr r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId AND g.Tag LIKE N'E%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] current shift + subtree: this shift''s events, plus still-open unvoided ones from any shift, newest first, tie by higher Id',
    @Expected = N'E9,E2,E1,E3,E4', @Actual = @S;
SET @S = (SELECT CONCAT(IsOpen, IsVoided, N'|', ScopeLocationId - @P, N'|', DurationMinutes) FROM #Gr r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId WHERE g.Tag = N'E3');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] a voided closed event in the shift is listed and flagged (IsOpen 0, IsVoided 1), ScopeLocationId echoed, duration derived',
    @Expected = N'01|0|10', @Actual = @S;
SET @S = (SELECT CONVERT(NVARCHAR(30), StartedAtEt, 121) FROM #Gr r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId WHERE g.Tag = N'E9');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] StartedAt is converted UTC to Eastern', @Expected = N'2030-01-01 06:00:00.000', @Actual = @S;

-- 2. no descendants
TRUNCATE TABLE #Gr;
INSERT INTO #Gr (DowntimeEventId, LocationId, LocationCode, ScopeLocationId, DowntimeReasonCodeId, ReasonCode, ReasonDescription, SourceCode, StartedAtEt, EndedAtEt, DurationMinutes, IsApproximate, Remarks, AppUserId, OperatorInitials, IsOpen, IsVoided, VoidReason)
EXEC Oee.DowntimeEvent_GetByScope @ScopeLocationId = @P, @IncludeDescendants = 0, @ShiftId = NULL;
SET @S = ISNULL((SELECT STRING_AGG(g.Tag, N',') WITHIN GROUP (ORDER BY r.RowNo)
                 FROM #Gr r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId AND g.Tag LIKE N'E%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] @IncludeDescendants = 0: the location''s own events only',
    @Expected = N'E9,E3', @Actual = @S;

-- 3. one child, current shift
TRUNCATE TABLE #Gr;
INSERT INTO #Gr (DowntimeEventId, LocationId, LocationCode, ScopeLocationId, DowntimeReasonCodeId, ReasonCode, ReasonDescription, SourceCode, StartedAtEt, EndedAtEt, DurationMinutes, IsApproximate, Remarks, AppUserId, OperatorInitials, IsOpen, IsVoided, VoidReason)
EXEC Oee.DowntimeEvent_GetByScope @ScopeLocationId = @C1, @IncludeDescendants = 1, @ShiftId = NULL;
SET @S = ISNULL((SELECT STRING_AGG(g.Tag, N',') WITHIN GROUP (ORDER BY r.RowNo)
                 FROM #Gr r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId AND g.Tag LIKE N'E%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] a child scope sees only its own events (current + carried-open)',
    @Expected = N'E1,E4', @Actual = @S;

-- 4. explicit past shift
TRUNCATE TABLE #Gr;
INSERT INTO #Gr (DowntimeEventId, LocationId, LocationCode, ScopeLocationId, DowntimeReasonCodeId, ReasonCode, ReasonDescription, SourceCode, StartedAtEt, EndedAtEt, DurationMinutes, IsApproximate, Remarks, AppUserId, OperatorInitials, IsOpen, IsVoided, VoidReason)
EXEC Oee.DowntimeEvent_GetByScope @ScopeLocationId = @P, @IncludeDescendants = 1, @ShiftId = @Old;
SET @S = ISNULL((SELECT STRING_AGG(g.Tag, N',') WITHIN GROUP (ORDER BY r.RowNo)
                 FROM #Gr r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId AND g.Tag LIKE N'E%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] explicit @ShiftId: that shift''s events only (open, voided, closed), no carried-open from others',
    @Expected = N'E6,E5,E4', @Actual = @S;
SET @S = (SELECT CONCAT(IsOpen, IsVoided, N'|', VoidReason) FROM #Gr r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId WHERE g.Tag = N'E5');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] an open voided event is flagged IsOpen 1, IsVoided 1 with its reason',
    @Expected = N'11|test 130 void', @Actual = @S;
GO

-- 5. no open shift and no @ShiftId: every event in scope. Close the open
--    shift inside a transaction, capture into a table variable (survives the
--    rollback), roll back, then assert.
DECLARE @P BIGINT  = (SELECT Val FROM #Gbs WHERE Tag = N'P');
DECLARE @R5 TABLE (RowNo INT IDENTITY(1,1), DowntimeEventId BIGINT, LocationId BIGINT, LocationCode NVARCHAR(100), ScopeLocationId BIGINT,
    DowntimeReasonCodeId BIGINT, ReasonCode NVARCHAR(100), ReasonDescription NVARCHAR(500), SourceCode NVARCHAR(100),
    StartedAtEt DATETIME2(3), EndedAtEt DATETIME2(3), DurationMinutes INT, IsApproximate BIT, Remarks NVARCHAR(500),
    AppUserId BIGINT, OperatorInitials NVARCHAR(50), IsOpen BIT, IsVoided BIT, VoidReason NVARCHAR(500));
BEGIN TRANSACTION;
    UPDATE Oee.Shift SET ActualEnd = SYSUTCDATETIME() WHERE ActualEnd IS NULL;
    INSERT INTO @R5 (DowntimeEventId, LocationId, LocationCode, ScopeLocationId, DowntimeReasonCodeId, ReasonCode, ReasonDescription, SourceCode, StartedAtEt, EndedAtEt, DurationMinutes, IsApproximate, Remarks, AppUserId, OperatorInitials, IsOpen, IsVoided, VoidReason)
    EXEC Oee.DowntimeEvent_GetByScope @ScopeLocationId = @P, @IncludeDescendants = 1, @ShiftId = NULL;
ROLLBACK TRANSACTION;
DECLARE @S NVARCHAR(400) = ISNULL((SELECT STRING_AGG(g.Tag, N',') WITHIN GROUP (ORDER BY r.RowNo)
                 FROM @R5 r INNER JOIN #Gbs g ON g.Val = r.DowntimeEventId AND g.Tag LIKE N'E%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[GetByScope] no open shift and no @ShiftId: every event in scope, any shift, newest first',
    @Expected = N'E9,E2,E1,E3,E6,E5,E4,E8', @Actual = @S;
GO

-- ---- migration 0127: the index definition ----
DECLARE @IxId INT = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(N'Oee.DowntimeEvent') AND name = N'IX_DowntimeEvent_Location_Shift');
DECLARE @S NVARCHAR(400);
SET @S = CAST(CASE WHEN @IxId IS NULL THEN 0 ELSE 1 END AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[0127] IX_DowntimeEvent_Location_Shift exists', @Expected = N'1', @Actual = @S;
SET @S = (SELECT CONCAT(type_desc, N'|unique=', is_unique, N'|filtered=', has_filter)
          FROM sys.indexes WHERE object_id = OBJECT_ID(N'Oee.DowntimeEvent') AND index_id = @IxId);
EXEC test.Assert_IsEqual @TestName = N'[0127] index is NONCLUSTERED, non-unique, unfiltered', @Expected = N'NONCLUSTERED|unique=0|filtered=0', @Actual = @S;
SET @S = (SELECT STRING_AGG(CONCAT(c.name, CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END, CASE WHEN ic.is_included_column = 1 THEN N' (incl)' ELSE N'' END), N',')
                 WITHIN GROUP (ORDER BY ic.is_included_column, ic.key_ordinal, c.name)
          FROM sys.index_columns ic INNER JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
          WHERE ic.object_id = OBJECT_ID(N'Oee.DowntimeEvent') AND ic.index_id = @IxId);
EXEC test.Assert_IsEqual @TestName = N'[0127] keyed (LocationId, ShiftId), no included columns', @Expected = N'LocationId,ShiftId', @Actual = @S;
SET @S = CAST((SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0127_downtimeevent_location_shift_index') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0127] recorded in dbo.SchemaVersion', @Expected = N'1', @Actual = @S;
GO

-- ---- cleanup ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks = N'test 130';
DELETE FROM Oee.Shift WHERE Remarks = N'test 130';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'test 130 schedule';
IF OBJECT_ID(N'tempdb..#Gbs') IS NOT NULL DROP TABLE #Gbs;
IF OBJECT_ID(N'tempdb..#Gr') IS NOT NULL DROP TABLE #Gr;
GO
