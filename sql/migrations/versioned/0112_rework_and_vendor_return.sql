-- ============================================================
-- Migration:   0112_rework_and_vendor_return.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Description: Super-lot piece 5 of 6 -- trim rework and return to vendor.
--
--   DO NOT DEPLOY TO PRODUCTION ON ITS OWN. Spec:
--   docs/superpowers/specs/2026-10-12-controlled-run-rework-and-return-design.md
--
--   Lots.LotRework   -- one row per rework of a LOT: a supervisor-approved override
--                       move back into trim, closed by the Trim OUT that re-runs it.
--                       At most one OPEN rework per LOT (filtered unique index).
--   Lots.VendorReturn-- one row per return-to-vendor of part of a LOT's quantity.
--                       Marked, then confirmed or cancelled (never both). The
--                       PieceCountTaken / InventoryTaken pair records exactly what
--                       was removed so Cancel can restore it.
--
--   LotMovementId and CompletedProductionEventId are pointers with NO foreign key:
--   Lots.LotMovement and Workorder.ProductionEvent are partitioned (B2) with
--   composite (Id, timestamp) keys, so a bare-Id FK is not possible.
--
--   Idempotent per statement; ASCII-only (sqlcmd codepage rule).
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0112_rework_and_vendor_return')
BEGIN PRINT 'Migration 0112 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Lots.LotRework ----
IF OBJECT_ID(N'Lots.LotRework', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotRework (
        Id                         BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_LotRework PRIMARY KEY,
        LotId                      BIGINT        NOT NULL CONSTRAINT FK_LotRework_Lot REFERENCES Lots.Lot(Id),
        ReEntrySequenceNumber      INT           NOT NULL,
        LotMovementId              BIGINT        NULL,
        StartedAt                  DATETIME2(3)  NOT NULL CONSTRAINT DF_LotRework_StartedAt DEFAULT (SYSUTCDATETIME()),
        MovedByUserId              BIGINT        NOT NULL CONSTRAINT FK_LotRework_MovedBy REFERENCES Location.AppUser(Id),
        ApprovedByUserId           BIGINT        NULL CONSTRAINT FK_LotRework_ApprovedBy REFERENCES Location.AppUser(Id),
        TerminalLocationId         BIGINT        NULL CONSTRAINT FK_LotRework_Terminal REFERENCES Location.Location(Id),
        CompletedAt                DATETIME2(3)  NULL,
        CompletedProductionEventId BIGINT        NULL,
        CONSTRAINT CK_LotRework_Completed CHECK ((CompletedAt IS NULL AND CompletedProductionEventId IS NULL)
                                              OR (CompletedAt IS NOT NULL AND CompletedProductionEventId IS NOT NULL)));
    CREATE UNIQUE INDEX UQ_LotRework_OpenPerLot ON Lots.LotRework (LotId) WHERE CompletedAt IS NULL;
    CREATE INDEX IX_LotRework_Lot ON Lots.LotRework (LotId, StartedAt DESC) INCLUDE (ReEntrySequenceNumber, CompletedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'One row each time a LOT is moved back into trim for rework (super-lot piece 5). Open until the Trim OUT that re-runs it; at most one open row per LOT. ReEntrySequenceNumber is the route step the LOT re-enters at. LotMovementId and CompletedProductionEventId point at partitioned tables and carry no FK.',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'LotRework';
END
GO

-- ---- 2. Lots.VendorReturn ----
IF OBJECT_ID(N'Lots.VendorReturn', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.VendorReturn (
        Id                    BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_VendorReturn PRIMARY KEY,
        LotId                 BIGINT        NOT NULL CONSTRAINT FK_VendorReturn_Lot REFERENCES Lots.Lot(Id),
        Quantity              INT           NOT NULL,
        PieceCountTaken       INT           NOT NULL,
        InventoryTaken        INT           NOT NULL,
        Remarks               NVARCHAR(500) NULL,
        ControlledRunResultId BIGINT        NULL CONSTRAINT FK_VendorReturn_Result REFERENCES Quality.ControlledRunResult(Id),
        MarkedByUserId        BIGINT        NOT NULL CONSTRAINT FK_VendorReturn_MarkedBy REFERENCES Location.AppUser(Id),
        MarkedAt              DATETIME2(3)  NOT NULL CONSTRAINT DF_VendorReturn_MarkedAt DEFAULT (SYSUTCDATETIME()),
        TerminalLocationId    BIGINT        NULL CONSTRAINT FK_VendorReturn_Terminal REFERENCES Location.Location(Id),
        ConfirmedAt           DATETIME2(3)  NULL,
        ConfirmedByUserId     BIGINT        NULL CONSTRAINT FK_VendorReturn_ConfirmedBy REFERENCES Location.AppUser(Id),
        CancelledAt           DATETIME2(3)  NULL,
        CancelledByUserId     BIGINT        NULL CONSTRAINT FK_VendorReturn_CancelledBy REFERENCES Location.AppUser(Id),
        CancelRemarks         NVARCHAR(500) NULL,
        CONSTRAINT CK_VendorReturn_Quantity   CHECK (Quantity > 0),
        CONSTRAINT CK_VendorReturn_Taken      CHECK (PieceCountTaken >= 0 AND InventoryTaken >= 0),
        CONSTRAINT CK_VendorReturn_OneEnd     CHECK (ConfirmedAt IS NULL OR CancelledAt IS NULL),
        CONSTRAINT CK_VendorReturn_Confirm    CHECK ((ConfirmedAt IS NULL AND ConfirmedByUserId IS NULL)
                                                  OR (ConfirmedAt IS NOT NULL AND ConfirmedByUserId IS NOT NULL)),
        CONSTRAINT CK_VendorReturn_Cancel     CHECK ((CancelledAt IS NULL AND CancelledByUserId IS NULL)
                                                  OR (CancelledAt IS NOT NULL AND CancelledByUserId IS NOT NULL)));
    CREATE INDEX IX_VendorReturn_Open ON Lots.VendorReturn (MarkedAt) WHERE ConfirmedAt IS NULL AND CancelledAt IS NULL;
    CREATE INDEX IX_VendorReturn_Lot  ON Lots.VendorReturn (LotId);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'One row per return-to-vendor of part of a LOT (super-lot piece 5). Marked, then confirmed or cancelled, never both. PieceCountTaken and InventoryTaken record exactly what was removed from the LOT so a Cancel restores it; they differ when Quantity exceeded InventoryAvailable. ControlledRunResultId links the failed-result row when the return came from a super-lot result.',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'VendorReturn';
END
GO

-- ---- 3. Audit event codes (plain PKs: next free id, guarded by Code) ----
DECLARE @Ev TABLE (Code NVARCHAR(50), Name NVARCHAR(200), Description NVARCHAR(500), Ord INT IDENTITY(1,1));
INSERT INTO @Ev (Code, Name, Description) VALUES
    (N'LotReworkStarted',       N'LOT Rework Started',       N'A LOT was moved back into trim for rework.'),
    (N'LotReworkCompleted',     N'LOT Rework Completed',     N'A Trim OUT closed the open rework of a LOT.'),
    (N'VendorReturnMarked',     N'Vendor Return Marked',     N'Part of a LOT was marked for return to the vendor.'),
    (N'VendorReturnConfirmed',  N'Vendor Return Confirmed',  N'A marked vendor return was confirmed as shipped back.'),
    (N'VendorReturnCancelled',  N'Vendor Return Cancelled',  N'A marked vendor return was cancelled and the quantity restored.');
DECLARE @Base BIGINT = (SELECT ISNULL(MAX(Id), 0) FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @Base + ROW_NUMBER() OVER (ORDER BY e.Ord), e.Code, e.Name, e.Description
FROM @Ev e
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType x WHERE x.Code = e.Code);
GO

IF OBJECT_ID(N'Lots.LotRework', N'U') IS NULL OR OBJECT_ID(N'Lots.VendorReturn', N'U') IS NULL
    THROW 51000, 'Migration 0112: LotRework / VendorReturn did not land.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0112_rework_and_vendor_return')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0112_rework_and_vendor_return',
            N'Super-lot piece 5: Lots.LotRework, Lots.VendorReturn, audit codes LotReworkStarted/Completed and VendorReturnMarked/Confirmed/Cancelled. Do NOT deploy alone.');
GO
PRINT 'Migration 0112 (rework_and_vendor_return) applied.';
GO
