-- =============================================
-- Procedure:   Parts.ContainerConfig_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.3
--
-- Description:
--   Updates mutable fields of an active ContainerConfig. ItemId is
--   immutable — to associate a config with a different Item, deprecate
--   this one and create a new one. Sets UpdatedAt = SYSUTCDATETIME() on
--   every successful update.
--
--   @ClosureMethod and @TargetWeight are OI-02 columns (scale-driven
--   container closure) — accepted as optional parameters pending MPP
--   customer validation. Safe to leave NULL today.
--
-- Parameters (input):
--   @Id BIGINT                       - Required.
--   @TraysPerContainer INT           - Required.
--   @PartsPerTray INT                - Required.
--   @IsSerialized BIT = 0
--   @DunnageCode NVARCHAR(50) NULL
--   @CustomerCode NVARCHAR(50) NULL
--   @ClosureMethod NVARCHAR(20) NULL   -- OI-02 pending
--   @TargetWeight DECIMAL(10,4) NULL   -- OI-02 pending
--   @AppUserId BIGINT                - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Parts.ContainerConfig
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.3: @MaxParts added (OI-12)
--   2026-04-27 - 2.2 - OI-12 correction: @MaxParts removed (moved to Parts.Item)
--   2026-05-29 - 2.3 - Audit-readability convention (Slice 5 Item core):
--                       <PartNumber> . Container Config . Updated <field
--                       old->new ...> narrative (changed fields only) +
--                       resolved-FK Old/NewValue JSON (Item). Old values
--                       captured BEFORE the UPDATE.
--   2026-07-17 - 2.4 - ClosureMethod is now immutable (the per-method
--                       discriminator): removed from the UPDATE SET + audit
--                       diff; a change attempt is rejected pre-transaction.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_Update
    @Id                BIGINT,
    @TraysPerContainer INT,
    @PartsPerTray      INT,
    @IsSerialized      BIT            = 0,
    @DunnageCode       NVARCHAR(50)   = NULL,
    @CustomerCode      NVARCHAR(50)   = NULL,
    @ClosureMethod     NVARCHAR(20)   = NULL,
    @TargetWeight      DECIMAL(10,4)  = NULL,
    @AppUserId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.ContainerConfig_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @TraysPerContainer AS TraysPerContainer,
                @PartsPerTray AS PartsPerTray, @IsSerialized AS IsSerialized,
                @DunnageCode AS DunnageCode, @CustomerCode AS CustomerCode,
                @ClosureMethod AS ClosureMethod, @TargetWeight AS TargetWeight
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @TraysPerContainer IS NULL OR @PartsPerTray IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'ContainerConfig not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ClosureMethod is immutable (the per-method discriminator). A passed
        -- value that differs from the row's current method is rejected;
        -- deprecate + create a new config to switch methods. When @ClosureMethod
        -- is NULL or matches, the method is simply left unchanged (never SET).
        IF @ClosureMethod IS NOT NULL
           AND @ClosureMethod <> (SELECT ClosureMethod FROM Parts.ContainerConfig WHERE Id = @Id)
        BEGIN
            SET @Message = N'ClosureMethod is immutable; deprecate and create a new config to change it.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Capture OLD values BEFORE the UPDATE (for field-diff + subject) =====
        DECLARE @ItemId            BIGINT;
        DECLARE @OldTrays          INT;
        DECLARE @OldPartsPerTray   INT;
        DECLARE @OldIsSerialized   BIT;
        DECLARE @OldDunnageCode    NVARCHAR(50);
        DECLARE @OldCustomerCode   NVARCHAR(50);
        DECLARE @OldClosureMethod  NVARCHAR(20);
        DECLARE @OldTargetWeight   DECIMAL(10,4);

        SELECT @ItemId           = ItemId,
               @OldTrays         = TraysPerContainer,
               @OldPartsPerTray  = PartsPerTray,
               @OldIsSerialized  = IsSerialized,
               @OldDunnageCode   = DunnageCode,
               @OldCustomerCode  = CustomerCode,
               @OldClosureMethod = ClosureMethod,
               @OldTargetWeight  = TargetWeight
        FROM Parts.ContainerConfig WHERE Id = @Id;

        -- Subject: parent Item's PartNumber
        DECLARE @PartNumber NVARCHAR(50) =
            (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);

        -- Resolved-FK OldValue snapshot (pre-update state)
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                            FROM Parts.Item i WHERE i.Id = cc.ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))     AS Item,
                cc.TraysPerContainer,
                cc.PartsPerTray,
                cc.IsSerialized,
                cc.DunnageCode,
                cc.CustomerCode,
                cc.ClosureMethod,
                cc.TargetWeight
            FROM Parts.ContainerConfig cc
            WHERE cc.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- Build the field-diff Action prose: changed fields only.
        DECLARE @Arrow NVARCHAR(3) = NCHAR(8594);

        DECLARE @Diff NVARCHAR(MAX) = STUFF(CONCAT(
            CASE WHEN ISNULL(@OldTrays, -2147483648) <> ISNULL(@TraysPerContainer, -2147483648)
                 THEN N', TraysPerContainer ' + ISNULL(CAST(@OldTrays AS NVARCHAR(20)), N'null') + @Arrow + ISNULL(CAST(@TraysPerContainer AS NVARCHAR(20)), N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldPartsPerTray, -2147483648) <> ISNULL(@PartsPerTray, -2147483648)
                 THEN N', PartsPerTray ' + ISNULL(CAST(@OldPartsPerTray AS NVARCHAR(20)), N'null') + @Arrow + ISNULL(CAST(@PartsPerTray AS NVARCHAR(20)), N'null')
                 ELSE N'' END,
            CASE WHEN @OldIsSerialized <> @IsSerialized
                 THEN N', IsSerialized ' + CASE WHEN @OldIsSerialized = 1 THEN N'true' ELSE N'false' END + @Arrow + CASE WHEN @IsSerialized = 1 THEN N'true' ELSE N'false' END
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldDunnageCode, N'') <> ISNULL(@DunnageCode, N'')
                 THEN N', DunnageCode ' + ISNULL(N'"' + @OldDunnageCode + N'"', N'null') + @Arrow + ISNULL(N'"' + @DunnageCode + N'"', N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldCustomerCode, N'') <> ISNULL(@CustomerCode, N'')
                 THEN N', CustomerCode ' + ISNULL(N'"' + @OldCustomerCode + N'"', N'null') + @Arrow + ISNULL(N'"' + @CustomerCode + N'"', N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldTargetWeight, -999999) <> ISNULL(@TargetWeight, -999999)
                 THEN N', TargetWeight ' + ISNULL(CAST(@OldTargetWeight AS NVARCHAR(40)), N'null') + @Arrow + ISNULL(CAST(@TargetWeight AS NVARCHAR(40)), N'null')
                 ELSE N'' END
        ), 1, 2, N'');  -- strip leading ", "

        IF @Diff IS NULL OR @Diff = N''
            SET @Diff = N'no field changes';

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            ISNULL(@PartNumber, N'(unknown item)') + N' ' + Audit.ufn_MidDot() +
            N' Container Config ' + Audit.ufn_MidDot() + N' Updated ' + @Diff;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        BEGIN TRANSACTION;

        -- ClosureMethod is intentionally NOT in the SET list (immutable; the
        -- pre-transaction guard above rejects any change attempt).
        UPDATE Parts.ContainerConfig
        SET TraysPerContainer = @TraysPerContainer,
            PartsPerTray      = @PartsPerTray,
            IsSerialized      = @IsSerialized,
            DunnageCode       = @DunnageCode,
            CustomerCode      = @CustomerCode,
            TargetWeight      = @TargetWeight,
            UpdatedAt         = SYSUTCDATETIME()
        WHERE Id = @Id;

        -- Resolved-FK NewValue snapshot (post-update state)
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                            FROM Parts.Item i WHERE i.Id = cc.ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))     AS Item,
                cc.TraysPerContainer,
                cc.PartsPerTray,
                cc.IsSerialized,
                cc.DunnageCode,
                cc.CustomerCode,
                cc.ClosureMethod,
                cc.TargetWeight
            FROM Parts.ContainerConfig cc
            WHERE cc.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ContainerConfig',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'ContainerConfig updated successfully.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
