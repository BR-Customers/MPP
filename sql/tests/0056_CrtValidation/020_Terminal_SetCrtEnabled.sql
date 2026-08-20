-- =============================================
-- File: 0056_CrtValidation/020_Terminal_SetCrtEnabled.sql
-- Desc: Location.Terminal_SetCrtEnabled - upsert the CrtEnabled attribute, audited.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/020_Terminal_SetCrtEnabled.sql';
GO

DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Base INT = (SELECT COUNT(*) FROM Audit.ConfigLog);

DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] enable returns Status 1',
    @Expected = N'1', @Actual = @S1;

DECLARE @V1 NVARCHAR(20) = (SELECT la.AttributeValue FROM Location.LocationAttribute la
    JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
    WHERE la.LocationId = @Term AND ad.AttributeName = N'CrtEnabled');
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] attribute value is 1', @Expected = N'1', @Actual = @V1;

DECLARE @Audited NVARCHAR(10) = CASE WHEN (SELECT COUNT(*) FROM Audit.ConfigLog) > @Base THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] writes a ConfigLog row', @Expected = N'1', @Actual = @Audited;

DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
DECLARE @V2 NVARCHAR(20) = (SELECT la.AttributeValue FROM Location.LocationAttribute la
    JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
    WHERE la.LocationId = @Term AND ad.AttributeName = N'CrtEnabled');
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] disable flips it back to 0', @Expected = N'0', @Actual = @V2;

DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R3 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = 999999999, @Enabled = 1, @AppUserId = 1;
DECLARE @S3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R3);
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] unknown terminal rejected, Status 0',
    @Expected = N'0', @Actual = @S3;
GO

EXEC test.EndTestFile;
