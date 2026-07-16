-- File: 0039_PlcHandshakeAudit/010_seed.sql
-- Asserts migration 0039's PLC handshake LogEventType seeds are present.
EXEC test.BeginTestFile @FileName = N'0039_PlcHandshakeAudit/010_seed.sql';

DECLARE @HasHandshake NVARCHAR(1) =
    CASE WHEN EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'PlcHandshake') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'LogEventType PlcHandshake seeded',
    @Actual = @HasHandshake, @Expected = N'1';

DECLARE @HasLineStop NVARCHAR(1) =
    CASE WHEN EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'PlcLineStop') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'LogEventType PlcLineStop seeded',
    @Actual = @HasLineStop, @Expected = N'1';
