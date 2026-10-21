-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListMarkers.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: READ. Super-lot piece 6 (spec 3.3) -- the super-lot markers on the
--              genealogy tree and Global Trace nodes. A second read keyed by the
--              node ids, so the recursive tree queries are not touched.
--
--              @LotIdsCsv / @ContainerIdsCsv: comma-separated ids (a list passed to
--              runScript arrives as QualifiedValue[] and throws, so the screen sends
--              one string). Blanks, spaces and anything not a whole number are
--              ignored; duplicates are folded. NULL / '' = no nodes of that kind.
--
--              LOT nodes go through Quality.ufn_ControlledRunMembershipsForLot (THE
--              fold: a tray LOT carries its container's super-lots while it was in
--              the container). Container nodes go through ControlledRunMember.
--              ContainerId.
--
--              ONE row per (node, super-lot): when a unit was in the same super-lot
--              more than once (removed, then re-joined) the marker shows where its
--              LATEST membership stands. MembershipState from
--              Quality.ufn_ControlledRunMembershipState (as ControlledRun_ListByLot):
--              Open | Released | Removed (incl. ContainerVoided) | Closed | Cancelled.
--
--              Result: NodeKind (Lot|Container), NodeId, RunNumber, ControlledRunId,
--              MembershipState; ordered NodeKind, NodeId, newest membership first.
--              No status row, no OUTPUT params (FDS-11-011). Empty set = no markers.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListMarkers
    @LotIdsCsv       NVARCHAR(MAX) = NULL,
    @ContainerIdsCsv NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Lots TABLE (Id BIGINT PRIMARY KEY);
    DECLARE @Cons TABLE (Id BIGINT PRIMARY KEY);

    -- Trimmed plain digit strings only; TRY_CAST drops anything too long for BIGINT.
    INSERT INTO @Lots (Id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(s.value)) AS BIGINT)
    FROM STRING_SPLIT(ISNULL(@LotIdsCsv, N''), N',') s
    WHERE LTRIM(RTRIM(s.value)) <> N'' AND LTRIM(RTRIM(s.value)) NOT LIKE N'%[^0-9]%'
      AND TRY_CAST(LTRIM(RTRIM(s.value)) AS BIGINT) IS NOT NULL;

    INSERT INTO @Cons (Id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(s.value)) AS BIGINT)
    FROM STRING_SPLIT(ISNULL(@ContainerIdsCsv, N''), N',') s
    WHERE LTRIM(RTRIM(s.value)) <> N'' AND LTRIM(RTRIM(s.value)) NOT LIKE N'%[^0-9]%'
      AND TRY_CAST(LTRIM(RTRIM(s.value)) AS BIGINT) IS NOT NULL;

    WITH Raw AS (
        SELECT CAST(N'Lot' AS NVARCHAR(10)) AS NodeKind, l.Id AS NodeId,
               f.ControlledRunMemberId AS MemberId, f.ControlledRunId, f.RunNumber, f.AddedAt
        FROM @Lots l
        CROSS APPLY Quality.ufn_ControlledRunMembershipsForLot(l.Id) f
        UNION ALL
        SELECT CAST(N'Container' AS NVARCHAR(10)), c.Id, m.Id, m.ControlledRunId, r.RunNumber, m.AddedAt
        FROM @Cons c
        INNER JOIN Quality.ControlledRunMember m ON m.ContainerId = c.Id
        INNER JOIN Quality.ControlledRun r       ON r.Id = m.ControlledRunId
    ),
    Latest AS (
        SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.NodeKind, x.NodeId, x.ControlledRunId
                                       ORDER BY x.AddedAt DESC, x.MemberId DESC) AS Rn
        FROM Raw x
    )
    SELECT
        lt.NodeKind,
        lt.NodeId,
        lt.RunNumber,
        lt.ControlledRunId,
        st.MembershipState
    FROM Latest lt
    CROSS APPLY Quality.ufn_ControlledRunMembershipState(lt.MemberId) st
    WHERE lt.Rn = 1
    ORDER BY lt.NodeKind, lt.NodeId, lt.AddedAt DESC, lt.MemberId DESC;
END;
GO
