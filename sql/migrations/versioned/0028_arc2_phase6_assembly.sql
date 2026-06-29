-- ============================================================
-- Migration:   0028_arc2_phase6_assembly.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-19
-- Description: Arc 2 Phase 6 (Assembly + MIP + Container Pack). CREATEs the
--              Container family (anchored here, consumed across P6 + P7) plus the
--              AIM Shipper-ID pool tables pulled forward from P7 so P6's
--              Container_Complete can claim atomically (roadmap circular-dep
--              resolution): the pool CREATE ships before its consumer.
--                Tables: Lots.Container, Lots.SerializedPart, Lots.ContainerTray,
--                Lots.ContainerSerial, Lots.ShippingLabel, Lots.AimShipperIdPool,
--                Lots.AimPoolConfig.
--                Existing code tables reused (NOT created): Lots.ContainerStatusCode
--                (Open=1/Complete=2/Shipped=3/Hold=4/Void=5), Lots.LabelTypeCode,
--                Lots.IdentifierSequence ('SerializedItem' present).
--                Audit seeds: LogEntityType 48-54; LogEventType 46-53.
--                Seed: AimPoolConfig single row (CHECK Id=1).
--              Idempotent, GO-separated. ASCII-only audit strings. LogEventType /
--              LogEntityType PKs are NOT identity -> explicit Id insert + IF NOT
--              EXISTS guard. Container.ContainerStatusCodeId defaults to 1 (Open).
-- ============================================================

-- ---- 1. Lots.Container (packaging-unit header) ----
IF OBJECT_ID(N'Lots.Container', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.Container (
        Id                    BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        ItemId                BIGINT       NOT NULL,
        ContainerConfigId     BIGINT       NOT NULL,
        CurrentLocationId     BIGINT       NOT NULL,
        ContainerStatusCodeId BIGINT       NOT NULL CONSTRAINT DF_Container_Status DEFAULT 1,
        OpenedAt              DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        CompletedAt           DATETIME2(3) NULL,
        CreatedByUserId       BIGINT       NOT NULL,
        RowVersion            ROWVERSION,
        CONSTRAINT FK_Container_Item     FOREIGN KEY (ItemId)                REFERENCES Parts.Item(Id),
        CONSTRAINT FK_Container_Config   FOREIGN KEY (ContainerConfigId)     REFERENCES Parts.ContainerConfig(Id),
        CONSTRAINT FK_Container_Location FOREIGN KEY (CurrentLocationId)     REFERENCES Location.Location(Id),
        CONSTRAINT FK_Container_Status   FOREIGN KEY (ContainerStatusCodeId) REFERENCES Lots.ContainerStatusCode(Id),
        CONSTRAINT FK_Container_User     FOREIGN KEY (CreatedByUserId)       REFERENCES Location.AppUser(Id)
    );

    -- OI-35 B8: open containers by location (Open=1).
    CREATE INDEX IX_Container_OpenByLocation
        ON Lots.Container (CurrentLocationId, OpenedAt) WHERE ContainerStatusCodeId = 1;
END
GO

-- ---- 2. Lots.SerializedPart (laser-etched part) ----
IF OBJECT_ID(N'Lots.SerializedPart', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.SerializedPart (
        Id             BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        SerialNumber   NVARCHAR(50) NOT NULL,
        ItemId         BIGINT       NOT NULL,
        ProducingLotId BIGINT       NOT NULL,
        EtchedAt       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        EtchedByUserId BIGINT       NOT NULL,
        CONSTRAINT UQ_SerializedPart_SerialNumber UNIQUE (SerialNumber),
        CONSTRAINT FK_SerializedPart_Item FOREIGN KEY (ItemId)         REFERENCES Parts.Item(Id),
        CONSTRAINT FK_SerializedPart_Lot  FOREIGN KEY (ProducingLotId) REFERENCES Lots.Lot(Id),
        CONSTRAINT FK_SerializedPart_User FOREIGN KEY (EtchedByUserId) REFERENCES Location.AppUser(Id)
    );
    CREATE INDEX IX_SerializedPart_ProducingLot ON Lots.SerializedPart (ProducingLotId);
END
GO

-- ---- 3. Lots.ContainerTray (child of Container) ----
IF OBJECT_ID(N'Lots.ContainerTray', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.ContainerTray (
        Id               BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        ContainerId      BIGINT       NOT NULL,
        TrayPosition     INT          NOT NULL,
        PartsClosedCount INT          NOT NULL DEFAULT 0,
        ClosedAt         DATETIME2(3) NULL,
        ClosedByUserId   BIGINT       NULL,
        ClosureMethod    NVARCHAR(20) NULL,
        CONSTRAINT FK_ContainerTray_Container FOREIGN KEY (ContainerId)    REFERENCES Lots.Container(Id),
        CONSTRAINT FK_ContainerTray_User      FOREIGN KEY (ClosedByUserId) REFERENCES Location.AppUser(Id),
        CONSTRAINT UQ_ContainerTray_Position   UNIQUE (ContainerId, TrayPosition)
    );
END
GO

-- ---- 4. Lots.ContainerSerial (serial -> tray position junction) ----
IF OBJECT_ID(N'Lots.ContainerSerial', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.ContainerSerial (
        Id                        BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        ContainerId               BIGINT       NOT NULL,
        ContainerTrayId           BIGINT       NULL,
        SerializedPartId          BIGINT       NOT NULL,
        TrayPosition              INT          NULL,
        HardwareInterlockBypassed BIT          NOT NULL DEFAULT 0,
        CreatedAt                 DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ContainerSerial_Container FOREIGN KEY (ContainerId)      REFERENCES Lots.Container(Id),
        CONSTRAINT FK_ContainerSerial_Tray      FOREIGN KEY (ContainerTrayId)  REFERENCES Lots.ContainerTray(Id),
        CONSTRAINT FK_ContainerSerial_Serial    FOREIGN KEY (SerializedPartId) REFERENCES Lots.SerializedPart(Id),
        CONSTRAINT UQ_ContainerSerial_Part      UNIQUE (SerializedPartId)
    );
    CREATE INDEX IX_ContainerSerial_Container ON Lots.ContainerSerial (ContainerId);
END
GO

-- ---- 5. Lots.ShippingLabel (print/void/reprint history; C-5) ----
IF OBJECT_ID(N'Lots.ShippingLabel', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.ShippingLabel (
        Id                  BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        ContainerId         BIGINT        NOT NULL,
        AimShipperId        NVARCHAR(50)  NOT NULL,
        LabelTypeCodeId     BIGINT        NOT NULL,
        Initial             BIT           NOT NULL DEFAULT 1,
        PrintReasonCode     NVARCHAR(50)  NULL,
        PrintedByUserId     BIGINT        NULL,
        TerminalLocationId  BIGINT        NULL,
        IsVoid              BIT           NOT NULL DEFAULT 0,
        CreatedAt           DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        PrintedAt           DATETIME2(3)  NULL,
        VoidedAt            DATETIME2(3)  NULL,
        VoidedByUserId      BIGINT        NULL,
        PrintAttempts       INT           NOT NULL DEFAULT 0,
        LastPrintAttemptAt  DATETIME2(3)  NULL,
        LastPrintError      NVARCHAR(500) NULL,
        PrintFailedAt       DATETIME2(3)  NULL,
        BannerAcknowledgedAt DATETIME2(3) NULL,
        CONSTRAINT FK_ShippingLabel_Container FOREIGN KEY (ContainerId)        REFERENCES Lots.Container(Id),
        CONSTRAINT FK_ShippingLabel_LabelType FOREIGN KEY (LabelTypeCodeId)    REFERENCES Lots.LabelTypeCode(Id),
        CONSTRAINT FK_ShippingLabel_PrintUser FOREIGN KEY (PrintedByUserId)    REFERENCES Location.AppUser(Id),
        CONSTRAINT FK_ShippingLabel_Terminal  FOREIGN KEY (TerminalLocationId) REFERENCES Location.Location(Id),
        CONSTRAINT FK_ShippingLabel_VoidUser  FOREIGN KEY (VoidedByUserId)     REFERENCES Location.AppUser(Id)
    );
    CREATE INDEX IX_ShippingLabel_Container ON Lots.ShippingLabel (ContainerId);
    -- print-failure safety sweep (P7): stranded prints.
    CREATE INDEX IX_ShippingLabel_Stranded ON Lots.ShippingLabel (CreatedAt)
        WHERE PrintedAt IS NULL AND PrintFailedAt IS NULL;
END
GO

-- ---- 6. Lots.AimShipperIdPool (pulled forward from P7; consumed by Container_Complete) ----
IF OBJECT_ID(N'Lots.AimShipperIdPool', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.AimShipperIdPool (
        Id                    BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        AimShipperId          NVARCHAR(50) NOT NULL,
        PartNumber            NVARCHAR(50) NOT NULL,
        FetchedAt             DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        FetchedInterfaceLogId BIGINT       NULL,
        ConsumedAt            DATETIME2(3) NULL,
        ConsumedByContainerId BIGINT       NULL,
        ConsumedByUserId      BIGINT       NULL,
        -- FetchedInterfaceLogId is a provenance pointer only: Audit.InterfaceLog is
        -- partitioned (composite PK Id, LoggedAt) so a single-column FK to it is invalid.
        CONSTRAINT UQ_AimShipperIdPool_ShipperId UNIQUE (AimShipperId),
        CONSTRAINT FK_AimPool_Container    FOREIGN KEY (ConsumedByContainerId) REFERENCES Lots.Container(Id),
        CONSTRAINT FK_AimPool_User         FOREIGN KEY (ConsumedByUserId)      REFERENCES Location.AppUser(Id)
    );
    -- FIFO-by-part-number claim over un-consumed IDs.
    CREATE INDEX IX_AimShipperIdPool_AvailableByPart
        ON Lots.AimShipperIdPool (PartNumber, FetchedAt) WHERE ConsumedAt IS NULL;
END
GO

-- ---- 7. Lots.AimPoolConfig (single-row thresholds) ----
IF OBJECT_ID(N'Lots.AimPoolConfig', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.AimPoolConfig (
        Id                INT          NOT NULL PRIMARY KEY CONSTRAINT CK_AimPoolConfig_SingleRow CHECK (Id = 1),
        TargetBufferDepth INT          NOT NULL DEFAULT 50,
        TopupThreshold    INT          NOT NULL DEFAULT 30,
        AlarmWarningDepth INT          NOT NULL DEFAULT 20,
        AlarmCriticalDepth INT         NOT NULL DEFAULT 10,
        UpdatedAt         DATETIME2(3) NULL,
        UpdatedByUserId   BIGINT       NULL,
        CONSTRAINT FK_AimPoolConfig_User FOREIGN KEY (UpdatedByUserId) REFERENCES Location.AppUser(Id)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM Lots.AimPoolConfig WHERE Id = 1)
    INSERT INTO Lots.AimPoolConfig (Id, TargetBufferDepth, TopupThreshold, AlarmWarningDepth, AlarmCriticalDepth)
    VALUES (1, 50, 30, 20, 10);
GO

-- ---- 8. Audit LogEntityType seeds (48-54; not identity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 48 OR Code = N'Container')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (48, N'Container', N'Container', N'Lots.Container - packaging unit.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 49 OR Code = N'ContainerTray')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (49, N'ContainerTray', N'Container Tray', N'Lots.ContainerTray - tray within a container.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 50 OR Code = N'ContainerSerial')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (50, N'ContainerSerial', N'Container Serial', N'Lots.ContainerSerial - serial in a tray position.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 51 OR Code = N'SerializedPart')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (51, N'SerializedPart', N'Serialized Part', N'Lots.SerializedPart - laser-etched part.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 52 OR Code = N'ShippingLabel')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (52, N'ShippingLabel', N'Shipping Label', N'Lots.ShippingLabel - container shipping label.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 53 OR Code = N'AimShipperIdPool')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (53, N'AimShipperIdPool', N'AIM Shipper ID Pool', N'Lots.AimShipperIdPool - buffered Honda AIM shipper IDs.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 54 OR Code = N'AimPoolConfig')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (54, N'AimPoolConfig', N'AIM Pool Config', N'Lots.AimPoolConfig - AIM pool thresholds.');
GO

-- ---- 9. Audit LogEventType seeds (46-53; not identity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 46 OR Code = N'ContainerOpened')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (46, N'ContainerOpened', N'Container Opened', N'A container was opened at a cell.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 47 OR Code = N'TrayClosed')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (47, N'TrayClosed', N'Tray Closed', N'A container tray reached its part count and closed.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 48 OR Code = N'ContainerCompleted')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (48, N'ContainerCompleted', N'Container Completed', N'A container completed; AIM ID claimed + shipping label created.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 49 OR Code = N'ContainerSerialAdded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (49, N'ContainerSerialAdded', N'Container Serial Added', N'A serialized part was placed into a container tray position.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 50 OR Code = N'MaterialSubstituteOverride')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (50, N'MaterialSubstituteOverride', N'Material Substitute Override', N'A supervisor authorized a BOM-mismatch consumption (UJ-09).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 51 OR Code = N'WorkOrderCompletionConfirmed')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (51, N'WorkOrderCompletionConfirmed', N'Work Order Completion Confirmed', N'Operator confirmed completion (FDS-06-028 / OI-16).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 52 OR Code = N'AimShipperIdClaimed')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (52, N'AimShipperIdClaimed', N'AIM Shipper ID Claimed', N'An AIM shipper ID was claimed from the pool for a container.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 53 OR Code = N'AimShipperIdToppedUp')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (53, N'AimShipperIdToppedUp', N'AIM Shipper ID Topped Up', N'A fetched AIM shipper ID was inserted into the pool.');
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0028_arc2_phase6_assembly')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0028_arc2_phase6_assembly',
        N'Arc 2 Phase 6: Container family (Container/SerializedPart/ContainerTray/ContainerSerial/ShippingLabel) + AIM pool (AimShipperIdPool/AimPoolConfig, pulled forward from P7) + audit seeds (LogEntityType 48-54, LogEventType 46-53) + AimPoolConfig single row.');
GO

PRINT 'Migration 0028 (Arc 2 Phase 6 assembly + container family + AIM pool) applied.';
GO
