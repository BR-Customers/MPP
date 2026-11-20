-- =============================================
-- Procedure: Workorder.ScalePartCode_ListForTerminal
-- Author:    Blue Ridge Automation
-- Created:   2026-11-20
-- Version:   1.0
--
-- Description:
--   A terminal's ACTIVE learned scale part codes (migration 0135), for the
--   Config Tool's PLC Devices page, code order. LearnedAtEt is Eastern.
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 13.
--
-- Parameters:
--   @TerminalLocationId BIGINT - the scale's terminal.
--
-- Result: Id, ScalePartCode, ItemId, PartNumber, Description, LearnedAtEt, LearnedBy.
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScalePartCode_ListForTerminal
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT m.Id,
           m.ScalePartCode,
           m.ItemId,
           i.PartNumber,
           i.Description,
           CAST(m.LearnedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LearnedAtEt,
           ISNULL(u.Initials, N'') AS LearnedBy
    FROM Workorder.ScalePartCode m
    JOIN Parts.Item i ON i.Id = m.ItemId
    LEFT JOIN Location.AppUser u ON u.Id = m.LearnedByAppUserId
    WHERE m.TerminalLocationId = @TerminalLocationId
      AND m.DeprecatedAt IS NULL
    ORDER BY m.ScalePartCode;
END;
GO
