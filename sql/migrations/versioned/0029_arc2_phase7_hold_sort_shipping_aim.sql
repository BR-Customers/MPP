-- ============================================================
-- Migration:   0029_arc2_phase7_hold_sort_shipping_aim.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-19
-- Description: Arc 2 Phase 7 (Hold + Sort Cage + Shipping + AIM Pool Lifecycle).
--                1. Quality.HoldEvent -- hold lifecycle on LOTs and Containers
--                   (C-4: owning phase; at-most-one-open per LotId / per ContainerId,
--                   B3). Exactly one of LotId/ContainerId set.
--                2. Lots.ContainerSerialHistory -- Sort Cage update-in-place serial
--                   migration trail (UJ-05 default direction).
--              Reuses existing code tables: Quality.HoldTypeCode (QualityHold/
--              EngineeringHold/CustomerHold), Lots.LotStatusCode (Hold=2,
--              BlocksProduction=1), Lots.ContainerStatusCode (Shipped=3/Hold=4/Void=5),
--              Lots.AimShipperIdPool/AimPoolConfig (CREATEd in 0028).
--              Audit seeds: LogEntityType 55-56; LogEventType 54-62.
--              Idempotent, GO-separated, ASCII-only. Explicit-Id audit inserts
--              (those PKs are not identity) guarded by IF NOT EXISTS.
-- ============================================================

-- ---- 1. Quality.HoldEvent ----
IF OBJECT_ID(N'Quality.HoldEvent', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.HoldEvent (
        Id               BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        LotId            BIGINT        NULL,
        ContainerId      BIGINT        NULL,
        HoldTypeCodeId   BIGINT        NOT NULL,
        Reason           NVARCHAR(500) NULL,
        PlacedByUserId   BIGINT        NOT NULL,
        PlacedAt         DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        ReleasedByUserId BIGINT        NULL,
        ReleasedAt       DATETIME2(3)  NULL,
        ReleaseRemarks   NVARCHAR(500) NULL,
        CONSTRAINT CK_HoldEvent_LotXorContainer CHECK (
            (LotId IS NOT NULL AND ContainerId IS NULL) OR (LotId IS NULL AND ContainerId IS NOT NULL)),
        CONSTRAINT FK_HoldEvent_Lot       FOREIGN KEY (LotId)            REFERENCES Lots.Lot(Id),
        CONSTRAINT FK_HoldEvent_Container FOREIGN KEY (ContainerId)      REFERENCES Lots.Container(Id),
        CONSTRAINT FK_HoldEvent_HoldType  FOREIGN KEY (HoldTypeCodeId)   REFERENCES Quality.HoldTypeCode(Id),
        CONSTRAINT FK_HoldEvent_PlacedBy  FOREIGN KEY (PlacedByUserId)   REFERENCES Location.AppUser(Id),
        CONSTRAINT FK_HoldEvent_RelBy     FOREIGN KEY (ReleasedByUserId) REFERENCES Location.AppUser(Id)
    );

    -- B3: at most one OPEN hold per LOT and per Container.
    CREATE UNIQUE INDEX UX_HoldEvent_OneOpenPerLot
        ON Quality.HoldEvent (LotId) WHERE ReleasedAt IS NULL AND LotId IS NOT NULL;
    CREATE UNIQUE INDEX UX_HoldEvent_OneOpenPerContainer
        ON Quality.HoldEvent (ContainerId) WHERE ReleasedAt IS NULL AND ContainerId IS NOT NULL;
END
GO

-- ---- 2. Lots.ContainerSerialHistory (Sort Cage update-in-place trail) ----
IF OBJECT_ID(N'Lots.ContainerSerialHistory', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.ContainerSerialHistory (
        Id                  BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        ContainerSerialId   BIGINT       NOT NULL,
        OldContainerId      BIGINT       NOT NULL,
        NewContainerId      BIGINT       NOT NULL,
        OldTrayPosition     INT          NULL,
        NewTrayPosition     INT          NULL,
        MigrationReasonCode NVARCHAR(50) NOT NULL,
        MigratedAt          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        MigratedByUserId    BIGINT       NOT NULL,
        CONSTRAINT FK_CSH_ContainerSerial FOREIGN KEY (ContainerSerialId) REFERENCES Lots.ContainerSerial(Id),
        CONSTRAINT FK_CSH_OldContainer    FOREIGN KEY (OldContainerId)    REFERENCES Lots.Container(Id),
        CONSTRAINT FK_CSH_NewContainer    FOREIGN KEY (NewContainerId)    REFERENCES Lots.Container(Id),
        CONSTRAINT FK_CSH_User            FOREIGN KEY (MigratedByUserId)  REFERENCES Location.AppUser(Id)
    );
    CREATE INDEX IX_CSH_ContainerSerial ON Lots.ContainerSerialHistory (ContainerSerialId, MigratedAt);
END
GO

-- ---- 3. Audit LogEntityType seeds (55-56; not identity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 55 OR Code = N'HoldEvent')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (55, N'HoldEvent', N'Hold Event', N'Quality.HoldEvent - LOT/container hold lifecycle.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 56 OR Code = N'ContainerSerialHistory')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (56, N'ContainerSerialHistory', N'Container Serial History', N'Lots.ContainerSerialHistory - Sort Cage serial migration trail.');
GO

-- ---- 4. Audit LogEventType seeds (54-62; not identity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 54 OR Code = N'HoldPlaced')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (54, N'HoldPlaced', N'Hold Placed', N'A hold was placed on a LOT or container.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 55 OR Code = N'HoldReleased')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (55, N'HoldReleased', N'Hold Released', N'A hold was released from a LOT or container.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 56 OR Code = N'ContainerSerialMigrated')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (56, N'ContainerSerialMigrated', N'Container Serial Migrated', N'A serial was re-containerized at the Sort Cage (update-in-place).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 57 OR Code = N'ContainerShipped')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (57, N'ContainerShipped', N'Container Shipped', N'A container was scanned out at the Shipping Dock.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 58 OR Code = N'ShippingLabelVoided')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (58, N'ShippingLabelVoided', N'Shipping Label Voided', N'A container shipping label was voided.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 59 OR Code = N'ShippingLabelReprinted')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (59, N'ShippingLabelReprinted', N'Shipping Label Reprinted', N'A container shipping label was reprinted (append-only).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 60 OR Code = N'AimPoolWarningAlarmFired')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (60, N'AimPoolWarningAlarmFired', N'AIM Pool Warning Alarm', N'AIM pool depth crossed the warning threshold.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 61 OR Code = N'AimPoolCriticalAlarmFired')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (61, N'AimPoolCriticalAlarmFired', N'AIM Pool Critical Alarm', N'AIM pool depth crossed the critical threshold.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 62 OR Code = N'PrintFailureSafetySweepRecovered')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (62, N'PrintFailureSafetySweepRecovered', N'Print Failure Sweep Recovered', N'The safety sweep re-dispatched a stranded shipping label.');
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0029_arc2_phase7_hold_sort_shipping_aim')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0029_arc2_phase7_hold_sort_shipping_aim',
        N'Arc 2 Phase 7: Quality.HoldEvent (one-open-per-lot/container, B3) + Lots.ContainerSerialHistory (Sort Cage update-in-place) + audit seeds (LogEntityType 55-56, LogEventType 54-62). AIM pool tables + ShippingLabel already in 0028.');
GO

PRINT 'Migration 0029 (Arc 2 Phase 7 hold + sort cage + shipping + AIM lifecycle) applied.';
GO
