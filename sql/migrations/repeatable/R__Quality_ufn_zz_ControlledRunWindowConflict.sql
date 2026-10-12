-- ============================================================
-- Repeatable:  R__Quality_ufn_zz_ControlledRunWindowConflict.sql
-- Object:      Quality.ufn_ControlledRunWindowConflict
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: Is there ALREADY an open super-lot whose rolling window covers
--              this part at this place? Returns its RunNumber (one row), or no
--              rows when there is none.
--
--              Why the rule exists: Lots.ufn_CrtForMint tags a new LOT ONCE,
--              however many open windows cover it, and a LOT can be in only one
--              open super-lot. With two overlapping windows, which super-lot got
--              the LOT would depend on which one synced first (the timer goes in
--              Id order; opening a super-lot on the screen syncs that one first).
--              So a second overlapping window is refused, by
--              Quality.ControlledRun_Open and Quality.ControlledRun_SetAutoJoin.
--
--              Two windows on the same part OVERLAP when either names no
--              location, or they name the same one, or one is above the other in
--              the location hierarchy. Windows on the same part at two unrelated
--              lines do not overlap and are allowed.
--
--              @ExcludeRunId: the super-lot being resumed (it is not a conflict
--              with itself). NULL when opening a new one.
--
--              FILE NAME IS ORDER-SENSITIVE: 'zz_' is a deploy-order marker
--              (functions get no deferred name resolution), same convention as
--              R__Lots_ufn_zz_CrtBlocks.sql. Do not "tidy" it.
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunWindowConflict
(
    @ItemId       BIGINT,
    @LocationId   BIGINT = NULL,
    @ExcludeRunId BIGINT = NULL
)
RETURNS TABLE
AS
RETURN
(
    WITH Up AS (     -- @LocationId and everything above it
        SELECT l.Id, l.ParentLocationId FROM Location.Location l WHERE l.Id = @LocationId
        UNION ALL
        SELECT p.Id, p.ParentLocationId FROM Location.Location p INNER JOIN Up u ON p.Id = u.ParentLocationId
    ),
    Down AS (        -- @LocationId and everything below it
        SELECT l.Id FROM Location.Location l WHERE l.Id = @LocationId
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Down d ON c.ParentLocationId = d.Id
    )
    SELECT TOP 1 r.RunNumber
    FROM Quality.ControlledRun r
    WHERE r.ControlledRunStatusId = 1
      AND r.AutoJoinEnabled = 1
      AND r.SelectionItemId = @ItemId
      AND (@ExcludeRunId IS NULL OR r.Id <> @ExcludeRunId)
      AND ( @LocationId IS NULL
         OR r.SelectionLocationId IS NULL
         OR r.SelectionLocationId IN (SELECT Id FROM Up)
         OR r.SelectionLocationId IN (SELECT Id FROM Down) )
    ORDER BY r.Id
);
GO
