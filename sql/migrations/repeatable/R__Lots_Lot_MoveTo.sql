-- ============================================================
-- Repeatable:  R__Lots_Lot_MoveTo.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Moves a LOT to a new location: updates Lots.Lot.CurrentLocationId
--              and appends a Lots.LotMovement row (FromLocationId = prior,
--              ToLocationId = new). Audits 'LotMoved'.
--
--              B2: rejects a blocked LOT FIRST (Hold/Scrap/Closed). The block
--              determination mirrors Lots.Lot_AssertNotBlocked exactly and is
--              evaluated INLINE here (Lot_AssertNotBlocked returns a result set;
--              this proc is itself invoked via INSERT-EXEC, and nesting
--              INSERT-EXEC of the guard is illegal). Lot_AssertNotBlocked
--              remains the standalone guard for the Ignition layer / other
--              callers per the B2 contract.
--
--              B1 context params; no OUTPUT params; every exit ends
--              SELECT @Status, @Message; RAISERROR in nested CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_MoveTo
    @LotId              BIGINT,
    @ToLocationId       BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_MoveTo';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @ToLocationId AS ToLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @FromLocationId BIGINT;
    DECLARE @StatusCode     NVARCHAR(20);
    DECLARE @StatusName     NVARCHAR(100);
    DECLARE @Blocks         BIT;

    BEGIN TRY
        IF @LotId IS NULL OR @ToLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, ToLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @FromLocationId = l.CurrentLocationId,
               @StatusCode     = sc.Code,
               @StatusName     = sc.Name,
               @Blocks         = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @StatusCode IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- B2 guard (mirrors Lots.Lot_AssertNotBlocked).
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot be moved.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @ToLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Destination location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ToLocationId = @FromLocationId
        BEGIN
            SET @Message = N'LOT is already at the destination location (no-op).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        DECLARE @LotName  NVARCHAR(50)  = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
        DECLARE @FromName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @FromLocationId);
        DECLARE @ToName   NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @ToLocationId);

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @FromLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @ToLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Movement ' + Audit.ufn_MidDot()
            + N' ' + ISNULL(@FromName, N'(none)') + NCHAR(8594) + @ToName;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        BEGIN TRANSACTION;

        UPDATE Lots.Lot
        SET CurrentLocationId = @ToLocationId,
            UpdatedAt         = SYSUTCDATETIME(),
            UpdatedByUserId   = @AppUserId
        WHERE Id = @LotId;

        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@LotId, @FromLocationId, @ToLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @ToLocationId,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'LotMoved',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT moved to ' + @ToName + N'.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
