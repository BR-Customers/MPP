-- ============================================================
-- Repeatable:  R__Lots_IdentifierSequence_Next.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: B6 row-locked, gap-free identifier minting. Atomically
--              increments Lots.IdentifierSequence.LastValue under a
--              ROWLOCK/UPDLOCK/HOLDLOCK and returns the formatted string
--              (e.g. 'MESL3000001' from FormatString 'MESL{0:D7}').
--
--              Designed to be called INSIDE the caller's transaction
--              (e.g. Lot_Create): a rolled-back caller un-burns the
--              counter - the whole point of the row-lock approach over a
--              SQL SEQUENCE object.
--
--              Single result set: Value NVARCHAR(50) (Ignition JDBC
--              single-result-set convention, FDS-11-011). No OUTPUT params.
--
--              Raises (RAISERROR) on unknown @Code and on rollover breach
--              (next value would exceed EndingValue); on breach the
--              increment is NOT persisted (the row lock + pre-check keep the
--              sequence gap-free and prevent a stuck one-past-end state).
--
--              FormatString is parsed as the .NET pattern '<PREFIX>{0:D<N>}'
--              - text before '{' is the literal prefix, the integer after
--              'D' is the zero-pad width. (DM section 3 retains FormatString rather
--              than separate Prefix/Padding columns.)
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.IdentifierSequence_Next
    @Code NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Last         BIGINT,
            @End          BIGINT,
            @Format       NVARCHAR(50),
            @Prefix       NVARCHAR(50),
            @Pad          INT,
            @Value        NVARCHAR(50);

    -- Row-locked read-modify within an explicit tran so a breach can be
    -- rolled back atomically (and so the lock is held only as briefly as
    -- the increment needs when this proc is called standalone).
    BEGIN TRANSACTION;

    -- Acquire the row lock and capture current state. We compute the NEXT
    -- value as @Last but do NOT persist the increment until the breach
    -- check passes.
    SELECT @Last   = s.LastValue + 1,
           @End    = s.EndingValue,
           @Format = s.FormatString
    FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
    WHERE s.Code = @Code;

    IF @Last IS NULL
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(N'Unknown identifier sequence code: %s', 16, 1, @Code);
        RETURN;
    END

    IF @Last > @End
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(N'Identifier sequence %s exhausted at ending value %I64d.', 16, 1, @Code, @End);
        RETURN;
    END

    -- Persist the increment (gap-free).
    UPDATE Lots.IdentifierSequence
    SET LastValue = @Last,
        UpdatedAt = SYSUTCDATETIME()
    WHERE Code = @Code;

    COMMIT TRANSACTION;

    -- Parse the .NET FormatString '<PREFIX>{0:D<N>}' -> prefix + pad width.
    SET @Prefix = CASE WHEN CHARINDEX(N'{', @Format) > 0
                       THEN LEFT(@Format, CHARINDEX(N'{', @Format) - 1)
                       ELSE @Format END;

    SET @Pad = TRY_CAST(
        SUBSTRING(
            @Format,
            CHARINDEX(N'D', @Format, CHARINDEX(N'{', @Format)) + 1,
            CHARINDEX(N'}', @Format) - CHARINDEX(N'D', @Format, CHARINDEX(N'{', @Format)) - 1
        ) AS INT);

    -- Defensive: if the format has no D-pad token, fall back to no padding.
    IF @Pad IS NULL OR @Pad < 1
        SET @Value = @Prefix + CAST(@Last AS NVARCHAR(20));
    ELSE
        SET @Value = @Prefix + RIGHT(REPLICATE(N'0', @Pad) + CAST(@Last AS NVARCHAR(20)), @Pad);

    SELECT @Value AS Value;
END;
GO
