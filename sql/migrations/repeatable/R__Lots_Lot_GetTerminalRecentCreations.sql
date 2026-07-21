-- ============================================================
-- Repeatable:  R__Lots_Lot_GetTerminalRecentCreations.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0 (2026-07-21)
-- Description: Die-cast right-rail activity log. Returns the most recent @TopN
--              die-cast LOTs CREATED AT a terminal (CreatedAtTerminalId), newest
--              first -- across ALL presses the terminal controls, NOT scoped to the
--              currently-selected die-cast machine. Replaces the old session-local
--              "logged this run" list.
--
--              CavityText = the cavity's Number + Description (e.g. "1 - In 1"),
--              resolved from Tools.ToolCavity; falls back to the manual free-text
--              cavity note (legacy Lot.CavityNumber) when no configured ToolCavity
--              was chosen. The consuming row view prepends "Cavity " so this column
--              carries only "<number> - <description>". ASCII-only.
--
--              Die-cast scope: CreatedAtTerminalId + Lot.ToolId IS NOT NULL (every
--              die-cast birth stamps a ToolId; non-die-cast LOTs are not created at
--              a die-cast terminal anyway).
--
--              Read proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty result = no die-cast LOTs at this terminal.
--              CreatedAt converted to Eastern at the read boundary (display TZ).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetTerminalRecentCreations
    @TerminalLocationId BIGINT,
    @TopN               INT = 15
AS
BEGIN
    SET NOCOUNT ON;

    IF @TopN IS NULL OR @TopN <= 0
        SET @TopN = 15;

    SELECT TOP (@TopN)
        l.Id          AS LotId,
        l.LotName     AS LotName,
        l.PieceCount  AS PieceCount,
        CASE
            WHEN tc.Id IS NOT NULL
                THEN CONCAT(
                        CAST(tc.CavityNumber AS NVARCHAR(20)),
                        CASE WHEN NULLIF(LTRIM(RTRIM(tc.Description)), N'') IS NOT NULL
                             THEN N' - ' + tc.Description ELSE N'' END)
            WHEN NULLIF(LTRIM(RTRIM(l.CavityNumber)), N'') IS NOT NULL
                THEN l.CavityNumber
            ELSE N'-'
        END           AS CavityText,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt
    FROM Lots.Lot l
    LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
    WHERE l.CreatedAtTerminalId = @TerminalLocationId
      AND l.ToolId IS NOT NULL
    ORDER BY l.CreatedAt DESC, l.Id DESC;
END;
GO
