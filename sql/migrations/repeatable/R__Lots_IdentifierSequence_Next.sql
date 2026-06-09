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
--
--              TRANSACTION SEMANTICS (Fix 6, holistic review): this proc holds
--              NO explicit transaction of its own. The earlier draft wrapped the
--              read-modify in BEGIN/COMMIT/ROLLBACK TRANSACTION; that was unsafe
--              when called inside a caller's (ambient) transaction because the
--              bare ROLLBACK on a breach path would unwind the caller's ENTIRE
--              outer transaction (and under XACT_ABORT ON a breach RAISERROR
--              already dooms the whole transaction regardless, so a savepoint
--              cannot rescue it either). The explicit transaction is in fact
--              UNNECESSARY: the increment is now done as a SINGLE atomic
--              UPDATE ... WITH (ROWLOCK, UPDLOCK, HOLDLOCK) ... OUTPUT, so there
--              is no SELECT-then-UPDATE window that needs a transaction to hold
--              the lock across statements. The lone UPDATE is atomic on its own,
--              gap-free, and composes cleanly with ANY ambient transaction:
--                * Inside a caller's tran (the Lot_Create-style pattern) the
--                  UPDATE enlists in that tran, so a caller ROLLBACK un-burns the
--                  counter — the whole point of B6 — with no nesting hazard.
--                * Standalone (Ignition autocommit) the UPDATE is its own atomic
--                  unit; the row lock is held for the statement, which is all the
--                  gap-free guarantee requires.
--              The exhaustion breach is enforced in the UPDATE's WHERE
--              (LastValue + 1 <= EndingValue): on breach zero rows update, nothing
--              is persisted, and we RAISERROR. Unknown @Code is distinguished from
--              exhaustion by a prior existence check.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.IdentifierSequence_Next
    @Code NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Last         BIGINT,
            @Format       NVARCHAR(50),
            @Prefix       NVARCHAR(50),
            @Pad          INT,
            @Value        NVARCHAR(50);

    -- Captures the post-increment LastValue + FormatString from the atomic UPDATE.
    DECLARE @Minted TABLE (NewLast BIGINT, Format NVARCHAR(50));

    BEGIN TRY
        -- Distinguish "unknown code" (raise) from "exhausted" (also raise, but a
        -- different message + the row exists). The atomic UPDATE below cannot tell
        -- the two apart (both update zero rows), so check existence first.
        IF NOT EXISTS (SELECT 1 FROM Lots.IdentifierSequence WHERE Code = @Code)
        BEGIN
            RAISERROR(N'Unknown identifier sequence code: %s', 16, 1, @Code);
            RETURN;
        END

        -- Single ATOMIC increment + breach guard. The WHERE clause's
        -- (LastValue + 1 <= EndingValue) predicate means an exhausted sequence
        -- updates ZERO rows (nothing persisted), keeping the counter gap-free and
        -- never advancing past EndingValue. ROWLOCK/UPDLOCK/HOLDLOCK serialize
        -- concurrent minters on the single row. OUTPUT hands back the new value +
        -- format without a second read. No explicit transaction: this lone UPDATE
        -- is atomic and enlists in the caller's ambient tran when there is one.
        UPDATE Lots.IdentifierSequence WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        SET LastValue = LastValue + 1,
            UpdatedAt = SYSUTCDATETIME()
        OUTPUT inserted.LastValue, inserted.FormatString INTO @Minted (NewLast, Format)
        WHERE Code = @Code
          AND LastValue + 1 <= EndingValue;

        SELECT @Last = NewLast, @Format = Format FROM @Minted;

        IF @Last IS NULL
        BEGIN
            -- Zero rows updated but the code exists -> rollover breach.
            DECLARE @EndVal BIGINT = (SELECT EndingValue FROM Lots.IdentifierSequence WHERE Code = @Code);
            RAISERROR(N'Identifier sequence %s exhausted at ending value %I64d.', 16, 1, @Code, @EndVal);
            RETURN;
        END

        -- Parse the .NET FormatString '<PREFIX>{0:D<N>}' -> prefix + pad width.
        SET @Prefix = CASE WHEN CHARINDEX(N'{', @Format) > 0
                           THEN LEFT(@Format, CHARINDEX(N'{', @Format) - 1)
                           ELSE @Format END;

        SET @Pad = TRY_CAST(
            SUBSTRING(
                @Format,
                CHARINDEX(N'D', @Format, CHARINDEX(N'{', @Format)) + 1,
                CHARINDEX(N'}', @Format, CHARINDEX(N'{', @Format)) - CHARINDEX(N'D', @Format, CHARINDEX(N'{', @Format)) - 1
            ) AS INT);

        -- Defensive: if the format has no D-pad token, fall back to no padding.
        IF @Pad IS NULL OR @Pad < 1
            SET @Value = @Prefix + CAST(@Last AS NVARCHAR(20));
        ELSE
            SET @Value = @Prefix + RIGHT(REPLICATE(N'0', @Pad) + CAST(@Last AS NVARCHAR(20)), @Pad);

        SELECT @Value AS Value;
    END TRY
    BEGIN CATCH
        -- This proc owns no transaction, so there is nothing to roll back here:
        -- the breach / unknown-code paths RAISERROR + RETURN above, and the lone
        -- atomic UPDATE either fully applied or (on an unexpected error under
        -- XACT_ABORT ON) was rolled back by the engine within whatever transaction
        -- context the caller supplied. We simply re-surface the error. If a caller
        -- ambient transaction is doomed (XACT_STATE() = -1) it is the CALLER's
        -- responsibility to roll back — we do NOT touch the caller's tran.
        -- RAISERROR (not THROW) per project convention.
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
