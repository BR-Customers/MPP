-- ============================================================
-- Migration: 0049_session_policy.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-04
-- Description: Global plant-floor session policy (single row): operator-presence
--              + elevation idle timeouts (seconds). Seeds Id=1 defaults 180/300.
--              Adds Audit.LogEntityType 'SessionPolicy'. Idempotent-guarded.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0049_session_policy')
BEGIN PRINT 'Migration 0049 already applied -- skipping.'; RETURN; END
GO

IF OBJECT_ID(N'Location.SessionPolicy') IS NULL
CREATE TABLE Location.SessionPolicy (
    Id                             BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SessionPolicy PRIMARY KEY,
    OperatorPresenceTimeoutSeconds INT          NOT NULL CONSTRAINT DF_SessionPolicy_OpTimeout  DEFAULT 180,
    ElevationTimeoutSeconds        INT          NOT NULL CONSTRAINT DF_SessionPolicy_ElevTimeout DEFAULT 300,
    UpdatedAt                      DATETIME2(3) NOT NULL CONSTRAINT DF_SessionPolicy_UpdatedAt   DEFAULT SYSUTCDATETIME(),
    UpdatedByUserId                BIGINT       NOT NULL CONSTRAINT FK_SessionPolicy_UpdatedBy   REFERENCES Location.AppUser(Id),
    CONSTRAINT CK_SessionPolicy_OpBounds   CHECK (OperatorPresenceTimeoutSeconds BETWEEN 30 AND 3600),
    CONSTRAINT CK_SessionPolicy_ElevBounds CHECK (ElevationTimeoutSeconds        BETWEEN 30 AND 3600)
);
GO

-- Single-row seed (Id 1), attributed to the bootstrap system user (AppUser 1).
IF NOT EXISTS (SELECT 1 FROM Location.SessionPolicy)
    INSERT INTO Location.SessionPolicy (OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, UpdatedByUserId)
    VALUES (180, 300, 1);
GO

-- Audit entity type (dynamic next Id -- no magic number / collision).
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'SessionPolicy')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    SELECT ISNULL(MAX(Id),0)+1, N'SessionPolicy', N'Session Policy',
           N'Global plant-floor operator-presence + elevation idle timeouts'
    FROM Audit.LogEntityType;
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0049_session_policy', N'Location.SessionPolicy single-row global timeouts + SessionPolicy LogEntityType.');
GO
PRINT 'Migration 0049 (session_policy) applied.';
GO
