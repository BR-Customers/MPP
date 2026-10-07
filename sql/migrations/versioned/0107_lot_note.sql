-- ============================================================
-- Migration:   0107_lot_note.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Description: Lots.LotNote -- free-text notes against a LOT, written from the
--              LOT Detail "Notes" tab.
--
--   APPEND-ONLY. There is no edit and no delete, and no proc offers either. A
--   note is a statement somebody made about a Honda-traceable LOT at a moment
--   in time; correcting one means writing another.
--
--   ANY SIGNED-IN USER MAY WRITE ONE (decided with Jacques 2026-10-06). A note
--   changes nothing about the LOT -- not status, not quantity, not location --
--   so it is not a protected action. If a note should stop a LOT, that is a
--   Hold, which is already gated.
--
--   WHY SO MUCH CONTEXT. A PIN is an identifier, not a credential, so the
--   AppUserId on a note is only as strong as the PIN sign-in behind it. The
--   answer to weak attribution is evidence, not a gate, so each note carries:
--
--     * typed columns for what is displayed and queried: who, which terminal,
--       whether an elevation window was open (during one, AppUserId is the
--       supervisor BY DESIGN -- see Common.Session.beginElevatedWindow);
--     * a SNAPSHOT of the LOT at that moment (status, location, piece count),
--       read by the proc itself so the client cannot get it wrong. "Basket
--       looks short" only means something next to where the LOT was and what
--       it held, and the LOT moves on;
--     * ContextJson -- the session and screen the note came from, curated by
--       BlueRidge.Lots.LotNote.buildContext. Deliberately NOT a dump of the
--       LOT Detail view's custom props: those are copies of rows this database
--       already holds and can re-read as of CreatedAt.
--
--   NO Audit.* ROWS. The table is itself the append-only, attributed record;
--   an audit row per note would say the same thing twice. Consequence: notes
--   do not appear in the LOT history timeline (Lots.LotEventLog) today.
--
--   Not partitioned: notes are human-typed and low volume, and they must live
--   as long as the LOT they describe.
-- ============================================================
IF OBJECT_ID(N'Lots.LotNote', N'U') IS NOT NULL
BEGIN
    PRINT 'Migration 0107: Lots.LotNote already present -- no change.';
END
ELSE
BEGIN
    CREATE TABLE Lots.LotNote (
        Id                 BIGINT          NOT NULL IDENTITY(1,1)
            CONSTRAINT PK_LotNote PRIMARY KEY,
        LotId              BIGINT          NOT NULL
            CONSTRAINT FK_LotNote_Lot REFERENCES Lots.Lot(Id),
        NoteText           NVARCHAR(1000)  NOT NULL,
        AppUserId          BIGINT          NOT NULL
            CONSTRAINT FK_LotNote_AppUser REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT          NULL
            CONSTRAINT FK_LotNote_Terminal REFERENCES Location.Location(Id),
        WasElevated        BIT             NOT NULL
            CONSTRAINT DF_LotNote_WasElevated DEFAULT (0),
        -- Snapshot of the LOT when the note was written.
        LotStatusId        BIGINT          NOT NULL
            CONSTRAINT FK_LotNote_LotStatus REFERENCES Lots.LotStatusCode(Id),
        LotLocationId      BIGINT          NOT NULL
            CONSTRAINT FK_LotNote_LotLocation REFERENCES Location.Location(Id),
        LotPieceCount      INT             NOT NULL,
        ContextJson        NVARCHAR(MAX)   NULL
            CONSTRAINT CK_LotNote_ContextJson CHECK (ContextJson IS NULL OR ISJSON(ContextJson) = 1),
        CreatedAt          DATETIME2(3)    NOT NULL
            CONSTRAINT DF_LotNote_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_LotNote_NoteText CHECK (LEN(LTRIM(RTRIM(NoteText))) > 0)
    );

    CREATE INDEX IX_LotNote_LotId_CreatedAt ON Lots.LotNote (LotId, CreatedAt DESC, Id DESC);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Append-only free-text notes against a LOT (LOT Detail Notes tab). No edit, no delete. Carries who/where, a snapshot of the LOT at write time, and the session context.',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'LotNote';
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'1 when an AD elevation window was open; AppUserId is then the supervisor, by design.',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'LotNote',
        @level2type = N'COLUMN', @level2name = N'WasElevated';
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'LOT status when the note was written (snapshot, stamped by Lots.LotNote_Add).',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'LotNote',
        @level2type = N'COLUMN', @level2name = N'LotStatusId';
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Where the LOT was when the note was written (snapshot of Lot.CurrentLocationId).',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'LotNote',
        @level2type = N'COLUMN', @level2name = N'LotLocationId';
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Lot.PieceCount when the note was written (snapshot).',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'LotNote',
        @level2type = N'COLUMN', @level2name = N'LotPieceCount';
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Session and screen context as JSON, curated by BlueRidge.Lots.LotNote.buildContext. Evidence only; nothing reads it for behaviour.',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'LotNote',
        @level2type = N'COLUMN', @level2name = N'ContextJson';

    PRINT 'Migration 0107: Lots.LotNote created.';
END
GO

IF OBJECT_ID(N'Lots.LotNote', N'U') IS NULL
    THROW 51000, 'Migration 0107: Lots.LotNote did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0107_lot_note')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0107_lot_note',
            N'Lots.LotNote: append-only free-text notes against a LOT, with who/terminal/elevation, a snapshot of the LOT at write time, and session ContextJson. Apply with Lots.LotNote_Add v1.0 and Lots.LotNote_ListByLot v1.0.');
GO
PRINT 'Migration 0107 (lot_note) applied.';
GO
