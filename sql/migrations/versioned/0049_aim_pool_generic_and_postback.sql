-- =============================================
-- Migration:   0049_aim_pool_generic_and_postback.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-31
-- Description: Makes the AIM shipper-ID pool part-agnostic and gives it a post-back
--              ledger, per the verified AIM contract.
--                * AIM's nextserial.csv accepts NO part parameter - serials are unique
--                  per company code - so the per-part pool (and FDS-07-010's per-part
--                  topup loop) is unimplementable. PartNumber and its filtered index go.
--                * postserial.csv is what actually creates the label in AIM, so every
--                  completed container owes AIM a payload. Those columns plus a posted
--                  flag and retry bookkeeping land on the pool row.
--                * AimPoolConfig gains connection settings (base URL, company code,
--                  path token) and post-backlog age thresholds, distinct from the
--                  existing depth thresholds which mean pool supply.
--                * Parts.Item gains AimCustomerPartNumber - AIM matches on its Customer
--                  Part, which is NOT derivable from our PartNumber.
--              Contract + evidence: notes/2026-07-28_aim-interface-contract.md
-- =============================================

-- ---- 1. Genericize the pool ----
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
             AND name = N'IX_AimShipperIdPool_AvailableByPart')
    DROP INDEX IX_AimShipperIdPool_AvailableByPart ON Lots.AimShipperIdPool;
GO

IF COL_LENGTH(N'Lots.AimShipperIdPool', N'PartNumber') IS NOT NULL
    ALTER TABLE Lots.AimShipperIdPool DROP COLUMN PartNumber;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
                 AND name = N'IX_AimShipperIdPool_Available')
    CREATE INDEX IX_AimShipperIdPool_Available
        ON Lots.AimShipperIdPool (FetchedAt) WHERE ConsumedAt IS NULL;
GO

-- ---- 2. Post-back payload + status ----
IF COL_LENGTH(N'Lots.AimShipperIdPool', N'CustomerPartNumber') IS NULL
    ALTER TABLE Lots.AimShipperIdPool ADD
        CustomerPartNumber NVARCHAR(50)  NULL,
        Quantity           INT           NULL,
        LotNumber          NVARCHAR(50)  NULL,
        PostedAt           DATETIME2(3)  NULL,
        PostAttempts       INT           NOT NULL
            CONSTRAINT DF_AimShipperIdPool_PostAttempts DEFAULT 0,
        LastPostAttemptAt  DATETIME2(3)  NULL,
        LastPostError      NVARCHAR(500) NULL;
GO

-- Sweep read: consumed but not yet reported to AIM. Rows leave this index on
-- success, so it stays small.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
                 AND name = N'IX_AimShipperIdPool_Unposted')
    CREATE INDEX IX_AimShipperIdPool_Unposted
        ON Lots.AimShipperIdPool (ConsumedAt)
        WHERE ConsumedAt IS NOT NULL AND PostedAt IS NULL;
GO

-- ---- 3. AimPoolConfig: connection + escalation ----
IF COL_LENGTH(N'Lots.AimPoolConfig', N'AimBaseUrl') IS NULL
    ALTER TABLE Lots.AimPoolConfig ADD
        AimBaseUrl             NVARCHAR(200) NULL,
        AimCompanyCode         NVARCHAR(10)  NULL,
        AimPathToken           NVARCHAR(50)  NULL,
        PostWarningAgeMinutes  INT NOT NULL
            CONSTRAINT DF_AimPoolConfig_PostWarnAge DEFAULT 30,
        PostCriticalAgeMinutes INT NOT NULL
            CONSTRAINT DF_AimPoolConfig_PostCritAge DEFAULT 120;
GO

-- ---- 4. Parts.Item: AIM customer part ----
-- NOT derivable from Item.PartNumber. AIM's X-Ref shows 11300R70 A000 -> 11300R7- A000
-- and 112006FBAA000 -> 112006FB A000. Must be stored per item, sourced from AIM.
IF COL_LENGTH(N'Parts.Item', N'AimCustomerPartNumber') IS NULL
    ALTER TABLE Parts.Item ADD AimCustomerPartNumber NVARCHAR(50) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion
               WHERE MigrationId = N'0049_aim_pool_generic_and_postback')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0049_aim_pool_generic_and_postback',
        N'AIM pool genericized (PartNumber dropped); post-back payload/status columns; AimPoolConfig connection + escalation settings; Parts.Item.AimCustomerPartNumber.');
GO
