-- =============================================
-- File:         0117_Oee_Dashboard/005_schema.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-30
-- Description:  Migration 0117 (OEE dashboard spec v0.3.1 sec 6.7, 7.4, D21):
--               Oee.ShiftSummary, Oee.ShiftSummaryConfig, Lots.Lot.ShiftId +
--               MintedPieceCount.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/005_schema.sql';
GO

DECLARE @c BIT;

SET @c = CASE WHEN EXISTS (
    SELECT 1 FROM sys.foreign_key_columns fkc
    WHERE fkc.parent_object_id = OBJECT_ID(N'Lots.Lot')
      AND COL_NAME(fkc.parent_object_id, fkc.parent_column_id) = N'ShiftId'
      AND fkc.referenced_object_id = OBJECT_ID(N'Oee.Shift')) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] Lot.ShiftId exists and FKs Oee.Shift', @Condition = @c;

SET @c = CASE WHEN COL_LENGTH(N'Lots.Lot', N'MintedPieceCount') IS NOT NULL THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] Lot.MintedPieceCount exists', @Condition = @c;

SET @c = CASE WHEN (SELECT COUNT(*) FROM Oee.ShiftSummaryConfig) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] ShiftSummaryConfig has exactly 1 row', @Condition = @c;
GO

-- Unique key + RowKind CHECK (need a real shift row for the FK).
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_005_Sched', N'005 schema test', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (SCOPE_IDENTITY(), '2026-01-05T06:00:00', '2026-01-05T14:00:00', N'TEST_005 shift');
DECLARE @ShiftId BIGINT = SCOPE_IDENTITY();

DECLARE @err INT = 0, @c BIT;
INSERT INTO Oee.ShiftSummary (ShiftId, LocationId, RowKind, AreaFamily, IsActive, ComputedAt, InputFingerprint)
VALUES (@ShiftId, NULL, N'AreaCharge', N'diecast', 0, SYSUTCDATETIME(), 0x00);
BEGIN TRY
    INSERT INTO Oee.ShiftSummary (ShiftId, LocationId, RowKind, AreaFamily, IsActive, ComputedAt, InputFingerprint)
    VALUES (@ShiftId, NULL, N'AreaCharge', N'diecast', 0, SYSUTCDATETIME(), 0x00);
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
SET @c = CASE WHEN @err IN (2601, 2627) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] ShiftSummary unique key rejects a duplicate (ShiftId, RowKind, AreaFamily, LocationId)', @Condition = @c;

SET @err = 0;
BEGIN TRY
    INSERT INTO Oee.ShiftSummary (ShiftId, LocationId, RowKind, AreaFamily, IsActive, ComputedAt, InputFingerprint)
    VALUES (@ShiftId, NULL, N'Bogus', N'trim', 0, SYSUTCDATETIME(), 0x00);
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
SET @c = CASE WHEN @err = 547 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] ShiftSummary RowKind CHECK rejects ''Bogus''', @Condition = @c;

DELETE FROM Oee.ShiftSummary WHERE ShiftId = @ShiftId;
DELETE FROM Oee.Shift WHERE Id = @ShiftId;
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_005_Sched';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
