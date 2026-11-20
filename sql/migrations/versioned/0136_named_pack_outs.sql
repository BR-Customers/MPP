-- ============================================================
-- Migration:   0136_named_pack_outs.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Description: Named pack-outs, selectable per terminal.
--
--   A part can go out in more than one container (cardboard vs tote: other
--   parts per tray, trays per box, gross weight). Until now Parts.ContainerConfig
--   held ONE active pack-out per (part, closure method), so switching container
--   meant overwriting it.
--
--   Parts.PackOut (new) is a pack-out's IDENTITY: part, method, a free-text
--   Name, the IsDefault flag. Parts.ContainerConfig rows become its immutable
--   VERSIONS (PackOutId + VersionNumber): an edit retires the active version and
--   inserts the next one, so Lots.Container.ContainerConfigId -- stamped when a
--   box opens -- keeps the exact numbers that box was packed to.
--   ContainerConfig keeps ItemId + ClosureMethod (copied from the header, never
--   changed) so the box-reading procs that read cc.ClosureMethod are untouched.
--
--   Location.TerminalPackOutSelection (new) is a terminal's pick, one per
--   (terminal, part, method). No pick -> the part's default.
--
--   Backfill: every existing (ItemId, ClosureMethod) group becomes one header,
--   named after the method ("By Weight"), IsDefault = 1 when the group has an
--   active row; all its rows become versions in CreatedAt order. Every terminal
--   therefore resolves to exactly the row it uses today.
--
--   FK choices: PackOut.ItemId and TerminalPackOutSelection.PackOutId cascade
--   on DELETE (prod never hard-deletes a part; test fixtures do). The
--   selection's ItemId / ClosureMethod carry no FK: they are copied from the
--   header by Location.Terminal_SetPackOut (avoids multiple cascade paths).
--
--   Spec: docs/superpowers/specs/2026-11-20-named-pack-outs-design.md.
-- ============================================================

-- ---------------- Parts.PackOut ----------------
IF OBJECT_ID(N'Parts.PackOut', N'U') IS NULL
BEGIN
    CREATE TABLE Parts.PackOut (
        Id                 BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_PackOut PRIMARY KEY,
        ItemId             BIGINT        NOT NULL
                           CONSTRAINT FK_PackOut_Item REFERENCES Parts.Item(Id) ON DELETE CASCADE,
        ClosureMethod      NVARCHAR(20)  NOT NULL
                           CONSTRAINT FK_PackOut_ClosureMethod REFERENCES Parts.ClosureMethodCode(Code),
        Name               NVARCHAR(50)  NOT NULL,
        IsDefault          BIT           NOT NULL CONSTRAINT DF_PackOut_IsDefault DEFAULT 0,
        CreatedAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_PackOut_CreatedAt DEFAULT SYSUTCDATETIME(),
        CreatedByUserId    BIGINT        NOT NULL CONSTRAINT FK_PackOut_CreatedBy REFERENCES Location.AppUser(Id),
        UpdatedAt          DATETIME2(3)  NULL,
        UpdatedByUserId    BIGINT        NULL CONSTRAINT FK_PackOut_UpdatedBy REFERENCES Location.AppUser(Id),
        DeprecatedAt       DATETIME2(3)  NULL,
        DeprecatedByUserId BIGINT        NULL CONSTRAINT FK_PackOut_DeprecatedBy REFERENCES Location.AppUser(Id),
        CONSTRAINT CK_PackOut_Name_NotBlank CHECK (LEN(LTRIM(RTRIM(Name))) > 0)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_PackOut_ActiveName' AND object_id = OBJECT_ID(N'Parts.PackOut'))
    CREATE UNIQUE INDEX UQ_PackOut_ActiveName ON Parts.PackOut (ItemId, ClosureMethod, Name)
        INCLUDE (IsDefault) WHERE DeprecatedAt IS NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_PackOut_ActiveDefault' AND object_id = OBJECT_ID(N'Parts.PackOut'))
    CREATE UNIQUE INDEX UQ_PackOut_ActiveDefault ON Parts.PackOut (ItemId, ClosureMethod)
        WHERE IsDefault = 1 AND DeprecatedAt IS NULL;
GO

-- ---------------- Parts.ContainerConfig -> versions ----------------
IF COL_LENGTH(N'Parts.ContainerConfig', N'PackOutId') IS NULL
    ALTER TABLE Parts.ContainerConfig ADD PackOutId BIGINT NULL;
IF COL_LENGTH(N'Parts.ContainerConfig', N'VersionNumber') IS NULL
    ALTER TABLE Parts.ContainerConfig ADD VersionNumber INT NULL;
IF COL_LENGTH(N'Parts.ContainerConfig', N'CreatedByUserId') IS NULL
    ALTER TABLE Parts.ContainerConfig ADD CreatedByUserId BIGINT NULL
        CONSTRAINT FK_ContainerConfig_CreatedBy REFERENCES Location.AppUser(Id);
GO

-- Backfill: one header per (ItemId, ClosureMethod) group that has no header yet.
IF EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE PackOutId IS NULL)
BEGIN
    ;WITH g AS (
        SELECT cc.ItemId, cc.ClosureMethod,
               MIN(cc.CreatedAt) AS FirstAt,
               MAX(CASE WHEN cc.DeprecatedAt IS NULL THEN 1 ELSE 0 END) AS HasActive,
               MAX(cc.DeprecatedAt) AS LastDeprecatedAt
        FROM Parts.ContainerConfig cc
        WHERE cc.PackOutId IS NULL
        GROUP BY cc.ItemId, cc.ClosureMethod
    )
    INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedAt, CreatedByUserId, DeprecatedAt)
    SELECT g.ItemId, g.ClosureMethod, m.Name,
           CAST(g.HasActive AS BIT), g.FirstAt, 1,
           CASE WHEN g.HasActive = 1 THEN NULL ELSE g.LastDeprecatedAt END
    FROM g
    JOIN Parts.ClosureMethodCode m ON m.Code = g.ClosureMethod;

    UPDATE cc
    SET PackOutId = p.Id,
        VersionNumber = v.Rn
    FROM Parts.ContainerConfig cc
    JOIN (SELECT Id, ROW_NUMBER() OVER (PARTITION BY ItemId, ClosureMethod ORDER BY CreatedAt, Id) AS Rn
          FROM Parts.ContainerConfig WHERE PackOutId IS NULL) v ON v.Id = cc.Id
    JOIN Parts.PackOut p ON p.ItemId = cc.ItemId AND p.ClosureMethod = cc.ClosureMethod;
END
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Parts.ContainerConfig') AND name = N'PackOutId' AND is_nullable = 1)
    ALTER TABLE Parts.ContainerConfig ALTER COLUMN PackOutId BIGINT NOT NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Parts.ContainerConfig') AND name = N'VersionNumber' AND is_nullable = 1)
    ALTER TABLE Parts.ContainerConfig ALTER COLUMN VersionNumber INT NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ContainerConfig_PackOut')
    ALTER TABLE Parts.ContainerConfig ADD CONSTRAINT FK_ContainerConfig_PackOut
        FOREIGN KEY (PackOutId) REFERENCES Parts.PackOut(Id);
-- The one-per-(item, method) rule is what this feature removes.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerConfig_ActiveItemMethod' AND object_id = OBJECT_ID(N'Parts.ContainerConfig'))
    DROP INDEX UQ_ContainerConfig_ActiveItemMethod ON Parts.ContainerConfig;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerConfig_ActivePackOut' AND object_id = OBJECT_ID(N'Parts.ContainerConfig'))
    CREATE UNIQUE INDEX UQ_ContainerConfig_ActivePackOut ON Parts.ContainerConfig (PackOutId)
        INCLUDE (ItemId, ClosureMethod, VersionNumber, PartsPerTray, TraysPerContainer, TargetWeight,
                 ToleranceWeight, IsSerialized, DunnageCode, CustomerCode)
        WHERE DeprecatedAt IS NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerConfig_PackOutVersion' AND object_id = OBJECT_ID(N'Parts.ContainerConfig'))
    CREATE UNIQUE INDEX UQ_ContainerConfig_PackOutVersion ON Parts.ContainerConfig (PackOutId, VersionNumber);
GO

-- ---------------- Location.TerminalPackOutSelection ----------------
IF OBJECT_ID(N'Location.TerminalPackOutSelection', N'U') IS NULL
BEGIN
    CREATE TABLE Location.TerminalPackOutSelection (
        Id                 BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_TerminalPackOutSelection PRIMARY KEY,
        TerminalLocationId BIGINT        NOT NULL
                           CONSTRAINT FK_TerminalPackOutSelection_Terminal REFERENCES Location.Location(Id),
        ItemId             BIGINT        NOT NULL,   -- copied from the header (no FK: cascade path via PackOut)
        ClosureMethod      NVARCHAR(20)  NOT NULL,   -- copied from the header
        PackOutId          BIGINT        NOT NULL
                           CONSTRAINT FK_TerminalPackOutSelection_PackOut REFERENCES Parts.PackOut(Id) ON DELETE CASCADE,
        SetByUserId        BIGINT        NOT NULL
                           CONSTRAINT FK_TerminalPackOutSelection_SetBy REFERENCES Location.AppUser(Id),
        SetAt              DATETIME2(3)  NOT NULL CONSTRAINT DF_TerminalPackOutSelection_SetAt DEFAULT SYSUTCDATETIME()
    );
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_TerminalPackOutSelection' AND object_id = OBJECT_ID(N'Location.TerminalPackOutSelection'))
    CREATE UNIQUE INDEX UQ_TerminalPackOutSelection ON Location.TerminalPackOutSelection (TerminalLocationId, ItemId, ClosureMethod)
        INCLUDE (PackOutId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_TerminalPackOutSelection_PackOut' AND object_id = OBJECT_ID(N'Location.TerminalPackOutSelection'))
    CREATE INDEX IX_TerminalPackOutSelection_PackOut ON Location.TerminalPackOutSelection (PackOutId);
GO

-- ---------------- Audit codes (plain-PK pattern of 0111 / 0135) ----------------
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'PackOut')
BEGIN
    DECLARE @EntId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@EntId, N'PackOut', N'Pack-out', N'Parts.PackOut - a named pack-out (container type) of a part for one closure method; its values live in versioned Parts.ContainerConfig rows.');
END
GO
DECLARE @Ev TABLE (Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500));
INSERT INTO @Ev VALUES
 (N'PackOutCreated',    N'Pack-Out Created',     N'A named pack-out was created (Parts.PackOut_Save).'),
 (N'PackOutVersioned',  N'Pack-Out Versioned',   N'A pack-out''s values changed: the active version was retired and a new version saved (Parts.PackOut_Save).'),
 (N'PackOutRenamed',    N'Pack-Out Renamed',     N'A pack-out''s name changed (Parts.PackOut_Save).'),
 (N'PackOutDefaultSet', N'Pack-Out Default Set', N'A pack-out became its part''s default for the closure method (Parts.PackOut_SetDefault).'),
 (N'PackOutDeprecated', N'Pack-Out Removed',     N'A pack-out was removed (Parts.PackOut_Deprecate).'),
 (N'PackOutSelected',   N'Pack-Out Selected',    N'A terminal''s running pack-out for a part was changed (Location.Terminal_SetPackOut).');
DECLARE @Code NVARCHAR(50), @Name NVARCHAR(100), @Desc NVARCHAR(500), @NextId BIGINT;
DECLARE ev CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Name, Description FROM @Ev;
OPEN ev; FETCH NEXT FROM ev INTO @Code, @Name, @Desc;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = @Code)
    BEGIN
        SET @NextId = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
        INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (@NextId, @Code, @Name, @Desc);
    END
    FETCH NEXT FROM ev INTO @Code, @Name, @Desc;
END
CLOSE ev; DEALLOCATE ev;
GO

-- ---------------- Retired procs (replaced by Parts.PackOut_*) ----------------
DROP PROCEDURE IF EXISTS Parts.ContainerConfig_Create;
DROP PROCEDURE IF EXISTS Parts.ContainerConfig_Update;
DROP PROCEDURE IF EXISTS Parts.ContainerConfig_Deprecate;
DROP PROCEDURE IF EXISTS Parts.ContainerConfig_GetByItem;
DROP PROCEDURE IF EXISTS Parts.ContainerConfig_ListHistory;
GO

-- ---------------- Landed? ----------------
IF OBJECT_ID(N'Parts.PackOut', N'U') IS NULL OR OBJECT_ID(N'Location.TerminalPackOutSelection', N'U') IS NULL
    THROW 51000, 'Migration 0136: pack-out tables did not land.', 1;
IF EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE PackOutId IS NULL)
    THROW 51000, 'Migration 0136: a ContainerConfig row has no PackOut.', 1;
IF (SELECT COUNT(*) FROM Audit.LogEventType WHERE Code LIKE N'PackOut%') <> 6
    THROW 51000, 'Migration 0136: LogEventType rows did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0136_named_pack_outs')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0136_named_pack_outs',
            N'Parts.PackOut (named pack-out per part + method, one default) with Parts.ContainerConfig rows as its versions (PackOutId, VersionNumber); Location.TerminalPackOutSelection; backfill one default header per existing (item, method). Drops ContainerConfig_Create/Update/Deprecate/GetByItem/ListHistory. Apply with Parts.PackOut_* + the pack-out-in-force readers.');
GO
PRINT 'Migration 0136 (named_pack_outs) applied.';
GO
