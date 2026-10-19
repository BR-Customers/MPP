-- =============================================
-- File:        0112_ReworkReturn/010_schema.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5 -- schema for trim rework + return to vendor:
--              Lots.LotRework, Lots.VendorReturn, and the five audit event codes.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/010_schema.sql';
GO

DECLARE @n NVARCHAR(MAX);

-- ---- tables exist ----
SET @n = CASE WHEN OBJECT_ID(N'Lots.LotRework', N'U') IS NOT NULL THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Lots.LotRework exists', @Expected = N'yes', @Actual = @n;
SET @n = CASE WHEN OBJECT_ID(N'Lots.VendorReturn', N'U') IS NOT NULL THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Lots.VendorReturn exists', @Expected = N'yes', @Actual = @n;

-- ---- LotRework columns ----
DECLARE @want TABLE (Tbl NVARCHAR(128), Col NVARCHAR(128));
INSERT INTO @want (Tbl, Col) VALUES
    (N'LotRework', N'Id'), (N'LotRework', N'LotId'), (N'LotRework', N'ReEntrySequenceNumber'),
    (N'LotRework', N'LotMovementId'), (N'LotRework', N'StartedAt'), (N'LotRework', N'MovedByUserId'),
    (N'LotRework', N'ApprovedByUserId'), (N'LotRework', N'TerminalLocationId'), (N'LotRework', N'CompletedAt'),
    (N'LotRework', N'CompletedProductionEventId'),
    (N'VendorReturn', N'Id'), (N'VendorReturn', N'LotId'), (N'VendorReturn', N'Quantity'),
    (N'VendorReturn', N'PieceCountTaken'), (N'VendorReturn', N'InventoryTaken'), (N'VendorReturn', N'Remarks'),
    (N'VendorReturn', N'ControlledRunResultId'), (N'VendorReturn', N'MarkedByUserId'), (N'VendorReturn', N'MarkedAt'),
    (N'VendorReturn', N'TerminalLocationId'), (N'VendorReturn', N'ConfirmedAt'), (N'VendorReturn', N'ConfirmedByUserId'),
    (N'VendorReturn', N'CancelledAt'), (N'VendorReturn', N'CancelledByUserId'), (N'VendorReturn', N'CancelRemarks');
SET @n = ISNULL((SELECT STRING_AGG(w.Col, N',') FROM @want w
          WHERE w.Tbl = N'LotRework' AND COL_LENGTH(N'Lots.LotRework', w.Col) IS NULL), N'');
EXEC test.Assert_IsEqual @TestName = N'[Schema] LotRework has every column (missing: none)', @Expected = N'', @Actual = @n;
SET @n = ISNULL((SELECT STRING_AGG(w.Col, N',') FROM @want w
          WHERE w.Tbl = N'VendorReturn' AND COL_LENGTH(N'Lots.VendorReturn', w.Col) IS NULL), N'');
EXEC test.Assert_IsEqual @TestName = N'[Schema] VendorReturn has every column (missing: none)', @Expected = N'', @Actual = @n;

-- ---- filtered unique index ----
SET @n = (SELECT CONCAT(i.is_unique, N'|', i.has_filter) FROM sys.indexes i
          WHERE i.object_id = OBJECT_ID(N'Lots.LotRework') AND i.name = N'UQ_LotRework_OpenPerLot');
EXEC test.Assert_IsEqual @TestName = N'[Schema] UQ_LotRework_OpenPerLot is a filtered unique index', @Expected = N'1|1', @Actual = @n;

-- ---- VendorReturn OneEnd check: a row both confirmed and cancelled is refused by CK_VendorReturn_OneEnd ----
-- FKs are disabled for the probe so the CHECK is the only thing that can fire; the table is empty so they re-enable cleanly.
DECLARE @sql NVARCHAR(MAX) = (SELECT STRING_AGG(N'ALTER TABLE Lots.VendorReturn NOCHECK CONSTRAINT ' + QUOTENAME(f.name) + N';', N' ')
                              FROM sys.foreign_keys f WHERE f.parent_object_id = OBJECT_ID(N'Lots.VendorReturn'));
EXEC sys.sp_executesql @sql;
DECLARE @msg NVARCHAR(2000) = N'not caught';
BEGIN TRY
    INSERT INTO Lots.VendorReturn (LotId, Quantity, PieceCountTaken, InventoryTaken, MarkedByUserId, ConfirmedAt, ConfirmedByUserId, CancelledAt, CancelledByUserId)
    VALUES (1, 5, 5, 5, 1, SYSUTCDATETIME(), 1, SYSUTCDATETIME(), 1);
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
SET @n = CASE WHEN @msg LIKE N'%CK_VendorReturn_OneEnd%' THEN N'refused' ELSE @msg END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] confirmed AND cancelled is refused by CK_VendorReturn_OneEnd', @Expected = N'refused', @Actual = @n;

-- a non-positive quantity is refused
SET @msg = N'not caught';
BEGIN TRY
    INSERT INTO Lots.VendorReturn (LotId, Quantity, PieceCountTaken, InventoryTaken, MarkedByUserId) VALUES (1, 0, 0, 0, 1);
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
SET @n = CASE WHEN @msg LIKE N'%CK_VendorReturn_Quantity%' THEN N'refused' ELSE @msg END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Quantity 0 is refused by CK_VendorReturn_Quantity', @Expected = N'refused', @Actual = @n;

SET @sql = (SELECT STRING_AGG(N'ALTER TABLE Lots.VendorReturn WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(f.name) + N';', N' ')
            FROM sys.foreign_keys f WHERE f.parent_object_id = OBJECT_ID(N'Lots.VendorReturn'));
EXEC sys.sp_executesql @sql;
SET @n = CAST((SELECT COUNT(*) FROM Lots.VendorReturn) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Schema] the probe left no VendorReturn row behind', @Expected = N'0', @Actual = @n;

-- ---- audit event codes ----
SET @n = CAST((SELECT COUNT(*) FROM Audit.LogEventType
               WHERE Code IN (N'LotReworkStarted', N'LotReworkCompleted', N'VendorReturnMarked', N'VendorReturnConfirmed', N'VendorReturnCancelled')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Schema] the five LogEventType codes exist', @Expected = N'5', @Actual = @n;
GO

EXEC test.EndTestFile;
GO
