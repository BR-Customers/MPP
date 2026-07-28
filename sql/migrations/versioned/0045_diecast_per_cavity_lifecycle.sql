SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- 1. Open status (append; do NOT renumber 1-4). Let IDENTITY assign the next Id.
IF NOT EXISTS (SELECT 1 FROM Lots.LotStatusCode WHERE Code = N'Open')
    INSERT INTO Lots.LotStatusCode (Code, Name, BlocksProduction)
    VALUES (N'Open', N'Open', 0);

-- 2. DieCastContribution ledger
IF OBJECT_ID(N'Workorder.DieCastContribution', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.DieCastContribution (
        Id                 BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        LotId              BIGINT       NOT NULL REFERENCES Lots.Lot(Id),
        ShiftId            BIGINT       NULL     REFERENCES Oee.Shift(Id),
        PieceDelta         INT          NOT NULL,
        AppUserId          BIGINT       NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT       NULL     REFERENCES Location.Location(Id),
        EventAt            DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_DieCastContribution_DeltaNonNeg CHECK (PieceDelta >= 0)
    );
    CREATE INDEX IX_DieCastContribution_Lot   ON Workorder.DieCastContribution (LotId);
    CREATE INDEX IX_DieCastContribution_Shift ON Workorder.DieCastContribution (ShiftId, LotId);
END

-- 3. Audit LogEventTypes (Id-or-Code guarded; take the next free ids at build time)
DECLARE @nextId INT = (SELECT ISNULL(MAX(Id),0) + 1 FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @nextId + ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1, v.Code, v.Name, v.Descr
FROM (VALUES
    (N'DieCastLotOpened',        N'Die Cast LOT Opened',       N'A die-cast accumulator basket LOT was opened (status Open).'),
    (N'DieCastPieceContributed', N'Die Cast Piece Contributed',N'Good pieces added to an open die-cast basket for a shift.'),
    (N'DieCastLotReleased',      N'Die Cast LOT Released',      N'An open die-cast basket was released to storage (Open->Good).'),
    (N'DieCastLotVoided',        N'Die Cast LOT Voided',        N'An empty open die-cast basket was voided (Open->Scrap).')
) v(Code, Name, Descr)
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType e WHERE e.Code = v.Code);

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES ('0045_diecast_per_cavity_lifecycle',
        'Die-cast per-cavity lifecycle: Open LotStatusCode, Workorder.DieCastContribution ledger, 4 audit LogEventTypes.');
COMMIT TRANSACTION;
PRINT 'Migration 0045 completed.';
