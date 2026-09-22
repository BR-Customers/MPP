-- =============================================
-- File:         0096_Trim_Partial/010_Schema.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-22
-- Description:  Migration 0096 -- ProductionEvent.ShiftId exists, is nullable,
--               FK to Oee.Shift; LogEventType 34 no longer says "reserved".
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0096_Trim_Partial/010_Schema.sql';
GO

DECLARE @Col NVARCHAR(10) = CASE WHEN COL_LENGTH(N'Workorder.ProductionEvent', N'ShiftId') IS NULL THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[0096] ProductionEvent.ShiftId exists', @Expected = N'1', @Actual = @Col;

DECLARE @Nullable NVARCHAR(10) = CAST(COLUMNPROPERTY(OBJECT_ID(N'Workorder.ProductionEvent'), N'ShiftId', 'AllowsNull') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0096] ShiftId is nullable', @Expected = N'1', @Actual = @Nullable;

DECLARE @Fk NVARCHAR(10) = CAST((SELECT COUNT(*) FROM sys.foreign_keys
    WHERE name = N'FK_ProductionEvent_Shift'
      AND parent_object_id = OBJECT_ID(N'Workorder.ProductionEvent')
      AND referenced_object_id = OBJECT_ID(N'Oee.Shift')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0096] FK_ProductionEvent_Shift -> Oee.Shift', @Expected = N'1', @Actual = @Fk;

DECLARE @Reserved NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Audit.LogEventType
    WHERE Id = 34 AND Code = N'TrimCheckpointRecorded' AND Description NOT LIKE N'%reserved%') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0096] LogEventType 34 describes the partial', @Expected = N'1', @Actual = @Reserved;
GO

EXEC test.EndTestFile;
GO
