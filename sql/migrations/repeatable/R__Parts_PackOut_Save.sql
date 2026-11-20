-- =============================================
-- Procedure:   Parts.PackOut_Save
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Version:     1.0
--
-- Description:
--   Creates or edits one named pack-out (migration 0136). Replaces
--   ContainerConfig_Create / _Update; the validation that lived in Python
--   (Parts.ContainerConfig.saveDraft) is here.
--
--   @PackOutId NULL  -> create the header + version 1. It is the default when
--                       it is the part's first active pack-out for the method.
--   @PackOutId given -> a NAME change updates the header (PackOutRenamed);
--                       any VALUE change retires the active version and saves
--                       version N+1 (PackOutVersioned). Both may happen in one
--                       call. Versions are immutable, so every box keeps the
--                       numbers it was opened on (spec D5). Nothing changed ->
--                       refused as "No changes to save.".
--   The part and closure method of an existing pack-out never change.
--
--   Rules: name trimmed and required, unique among the part's active
--   pack-outs for the method (case-insensitive, by collation); positive trays
--   per container and parts per tray; By Weight needs a positive target and a
--   positive tolerance (a zero-width window rejects every tray).
--
--   Status-row mutation (FDS-11-011): every rejection runs before BEGIN
--   TRANSACTION; CATCH is the only ROLLBACK site. Audited to Audit.ConfigLog,
--   entity PackOut.
--
-- Parameters:
--   @PackOutId BIGINT = NULL, @ItemId BIGINT, @ClosureMethod NVARCHAR(20),
--   @Name NVARCHAR(50), @TraysPerContainer INT, @PartsPerTray INT,
--   @IsSerialized BIT = 0, @DunnageCode NVARCHAR(50) = NULL,
--   @CustomerCode NVARCHAR(50) = NULL, @TargetWeight DECIMAL(10,4) = NULL,
--   @ToleranceWeight DECIMAL(10,4) = NULL, @AppUserId BIGINT.
--
-- Result: Status BIT, Message NVARCHAR(500), NewId BIGINT (the PackOutId).
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version (named pack-outs).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.PackOut_Save
    @PackOutId         BIGINT        = NULL,
    @ItemId            BIGINT,
    @ClosureMethod     NVARCHAR(20),
    @Name              NVARCHAR(50),
    @TraysPerContainer INT,
    @PartsPerTray      INT,
    @IsSerialized      BIT           = 0,
    @DunnageCode       NVARCHAR(50)  = NULL,
    @CustomerCode      NVARCHAR(50)  = NULL,
    @TargetWeight      DECIMAL(10,4) = NULL,
    @ToleranceWeight   DECIMAL(10,4) = NULL,
    @AppUserId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.PackOut_Save';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @PackOutId AS PackOutId, @ItemId AS ItemId, @ClosureMethod AS ClosureMethod, @Name AS Name,
               @TraysPerContainer AS TraysPerContainer, @PartsPerTray AS PartsPerTray, @IsSerialized AS IsSerialized,
               @DunnageCode AS DunnageCode, @CustomerCode AS CustomerCode,
               @TargetWeight AS TargetWeight, @ToleranceWeight AS ToleranceWeight
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @FailEvent NVARCHAR(50) = CASE WHEN @PackOutId IS NULL THEN N'PackOutCreated' ELSE N'PackOutVersioned' END;

    DECLARE @CleanName NVARCHAR(50) = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @DunnageCode  = NULLIF(LTRIM(RTRIM(@DunnageCode)), N'');
    SET @CustomerCode = NULLIF(LTRIM(RTRIM(@CustomerCode)), N'');
    SET @IsSerialized = ISNULL(@IsSerialized, 0);

    DECLARE @HdrItemId BIGINT, @HdrMethod NVARCHAR(20), @HdrName NVARCHAR(50);
    DECLARE @CurCfgId BIGINT, @CurVersion INT, @CurTrays INT, @CurPpt INT, @CurSer BIT,
            @CurDunnage NVARCHAR(50), @CurCustomer NVARCHAR(50), @CurTarget DECIMAL(10,4), @CurTol DECIMAL(10,4);
    DECLARE @NameChanged BIT = 0, @ValuesChanged BIT = 0;
    DECLARE @PartNumber NVARCHAR(50), @MethodName NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500), @OldValue NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ================= Pre-transaction validations =================
        IF @ItemId IS NULL OR @ClosureMethod IS NULL OR @AppUserId IS NULL
           OR @TraysPerContainer IS NULL OR @PartsPerTray IS NULL
            SET @Message = N'Required parameter missing (ItemId, ClosureMethod, TraysPerContainer, PartsPerTray, AppUserId).';
        ELSE IF @CleanName IS NULL
            SET @Message = N'A pack-out name is required.';
        ELSE IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
            SET @Message = N'Invalid or deprecated part.';
        ELSE IF NOT EXISTS (SELECT 1 FROM Parts.ClosureMethodCode WHERE Code = @ClosureMethod AND DeprecatedAt IS NULL)
            SET @Message = N'Invalid closure method.';
        ELSE IF @TraysPerContainer <= 0
            SET @Message = N'Enter a positive trays per container.';
        ELSE IF @PartsPerTray <= 0
            SET @Message = N'Enter a positive parts per tray.';
        ELSE IF @ClosureMethod = N'ByWeight' AND (@TargetWeight IS NULL OR @TargetWeight <= 0)
            SET @Message = N'The By Weight pack-out requires a positive target weight.';
        ELSE IF @ClosureMethod = N'ByWeight' AND (@ToleranceWeight IS NULL OR @ToleranceWeight <= 0)
            SET @Message = N'The By Weight pack-out requires a positive tolerance - a zero-width window rejects every tray.';
        ELSE
            SET @Message = NULL;

        IF @Message IS NULL AND @PackOutId IS NOT NULL
        BEGIN
            SELECT @HdrItemId = ItemId, @HdrMethod = ClosureMethod, @HdrName = Name
            FROM Parts.PackOut WHERE Id = @PackOutId AND DeprecatedAt IS NULL;
            IF @HdrItemId IS NULL
                SET @Message = N'Pack-out not found or removed.';
            ELSE IF @HdrItemId <> @ItemId OR @HdrMethod <> @ClosureMethod
                SET @Message = N'A pack-out''s part and closure method cannot change.';
        END

        IF @Message IS NULL AND EXISTS (
            SELECT 1 FROM Parts.PackOut
            WHERE ItemId = @ItemId AND ClosureMethod = @ClosureMethod AND Name = @CleanName
              AND DeprecatedAt IS NULL AND (@PackOutId IS NULL OR Id <> @PackOutId))
            SET @Message = N'A pack-out named ''' + @CleanName + N''' already exists for this part and closure method.';

        IF @Message IS NULL AND @PackOutId IS NOT NULL
        BEGIN
            SELECT @CurCfgId = Id, @CurVersion = VersionNumber, @CurTrays = TraysPerContainer, @CurPpt = PartsPerTray,
                   @CurSer = IsSerialized, @CurDunnage = DunnageCode, @CurCustomer = CustomerCode,
                   @CurTarget = TargetWeight, @CurTol = ToleranceWeight
            FROM Parts.ContainerConfig WHERE PackOutId = @PackOutId AND DeprecatedAt IS NULL;

            SET @NameChanged = CASE WHEN @HdrName COLLATE Latin1_General_BIN2 = @CleanName COLLATE Latin1_General_BIN2 THEN 0 ELSE 1 END;
            SET @ValuesChanged = CASE WHEN @CurCfgId IS NULL
                  OR @CurTrays <> @TraysPerContainer OR @CurPpt <> @PartsPerTray OR @CurSer <> @IsSerialized
                  OR ISNULL(@CurDunnage, N'') <> ISNULL(@DunnageCode, N'')
                  OR ISNULL(@CurCustomer, N'') <> ISNULL(@CustomerCode, N'')
                  OR ISNULL(@CurTarget, -1) <> ISNULL(@TargetWeight, -1)
                  OR ISNULL(@CurTol, -1) <> ISNULL(@ToleranceWeight, -1)
                THEN 1 ELSE 0 END;
            IF @NameChanged = 0 AND @ValuesChanged = 0
                SET @Message = N'No changes to save.';
        END

        IF @Message IS NOT NULL
        BEGIN
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut',
                    @EntityId = @PackOutId, @LogEventTypeCode = @FailEvent, @FailureReason = @Message,
                    @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SET @PartNumber = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);
        SET @MethodName = (SELECT Name FROM Parts.ClosureMethodCode WHERE Code = @ClosureMethod);
        DECLARE @ValuesText NVARCHAR(400) =
            CAST(@PartsPerTray AS NVARCHAR(20)) + N'/tray x ' + CAST(@TraysPerContainer AS NVARCHAR(20))
            + CASE WHEN @TargetWeight IS NOT NULL
                   THEN N'; ' + CAST(CAST(@TargetWeight AS DECIMAL(10,2)) AS NVARCHAR(20)) + N' +/- '
                        + CAST(CAST(@ToleranceWeight AS DECIMAL(10,2)) AS NVARCHAR(20)) ELSE N'' END
            + CASE WHEN @IsSerialized = 1 THEN N'; serialized' ELSE N'' END
            + CASE WHEN @DunnageCode IS NOT NULL THEN N'; dunnage ' + @DunnageCode ELSE N'' END;

        -- ================= Mutation =================
        BEGIN TRANSACTION;

        IF @PackOutId IS NULL
        BEGIN
            INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId)
            VALUES (@ItemId, @ClosureMethod, @CleanName,
                    CASE WHEN EXISTS (SELECT 1 FROM Parts.PackOut WITH (UPDLOCK, HOLDLOCK)
                                      WHERE ItemId = @ItemId AND ClosureMethod = @ClosureMethod
                                        AND IsDefault = 1 AND DeprecatedAt IS NULL) THEN 0 ELSE 1 END,
                    @AppUserId);
            SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

            INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray,
                                               IsSerialized, DunnageCode, CustomerCode, TargetWeight, ToleranceWeight, CreatedByUserId)
            VALUES (@ItemId, @ClosureMethod, @NewId, 1, @TraysPerContainer, @PartsPerTray,
                    @IsSerialized, @DunnageCode, @CustomerCode, @TargetWeight, @ToleranceWeight, @AppUserId);

            SET @Activity = Audit.ufn_TruncateActivity(@PartNumber + N' ' + Audit.ufn_MidDot() + N' Pack-Out ' + Audit.ufn_MidDot()
                + N' ' + @CleanName + N' (' + @MethodName + N') Created; ' + @ValuesText);
            SET @NewValue = (SELECT p.Id, p.Name, p.ClosureMethod, p.IsDefault,
                    JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = p.ItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                    JSON_QUERY((SELECT cc.Id, cc.VersionNumber, cc.TraysPerContainer, cc.PartsPerTray, cc.IsSerialized, cc.DunnageCode,
                                       cc.CustomerCode, cc.TargetWeight, cc.ToleranceWeight
                                FROM Parts.ContainerConfig cc WHERE cc.PackOutId = p.Id AND cc.DeprecatedAt IS NULL FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Version
                FROM Parts.PackOut p WHERE p.Id = @NewId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC Audit.Audit_LogConfigChange @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @NewId,
                @LogEventTypeCode = N'PackOutCreated', @LogSeverityCode = N'Info', @Description = @Activity,
                @OldValue = NULL, @NewValue = @NewValue;
            SET @Message = N'Pack-out created.';
        END
        ELSE
        BEGIN
            SET @NewId = @PackOutId;

            IF @NameChanged = 1
            BEGIN
                UPDATE Parts.PackOut SET Name = @CleanName, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @PackOutId;
                SET @Activity = Audit.ufn_TruncateActivity(@PartNumber + N' ' + Audit.ufn_MidDot() + N' Pack-Out ' + Audit.ufn_MidDot()
                    + N' ' + @HdrName + N' -> ' + @CleanName + N' (' + @MethodName + N') Renamed');
                SET @OldValue = (SELECT @PackOutId AS Id, @HdrName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                SET @NewValue = (SELECT @PackOutId AS Id, @CleanName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                EXEC Audit.Audit_LogConfigChange @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
                    @LogEventTypeCode = N'PackOutRenamed', @LogSeverityCode = N'Info', @Description = @Activity,
                    @OldValue = @OldValue, @NewValue = @NewValue;
            END

            IF @ValuesChanged = 1
            BEGIN
                SET @OldValue = (SELECT cc.Id, cc.VersionNumber, cc.TraysPerContainer, cc.PartsPerTray, cc.IsSerialized, cc.DunnageCode,
                                        cc.CustomerCode, cc.TargetWeight, cc.ToleranceWeight
                                 FROM Parts.ContainerConfig cc WHERE cc.Id = @CurCfgId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                UPDATE Parts.ContainerConfig SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @CurCfgId;
                DECLARE @NextVersion INT = ISNULL((SELECT MAX(VersionNumber) FROM Parts.ContainerConfig WHERE PackOutId = @PackOutId), 0) + 1;
                INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray,
                                                   IsSerialized, DunnageCode, CustomerCode, TargetWeight, ToleranceWeight, CreatedByUserId)
                VALUES (@ItemId, @ClosureMethod, @PackOutId, @NextVersion, @TraysPerContainer, @PartsPerTray,
                        @IsSerialized, @DunnageCode, @CustomerCode, @TargetWeight, @ToleranceWeight, @AppUserId);
                SET @NewValue = (SELECT cc.Id, cc.VersionNumber, cc.TraysPerContainer, cc.PartsPerTray, cc.IsSerialized, cc.DunnageCode,
                                        cc.CustomerCode, cc.TargetWeight, cc.ToleranceWeight
                                 FROM Parts.ContainerConfig cc WHERE cc.Id = SCOPE_IDENTITY() FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                SET @Activity = Audit.ufn_TruncateActivity(@PartNumber + N' ' + Audit.ufn_MidDot() + N' Pack-Out ' + Audit.ufn_MidDot()
                    + N' ' + @CleanName + N' (' + @MethodName + N') v' + CAST(@NextVersion AS NVARCHAR(10)) + N'; ' + @ValuesText);
                EXEC Audit.Audit_LogConfigChange @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
                    @LogEventTypeCode = N'PackOutVersioned', @LogSeverityCode = N'Info', @Description = @Activity,
                    @OldValue = @OldValue, @NewValue = @NewValue;
            END
            SET @Message = N'Pack-out saved.';
        END

        COMMIT TRANSACTION;
        SET @Status = 1;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId = NULL;
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
                @LogEventTypeCode = @FailEvent, @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
