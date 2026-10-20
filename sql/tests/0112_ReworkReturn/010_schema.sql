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
SET @n = (SELECT CONCAT(i.is_unique, N'|', i.has_filter, N'|', i.filter_definition) FROM sys.indexes i
          WHERE i.object_id = OBJECT_ID(N'Lots.VendorReturn') AND i.name = N'UQ_VendorReturn_Result');
EXEC test.Assert_IsEqual @TestName = N'[Schema] UQ_VendorReturn_Result is a filtered unique index on non-null result links', @Expected = N'1|1|([ControlledRunResultId] IS NOT NULL)', @Actual = @n;

-- ---- LotRework: the movement and the approver are required (spec 4.3) ----
SET @n = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY c.name) FROM sys.columns c
          WHERE c.object_id = OBJECT_ID(N'Lots.LotRework') AND c.name IN (N'LotMovementId', N'ApprovedByUserId') AND c.is_nullable = 0), N'');
EXEC test.Assert_IsEqual @TestName = N'[Schema] LotRework.LotMovementId and ApprovedByUserId are NOT NULL', @Expected = N'ApprovedByUserId,LotMovementId', @Actual = @n;

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

-- a second return linked to the same super-lot result is refused by UQ_VendorReturn_Result
-- (ufn_ControlledRunMemberResults LEFT JOINs on the link; a duplicate would double AppliedReturnQty)
INSERT INTO Lots.VendorReturn (LotId, Quantity, PieceCountTaken, InventoryTaken, MarkedByUserId, ControlledRunResultId) VALUES (1, 5, 5, 5, 1, 1);
SET @msg = N'not caught';
BEGIN TRY
    INSERT INTO Lots.VendorReturn (LotId, Quantity, PieceCountTaken, InventoryTaken, MarkedByUserId, ControlledRunResultId) VALUES (1, 3, 3, 3, 1, 1);
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
SET @n = CASE WHEN @msg LIKE N'%UQ_VendorReturn_Result%' THEN N'refused' ELSE @msg END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] two returns on one super-lot result are refused by UQ_VendorReturn_Result', @Expected = N'refused', @Actual = @n;
-- unlinked returns (NULL result) are not constrained
SET @msg = N'ok';
BEGIN TRY
    INSERT INTO Lots.VendorReturn (LotId, Quantity, PieceCountTaken, InventoryTaken, MarkedByUserId) VALUES (1, 2, 2, 2, 1);
    INSERT INTO Lots.VendorReturn (LotId, Quantity, PieceCountTaken, InventoryTaken, MarkedByUserId) VALUES (1, 2, 2, 2, 1);
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] several unlinked returns (NULL result) are allowed', @Expected = N'ok', @Actual = @msg;
DELETE FROM Lots.VendorReturn WHERE LotId = 1 AND MarkedByUserId = 1 AND Quantity IN (2, 5);

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
