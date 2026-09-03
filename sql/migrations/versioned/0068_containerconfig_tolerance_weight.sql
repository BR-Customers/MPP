-- ============================================================
-- Migration:   0068_containerconfig_tolerance_weight.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-27
-- Description: Parts.ContainerConfig.ToleranceWeight -- the checkweigh
--              window half-width for ByWeight tray closure.
--
--              FDS-06-014 describes ByWeight closure as "TargetWeight per
--              tray (+ optional tolerance)" but only TargetWeight reached
--              the schema. Legacy SparkMES carried the tolerance as
--              GroupTargetWeightTolerance, listed in the FDS legacy-column
--              crosswalk as "subsumed by OI-02 resolution when that closes"
--              -- it was not. This closes that gap.
--
--              SYMMETRIC by decision: one value, pushed to the IND570 as
--              both the (+) and (-) tolerance (commands 131 and 112). The
--              device supports an asymmetric window; the schema
--              deliberately does not. Revisit only if MPP asks for it.
--
--              NULLable, like TargetWeight: the tolerance is optional per
--              FDS-06-014, and the ByWeight closure path treats a missing
--              tolerance as a configuration error at load time rather than
--              as a zero-width window.
--
--              Unit-less, like TargetWeight. Units live on the scale UDT's
--              WeightUom parameter (default lb) and are verified against
--              the terminal at commissioning via command 30.
--
--              Additive. Idempotent-guarded; no explicit transaction
--              (repo convention).
--
-- Spec:        docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md Sec 7.1
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0068_containerconfig_tolerance_weight')
BEGIN
    PRINT 'Migration 0068 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- == Parts.ContainerConfig.ToleranceWeight ===================
-- ============================================================
IF COL_LENGTH(N'Parts.ContainerConfig', N'ToleranceWeight') IS NULL
    ALTER TABLE Parts.ContainerConfig
        ADD ToleranceWeight DECIMAL(10,4) NULL;   -- symmetric checkweigh window about TargetWeight
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0068_containerconfig_tolerance_weight')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0068_containerconfig_tolerance_weight',
        N'Parts.ContainerConfig.ToleranceWeight: symmetric checkweigh window half-width for ByWeight tray closure (FDS-06-014).'
    );
GO
