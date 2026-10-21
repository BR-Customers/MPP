-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_LogMemberLotEventsInternal.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: SILENT INTERNAL HELPER -- not called from Ignition. Super-lot
--              piece 6: writes one Lots.LotEventLog row per LOT a super-lot event
--              touches, so each LOT's own timeline shows it without knowing the
--              super-lot exists.
--
--              @MemberIdsJson is a JSON array of Quality.ControlledRunMember.Id.
--              A LOT member -> that LOT. A container member -> the tray LOTs in the
--              container NOW (Lots.ContainerTray.FinishedGoodLotId).
--
--              Description: <LotName> . Super-lot <RunNumber> . [Container <Id> . ]<ActionText>
--              (container members carry the Container segment). NewValue JSON:
--              {Lot, ControlledRun, Container|null} with {Id, Code, Name} each.
--              A container's name is 'Container <Id>' (Lots.Container has no name column).
--
--              Emits NO result set and NEVER rolls back (callers are status-row
--              procs captured by INSERT-EXEC). Call inside the caller's transaction.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_LogMemberLotEventsInternal
    @MemberIdsJson      NVARCHAR(MAX),
    @LogEventTypeCode   NVARCHAR(50),
    @ActionText         NVARCHAR(400),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @T TABLE (LotId BIGINT NOT NULL, LotName NVARCHAR(50) NOT NULL,
                      ControlledRunId BIGINT NOT NULL, RunNumber NVARCHAR(15) NOT NULL,
                      ContainerId BIGINT NULL);

    INSERT INTO @T (LotId, LotName, ControlledRunId, RunNumber, ContainerId)
    SELECT l.Id, l.LotName, r.Id, r.RunNumber, NULL
    FROM OPENJSON(@MemberIdsJson) j
    INNER JOIN Quality.ControlledRunMember m ON m.Id = TRY_CONVERT(BIGINT, j.value)
    INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
    INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE m.LotId IS NOT NULL;

    INSERT INTO @T (LotId, LotName, ControlledRunId, RunNumber, ContainerId)
    SELECT l.Id, l.LotName, r.Id, r.RunNumber, m.ContainerId
    FROM OPENJSON(@MemberIdsJson) j
    INNER JOIN Quality.ControlledRunMember m ON m.Id = TRY_CONVERT(BIGINT, j.value)
    INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
    INNER JOIN Lots.ContainerTray t ON t.ContainerId = m.ContainerId
    INNER JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
    WHERE m.ContainerId IS NOT NULL;

    DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @RunId BIGINT, @RunNumber NVARCHAR(15), @ContainerId BIGINT;
    DECLARE @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX), @ContainerName NVARCHAR(30);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT LotId, LotName, ControlledRunId, RunNumber, ContainerId FROM @T ORDER BY LotId, ControlledRunId;
    OPEN c;
    FETCH NEXT FROM c INTO @LotId, @LotName, @RunId, @RunNumber, @ContainerId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ContainerName = CASE WHEN @ContainerId IS NULL THEN NULL ELSE N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) END;
        SET @Activity = Audit.ufn_TruncateActivity(
              @LotName + N' ' + Audit.ufn_MidDot() + N' Super-lot ' + @RunNumber + N' ' + Audit.ufn_MidDot() + N' '
            + CASE WHEN @ContainerName IS NULL THEN N'' ELSE @ContainerName + N' ' + Audit.ufn_MidDot() + N' ' END
            + @ActionText);
        SET @NewValue = (
            SELECT JSON_QUERY((SELECT @LotId AS Id, @LotName AS Code, @LotName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT @RunId AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun,
                   JSON_QUERY(CASE WHEN @ContainerId IS NULL THEN NULL
                        ELSE (SELECT @ContainerId AS Id, CAST(@ContainerId AS NVARCHAR(20)) AS Code, @ContainerName AS Name
                              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END) AS Container
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = @LogEventTypeCode,
            @LogSeverityCode = N'Info', @Description = @Activity,
            @OldValue = NULL, @NewValue = @NewValue;
        FETCH NEXT FROM c INTO @LotId, @LotName, @RunId, @RunNumber, @ContainerId;
    END
    CLOSE c; DEALLOCATE c;
END;
GO
