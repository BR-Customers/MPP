-- =============================================
-- Migration:   0037_plc_integration_foundation.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-13
-- Description: PLC-integration SQL foundation (spec 2026-07-10 §4).
--              * Location.PlcDeviceType  - 4 UDT device types (fixed seed).
--              * Location.TerminalPlcDevice - 1-to-many thin pointer: terminal ->
--                UDT instance (UdtInstancePath). OPC addressing lives on the UDT
--                instance's params in the tag provider, NOT in this table.
--              * Parts.Item.PlcId - stable per-part PLC/vision recipe integer
--                (validated at run time against the assembly-out FIFO queue).
--              * Audit.LogEntityType += TerminalPlcDevice (Id 57 - next free Id;
--                brief specified 25, but that Id is already Uom, seeded in
--                migration 0004. Highest Id in use as of 0036 is 56
--                (ContainerSerialHistory, migration 0029), so 57 is used here).
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF OBJECT_ID(N'Location.PlcDeviceType') IS NULL
CREATE TABLE Location.PlcDeviceType (
    Id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PlcDeviceType PRIMARY KEY,
    Code         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_PlcDeviceType_Code UNIQUE,
    Name         NVARCHAR(100) NOT NULL,
    Description  NVARCHAR(500) NULL,
    CreatedAt    DATETIME2(3)  NOT NULL CONSTRAINT DF_PlcDeviceType_CreatedAt DEFAULT SYSUTCDATETIME(),
    DeprecatedAt DATETIME2(3)  NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType)
INSERT INTO Location.PlcDeviceType (Code, Name, Description) VALUES
    (N'ScaleStation',           N'Scale Station',            N'OmniServer weight indicator (NET_/TRG_ members)'),
    (N'SerializedMipStation',   N'Serialized MIP Station',   N'Serialized assembly MIP handshake (5G0 - PartSN, container)'),
    (N'NonSerializedMipStation',N'Non-Serialized MIP Station',N'LOT-tracked MIP handshake (5A2 - DataReady, no serial)'),
    (N'TrayInspectionStation',  N'Tray Inspection Station',  N'Tray lock/inspection (disposition/vision/sort variants)');
GO

-- Thin pointer: terminal -> UDT instance. OPC addressing lives on the UDT
-- instance's params in the MPP tag provider, NOT here.
IF OBJECT_ID(N'Location.TerminalPlcDevice') IS NULL
CREATE TABLE Location.TerminalPlcDevice (
    Id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TerminalPlcDevice PRIMARY KEY,
    TerminalLocationId  BIGINT        NOT NULL CONSTRAINT FK_TerminalPlcDevice_Terminal   REFERENCES Location.Location(Id),
    PlcDeviceTypeId     BIGINT        NOT NULL CONSTRAINT FK_TerminalPlcDevice_DeviceType REFERENCES Location.PlcDeviceType(Id),
    DeviceCode          NVARCHAR(100) NOT NULL,
    UdtInstancePath     NVARCHAR(400) NOT NULL,
    SortOrder           INT           NOT NULL CONSTRAINT DF_TerminalPlcDevice_SortOrder DEFAULT 0,
    CreatedAt           DATETIME2(3)  NOT NULL CONSTRAINT DF_TerminalPlcDevice_CreatedAt DEFAULT SYSUTCDATETIME(),
    UpdatedAt           DATETIME2(3)  NULL,
    UpdatedByUserId     BIGINT        NULL CONSTRAINT FK_TerminalPlcDevice_User REFERENCES Location.AppUser(Id),
    DeprecatedAt        DATETIME2(3)  NULL
);
GO

IF OBJECT_ID(N'Location.TerminalPlcDevice') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_TerminalPlcDevice_ActiveDeviceCode')
CREATE UNIQUE INDEX UQ_TerminalPlcDevice_ActiveDeviceCode
    ON Location.TerminalPlcDevice (TerminalLocationId, DeviceCode)
    WHERE DeprecatedAt IS NULL;
GO

IF OBJECT_ID(N'Location.TerminalPlcDevice') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_TerminalPlcDevice_Terminal')
CREATE INDEX IX_TerminalPlcDevice_Terminal
    ON Location.TerminalPlcDevice (TerminalLocationId);
GO

-- Item.PlcId: stable per-part PLC/vision recipe integer. Not globally unique
-- (FIFO fixes the expected part at run time), so no unique index.
IF COL_LENGTH(N'Parts.Item', N'PlcId') IS NULL
    ALTER TABLE Parts.Item ADD PlcId INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'TerminalPlcDevice')
INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
    (57, N'TerminalPlcDevice', N'Terminal PLC Device', N'Terminal-to-PLC-device mapping row');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0037_plc_integration_foundation')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0037_plc_integration_foundation',
        N'PLC integration foundation: PlcDeviceType (+seed), TerminalPlcDevice, Item.PlcId, TerminalPlcDevice audit entity (Id 57).');
GO
