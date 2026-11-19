-- =============================================
-- File:         0134_ScaleDigi/010_schema.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-19
-- Description:
--   Migration 0134: the ScaleStationDigi device type (ByWeight), the
--   ScalePendingPressStatus code table (Pending = Id 1), the
--   ScalePendingPress table, and the one-Pending-per-terminal rule enforced
--   by the filtered unique index.
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0134_ScaleDigi/010_schema.sql';
GO

DECLARE @Dt NVARCHAR(100) = (SELECT CONCAT(Code, N'|', ClosureMethodCode) FROM Location.PlcDeviceType WHERE Code = N'ScaleStationDigi');
EXEC test.Assert_IsEqual @TestName = N'[0134] ScaleStationDigi device type is ByWeight', @Expected = N'ScaleStationDigi|ByWeight', @Actual = @Dt;

DECLARE @Codes NVARCHAR(200) = (SELECT STRING_AGG(CONCAT(Id, N'=', Code), N',') WITHIN GROUP (ORDER BY Id)
                                FROM Workorder.ScalePendingPressStatus);
EXEC test.Assert_IsEqual @TestName = N'[0134] status codes Pending=1, Closed=2, Discarded=3', @Expected = N'1=Pending,2=Closed,3=Discarded', @Actual = @Codes;

DECLARE @Ev NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEventType
                            WHERE Code IN (N'ScalePressHeld', N'ScalePressPicked', N'ScalePressDiscarded'));
EXEC test.Assert_IsEqual @TestName = N'[0134] three LogEventType rows', @Expected = N'3', @Actual = @Ev;

DECLARE @Sv NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM dbo.SchemaVersion WHERE MigrationId = N'0134_scale_digi_and_pending_press');
EXEC test.Assert_IsEqual @TestName = N'[0134] SchemaVersion row', @Expected = N'1', @Actual = @Sv;
GO

-- ==== one Pending per terminal ====
DECLARE @Term BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DELETE FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @Term;
INSERT INTO Workorder.ScalePendingPress (TerminalLocationId, ReceivedAt, NetWeight, Uom, ScalePartCode, StatusId)
VALUES (@Term, SYSUTCDATETIME(), 15.5, N'LB', N'TEST3', 1);
DECLARE @Err INT = 0;
BEGIN TRY
    INSERT INTO Workorder.ScalePendingPress (TerminalLocationId, ReceivedAt, NetWeight, Uom, ScalePartCode, StatusId)
    VALUES (@Term, SYSUTCDATETIME(), 15.6, N'LB', N'TEST3', 1);
END TRY
BEGIN CATCH
    SET @Err = ERROR_NUMBER();
END CATCH
DECLARE @ErrS NVARCHAR(10) = CAST(@Err AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0134] second Pending at one terminal violates the unique index', @Expected = N'2601', @Actual = @ErrS;

DECLARE @Ok BIT = 1;
BEGIN TRY
    INSERT INTO Workorder.ScalePendingPress (TerminalLocationId, ReceivedAt, NetWeight, Uom, ScalePartCode, StatusId)
    VALUES (@Term, SYSUTCDATETIME(), 15.7, N'LB', N'TEST3', 2);
END TRY
BEGIN CATCH
    SET @Ok = 0;
END CATCH
EXEC test.Assert_IsTrue @TestName = N'[0134] a Closed row beside the Pending one is allowed', @Condition = @Ok;
DELETE FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @Term;
GO

EXEC test.EndTestFile;
GO
