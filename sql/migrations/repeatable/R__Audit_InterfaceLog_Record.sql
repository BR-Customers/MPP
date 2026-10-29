-- =============================================
-- Procedure:   Audit.InterfaceLog_Record
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
--
-- Description:
--   Writes one Audit.InterfaceLog row and RETURNS ITS ID -- the status-row twin
--   of Audit.Audit_LogInterfaceCall, for callers that need the new Id back.
--   First caller: BlueRidge.Lots.AimHttp, which hands the id to the AIM
--   failure row in Audit.FailureLog (AttemptedParameters.interfaceLogId) and to
--   Lots.AimShipperIdPool.FetchedInterfaceLogId.
--
--   WHY A SEPARATE PROC. Audit_LogInterfaceCall must keep emitting NO result
--   set: Lots.LotLabel_RecordDispatch EXECs it from inside SQL. The INSERT is
--   INLINED here (it mirrors Audit_LogInterfaceCall v1.1 -- keep the column
--   lists and the payload/fidelity rule in step).
--
-- Parameters: identical to Audit.Audit_LogInterfaceCall v1.1.
--
-- Result set:
--   One row: Status (BIT), Message (NVARCHAR(500)), NewId (BIGINT, the InterfaceLog Id).
--
-- Change Log:
--   2026-10-29 - 1.0 - Initial version (migration 0116).
-- =============================================
CREATE OR ALTER PROCEDURE Audit.InterfaceLog_Record
    @SystemName         NVARCHAR(50),
    @Direction          NVARCHAR(10),
    @LogEventTypeCode   NVARCHAR(50),
    @Description        NVARCHAR(1000),
    @RequestPayload     NVARCHAR(MAX)   = NULL,
    @ResponsePayload    NVARCHAR(MAX)   = NULL,
    @ErrorCondition     NVARCHAR(200)   = NULL,
    @ErrorDescription   NVARCHAR(1000)  = NULL,
    @IsHighFidelity     BIT             = 0,
    @LocationId         BIGINT          = NULL,
    @ItemId             BIGINT          = NULL,
    @LotId              BIGINT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;
    DECLARE @LogEventTypeId BIGINT;

    BEGIN TRY
        IF NULLIF(@SystemName, N'') IS NULL OR NULLIF(@Direction, N'') IS NULL OR NULLIF(@Description, N'') IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (SystemName, Direction and Description are required).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @LogEventTypeId = Id FROM Audit.LogEventType WHERE Code = @LogEventTypeCode;

        -- Insert (mirrors Audit.Audit_LogInterfaceCall v1.1)
        INSERT INTO Audit.InterfaceLog (
            LoggedAt,
            SystemName,
            Direction,
            LogEventTypeId,
            Description,
            RequestPayload,
            ResponsePayload,
            ErrorCondition,
            ErrorDescription,
            IsHighFidelity,
            LocationId,
            ItemId,
            LotId
        )
        VALUES (
            SYSUTCDATETIME(),
            @SystemName,
            @Direction,
            ISNULL(@LogEventTypeId, 19),     -- default to InterfaceCall
            @Description,
            CASE WHEN @IsHighFidelity = 1 THEN @RequestPayload  ELSE NULL END,
            CASE WHEN @IsHighFidelity = 1 THEN @ResponsePayload ELSE NULL END,
            @ErrorCondition,
            @ErrorDescription,
            @IsHighFidelity,
            @LocationId,
            @ItemId,
            @LotId
        );

        SET @NewId   = CAST(SCOPE_IDENTITY() AS BIGINT);
        SET @Status  = 1;
        SET @Message = N'Interface call logged.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = LEFT(N'Could not log interface call: ' + @ErrMsg, 500);
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
