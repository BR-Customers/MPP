-- ============================================================
-- Repeatable:  R__Lots_Lot_GetAttributeHistory.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Unified LOT history read (Phase 2 Task 5 / G3; spec section 4.3).
--              READ proc -- no @Status/@Message, no status row, ONE result set,
--              empty set = not found (FDS-11-011). No OUTPUT params.
--
--              UNION ALL of three append-only streams for @LotId, normalized to one
--              common shape and ordered chronologically (ASCENDING by EventAt):
--                * Lots.LotAttributeChange -> EventKind='Attribute';
--                  Detail = '<AttributeName>: <OldValue> -> <NewValue>'.
--                * Lots.LotStatusHistory   -> EventKind='Status';
--                  Detail = '<OldStatusCode|(none)> -> <NewStatusCode>' (codes
--                  resolved from Lots.LotStatusCode).
--                * Lots.LotMovement        -> EventKind='Movement';
--                  Detail = '<FromLocationName|(none)> -> <ToLocationName>'
--                  (names resolved from Location.Location).
--
--              Result columns:
--                EventAt   DATETIME2(3)
--                EventKind NVARCHAR(20)    ('Attribute' | 'Status' | 'Movement')
--                Detail    NVARCHAR(500)
--                ByUserId  BIGINT          (the acting AppUser id)
--                ByUserName NVARCHAR(200)  (Location.AppUser.DisplayName)
--
--              All three branch SELECTs CAST every column to the identical type so
--              the UNION cannot fail on a type mismatch. The audit stream
--              (Lots.LotEventLog) is intentionally NOT unioned here -- this proc is
--              the attribute/state/movement timeline, not the audit trail; the
--              Audit Browser surfaces the audit log. The Detail strings use an
--              ASCII '->' arrow (no non-ASCII glyphs).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_GetAttributeHistory
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.EventAt, u.EventKind, u.Detail, u.ByUserId, u.ByUserName
    FROM (
        -- ---- Stream 1: attribute changes ----
        SELECT
            ac.ChangedAt                          AS EventAt,
            CAST(N'Attribute' AS NVARCHAR(20))    AS EventKind,
            CAST(ac.AttributeName + N': ' + ISNULL(ac.OldValue, N'(none)')
                 + N' -> ' + ISNULL(ac.NewValue, N'(none)') AS NVARCHAR(500)) AS Detail,
            CAST(ac.ChangedByUserId AS BIGINT)    AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotAttributeChange ac
        INNER JOIN Location.AppUser au ON au.Id = ac.ChangedByUserId
        WHERE ac.LotId = @LotId

        UNION ALL

        -- ---- Stream 2: status transitions ----
        SELECT
            sh.ChangedAt                          AS EventAt,
            CAST(N'Status' AS NVARCHAR(20))       AS EventKind,
            CAST(ISNULL(oldc.Code, N'(none)') + N' -> ' + newc.Code AS NVARCHAR(500)) AS Detail,
            CAST(sh.ChangedByUserId AS BIGINT)    AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotStatusHistory sh
        INNER JOIN Lots.LotStatusCode newc ON newc.Id = sh.NewStatusId
        LEFT  JOIN Lots.LotStatusCode oldc ON oldc.Id = sh.OldStatusId
        INNER JOIN Location.AppUser   au   ON au.Id   = sh.ChangedByUserId
        WHERE sh.LotId = @LotId

        UNION ALL

        -- ---- Stream 3: movements ----
        SELECT
            mv.MovedAt                            AS EventAt,
            CAST(N'Movement' AS NVARCHAR(20))     AS EventKind,
            CAST(ISNULL(fromloc.Name, N'(none)') + N' -> ' + toloc.Name AS NVARCHAR(500)) AS Detail,
            CAST(mv.MovedByUserId AS BIGINT)      AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotMovement mv
        INNER JOIN Location.Location toloc   ON toloc.Id   = mv.ToLocationId
        LEFT  JOIN Location.Location fromloc ON fromloc.Id = mv.FromLocationId
        INNER JOIN Location.AppUser  au      ON au.Id      = mv.MovedByUserId
        WHERE mv.LotId = @LotId
    ) u
    ORDER BY u.EventAt ASC;
END;
GO
