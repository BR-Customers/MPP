-- =============================================
-- Migration: 0041_closure_terminal_and_plc_capability.sql
-- Date: 2026-07-17
-- Desc: (1) Location.PlcDeviceType.ClosureMethodCode (device-type -> closure
--           method map): ScaleStation->ByWeight, TrayInspectionStation->ByVision,
--           MIP types NULL.
--       (2) Terminal LTD-7 attribute defs: CurrentClosureMethod, VisionAppUrl.
--       (3) Quality.HoldTypeCode 'Changeover' (freeze an open container on a
--           closure-mode changeover).
--       (4) Audit.LogEventType 'ClosureModeChanged' for the changeover proc.
--       Idempotent-guarded; repo convention (no explicit outer transaction).
-- =============================================

-- (1) device-type -> method map -----------------------------------------------
IF COL_LENGTH(N'Location.PlcDeviceType', N'ClosureMethodCode') IS NULL
    ALTER TABLE Location.PlcDeviceType ADD ClosureMethodCode NVARCHAR(20) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_PlcDeviceType_ClosureMethod')
    ALTER TABLE Location.PlcDeviceType
        ADD CONSTRAINT FK_PlcDeviceType_ClosureMethod
        FOREIGN KEY (ClosureMethodCode) REFERENCES Parts.ClosureMethodCode(Code);
GO
UPDATE Location.PlcDeviceType SET ClosureMethodCode = N'ByWeight' WHERE Code = N'ScaleStation'          AND ClosureMethodCode IS NULL;
UPDATE Location.PlcDeviceType SET ClosureMethodCode = N'ByVision' WHERE Code = N'TrayInspectionStation' AND ClosureMethodCode IS NULL;
GO

-- (2) terminal attribute definitions (LTD 7) ----------------------------------
-- Mirror the DefaultScreen seed shape (0020); SortOrder continues after existing.
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
               WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CurrentClosureMethod' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'CurrentClosureMethod', N'NVARCHAR', 0, NULL, NULL,
         (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
         N'Assembly-out terminal active closure mode (ByCount/ByWeight/ByVision); set at changeover.');
GO
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
               WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppUrl' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'VisionAppUrl', N'NVARCHAR', 0, NULL, NULL,
         (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
         N'External vision web-app URL embedded in the ByVision assembly appearance.');
GO

-- (3) Changeover hold type (next free Id; guarded) ----------------------------
IF NOT EXISTS (SELECT 1 FROM Quality.HoldTypeCode WHERE Code = N'Changeover')
BEGIN
    DECLARE @HId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Quality.HoldTypeCode);
    SET IDENTITY_INSERT Quality.HoldTypeCode ON;
    INSERT INTO Quality.HoldTypeCode (Id, Code, Name) VALUES (@HId, N'Changeover', N'Changeover Freeze');
    SET IDENTITY_INSERT Quality.HoldTypeCode OFF;
END
GO

-- (4) ClosureModeChanged audit event type (next free Id; guarded) --------------
-- Audit.LogEventType.Id is a plain PK (NOT identity) -- insert the Id directly.
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ClosureModeChanged')
BEGIN
    DECLARE @EId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@EId, N'ClosureModeChanged', N'Closure Mode Changed',
            N'An assembly-out terminal closure mode was changed at a changeover.');
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0041_closure_terminal_and_plc_capability')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0041_closure_terminal_and_plc_capability',
        N'PlcDeviceType.ClosureMethodCode map; Terminal CurrentClosureMethod/VisionAppUrl attrs; Changeover HoldTypeCode; ClosureModeChanged LogEventType.');
GO
