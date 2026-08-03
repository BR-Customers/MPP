-- =============================================
-- Migration:   0050_aim_posting_enabled.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-03
-- Description: Adds the actual off-switch for AIM traffic. The plan document claimed
--              the integration "ships disabled" because AimPostTimer.enabled is false
--              in resource.json -- but that only gates the 60s RETRY SWEEP. The FIRST
--              post to AIM runs synchronously inside Container.complete ->
--              AimPost.postOne, on the live plant-floor path (AssemblySerialized,
--              AssemblyNonSerialized, Workorder.Assembly.plcCompleteTray). A timer flag
--              cannot gate a call that never goes through the timer. Deploying as-is
--              starts posting to whatever AIM company code is configured the moment an
--              operator completes a container.
--
--              AIM's nextserial.csv / postserial.csv calls CONSUME serials from AIM's
--              own counter -- a fetched or posted serial can never be handed back. That
--              makes the integration fundamentally different from an ordinary feature
--              flag: turning it on by accident, even briefly, burns real Honda-facing
--              shipper IDs that cannot be un-burned. So the gate does not live in a
--              caller or a timer -- it lives in the ONE place an AIM call leaves the
--              Gateway (BlueRidge.Lots.AimHttp._config() / nextSerial() / postSerial(),
--              per that module's header), where no caller can bypass it.
--
--              AimPostingEnabled defaults to 0 (off). It must be deliberately switched
--              on per environment via the AIM Pool Config admin screen (AD-elevated)
--              once that environment's connection settings (AimBaseUrl, AimCompanyCode,
--              AimPathToken) have been verified against the correct AIM company code --
--              MES traffic must never target Honda's production company (99) from a
--              non-production environment.
-- =============================================

IF COL_LENGTH(N'Lots.AimPoolConfig', N'AimPostingEnabled') IS NULL
    ALTER TABLE Lots.AimPoolConfig ADD
        AimPostingEnabled BIT NOT NULL
            CONSTRAINT DF_AimPoolConfig_PostingEnabled DEFAULT 0;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion
               WHERE MigrationId = N'0050_aim_posting_enabled')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0050_aim_posting_enabled',
        N'Lots.AimPoolConfig.AimPostingEnabled (default 0) -- the transport-layer gate that makes AIM posting inert until deliberately enabled per environment.');
GO
