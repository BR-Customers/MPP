-- =============================================
-- File:        0109_ControlledRun/010_schema.sql
-- Author:      Blue Ridge Automation
-- Description: Migration 0109 landed: tables, constraints, seeds.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/010_schema.sql';
GO
DECLARE @n NVARCHAR(10);

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
          WHERE s.name = N'Quality' AND t.name IN (N'ControlledRun', N'ControlledRunMember', N'ControlledRunLabel',
              N'ControlledRunStatusCode', N'ControlledRunJoinMethod', N'ControlledRunMemberEndReason'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] six tables exist', @Expected = N'6', @Actual = @n;

SET @n = (SELECT CAST(max_length / 2 AS NVARCHAR(10)) FROM sys.columns
          WHERE object_id = OBJECT_ID(N'Quality.ControlledRun') AND name = N'RunNumber');
EXEC test.Assert_IsEqual @TestName = N'[Schema] RunNumber is NVARCHAR(15)', @Expected = N'15', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunStatusCode WHERE Code IN (N'Open', N'Closed', N'Cancelled'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] 3 status codes', @Expected = N'3', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunJoinMethod WHERE Code IN (N'Selected', N'Manual', N'AutoJoined', N'Descendant'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] 4 join methods', @Expected = N'4', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunMemberEndReason WHERE Code IN (N'Removed', N'RunClosed', N'RunCancelled'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] 3 end reasons', @Expected = N'3', @Actual = @n;

SET @n = (SELECT FormatString FROM Lots.IdentifierSequence WHERE Code = N'ControlledRun');
EXEC test.Assert_IsEqual @TestName = N'[Schema] sequence format', @Expected = N'CR{0:D6}', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LabelTemplate t JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
          WHERE c.Code = N'ControlledRun' AND t.DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Schema] one active ControlledRun label template', @Expected = N'1', @Actual = @n;

-- ASCII-only template (sqlcmd codepage rule)
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LabelTemplate t JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
          WHERE c.Code = N'ControlledRun' AND t.ZplBody LIKE N'%[^ -~]%' COLLATE Latin1_General_BIN2);
EXEC test.Assert_IsEqual @TestName = N'[Schema] label template is ASCII-only', @Expected = N'0', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEventType WHERE Code LIKE N'ControlledRun%');
EXEC test.Assert_IsEqual @TestName = N'[Schema] 7 audit event codes', @Expected = N'7', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEntityType WHERE Code = N'ControlledRun');
EXEC test.Assert_IsEqual @TestName = N'[Schema] audit entity type', @Expected = N'1', @Actual = @n;

-- XOR check: a member row with both ids is refused
DECLARE @App BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId) VALUES (N'CRTEST1', 1, N'schema test', @App);
DECLARE @Run BIGINT = SCOPE_IDENTITY();
DECLARE @err NVARCHAR(10) = N'0';
BEGIN TRY
    INSERT INTO Quality.ControlledRunMember (ControlledRunId, LotId, ContainerId, ControlledRunJoinMethodId, CrtSetByRun, AddedByUserId)
    VALUES (@Run, NULL, NULL, 1, 0, @App);
END TRY BEGIN CATCH SET @err = N'1'; END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] member with neither LotId nor ContainerId refused', @Expected = N'1', @Actual = @err;

-- auto-join without a part is refused
SET @err = N'0';
BEGIN TRY
    INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId, AutoJoinEnabled) VALUES (N'CRTEST2', 1, N'x', @App, 1);
END TRY BEGIN CATCH SET @err = N'1'; END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] AutoJoinEnabled without SelectionItemId refused', @Expected = N'1', @Actual = @err;

DELETE FROM Quality.ControlledRun WHERE RunNumber LIKE N'CRTEST%';
GO
EXEC test.EndTestFile;
GO
