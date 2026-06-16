-- ============================================================
-- Repeatable:  R__Lots_Lot_GetAttributeHistory.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-15
-- Version:     1.1
-- Description: Unified LOT history read (Phase 2 Task 5 / G3; spec section 4.3).
--              READ proc -- no @Status/@Message, no status row, ONE result set,
--              empty set = not found (FDS-11-011). No OUTPUT params.
--
--              UNION ALL of the LOT lifecycle streams for @LotId, normalized to one
--              common shape and ordered chronologically (ASCENDING by EventAt, then
--              SortRank for deterministic same-instant ordering, e.g. create-time
--              placement+status):
--                * Lots.LotAttributeChange -> EventKind='Attribute';
--                  Detail = '<AttributeName>: <OldValue> -> <NewValue>'.
--                * Lots.LotStatusHistory   -> EventKind='Status';
--                  Detail = '<OldStatusCode|(none)> -> <NewStatusCode>' + optional
--                  ' (<Reason>)' (codes resolved from Lots.LotStatusCode).
--                * Lots.LotMovement        -> EventKind='Movement';
--                  Detail = '<FromLocationName|(none)> -> <ToLocationName>'.
--                * Lots.PauseEvent         -> EventKind='Pause' (at PausedAt) and
--                  EventKind='Resume' (at ResumedAt, only when resumed);
--                  Detail = 'Paused at <Loc> (<reason>)' / 'Resumed at <Loc> (<remarks>)'.
--                * Lots.LotGenealogy       -> EventKind='Genealogy'; one row per edge
--                  this LOT participates in. As parent: '<RelType> -> <ChildLotName>';
--                  as child: '<RelType> <- <ParentLotName>' + optional ' (<n> pcs)'.
--                * Lots.LotLabel           -> EventKind='Label';
--                  Detail = 'Label printed: <LabelType> (<PrintReason>)'.
--
--              Result columns:
--                EventAt    DATETIME2(3)
--                EventKind  NVARCHAR(20)   ('Attribute'|'Status'|'Movement'|'Pause'
--                                           |'Resume'|'Genealogy'|'Label')
--                Detail     NVARCHAR(500)
--                ByUserId   BIGINT         (the acting AppUser id)
--                ByUserName NVARCHAR(200)  (Location.AppUser.DisplayName)
--
--              Every branch CASTs every column to identical types so the UNION
--              cannot fail on a type mismatch. The audit stream (Lots.LotEventLog)
--              is intentionally NOT unioned -- this is the lifecycle timeline, not
--              the audit trail; the Audit Browser surfaces the audit log. All Detail
--              strings are ASCII (no non-ASCII glyphs) -- '->' / '<-' arrows and
--              parenthesized reasons (sqlcmd codepage would mojibake a middle-dot).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_GetAttributeHistory
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- EventAt converted UTC -> Eastern for display (matches the Audit Browser
    -- tz convention). Inner branches keep raw UTC so ORDER BY stays correct.
    SELECT CAST(u.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAt,
           u.EventKind, u.Detail, u.ByUserId, u.ByUserName
    FROM (
        -- ---- Stream 1: attribute changes ----
        SELECT
            ac.ChangedAt                          AS EventAt,
            CAST(7 AS INT)                        AS SortRank,
            CAST(N'Attribute' AS NVARCHAR(20))    AS EventKind,
            CAST(ac.AttributeName + N': ' + ISNULL(ac.OldValue, N'(none)')
                 + N' -> ' + ISNULL(ac.NewValue, N'(none)') AS NVARCHAR(500)) AS Detail,
            CAST(ac.ChangedByUserId AS BIGINT)    AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotAttributeChange ac
        INNER JOIN Location.AppUser au ON au.Id = ac.ChangedByUserId
        WHERE ac.LotId = @LotId

        UNION ALL

        -- ---- Stream 2: status transitions (with reason) ----
        SELECT
            sh.ChangedAt                          AS EventAt,
            CAST(2 AS INT)                        AS SortRank,
            CAST(N'Status' AS NVARCHAR(20))       AS EventKind,
            CAST(ISNULL(oldc.Code, N'(none)') + N' -> ' + newc.Code
                 + ISNULL(N' (' + sh.Reason + N')', N'') AS NVARCHAR(500)) AS Detail,
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
            CAST(1 AS INT)                        AS SortRank,
            CAST(N'Movement' AS NVARCHAR(20))     AS EventKind,
            CAST(ISNULL(fromloc.Name, N'(none)') + N' -> ' + toloc.Name AS NVARCHAR(500)) AS Detail,
            CAST(mv.MovedByUserId AS BIGINT)      AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotMovement mv
        INNER JOIN Location.Location toloc   ON toloc.Id   = mv.ToLocationId
        LEFT  JOIN Location.Location fromloc ON fromloc.Id = mv.FromLocationId
        INNER JOIN Location.AppUser  au      ON au.Id      = mv.MovedByUserId
        WHERE mv.LotId = @LotId

        UNION ALL

        -- ---- Stream 4: pause placed ----
        SELECT
            pe.PausedAt                           AS EventAt,
            CAST(3 AS INT)                        AS SortRank,
            CAST(N'Pause' AS NVARCHAR(20))        AS EventKind,
            CAST(N'Paused at ' + loc.Name
                 + ISNULL(N' (' + pe.PausedReason + N')', N'') AS NVARCHAR(500)) AS Detail,
            CAST(pe.PausedByUserId AS BIGINT)     AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.PauseEvent pe
        INNER JOIN Location.Location loc ON loc.Id = pe.LocationId
        INNER JOIN Location.AppUser  au  ON au.Id  = pe.PausedByUserId
        WHERE pe.LotId = @LotId

        UNION ALL

        -- ---- Stream 5: pause resumed (only when resumed) ----
        SELECT
            pe.ResumedAt                          AS EventAt,
            CAST(4 AS INT)                        AS SortRank,
            CAST(N'Resume' AS NVARCHAR(20))       AS EventKind,
            CAST(N'Resumed at ' + loc.Name
                 + ISNULL(N' (' + pe.ResumedRemarks + N')', N'') AS NVARCHAR(500)) AS Detail,
            CAST(pe.ResumedByUserId AS BIGINT)    AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.PauseEvent pe
        INNER JOIN Location.Location loc ON loc.Id = pe.LocationId
        INNER JOIN Location.AppUser  au  ON au.Id  = pe.ResumedByUserId
        WHERE pe.LotId = @LotId AND pe.ResumedAt IS NOT NULL

        UNION ALL

        -- ---- Stream 6a: genealogy -- this LOT as PARENT (produced a child) ----
        SELECT
            g.EventAt                             AS EventAt,
            CAST(5 AS INT)                        AS SortRank,
            CAST(N'Genealogy' AS NVARCHAR(20))    AS EventKind,
            CAST(grt.Name + N' -> ' + child.LotName
                 + ISNULL(N' (' + CAST(g.PieceCount AS NVARCHAR(20)) + N' pcs)', N'') AS NVARCHAR(500)) AS Detail,
            CAST(g.EventUserId AS BIGINT)         AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotGenealogy g
        INNER JOIN Lots.GenealogyRelationshipType grt ON grt.Id = g.RelationshipTypeId
        INNER JOIN Lots.Lot         child ON child.Id = g.ChildLotId
        INNER JOIN Location.AppUser au    ON au.Id    = g.EventUserId
        WHERE g.ParentLotId = @LotId

        UNION ALL

        -- ---- Stream 6b: genealogy -- this LOT as CHILD (came from a parent) ----
        SELECT
            g.EventAt                             AS EventAt,
            CAST(5 AS INT)                        AS SortRank,
            CAST(N'Genealogy' AS NVARCHAR(20))    AS EventKind,
            CAST(grt.Name + N' <- ' + parent.LotName
                 + ISNULL(N' (' + CAST(g.PieceCount AS NVARCHAR(20)) + N' pcs)', N'') AS NVARCHAR(500)) AS Detail,
            CAST(g.EventUserId AS BIGINT)         AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotGenealogy g
        INNER JOIN Lots.GenealogyRelationshipType grt ON grt.Id = g.RelationshipTypeId
        INNER JOIN Lots.Lot         parent ON parent.Id = g.ParentLotId
        INNER JOIN Location.AppUser au     ON au.Id     = g.EventUserId
        WHERE g.ChildLotId = @LotId

        UNION ALL

        -- ---- Stream 7: label prints ----
        SELECT
            ll.PrintedAt                          AS EventAt,
            CAST(6 AS INT)                        AS SortRank,
            CAST(N'Label' AS NVARCHAR(20))        AS EventKind,
            CAST(N'Label printed: ' + lt.Name
                 + ISNULL(N' (' + pr.Name + N')', N'') AS NVARCHAR(500)) AS Detail,
            CAST(ll.PrintedByUserId AS BIGINT)    AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Lots.LotLabel ll
        INNER JOIN Lots.LabelTypeCode   lt ON lt.Id = ll.LabelTypeCodeId
        INNER JOIN Lots.PrintReasonCode pr ON pr.Id = ll.PrintReasonCodeId
        INNER JOIN Location.AppUser     au ON au.Id = ll.PrintedByUserId
        WHERE ll.LotId = @LotId
    ) u
    ORDER BY u.EventAt ASC, u.SortRank ASC;
END;
GO
