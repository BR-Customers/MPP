-- ============================================================
-- Repeatable:  R__Lots_Lot_AssertNotBlocked.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: B2 shared guard. Every downstream proc that ADVANCES a LOT
--              (Lot_MoveTo, future Lot_Split/Merge/operation procs) calls
--              this first and rejects when IsBlocked=1.
--
--              Reads Lot.LotStatusId -> LotStatusCode. A LOT is blocked when
--              its status BlocksProduction flag is set (Hold/Scrap) OR the
--              status is terminal-Closed (a closed LOT must not advance even
--              though BlocksProduction=0 on the Closed code). Non-existent
--              lot -> blocked, 'LOT not found'.
--
--              Internal guard: NO audit, NO FailureLog (callers that receive
--              IsBlocked=1 log their own rejection). Single result set
--              (IsBlocked BIT, Message NVARCHAR(500)); no OUTPUT params.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_AssertNotBlocked
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsBlocked BIT           = 1;
    DECLARE @Message   NVARCHAR(500) = N'LOT not found.';
    DECLARE @StatusCode NVARCHAR(20);
    DECLARE @StatusName NVARCHAR(100);
    DECLARE @Blocks     BIT;

    SELECT @StatusCode = sc.Code,
           @StatusName = sc.Name,
           @Blocks     = sc.BlocksProduction
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.Id = @LotId;

    IF @StatusCode IS NULL
    BEGIN
        -- not found: @IsBlocked / @Message already at the not-found defaults
        SELECT @IsBlocked AS IsBlocked, @Message AS Message;
        RETURN;
    END

    IF @Blocks = 1 OR @StatusCode = N'Closed'
    BEGIN
        SET @IsBlocked = 1;
        SET @Message   = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot advance.';
    END
    ELSE
    BEGIN
        SET @IsBlocked = 0;
        SET @Message   = N'LOT is not blocked.';
    END

    SELECT @IsBlocked AS IsBlocked, @Message AS Message;
END;
GO
