-- ============================================================
-- Repeatable:  R__Lots_SerializedPart_Mint.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Mints a laser-etched SerializedPart (Arc 2 Phase 6 assembly).
--              SerialNumber is minted from the 'SerializedItem' IdentifierSequence
--              INLINE (row-locked, gap-free) rather than via INSERT-EXEC of
--              Lots.IdentifierSequence_Next -- this proc is captured via INSERT-EXEC
--              by callers/tests and nesting INSERT-EXEC is illegal; the inline mint
--              mirrors IdentifierSequence_Next and runs in this proc's transaction
--              so a rollback un-burns the counter (B6/B15). EtchedByUserId is NOT
--              NULL (PLC flow passes the system AppUser). No separate OperationLog
--              event -- the audited events are the downstream ContainerSerialAdded +
--              ConsumptionEvent + genealogy that carry the trace. No OUTPUT params
--              (FDS-11-011); single terminal SELECT @Status,@Message,@NewId,
--              @SerialNumber. RAISERROR (not THROW) in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.SerializedPart_Mint
    @ItemId             BIGINT,
    @ProducingLotId     BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status       BIT           = 0;
    DECLARE @Message      NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId        BIGINT        = NULL;
    DECLARE @SerialNumber NVARCHAR(50)  = NULL;

    DECLARE @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT;

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @ItemId IS NULL OR @ProducingLotId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ItemId, ProducingLotId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @SerialNumber AS SerialNumber;
            RETURN;
        END

        -- ---- Tier 2: referential validation ----
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId)
        BEGIN
            SET @Message = N'Item not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @SerialNumber AS SerialNumber;
            RETURN;
        END
        IF NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @ProducingLotId)
        BEGIN
            SET @Message = N'Producing LOT not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @SerialNumber AS SerialNumber;
            RETURN;
        END

        -- ---- Mutation (atomic): inline 'SerializedItem' mint + insert ----
        BEGIN TRANSACTION;

        SELECT @SeqLast   = s.LastValue + 1,
               @SeqEnd    = s.EndingValue,
               @SeqFormat = s.FormatString
        FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        WHERE s.Code = N'SerializedItem';

        IF @SeqLast IS NULL
            RAISERROR(N'Identifier sequence ''SerializedItem'' is not configured.', 16, 1);
        IF @SeqLast > @SeqEnd
            RAISERROR(N'Identifier sequence ''SerializedItem'' is exhausted.', 16, 1);

        UPDATE Lots.IdentifierSequence
        SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME()
        WHERE Code = N'SerializedItem';

        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0
                              THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1)
                              ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(
            SUBSTRING(@SeqFormat,
                      CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                      CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1)
            AS INT);
        SET @SerialNumber = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
            THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
            ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId)
        VALUES (@SerialNumber, @ItemId, @ProducingLotId, SYSUTCDATETIME(), @AppUserId);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Serialized part ' + @SerialNumber + N' minted.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @SerialNumber AS SerialNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();

        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId = NULL;
        SET @SerialNumber = NULL;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @SerialNumber AS SerialNumber;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
