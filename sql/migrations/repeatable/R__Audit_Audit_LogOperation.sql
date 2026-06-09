-- ============================================================
-- Repeatable:  R__Audit_Audit_LogOperation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     2.0
-- Description: Writes one row for a successful plant-floor mutation (LOT
--              creation, movement, status change, production recording,
--              holds, etc.). Called inside the caller's transaction, atomic
--              with the data — same pattern as Audit_LogConfigChange.
--
--              B7 ROUTING (Arc 2 Phase 1, OI-35 Phase 0 decision):
--              LOT-relevant audit events are split out of the 7-yr general
--              Audit.OperationLog into the 20-yr Honda-class Lots.LotEventLog.
--              Phase 1 routes entity 'Lot' (container-close / ShippingLabel-mint
--              join the routed set in later phases). For a routed event the
--              EntityId IS the LOT id, so LotEventLog.LotId is populated from
--              @EntityId. If a 'Lot' event arrives with a NULL @EntityId we
--              CANNOT satisfy LotEventLog.LotId NOT NULL, so we fall back to
--              OperationLog rather than fail the caller's transaction. That
--              fallback is a silent Honda-20yr retention downgrade, so it is made
--              DETECTABLE: the row is forced to 'Warning' severity and its
--              Description is prefixed '[LOT-EVENT-FALLBACK] ' so the mis-
--              attributed rows are queryable / correctable. Everything else ->
--              Audit.OperationLog as before.
--
--              Emits NO result set: it runs inside caller transactions, and a
--              result set would break the INSERT-EXEC + ROLLBACK pattern.
-- ============================================================

CREATE OR ALTER PROCEDURE Audit.Audit_LogOperation
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT          = NULL,
    @LocationId         BIGINT          = NULL,
    @LogEntityTypeCode  NVARCHAR(50),
    @EntityId           BIGINT          = NULL,
    @LogEventTypeCode   NVARCHAR(50),
    @LogSeverityCode    NVARCHAR(20)    = N'Info',
    @Description        NVARCHAR(1000),
    @OldValue           NVARCHAR(MAX)   = NULL,
    @NewValue           NVARCHAR(MAX)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LogSeverityId   BIGINT;
    DECLARE @LogEventTypeId  BIGINT;
    DECLARE @LogEntityTypeId BIGINT;

    -- Resolve code strings to IDs (identical resolution to legacy behaviour).
    SELECT @LogSeverityId   = Id FROM Audit.LogSeverity   WHERE Code = @LogSeverityCode;
    SELECT @LogEventTypeId  = Id FROM Audit.LogEventType  WHERE Code = @LogEventTypeCode;
    SELECT @LogEntityTypeId = Id FROM Audit.LogEntityType WHERE Code = @LogEntityTypeCode;

    -- B7 route decision: 'Lot' events with a non-NULL EntityId -> LotEventLog.
    -- (Phase 1 routed set = just 'Lot'. NULL EntityId falls back to OperationLog
    --  to honour LotEventLog.LotId NOT NULL.)
    IF @LogEntityTypeCode = N'Lot' AND @EntityId IS NOT NULL
    BEGIN
        INSERT INTO Lots.LotEventLog (
            LoggedAt,
            UserId,
            TerminalLocationId,
            LocationId,
            LogSeverityId,
            LogEventTypeId,
            LogEntityTypeId,
            EntityId,
            LotId,
            Description,
            OldValue,
            NewValue
        )
        VALUES (
            SYSUTCDATETIME(),
            @AppUserId,
            @TerminalLocationId,
            @LocationId,
            ISNULL(@LogSeverityId, 1),
            ISNULL(@LogEventTypeId, 1),
            ISNULL(@LogEntityTypeId, 1),
            @EntityId,
            @EntityId,            -- for a LOT event, EntityId IS the LOT id
            @Description,
            @OldValue,
            @NewValue
        );
        RETURN;
    END

    -- LOT-EVENT FALLBACK DETECTION (Fix 2, holistic review): a 'Lot' event with
    -- a NULL @EntityId cannot satisfy LotEventLog.LotId NOT NULL, so it lands in
    -- the 7-yr OperationLog instead of the 20-yr LotEventLog — a SILENT Honda-
    -- 20yr-class retention downgrade. Make these mis-attributed rows DETECTABLE
    -- (so they can be found + corrected) without failing the caller:
    --   (a) force @LogSeverityCode -> 'Warning' (re-resolve @LogSeverityId), and
    --   (b) prefix the Description with a queryable '[LOT-EVENT-FALLBACK] ' marker.
    -- Truncate the marked Description to the 1000-char column width so the prefix
    -- never overflows the insert.
    IF @LogEntityTypeCode = N'Lot' AND @EntityId IS NULL
    BEGIN
        SET @LogSeverityCode = N'Warning';
        SELECT @LogSeverityId = Id FROM Audit.LogSeverity WHERE Code = @LogSeverityCode;
        SET @Description = LEFT(N'[LOT-EVENT-FALLBACK] ' + ISNULL(@Description, N''), 1000);
    END

    INSERT INTO Audit.OperationLog (
        LoggedAt,
        UserId,
        TerminalLocationId,
        LocationId,
        LogSeverityId,
        LogEventTypeId,
        LogEntityTypeId,
        EntityId,
        Description,
        OldValue,
        NewValue
    )
    VALUES (
        SYSUTCDATETIME(),
        @AppUserId,
        @TerminalLocationId,
        @LocationId,
        ISNULL(@LogSeverityId, 1),
        ISNULL(@LogEventTypeId, 1),
        ISNULL(@LogEntityTypeId, 1),
        @EntityId,
        @Description,
        @OldValue,
        @NewValue
    );

END;
GO
