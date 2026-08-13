-- seed_showcase_audit.sql
-- Populates Audit.ConfigLog with realistic config-change history for the showcase
-- (the config was loaded via SQL seeds, which don't write config-audit rows).
-- Idempotent: clears showcase audit rows then re-inserts. ASCII-only (middot via ufn_MidDot).
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;

-- Two named engineers for realistic attribution (idempotent).
IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Initials = N'SLC')
    INSERT INTO Location.AppUser (AdAccount, DisplayName, IgnitionRole, Initials, CreatedAt)
    VALUES (N'RIVERSIDE\schen', N'Sarah Chen', N'Engineer', N'SLC', SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Initials = N'MDT')
    INSERT INTO Location.AppUser (AdAccount, DisplayName, IgnitionRole, Initials, CreatedAt)
    VALUES (N'RIVERSIDE\mtorres', N'Mike Torres', N'Supervisor', N'MDT', SYSUTCDATETIME());

DECLARE @Sarah BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SLC');
DECLARE @Mike  BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'MDT');
DECLARE @Dev   BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Info  BIGINT = (SELECT Id FROM Audit.LogSeverity WHERE Code = N'Info');
DECLARE @Warn  BIGINT = (SELECT Id FROM Audit.LogSeverity WHERE Code = N'Warning');
DECLARE @Created BIGINT = 1, @Updated BIGINT = 2, @Deprecated BIGINT = 3;  -- Audit.LogEventType ids
DECLARE @md NVARCHAR(10) = Audit.ufn_MidDot();
DECLARE @now DATETIME2(3) = SYSUTCDATETIME();

-- Clear prior showcase audit rows so this is re-runnable.
DELETE FROM Audit.ConfigLog;

INSERT INTO Audit.ConfigLog (LoggedAt, UserId, LogSeverityId, LogEventTypeId, LogEntityTypeId, EntityId, Description, OldValue, NewValue)
VALUES
 (DATEADD(DAY,-6,@now), @Sarah, @Info, @Created, 1, NULL,
    N'Riverside Die Casting - Plant 1' + @md + N'Facility' + @md + N'Created',
    NULL, N'{"Name":"Riverside Die Casting - Plant 1","Code":"MPP-MAD"}'),
 (DATEADD(DAY,-6,DATEADD(HOUR,2,@now)), @Sarah, @Info, @Created, 1, NULL,
    N'Machining & Assembly 2' + @md + N'Cell' + @md + N'Created',
    NULL, N'{"Name":"Machining & Assembly 2","Code":"MA2","Parent":{"Code":"MPP-MAD","Name":"Riverside Die Casting - Plant 1"}}'),
 (DATEADD(DAY,-5,@now), @Mike, @Info, @Created, 5, NULL,
    N'Oil Pump Housing Assembly' + @md + N'Item' + @md + N'Created',
    NULL, N'{"PartNumber":"12270-6NA -0001","Description":"Oil Pump Housing Assembly","ItemType":"FinishedGood"}'),
 (DATEADD(DAY,-5,DATEADD(HOUR,3,@now)), @Mike, @Info, @Updated, 18, NULL,
    N'Oil Pump Housing Assembly' + @md + N'Container Config' + @md + N'Serialized set ~ true',
    N'{"IsSerialized":false}', N'{"IsSerialized":true,"ClosureMethod":"ByVision"}'),
 (DATEADD(DAY,-4,@now), @Sarah, @Info, @Updated, 7, NULL,
    N'Oil Pump Housing - Raw Casting' + @md + N'Route' + @md + N'Published v1',
    N'{"PublishedAt":null,"VersionNumber":1}', N'{"PublishedAt":"2026-08-08","VersionNumber":1}'),
 (DATEADD(DAY,-4,DATEADD(HOUR,1,@now)), @Sarah, @Info, @Updated, 8, NULL,
    N'Machining Out' + @md + N'Operation Template' + @md + N'Published v1',
    N'{"PublishedAt":null}', N'{"PublishedAt":"2026-08-08","VersionNumber":1}'),
 (DATEADD(DAY,-3,@now), @Mike, @Info, @Created, 12, NULL,
    N'Oil Pump Housing - Machined' + @md + N'Quality Spec' + @md + N'Created',
    NULL, N'{"Name":"Dimensional - Bore Diameter","AttributeCount":4}'),
 (DATEADD(DAY,-3,DATEADD(HOUR,4,@now)), @Dev, @Info, @Updated, 14, NULL,
    N'Porosity' + @md + N'Defect Code' + @md + N'Updated',
    N'{"Description":"Porosity"}', N'{"Description":"Porosity - surface","Severity":"Major"}'),
 (DATEADD(DAY,-2,@now), @Mike, @Warn, @Deprecated, 1, NULL,
    N'Trim Shop 1 - Legacy Printer' + @md + N'Printer' + @md + N'Deprecated',
    N'{"DeprecatedAt":null}', N'{"DeprecatedAt":"2026-08-10","Reason":"Replaced by Zebra ZT411"}'),
 (DATEADD(DAY,-1,@now), @Sarah, @Info, @Updated, 5, NULL,
    N'Front Cover - Finished Good' + @md + N'Item' + @md + N'Unit weight ~ 0.84 kg',
    N'{"UnitWeight":null}', N'{"UnitWeight":0.84,"WeightUom":"kg"}'),
 (DATEADD(HOUR,-6,@now), @Mike, @Info, @Updated, 7, NULL,
    N'Front Cover - Casting' + @md + N'Route' + @md + N'Published v2',
    N'{"VersionNumber":1}', N'{"VersionNumber":2,"PublishedAt":"2026-08-12"}');

DECLARE @n INT = (SELECT COUNT(*) FROM Audit.ConfigLog);
PRINT N'seed_showcase_audit: ' + CAST(@n AS NVARCHAR(5)) + N' config-audit rows.';
GO
