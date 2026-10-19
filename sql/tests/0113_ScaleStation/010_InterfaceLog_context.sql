-- =============================================
-- File:         0113_ScaleStation/010_InterfaceLog_context.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-19
-- Description:
--   Migration 0113: Audit.InterfaceLog carries LocationId / ItemId / LotId so
--   an integration call can be tied to a terminal, a part and the production
--   record it produced (shift derives from LocationId + LoggedAt). Also the
--   ScaleRunningItemId terminal attribute definition.
--   Spec: docs/superpowers/specs/2026-10-19-assembly-out-scale-station-design.md §3
-- =============================================

EXEC test.BeginTestFile @FileName = N'0113_ScaleStation/010_InterfaceLog_context.sql';
GO

DECLARE @Loc BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Lot BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
DECLARE @Before BIGINT = ISNULL((SELECT MAX(Id) FROM Audit.InterfaceLog), 0);

EXEC Audit.Audit_LogInterfaceCall @SystemName = N'TEST:IfCtx', @Direction = N'Inbound',
    @LogEventTypeCode = N'PlcHandshake', @Description = N'ctx set',
    @LocationId = @Loc, @ItemId = @Item, @LotId = @Lot, @IsHighFidelity = 1;
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'TEST:IfCtx', @Direction = N'Inbound',
    @LogEventTypeCode = N'PlcHandshake', @Description = N'ctx none', @IsHighFidelity = 1;

DECLARE @Got NVARCHAR(100) = (SELECT CONCAT(LocationId, N'/', ItemId, N'/', LotId) FROM Audit.InterfaceLog
                             WHERE Id > @Before AND SystemName = N'TEST:IfCtx' AND Description = N'ctx set');
DECLARE @Exp NVARCHAR(100) = CONCAT(@Loc, N'/', @Item, N'/', @Lot);
EXEC test.Assert_IsEqual @TestName = N'[IfLog] context columns written', @Expected = @Exp, @Actual = @Got;

DECLARE @Nulls NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.InterfaceLog
                               WHERE Id > @Before AND SystemName = N'TEST:IfCtx' AND Description = N'ctx none'
                                 AND LocationId IS NULL AND ItemId IS NULL AND LotId IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[IfLog] context columns default NULL', @Expected = N'1', @Actual = @Nulls;

DELETE FROM Audit.InterfaceLog WHERE Id > @Before AND SystemName = N'TEST:IfCtx';
GO

DECLARE @Ps NVARCHAR(128) = (SELECT ps.name FROM sys.indexes i
                             JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
                             WHERE i.object_id = OBJECT_ID(N'Audit.InterfaceLog')
                               AND i.name = N'IX_InterfaceLog_Location_LoggedAt');
EXEC test.Assert_IsEqual @TestName = N'[IfLog] index is partition-aligned', @Expected = N'ps_MonthlyUtc', @Actual = @Ps;

DECLARE @Attr NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Location.LocationAttributeDefinition
                              WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'ScaleRunningItemId' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[IfLog] ScaleRunningItemId attribute defined on LTD 7', @Expected = N'1', @Actual = @Attr;
GO

EXEC test.EndTestFile;
GO
