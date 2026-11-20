-- =============================================
-- Procedure: Workorder.ScalePartCode_Resolve
-- Author:    Blue Ridge Automation
-- Created:   2026-11-20
-- Version:   1.0
--
-- Description:
--   The part a Digi-read scale's <Part> code names at this terminal. The ONE
--   rule, used by BlueRidge.Workorder.ScaleDigiWatcher:
--     1. an active part whose PartNumber equals the code (trimmed)  -> Source 'PartNumber'
--     2. else this terminal's active learned mapping (0135)         -> Source 'Learned'
--     3. else no row: the press is held for the operator to pick.
--   A learned mapping whose part has since been deprecated resolves to nothing,
--   so the press is held and the new pick replaces the mapping.
--
--   Eligible = the part is in Workorder.ufn_ScaleStationEligibleParts for the
--   terminal right now. The watcher holds a LEARNED part that is not eligible
--   (the pick then re-teaches); a part-number match that is not eligible is
--   refused by the part switch, as before.
--
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 13.
--
-- Parameters:
--   @TerminalLocationId BIGINT       - the scale's terminal.
--   @ScalePartCode      NVARCHAR(50) - the code as the scale sent it.
--
-- Result: 0 or 1 row: ItemId, PartNumber, Source, Eligible.
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScalePartCode_Resolve
    @TerminalLocationId BIGINT,
    @ScalePartCode      NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code   NVARCHAR(50) = LTRIM(RTRIM(ISNULL(@ScalePartCode, N'')));
    DECLARE @ItemId BIGINT = NULL;
    DECLARE @Source NVARCHAR(20) = NULL;

    IF @Code <> N''
    BEGIN
        SELECT TOP 1 @ItemId = i.Id
        FROM Parts.Item i
        WHERE i.PartNumber = @Code AND i.DeprecatedAt IS NULL
        ORDER BY i.Id;

        IF @ItemId IS NOT NULL
            SET @Source = N'PartNumber';
        ELSE
        BEGIN
            SELECT @ItemId = m.ItemId
            FROM Workorder.ScalePartCode m
            JOIN Parts.Item i ON i.Id = m.ItemId AND i.DeprecatedAt IS NULL
            WHERE m.TerminalLocationId = @TerminalLocationId
              AND m.ScalePartCode = @Code
              AND m.DeprecatedAt IS NULL;
            IF @ItemId IS NOT NULL
                SET @Source = N'Learned';
        END
    END

    SELECT i.Id AS ItemId,
           i.PartNumber,
           @Source AS Source,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM Workorder.ufn_ScaleStationEligibleParts(@TerminalLocationId) e
                                  WHERE e.ItemId = i.Id)
                     THEN 1 ELSE 0 END AS BIT) AS Eligible
    FROM Parts.Item i
    WHERE i.Id = @ItemId;
END;
GO
