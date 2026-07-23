-- =============================================
-- File:         01_audit_infrastructure/060_OperatorChange_Log.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-23
-- Description:  Tests for Audit.OperatorChange_Log (terminal operator handoff audit).
--   Covers: (a) normal handoff A->B writes one OperationLog row (AppUser entity,
--   OperatorChanged event, EntityId+UserId = new operator, resolved-name Old/New JSON,
--   'Terminal * Operator * Changed A -> B' description); (b) first bind (old NULL) ->
--   null OldValue + 'Signed in' description; (c) same-operator re-scan -> no row, Status 1;
--   (d) unknown new operator -> Status 0 reject; (e) NULL terminal -> 'Terminal' literal.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'01_audit_infrastructure/060_OperatorChange_Log.sql';
GO

-- ---- fixture: two operator AppUsers + a real terminal ----
-- operators sign in by initials with no AD account (CK_AppUser_IgnitionRole_Requires_AdAccount:
-- an IgnitionRole requires an AdAccount, so an initials-only operator leaves both NULL).
IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Initials = N'ZZA')
    INSERT INTO Location.AppUser (DisplayName, Initials, CreatedAt) VALUES (N'Op Alpha', N'ZZA', SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Initials = N'ZZB')
    INSERT INTO Location.AppUser (DisplayName, Initials, CreatedAt) VALUES (N'Op Beta', N'ZZB', SYSUTCDATETIME());
GO

-- =============================================
-- Test (a): normal handoff A -> B
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'ZZA');
DECLARE @B BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'ZZB');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @TermCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @Term);
DECLARE @Base INT = (SELECT COUNT(*) FROM Audit.OperationLog);

DECLARE @Ra TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Ra EXEC Audit.OperatorChange_Log @OldAppUserId = @A, @NewAppUserId = @B, @TerminalLocationId = @Term, @AppUserId = @B;

DECLARE @Sa NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Ra);
EXEC test.Assert_IsEqual @TestName = N'[OpChg] handoff Status 1', @Expected = N'1', @Actual = @Sa;

DECLARE @Added INT = (SELECT COUNT(*) FROM Audit.OperationLog) - @Base;
DECLARE @AddedStr NVARCHAR(10) = CAST(@Added AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpChg] handoff writes exactly one OperationLog row', @Expected = N'1', @Actual = @AddedStr;

-- inspect the row
DECLARE @Ev NVARCHAR(50), @Ent NVARCHAR(50), @Eid BIGINT, @Uid BIGINT, @Desc NVARCHAR(1000), @Old NVARCHAR(MAX), @New NVARCHAR(MAX);
SELECT TOP 1 @Ev = et.Code, @Ent = ent.Code, @Eid = ol.EntityId, @Uid = ol.UserId, @Desc = ol.Description, @Old = ol.OldValue, @New = ol.NewValue
FROM Audit.OperationLog ol
JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
JOIN Audit.LogEntityType ent ON ent.Id = ol.LogEntityTypeId
WHERE ol.LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'OperatorChanged')
ORDER BY ol.Id DESC;

EXEC test.Assert_IsEqual @TestName = N'[OpChg] event type OperatorChanged', @Expected = N'OperatorChanged', @Actual = @Ev;
EXEC test.Assert_IsEqual @TestName = N'[OpChg] entity type AppUser', @Expected = N'AppUser', @Actual = @Ent;
DECLARE @EidStr NVARCHAR(20) = CAST(@Eid AS NVARCHAR(20)); DECLARE @BStr NVARCHAR(20) = CAST(@B AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[OpChg] EntityId = new operator', @Expected = @BStr, @Actual = @EidStr;
DECLARE @UidStr NVARCHAR(20) = CAST(@Uid AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[OpChg] UserId attribution = new operator', @Expected = @BStr, @Actual = @UidStr;
EXEC test.Assert_Contains @TestName = N'[OpChg] description cites the terminal code', @HaystackStr = @Desc, @NeedleStr = @TermCode;
EXEC test.Assert_Contains @TestName = N'[OpChg] description says Changed', @HaystackStr = @Desc, @NeedleStr = N'Changed';
EXEC test.Assert_Contains @TestName = N'[OpChg] description has old initials ZZA', @HaystackStr = @Desc, @NeedleStr = N'ZZA';
EXEC test.Assert_Contains @TestName = N'[OpChg] description has new initials ZZB', @HaystackStr = @Desc, @NeedleStr = N'ZZB';
EXEC test.Assert_Contains @TestName = N'[OpChg] OldValue JSON resolves old name', @HaystackStr = @Old, @NeedleStr = N'Op Alpha';
EXEC test.Assert_Contains @TestName = N'[OpChg] NewValue JSON resolves new name', @HaystackStr = @New, @NeedleStr = N'Op Beta';
GO

-- =============================================
-- Test (b): first bind (old NULL) -> 'Signed in', null OldValue
-- =============================================
DECLARE @B BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'ZZB');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @Rb TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Rb EXEC Audit.OperatorChange_Log @OldAppUserId = NULL, @NewAppUserId = @B, @TerminalLocationId = @Term, @AppUserId = @B;
DECLARE @Sb NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Rb);
EXEC test.Assert_IsEqual @TestName = N'[OpChg] first-bind Status 1', @Expected = N'1', @Actual = @Sb;
DECLARE @DescB NVARCHAR(1000), @OldB NVARCHAR(MAX);
SELECT TOP 1 @DescB = Description, @OldB = OldValue FROM Audit.OperationLog
WHERE LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'OperatorChanged') ORDER BY Id DESC;
EXEC test.Assert_Contains @TestName = N'[OpChg] first-bind says Signed in', @HaystackStr = @DescB, @NeedleStr = N'Signed in';
DECLARE @OldBStr NVARCHAR(10) = CASE WHEN @OldB IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpChg] first-bind OldValue is NULL', @Expected = N'1', @Actual = @OldBStr;
GO

-- =============================================
-- Test (c): same-operator re-scan -> no row, Status 1, 'No operator change'
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'ZZA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @BaseC INT = (SELECT COUNT(*) FROM Audit.OperationLog);
DECLARE @Rc TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Rc EXEC Audit.OperatorChange_Log @OldAppUserId = @A, @NewAppUserId = @A, @TerminalLocationId = @Term, @AppUserId = @A;
DECLARE @Sc NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Rc);
DECLARE @Mc NVARCHAR(500) = (SELECT Message FROM @Rc);
EXEC test.Assert_IsEqual @TestName = N'[OpChg] same-operator Status 1 (no-op)', @Expected = N'1', @Actual = @Sc;
EXEC test.Assert_Contains @TestName = N'[OpChg] same-operator message', @HaystackStr = @Mc, @NeedleStr = N'No operator change';
DECLARE @AddedC NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Audit.OperationLog) - @BaseC AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpChg] same-operator writes NO row', @Expected = N'0', @Actual = @AddedC;
GO

-- =============================================
-- Test (d): unknown new operator -> Status 0 reject, no row
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @BaseD INT = (SELECT COUNT(*) FROM Audit.OperationLog);
DECLARE @Rd TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Rd EXEC Audit.OperatorChange_Log @OldAppUserId = NULL, @NewAppUserId = 99000000, @TerminalLocationId = @Term, @AppUserId = 99000000;
DECLARE @Sd BIT = (SELECT Status FROM @Rd);
DECLARE @SdCond BIT = CASE WHEN @Sd = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[OpChg] unknown new operator rejected (Status 0)', @Condition = @SdCond;
DECLARE @AddedD NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Audit.OperationLog) - @BaseD AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpChg] unknown new operator writes NO row', @Expected = N'0', @Actual = @AddedD;
GO

-- =============================================
-- Test (e): NULL terminal (fallback) -> 'Terminal' literal in description
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'ZZA');
DECLARE @B BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'ZZB');
DECLARE @Re TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Re EXEC Audit.OperatorChange_Log @OldAppUserId = @A, @NewAppUserId = @B, @TerminalLocationId = NULL, @AppUserId = @B;
DECLARE @DescE NVARCHAR(1000);
SELECT TOP 1 @DescE = Description FROM Audit.OperationLog
WHERE LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'OperatorChanged') ORDER BY Id DESC;
EXEC test.Assert_Contains @TestName = N'[OpChg] NULL terminal uses Terminal literal', @HaystackStr = @DescE, @NeedleStr = N'Terminal';
GO

EXEC test.EndTestFile;
GO
