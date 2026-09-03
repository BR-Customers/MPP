-- ============================================================
-- Migration:   0067_reject_chargeto_and_location.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-25
-- Description: FDS-12-006 Rejects reporting foundation. Spec:
--              docs/superpowers/specs/2026-08-25-aggregate-reports-design.md
--
--              1. Quality.ChargeToParty -- read-only code table for the
--                 RESPONSIBLE PARTY on a reject. The legacy Departmental Scrap
--                 block groups by this. Migration 0048 replaced
--                 DefectCode.AreaLocationId with OperationCategoryId (DieCast /
--                 Trim / MachiningAssembly, NULL = plant-wide), which collapses
--                 the legacy's "Non-Specific Supplier" and "Non-Specific MPP"
--                 rows into one bucket. Responsibility is ORTHOGONAL to process:
--                 OperationCategory drives reject-screen filtering, this drives
--                 chargeback reporting. Two dimensions, two columns.
--
--              2. Quality.DefectCode.ChargeToPartyId -- nullable FK, backfilled
--                 from the source CSV's DeptDesc. Nullable on purpose: an
--                 unclassified code reports under an explicit Unassigned row
--                 rather than vanishing from the totals.
--
--              3. Quality.DefectCode.IsNonRejectScrap -- the legacy Reject
--                 Summary's "Non-Reject Scrap" block (Trial Parts, Test Parts,
--                 Assembled-on-to-NG) is a NAMED SET OF DEFECT CODES, not a
--                 flag. Counted, but excluded from every reject percentage.
--                 IsExcused is a DIFFERENT axis (OEE quality calculation) and
--                 is deliberately NOT reused for this.
--
--              4. Workorder.RejectEvent.TerminalLocationId -- where the scrap
--                 was recorded. Workorder.RejectEvent_Record ALREADY accepts
--                 @TerminalLocationId, commented "audit-only; no column on
--                 RejectEvent": the caller passes it and it reaches only the
--                 audit log. Sibling tables ProductionEvent and ConsumptionEvent
--                 both persist it; RejectEvent was the outlier. Backfilled once
--                 from the last LotMovement at or before RecordedAt -- deriving
--                 at READ time was rejected because Lot.CurrentLocationId drifts
--                 (a casting scrapped at Die Cast then moved onward would report
--                 as Machining -- the failure FDS-02-002a exists to prevent).
--
--              All four changes are additive. Idempotent-guarded; no explicit
--              transaction (repo convention).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0067_reject_chargeto_and_location')
BEGIN
    PRINT 'Migration 0067 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Quality.ChargeToParty (read-only code table)
-- ============================================================
IF OBJECT_ID(N'Quality.ChargeToParty', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ChargeToParty (
        Id        BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Code      NVARCHAR(50)  NOT NULL,
        Name      NVARCHAR(100) NOT NULL,
        SortOrder INT           NOT NULL CONSTRAINT DF_ChargeToParty_SortOrder DEFAULT (0),
        CONSTRAINT UQ_ChargeToParty_Code UNIQUE (Code)
    );
END
GO

-- ASCII-only seed values (sqlcmd reads .sql in the Windows codepage; non-ASCII
-- lands as mojibake and then shows in Ignition).
SET IDENTITY_INSERT Quality.ChargeToParty ON;
INSERT INTO Quality.ChargeToParty (Id, Code, Name, SortOrder)
SELECT v.Id, v.Code, v.Name, v.SortOrder
FROM (VALUES
    (1, N'DieCast',              N'Die Cast',              10),
    (2, N'TrimShop',             N'Trim Shop',             20),
    (3, N'MachineShop',          N'Machine Shop',          30),
    (4, N'DieMaintenance',       N'Die Maintenance',       40),
    (5, N'MppNonSpecific',       N'Non-Specific MPP',      50),
    (6, N'SupplierNonSpecific',  N'Non-Specific Supplier', 60)
) v (Id, Code, Name, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM Quality.ChargeToParty p WHERE p.Code = v.Code);
SET IDENTITY_INSERT Quality.ChargeToParty OFF;
GO

-- ============================================================
-- 2. Quality.DefectCode.ChargeToPartyId
-- ============================================================
IF COL_LENGTH(N'Quality.DefectCode', N'ChargeToPartyId') IS NULL
    ALTER TABLE Quality.DefectCode ADD ChargeToPartyId BIGINT NULL
        CONSTRAINT FK_DefectCode_ChargeToParty REFERENCES Quality.ChargeToParty(Id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DefectCode_ChargeToPartyId')
    CREATE INDEX IX_DefectCode_ChargeToPartyId ON Quality.DefectCode (ChargeToPartyId);
GO

-- Backfill. The source CSV's DeptDesc is the authority
-- (reference/seed_data/defect_codes.csv):
--   Die Cast (10) -> DieCast          Machine Shop (12) -> MachineShop
--   Trim Shop (11) -> TrimShop        HSP (35)          -> SupplierNonSpecific
--   Prod. Control (16) + Quality Control (19) -> MppNonSpecific
--
-- OperationCategory carries the first three; the last two live only in the CSV,
-- so the HSP / Prod-Control / Quality-Control codes are listed explicitly.
DECLARE @DieCast     BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'DieCast');
DECLARE @TrimShop    BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'TrimShop');
DECLARE @MachineShop BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'MachineShop');
DECLARE @MppNS       BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'MppNonSpecific');
DECLARE @SupplierNS  BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'SupplierNonSpecific');

DECLARE @OcDieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @OcTrim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
DECLARE @OcMachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');

-- HSP -> Non-Specific Supplier (supplier-provided parts).
UPDATE Quality.DefectCode SET ChargeToPartyId = @SupplierNS
WHERE ChargeToPartyId IS NULL
  AND Code IN (N'247', N'248', N'249', N'250', N'252', N'253');

-- Prod. Control + Quality Control -> Non-Specific MPP.
UPDATE Quality.DefectCode SET ChargeToPartyId = @MppNS
WHERE ChargeToPartyId IS NULL
  AND Code IN (N'225', N'201', N'202', N'203', N'204', N'205', N'212');

-- The three process families, from OperationCategory.
UPDATE Quality.DefectCode SET ChargeToPartyId = @DieCast
WHERE ChargeToPartyId IS NULL AND OperationCategoryId = @OcDieCast;

UPDATE Quality.DefectCode SET ChargeToPartyId = @TrimShop
WHERE ChargeToPartyId IS NULL AND OperationCategoryId = @OcTrim;

UPDATE Quality.DefectCode SET ChargeToPartyId = @MachineShop
WHERE ChargeToPartyId IS NULL AND OperationCategoryId = @OcMachAsm;
GO

-- ============================================================
-- 3. Quality.DefectCode.IsNonRejectScrap
-- ============================================================
IF COL_LENGTH(N'Quality.DefectCode', N'IsNonRejectScrap') IS NULL
    ALTER TABLE Quality.DefectCode ADD IsNonRejectScrap BIT NOT NULL
        CONSTRAINT DF_DefectCode_IsNonRejectScrap DEFAULT (0);
GO

--   107 Test Part (DC)                170 Machine Trial (MS)
--   229 Trial Part (DC)
--   230 Assembled on to NG part DC    199 Assembled on to NG part MS
UPDATE Quality.DefectCode SET IsNonRejectScrap = 1
WHERE Code IN (N'107', N'170', N'229', N'230', N'199');
GO

-- ============================================================
-- 4. Workorder.RejectEvent.TerminalLocationId
-- ============================================================
IF COL_LENGTH(N'Workorder.RejectEvent', N'TerminalLocationId') IS NULL
    ALTER TABLE Workorder.RejectEvent ADD TerminalLocationId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_TerminalLocation')
    ALTER TABLE Workorder.RejectEvent
        ADD CONSTRAINT FK_RejectEvent_TerminalLocation
        FOREIGN KEY (TerminalLocationId) REFERENCES Location.Location(Id);
GO

-- Partition-aligned (RejectEvent is partitioned on RecordedAt).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_RejectEvent_TerminalLocationId')
    CREATE INDEX IX_RejectEvent_TerminalLocationId
        ON Workorder.RejectEvent (TerminalLocationId, RecordedAt)
        WHERE TerminalLocationId IS NOT NULL
        ON ps_MonthlyUtc(RecordedAt);
GO

-- One-shot backfill: the LOT's location as of the reject. Rows with no prior
-- movement stay NULL rather than being guessed at.
UPDATE re
SET TerminalLocationId = mv.ToLocationId
FROM Workorder.RejectEvent re
CROSS APPLY (
    SELECT TOP (1) m.ToLocationId
    FROM Lots.LotMovement m
    WHERE m.LotId = re.LotId AND m.MovedAt <= re.RecordedAt
    ORDER BY m.MovedAt DESC, m.Id DESC
) mv
WHERE re.TerminalLocationId IS NULL;
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0067_reject_chargeto_and_location')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0067_reject_chargeto_and_location',
        N'FDS-12-006: Quality.ChargeToParty code table; DefectCode.ChargeToPartyId + IsNonRejectScrap; RejectEvent.TerminalLocationId + backfill.'
    );
GO
