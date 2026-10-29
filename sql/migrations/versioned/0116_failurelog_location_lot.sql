-- ============================================================
-- Migration:   0116_failurelog_location_lot.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Description: Audit.FailureLog += LocationId / LotId, and the AIM failure
--              event types AimPostFailed / AimSerialFetchFailed.
--
--   WHY. MPP asked (2026-09-16) for every AIM integration failure to land in
--   the Failure Log with its Location, its LOT and the metadata. FailureLog had
--   only a generic EntityType + EntityId, so "every AIM failure at this cell"
--   and "every failure for this LOT" could not be filtered or shown by name.
--   Both columns are nullable: most existing writers (Config Tool mutations)
--   have neither. Existing rows stay NULL (no backfill).
--
--   FailureLog is born-partitioned on ps_MonthlyUtc(AttemptedAt) since 0020
--   (PK (Id, AttemptedAt), clustered on AttemptedAt). Adding nullable columns
--   is metadata-only; both new indexes are partition-ALIGNED so the sliding-
--   window TRUNCATE keeps working. FKs point OUT of the audit table, which
--   does not block partition truncation (the 0113 InterfaceLog pattern).
--
--   Apply with Audit_LogFailure v1.1, Audit.FailureLog_Record v1.0,
--   Audit.InterfaceLog_Record v1.0, FailureLog_List v3.1,
--   FailureLog_GetByEntity v2.1, Lots.AimShipperIdPool_GetForPost (LocationId,
--   LotId). ASCII only.
--
--   Spec: docs/superpowers/specs/2026-10-29-aim-failure-log-design.md
-- ============================================================
IF COL_LENGTH(N'Audit.FailureLog', N'LocationId') IS NULL
    ALTER TABLE Audit.FailureLog ADD
        LocationId BIGINT NULL CONSTRAINT FK_FailureLog_Location REFERENCES Location.Location(Id),
        LotId      BIGINT NULL CONSTRAINT FK_FailureLog_Lot      REFERENCES Lots.Lot(Id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.FailureLog')
               AND name = N'IX_FailureLog_Location_AttemptedAt')
    CREATE INDEX IX_FailureLog_Location_AttemptedAt
        ON Audit.FailureLog (LocationId, AttemptedAt DESC)
        WHERE LocationId IS NOT NULL
        ON ps_MonthlyUtc(AttemptedAt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.FailureLog')
               AND name = N'IX_FailureLog_Lot_AttemptedAt')
    CREATE INDEX IX_FailureLog_Lot_AttemptedAt
        ON Audit.FailureLog (LotId, AttemptedAt DESC)
        WHERE LotId IS NOT NULL
        ON ps_MonthlyUtc(AttemptedAt);
GO

-- AIM failure event types (next free Id; guarded).
-- Audit.LogEventType.Id is a plain PK (NOT identity) -- insert the Id directly
-- (the 0041 / 0113 pattern).
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'AimPostFailed')
BEGIN
    DECLARE @PId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@PId, N'AimPostFailed', N'AIM Post Failed',
            N'An attempt to post a container serial to AIM failed (refused, unreachable, bad reply, not configured, incomplete payload, or an exception).');
END
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'AimSerialFetchFailed')
BEGIN
    DECLARE @FId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@FId, N'AimSerialFetchFailed', N'AIM Serial Fetch Failed',
            N'An attempt to fetch a new serial from AIM for the shipper ID pool failed.');
END
GO

IF COL_LENGTH(N'Audit.FailureLog', N'LotId') IS NULL
   OR NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'AimSerialFetchFailed')
    THROW 51000, 'Migration 0116: FailureLog context columns or AIM event types did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0116_failurelog_location_lot')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0116_failurelog_location_lot',
            N'Audit.FailureLog += LocationId/LotId (partition-aligned indexes); event types AimPostFailed/AimSerialFetchFailed. Apply with Audit_LogFailure v1.1 + FailureLog_Record.');
GO
PRINT 'Migration 0116 (failurelog_location_lot) applied.';
GO
