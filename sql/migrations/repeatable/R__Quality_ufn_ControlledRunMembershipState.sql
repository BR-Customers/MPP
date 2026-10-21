-- ============================================================
-- Repeatable:  R__Quality_ufn_ControlledRunMembershipState.sql
-- Object:      Quality.ufn_ControlledRunMembershipState
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: Super-lot piece 6. Where ONE membership (Quality.ControlledRunMember
--              row) stands, as the word every screen shows: one row,
--              MembershipState NVARCHAR(10):
--                Open      -- still in the super-lot (EndedAt IS NULL)
--                Released  -- left by a signed release (ControlledRunReleaseId /
--                             end reason Released)
--                Closed    -- the super-lot closed with it still in
--                Cancelled -- the super-lot was cancelled with it still in
--                Removed   -- removed by hand, OR end reason ContainerVoided (the
--                             container was emptied and voided under it -- piece 4);
--                             the end reason's name says which.
--              Read by ControlledRun_ListByLot and ControlledRun_ListMarkers so the
--              LOT Detail tab and the trace markers cannot disagree. Reads tables
--              only (no file-order dependency).
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunMembershipState (@MemberId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(CASE
               WHEN m.EndedAt IS NULL THEN N'Open'
               WHEN m.ControlledRunReleaseId IS NOT NULL OR er.Code = N'Released' THEN N'Released'
               WHEN er.Code = N'RunClosed'    THEN N'Closed'
               WHEN er.Code = N'RunCancelled' THEN N'Cancelled'
               ELSE N'Removed'   -- Removed, ContainerVoided
           END AS NVARCHAR(10)) AS MembershipState
    FROM Quality.ControlledRunMember m
    LEFT JOIN Quality.ControlledRunMemberEndReason er ON er.Id = m.ControlledRunMemberEndReasonId
    WHERE m.Id = @MemberId
);
GO
