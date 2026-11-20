-- ============================================================
-- Migration:   0135_scale_part_code_map.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Description: Learned scale part codes, per terminal.
--
--   A Digi-read scale sends the code selected on the scale (<Part>), which on
--   some heads is not an MES part number (prod terminal 215 sends `66V`). The
--   first such press is held and the operator picks the part; the pick now
--   teaches the MES `code -> part` FOR THAT TERMINAL, so later presses resolve
--   with no tap. Workorder.ScalePendingPress_Complete v1.1 writes the mapping
--   in the pick's own transaction; Workorder.ScalePartCode_Resolve reads it
--   after an exact part-number match fails.
--
--   Per terminal, not plant-wide: another head's target table can reuse a
--   short code for another part. One active mapping per (terminal, code),
--   enforced by a filtered unique index; a replaced or removed mapping is kept,
--   deprecated, as history.
--
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 13.
-- ============================================================
IF OBJECT_ID(N'Workorder.ScalePartCode', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.ScalePartCode (
        Id                    BIGINT        NOT NULL IDENTITY(1,1)
                              CONSTRAINT PK_ScalePartCode PRIMARY KEY,
        TerminalLocationId    BIGINT        NOT NULL
                              CONSTRAINT FK_ScalePartCode_Terminal REFERENCES Location.Location(Id),
        ScalePartCode         NVARCHAR(50)  NOT NULL,
        ItemId                BIGINT        NOT NULL
                              CONSTRAINT FK_ScalePartCode_Item REFERENCES Parts.Item(Id),
        LearnedAt             DATETIME2(3)  NOT NULL
                              CONSTRAINT DF_ScalePartCode_LearnedAt DEFAULT SYSUTCDATETIME(),
        LearnedByAppUserId    BIGINT        NOT NULL
                              CONSTRAINT FK_ScalePartCode_LearnedBy REFERENCES Location.AppUser(Id),
        DeprecatedAt          DATETIME2(3)  NULL,
        DeprecatedByAppUserId BIGINT        NULL
                              CONSTRAINT FK_ScalePartCode_DeprecatedBy REFERENCES Location.AppUser(Id)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_ScalePartCode_Terminal_Code_Active'
               AND object_id = OBJECT_ID(N'Workorder.ScalePartCode'))
    CREATE UNIQUE INDEX UX_ScalePartCode_Terminal_Code_Active
        ON Workorder.ScalePartCode (TerminalLocationId, ScalePartCode)
        INCLUDE (ItemId)
        WHERE DeprecatedAt IS NULL;
GO

-- Audit.LogEventType.Id is a plain PK (not identity): the 0113 / 0134 pattern.
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ScalePartCodeLearned')
BEGIN
    DECLARE @E1 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@E1, N'ScalePartCodeLearned', N'Scale Part Code Learned',
            N'A pick on a held scale press taught (or replaced) the terminal''s mapping from the scale''s part code to a part (Workorder.ScalePendingPress_Complete).');
END
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ScalePartCodeRemoved')
BEGIN
    DECLARE @E2 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@E2, N'ScalePartCodeRemoved', N'Scale Part Code Removed',
            N'A learned scale part code mapping was removed in the Config Tool (Workorder.ScalePartCode_Deprecate); the next press with that code asks again.');
END
GO

IF OBJECT_ID(N'Workorder.ScalePartCode', N'U') IS NULL
    THROW 51000, 'Migration 0135: Workorder.ScalePartCode did not land.', 1;
IF (SELECT COUNT(*) FROM Audit.LogEventType WHERE Code IN (N'ScalePartCodeLearned', N'ScalePartCodeRemoved')) <> 2
    THROW 51000, 'Migration 0135: LogEventType rows did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0135_scale_part_code_map')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0135_scale_part_code_map',
            N'Workorder.ScalePartCode (learned scale part code -> part, per terminal, one active per code); LogEventType ScalePartCodeLearned/Removed. Apply with Workorder.ScalePartCode_* v1.0 + ScalePendingPress_Complete v1.1.');
GO
PRINT 'Migration 0135 (scale_part_code_map) applied.';
GO
