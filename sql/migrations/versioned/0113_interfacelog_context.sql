-- ============================================================
-- Migration:   0113_interfacelog_context.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Description: Audit.InterfaceLog += LocationId / ItemId / LotId, and the
--              ScaleRunningItemId terminal attribute definition.
--
--   WHY. Every integration call (a scale press, a label print) already
--   writes one InterfaceLog row, but the only handle on WHERE it happened
--   was SystemName -- a tag-instance name that resolves to a terminal only
--   through a mapping that changes -- and the part and the production record
--   it produced were free text in the payload. So a refused press could not
--   be tied to a terminal, a part or a shift. The three nullable columns make
--   the row joinable; shift derives from LocationId + LoggedAt
--   (Oee.ufn_ShiftIdForInstant). Existing rows stay NULL (no backfill).
--
--   InterfaceLog is born partitioned on ps_MonthlyUtc (B2). Adding nullable
--   columns is metadata-only; the new index is partition-ALIGNED so the
--   sliding-window TRUNCATE keeps working. FKs point OUT of the audit table,
--   which does not block partition truncation.
--
--   ScaleRunningItemId: the per-terminal running-part override for a By
--   Weight scale station (Location.Terminal_SetScaleRunningPart), stored like
--   CurrentClosureMethod (migration 0041), and its audit event type
--   ScaleRunningPartChanged. ASCII only.
--
--   Spec: docs/superpowers/specs/2026-10-19-assembly-out-scale-station-design.md
-- ============================================================
IF COL_LENGTH(N'Audit.InterfaceLog', N'LocationId') IS NULL
    ALTER TABLE Audit.InterfaceLog ADD
        LocationId BIGINT NULL CONSTRAINT FK_InterfaceLog_Location REFERENCES Location.Location(Id),
        ItemId     BIGINT NULL CONSTRAINT FK_InterfaceLog_Item     REFERENCES Parts.Item(Id),
        LotId      BIGINT NULL CONSTRAINT FK_InterfaceLog_Lot      REFERENCES Lots.Lot(Id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.InterfaceLog')
               AND name = N'IX_InterfaceLog_Location_LoggedAt')
    CREATE INDEX IX_InterfaceLog_Location_LoggedAt
        ON Audit.InterfaceLog (LocationId, LoggedAt DESC)
        WHERE LocationId IS NOT NULL
        ON ps_MonthlyUtc(LoggedAt);
GO

IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
               WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'ScaleRunningItemId' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'ScaleRunningItemId', N'NVARCHAR', 0, NULL, NULL,
         (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
         N'By Weight scale station running-part override (Parts.Item.Id). Set by Location.Terminal_SetScaleRunningPart; empty = default part.');
GO

-- ScaleRunningPartChanged audit event type (next free Id; guarded).
-- Audit.LogEventType.Id is a plain PK (NOT identity) -- insert the Id directly
-- (the 0041 ClosureModeChanged pattern).
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ScaleRunningPartChanged')
BEGIN
    DECLARE @EId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@EId, N'ScaleRunningPartChanged', N'Scale Running Part Changed',
            N'A By Weight scale station''s running-part override was set or cleared (Location.Terminal_SetScaleRunningPart).');
END
GO

IF COL_LENGTH(N'Audit.InterfaceLog', N'LotId') IS NULL
    THROW 51000, 'Migration 0113: InterfaceLog context columns did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0113_interfacelog_context')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0113_interfacelog_context',
            N'Audit.InterfaceLog += LocationId/ItemId/LotId (partition-aligned index); terminal attribute ScaleRunningItemId. Apply with Audit_LogInterfaceCall v1.1.');
GO
PRINT 'Migration 0113 (interfacelog_context) applied.';
GO
