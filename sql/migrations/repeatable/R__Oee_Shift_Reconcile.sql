-- ============================================================
-- Repeatable:  R__Oee_Shift_Reconcile.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-07-31
-- Version:     0.1 (STUB - full body lands in Task 2)
-- Description: Reconciles Oee.Shift runtime instances to the schedule up to
--              @NowLocal: snaps boundaries, closes stale open shifts at their
--              scheduled end, backfills missed instances (bounded @MaxBackfillDays),
--              and opens the active instance. Idempotent. Local-time (see spec
--              2026-07-31-shift-boundary-reconcile-design.md).
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.Shift_Reconcile
    @NowLocal           DATETIME2(3)  = NULL,
    @MaxBackfillDays    INT           = 7,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Stub';
    DECLARE @ShiftsClosed INT = 0, @ShiftsBackfilled INT = 0, @ShiftOpened BIGINT = NULL;
    SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed,
           @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;
END;
GO
