-- ============================================================
-- Migration:   0074_diecast_counter_anchor.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-10
-- Description: Die-cast COUNTER ANCHOR (spec
--              docs/superpowers/specs/2026-09-10-diecast-counter-anchor-design.md).
--              Closes spec 2026-09-09 edge cases E3 (reading goes backwards)
--              and E4 (counter reset mid-shift), which shipped as a hard wall
--              with no way past it.
--
--              THE PROBLEM. Both watermarks are MAX(ShotCounterReading) over
--              a shift, and a reading below the DIE watermark is rejected --
--              by Lots.DieCastLot_Release, by
--              Workorder.DieCastShiftOutput_Record, and at the Release
--              dialog's button. That is right for a typo. It is wrong for the
--              two cases the floor actually hits:
--                * the press counter was reset mid-shift (power loss,
--                  maintenance) and now genuinely reads a smaller number;
--                * a WRONG reading was entered earlier and has poisoned the
--                  watermark, so every subsequent release on that die is
--                  blocked for the rest of the shift.
--              A MAX cannot be lowered by appending, so there was no way out
--              of either without editing the ledger.
--
--              THE FIX. One new recorded fact -- an operator declaration that
--              "as of now, this press counter reads N" -- which becomes a
--              FLOOR under both watermarks:
--
--                  watermark = MAX( anchor.DeclaredReading,
--                                   MAX(reading) over contributions recorded
--                                       AFTER the anchor,
--                                   0 )
--
--              With no anchor this is byte-for-byte the pre-change behaviour.
--
--              FLOORING EVERY CAVITY AT THE ANCHOR IS THE POINT. Declaring a
--              reading re-anchors the die AND every cavity on it -- including
--              cavities with no open basket, which a DieCastContribution row
--              could never reach (LotId is NOT NULL, 0045). A counter reset is
--              simply DeclaredReading = 0; it needs no special case.
--
--              APPEND-ONLY AND FORWARD-ONLY. Nothing recorded is rewritten.
--              An anchor sets where crediting RESUMES from; pieces already
--              credited to baskets by a superseded reading stay where they
--              are, and so does the Tools.Tool.ShotCount those readings
--              advanced. The operator-facing dialog says so in as many words
--              -- see the spec, "What this deliberately does not fix".
--
--              Additive. Idempotent-guarded; no explicit transaction (repo
--              convention -- see 0067, 0073).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0074_diecast_counter_anchor')
BEGIN
    PRINT 'Migration 0074 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Workorder.DieCastCounterAnchorReason -- why the counter moved
--    Code-table backed per repo convention: no free-text reason, no magic
--    integers. 'Other' carries the operator's note and nothing else.
-- ============================================================
IF OBJECT_ID(N'Workorder.DieCastCounterAnchorReason', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.DieCastCounterAnchorReason (
        Id          BIGINT         NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Code        NVARCHAR(30)   NOT NULL,
        Name        NVARCHAR(100)  NOT NULL,
        Description NVARCHAR(500)  NULL,
        SortOrder   INT            NOT NULL CONSTRAINT DF_DieCastCounterAnchorReason_SortOrder DEFAULT (0),
        CONSTRAINT UQ_DieCastCounterAnchorReason_Code UNIQUE (Code)
    );

    SET IDENTITY_INSERT Workorder.DieCastCounterAnchorReason ON;
    INSERT INTO Workorder.DieCastCounterAnchorReason (Id, Code, Name, Description, SortOrder) VALUES
        (1, N'CounterReset',        N'The counter was reset',
            N'The press counter was zeroed or rolled over mid-shift (power loss, maintenance, controller swap). The declared reading is what it shows now.', 10),
        (2, N'WrongReadingEntered', N'A wrong reading was entered earlier',
            N'An earlier entry recorded a number that was not the counter reading, and it has blocked this die for the rest of the shift. The declared reading is the true one.', 20),
        (3, N'DieChangeover',       N'The die was changed over',
            N'A different die ran on this press earlier in the shift, so the counter carries its shots. The declared reading re-bases this die on the counter as it stands.', 30),
        (4, N'Other',               N'Other -- see the note',
            N'Anything else. The note is required and is the only record of why.', 90);
    SET IDENTITY_INSERT Workorder.DieCastCounterAnchorReason OFF;
END
GO

-- ============================================================
-- 2. Workorder.DieCastCounterAnchor -- the declaration itself
--
--    Scoped (ToolId, ShiftId, CellLocationId) -- the SAME three-part key the
--    watermarks use. Scoping by PRESS is load-bearing for the identical
--    reason it is on the contribution ledger: a die moved to another press is
--    a different counter space, and a changeover to another die on the same
--    press has different ToolCavity rows. See
--    R__Workorder_ufn_CavityShotWatermark.sql.
--
--    Append-only: superseding an anchor means recording a later one. There is
--    no UPDATE path and no DeprecatedAt -- the chain of declarations IS the
--    history, and Audit.OperationLog carries the same events for the browser.
-- ============================================================
IF OBJECT_ID(N'Workorder.DieCastCounterAnchor', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.DieCastCounterAnchor (
        Id                 BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        ToolId             BIGINT       NOT NULL REFERENCES Tools.Tool(Id),
        ShiftId            BIGINT       NOT NULL REFERENCES Oee.Shift(Id),
        CellLocationId     BIGINT       NULL     REFERENCES Location.Location(Id),
        DeclaredReading    INT          NOT NULL,
        ReasonId           BIGINT       NOT NULL REFERENCES Workorder.DieCastCounterAnchorReason(Id),
        Note               NVARCHAR(500) NULL,
        AppUserId          BIGINT       NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT       NULL     REFERENCES Location.Location(Id),
        EventAt            DATETIME2(3) NOT NULL CONSTRAINT DF_DieCastCounterAnchor_EventAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_DieCastCounterAnchor_ReadingNonNeg CHECK (DeclaredReading >= 0)
    );

    -- The watermark functions read the LATEST anchor for the three-part key,
    -- then the contributions recorded after it -- so this index is the whole
    -- access path for both.
    CREATE NONCLUSTERED INDEX IX_DieCastCounterAnchor_Scope
        ON Workorder.DieCastCounterAnchor (ToolId, ShiftId, CellLocationId, EventAt DESC, Id DESC)
        INCLUDE (DeclaredReading);
END
GO

-- ============================================================
-- 3. Audit vocabulary
--    Entity type is the existing 'Tool' (31): an anchor is a statement about
--    a die on a press, not about any one LOT. Event type is new.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'DieCastCounterAnchored')
BEGIN
    DECLARE @nextId INT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@nextId, N'DieCastCounterAnchored', N'Die Cast Counter Anchored',
            N'An operator declared the true press-counter reading for a die on a press in a shift, re-anchoring both shot watermarks from that point forward.');
END
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0074_diecast_counter_anchor')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0074_diecast_counter_anchor',
        N'Die-cast counter anchor: Workorder.DieCastCounterAnchor + DieCastCounterAnchorReason code table + DieCastCounterAnchored audit event. An operator declaration of the true press-counter reading becomes a FLOOR under both shot watermarks, scoped (ToolId, ShiftId, CellLocationId), so a mid-shift counter reset or a wrong reading entered earlier can be corrected without editing the append-only contribution ledger. Forward-only: pieces and ShotCount already credited are not reversed.'
    );
GO

PRINT 'Migration 0074 completed: Workorder.DieCastCounterAnchor.';
GO
