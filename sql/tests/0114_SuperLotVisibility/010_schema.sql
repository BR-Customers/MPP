-- =============================================
-- File:        0114_SuperLotVisibility/010_schema.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6 -- Audit.LogEventType.RepeatsLotTimeline /
--              LotTimelineKind, the six per-LOT super-lot event codes, and the
--              inventory of Lot-entity codes that repeat a timeline stream.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0114_SuperLotVisibility/010_schema.sql';
GO

DECLARE @n NVARCHAR(MAX);

-- ---- columns ----
SET @n = (SELECT CONCAT(t.name, N'|', c.is_nullable) FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
          WHERE c.object_id = OBJECT_ID(N'Audit.LogEventType') AND c.name = N'RepeatsLotTimeline');
EXEC test.Assert_IsEqual @TestName = N'[Schema] RepeatsLotTimeline is BIT NOT NULL', @Expected = N'bit|0', @Actual = @n;
SET @n = (SELECT CONCAT(t.name, N'|', c.max_length, N'|', c.is_nullable) FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
          WHERE c.object_id = OBJECT_ID(N'Audit.LogEventType') AND c.name = N'LotTimelineKind');
EXEC test.Assert_IsEqual @TestName = N'[Schema] LotTimelineKind is NVARCHAR(20) NULL', @Expected = N'nvarchar|40|1', @Actual = @n;
SET @n = (SELECT dc.definition FROM sys.default_constraints dc
          WHERE dc.parent_object_id = OBJECT_ID(N'Audit.LogEventType') AND COL_NAME(dc.parent_object_id, dc.parent_column_id) = N'RepeatsLotTimeline');
EXEC test.Assert_IsEqual @TestName = N'[Schema] RepeatsLotTimeline defaults to 0', @Expected = N'((0))', @Actual = @n;

-- ---- the six per-LOT super-lot codes ----
DECLARE @want TABLE (Code NVARCHAR(50));
INSERT INTO @want VALUES (N'ControlledRunLotJoined'), (N'ControlledRunLotLeft'), (N'ControlledRunLotResult'),
    (N'ControlledRunLotResultVoided'), (N'ControlledRunLotDeviation'), (N'ControlledRunLotReleased');
SET @n = ISNULL((SELECT STRING_AGG(w.Code, N',') FROM @want w
          WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType e WHERE e.Code = w.Code)), N'');
EXEC test.Assert_IsEqual @TestName = N'[Codes] all six super-lot codes exist (missing: none)', @Expected = N'', @Actual = @n;
SET @n = ISNULL((SELECT STRING_AGG(e.Code, N',') FROM Audit.LogEventType e JOIN @want w ON w.Code = e.Code
          WHERE ISNULL(e.LotTimelineKind, N'') <> N'Super-lot' OR e.RepeatsLotTimeline <> 0), N'');
EXEC test.Assert_IsEqual @TestName = N'[Codes] super-lot codes are kind Super-lot and show on the timeline', @Expected = N'', @Actual = @n;

-- ---- codes that repeat a record-table stream carry the flag ----
DECLARE @rep TABLE (Code NVARCHAR(50));
INSERT INTO @rep VALUES (N'LotCreated'), (N'LotMoved'), (N'LotStatusChanged'), (N'LotUpdated'), (N'LotSplit'), (N'LotMerged'),
    (N'LotConsumed'), (N'DieCastPieceContributed'), (N'DieCastLotOpened'), (N'DieCastLotReleased'), (N'DieCastLotVoided'),
    (N'MachiningInPicked'), (N'MachiningOutCompleted');
SET @n = ISNULL((SELECT STRING_AGG(r.Code, N',') FROM @rep r
          LEFT JOIN Audit.LogEventType e ON e.Code = r.Code WHERE ISNULL(e.RepeatsLotTimeline, 0) <> 1), N'');
EXEC test.Assert_IsEqual @TestName = N'[Flag] every code repeating a timeline stream is flagged (unflagged: none)', @Expected = N'', @Actual = @n;

-- ---- codes that exist only in the audit log are NOT flagged ----
DECLARE @only TABLE (Code NVARCHAR(50));
INSERT INTO @only VALUES (N'CrtActivated'), (N'CrtCleared'), (N'MissedCrtInspect'), (N'VendorReturnMarked'),
    (N'VendorReturnConfirmed'), (N'VendorReturnCancelled'), (N'LotReworkStarted'), (N'LotReworkCompleted'),
    (N'MaterialSubstituteOverride');
SET @n = ISNULL((SELECT STRING_AGG(o.Code, N',') FROM @only o
          JOIN Audit.LogEventType e ON e.Code = o.Code WHERE e.RepeatsLotTimeline <> 0), N'');
EXEC test.Assert_IsEqual @TestName = N'[Flag] audit-only codes are not flagged (flagged: none)', @Expected = N'', @Actual = @n;

-- ---- labels ----
SET @n = (SELECT CONCAT(RepeatsLotTimeline, N'|', LotTimelineKind) FROM Audit.LogEventType WHERE Code = N'CrtActivated');
EXEC test.Assert_IsEqual @TestName = N'[Label] CrtActivated is kind CRT, flag 0', @Expected = N'0|CRT', @Actual = @n;
SET @n = ISNULL((SELECT STRING_AGG(Code, N',') FROM Audit.LogEventType
          WHERE Code IN (N'CrtActivated', N'CrtCleared', N'MissedCrtInspect') AND ISNULL(LotTimelineKind, N'') <> N'CRT'), N'');
EXEC test.Assert_IsEqual @TestName = N'[Label] all CRT codes are kind CRT', @Expected = N'', @Actual = @n;
SET @n = ISNULL((SELECT STRING_AGG(Code, N',') FROM Audit.LogEventType
          WHERE Code LIKE N'VendorReturn%' AND ISNULL(LotTimelineKind, N'') <> N'Vendor return'), N'');
EXEC test.Assert_IsEqual @TestName = N'[Label] VendorReturn codes are kind Vendor return', @Expected = N'', @Actual = @n;
SET @n = ISNULL((SELECT STRING_AGG(Code, N',') FROM Audit.LogEventType
          WHERE Code LIKE N'LotRework%' AND ISNULL(LotTimelineKind, N'') <> N'Rework'), N'');
EXEC test.Assert_IsEqual @TestName = N'[Label] LotRework codes are kind Rework', @Expected = N'', @Actual = @n;
SET @n = ISNULL((SELECT CAST(LotTimelineKind AS NVARCHAR(20)) FROM Audit.LogEventType WHERE Code = N'MaterialSubstituteOverride'), N'(null)');
EXEC test.Assert_IsEqual @TestName = N'[Label] an unlabelled code keeps a NULL kind (reads as Event)', @Expected = N'(null)', @Actual = @n;
SET @n = ISNULL((SELECT STRING_AGG(i.name + N':' + c.name, N',') WITHIN GROUP (ORDER BY i.name)
          FROM sys.indexes i
          JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 1
          JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
          WHERE i.object_id = OBJECT_ID(N'Lots.ContainerSerialHistory') AND i.name IN (N'IX_CSH_OldContainer', N'IX_CSH_NewContainer')), N'');
EXEC test.Assert_IsEqual @TestName = N'[Index] ContainerSerialHistory by-container indexes lead on Old/NewContainerId', @Expected = N'IX_CSH_NewContainer:NewContainerId,IX_CSH_OldContainer:OldContainerId', @Actual = @n;
GO

EXEC test.EndTestFile;
GO
