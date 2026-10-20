-- =============================================
-- Procedure:   Workorder.ScaleStation_GetRunningPart
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.1
--
-- Description:
--   The part a By Weight scale station's next press will close. The ONE
--   rule shared by the scale close (Assembly.resolvePlcCloseContext) and the
--   screen, so they cannot disagree (spec 2026-10-19 scale station, sec. 5):
--     1. the station's own open By Weight box -> its part (a box is never
--        split across parts);
--     2. else the terminal's override (ScaleRunningItemId attribute), if
--        that part is still eligible;
--     3. else the eligible part closest to ready (ReadyRank 1);
--     4. else None, with a Message saying what is missing.
--   An override that is no longer eligible is not silently ignored: the
--   Message says the default is running instead.
--
--   Read proc. EXACTLY ONE row, always (FDS-11-011, no OUTPUT params).
--
-- Parameters:
--   @TerminalLocationId BIGINT - Required.
--
-- Result: ItemId, PartNumber, Description, Source (Override|Default|None),
--   PartsPerTray, TraysPerContainer, TargetWeight, ToleranceWeight,
--   LowLimit, HighLimit, EligibleCount, Message, OverrideItemId,
--   OverrideSetBy, OverrideSetAtEt, OpenContainerId, OpenTraysClosed,
--   OpenPartsClosed.
--
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
--   2026-10-20 - 1.1 - Eligibility evaluated once per call (table variable).
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScaleStation_GetRunningPart
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsTerminal      BIT = 0,
            @OverrideItemId  BIGINT,
            @OverrideSetBy   NVARCHAR(50),
            @OverrideSetAt   DATETIME2(3),
            @OpenContainerId BIGINT,
            @OpenItemId      BIGINT,
            @EligibleCount   INT = 0,
            @ItemId          BIGINT,
            @Source          NVARCHAR(20) = N'None',
            @Message         NVARCHAR(500);

    -- The eligibility rule is evaluated ONCE per call (it reads stock for every
    -- finished good x BOM line at the line).
    DECLARE @Elig TABLE (ItemId BIGINT PRIMARY KEY, ReadyRank BIGINT);
    INSERT INTO @Elig (ItemId, ReadyRank)
    SELECT ItemId, ReadyRank FROM Workorder.ufn_ScaleStationEligibleParts(@TerminalLocationId);

    IF EXISTS (SELECT 1 FROM Location.Location
               WHERE Id = @TerminalLocationId AND LocationTypeDefinitionId = 7
                 AND DeprecatedAt IS NULL AND ParentLocationId IS NOT NULL)
        SET @IsTerminal = 1;

    SELECT @OverrideItemId = TRY_CAST(NULLIF(LTRIM(RTRIM(a.AttributeValue)), N'') AS BIGINT),
           @OverrideSetAt  = COALESCE(a.UpdatedAt, a.CreatedAt),
           @OverrideSetBy  = u.Initials
    FROM Location.LocationAttribute a
    JOIN Location.LocationAttributeDefinition d
      ON d.Id = a.LocationAttributeDefinitionId
     AND d.LocationTypeDefinitionId = 7 AND d.AttributeName = N'ScaleRunningItemId' AND d.DeprecatedAt IS NULL
    LEFT JOIN Location.AppUser u ON u.Id = a.UpdatedByUserId
    WHERE a.LocationId = @TerminalLocationId;
    IF @OverrideItemId IS NULL
        SELECT @OverrideSetBy = NULL, @OverrideSetAt = NULL;

    SELECT TOP 1 @OpenContainerId = c.Id, @OpenItemId = c.ItemId
    FROM Lots.Container c
    JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId AND cc.ClosureMethod = N'ByWeight'
    WHERE c.StationLocationId = @TerminalLocationId AND c.ContainerStatusCodeId = 1
    ORDER BY c.OpenedAt, c.Id;

    SELECT @EligibleCount = COUNT(*) FROM @Elig;

    IF @IsTerminal = 0
        SET @Message = N'This location is not an active terminal on a line.';
    ELSE IF @OpenContainerId IS NOT NULL
    BEGIN
        SET @ItemId = @OpenItemId;
        SET @Source = N'Default';
        SET @Message = N'Finishing open box #' + CAST(@OpenContainerId AS NVARCHAR(20)) + N'.';
    END
    ELSE IF @OverrideItemId IS NOT NULL
         AND EXISTS (SELECT 1 FROM @Elig WHERE ItemId = @OverrideItemId)
    BEGIN
        SET @ItemId = @OverrideItemId;
        SET @Source = N'Override';
    END
    ELSE
    BEGIN
        SELECT @ItemId = ItemId FROM @Elig WHERE ReadyRank = 1;
        IF @ItemId IS NOT NULL
            SET @Source = N'Default';
        IF @OverrideItemId IS NOT NULL
            SET @Message = N'Override ' + ISNULL((SELECT PartNumber FROM Parts.Item WHERE Id = @OverrideItemId), CAST(@OverrideItemId AS NVARCHAR(20)))
                         + N' is not eligible at this line'
                         + CASE WHEN @ItemId IS NULL THEN N', and no other part is.' ELSE N'; running the default part.' END;
        ELSE IF @ItemId IS NULL
            SET @Message = N'No finished good at this line has a By Weight pack-out and the parts for a tray.';
    END

    SELECT i.Id AS ItemId, i.PartNumber, i.Description, @Source AS Source,
           cc.PartsPerTray, cc.TraysPerContainer, cc.TargetWeight, cc.ToleranceWeight,
           cc.TargetWeight - cc.ToleranceWeight AS LowLimit,
           cc.TargetWeight + cc.ToleranceWeight AS HighLimit,
           @EligibleCount AS EligibleCount, @Message AS Message,
           @OverrideItemId AS OverrideItemId, @OverrideSetBy AS OverrideSetBy,
           CAST(@OverrideSetAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OverrideSetAtEt,
           @OpenContainerId AS OpenContainerId,
           ISNULL(ob.TraysClosed, 0) AS OpenTraysClosed,
           ISNULL(ob.PartsClosed, 0) AS OpenPartsClosed
    FROM (SELECT 1 AS One) x
    LEFT JOIN Parts.Item i ON i.Id = @ItemId
    LEFT JOIN Parts.ContainerConfig cc
      ON cc.ItemId = @ItemId AND cc.ClosureMethod = N'ByWeight' AND cc.DeprecatedAt IS NULL
    OUTER APPLY (
        SELECT COUNT(*) AS TraysClosed, SUM(t.PartsClosedCount) AS PartsClosed
        FROM Lots.ContainerTray t WHERE t.ContainerId = @OpenContainerId
    ) ob;
END;
GO
