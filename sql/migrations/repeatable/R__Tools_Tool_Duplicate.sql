-- =============================================
-- Procedure:   Tools.Tool_Duplicate
-- Author:      Blue Ridge Automation
-- Created:     2026-08-18
-- Version:     1.0
--
-- Description:
--   Clones an existing Tool's CONFIGURATION onto a brand-new Tool row with
--   an operator-supplied Code + Name. One transaction; all-or-nothing.
--
--   COPIED (configuration -- describes the design of the tool):
--     * ToolTypeId          - a duplicate is the same kind of tool
--     * Description         - engineering text, describes the design
--     * DieRankId           - MPP Quality's rank for this die design
--     * ShotLimit           - design life (shots before rebuild), NOT a counter
--     * Tools.ToolCavity    - every NON-deprecated cavity on the source, copied
--                             WHOLE: CavityNumber, Description AND StatusCodeId.
--                             A Closed / Scrapped cavity is a decision about the
--                             die DESIGN, not wear, so it carries over.
--     * Tools.ToolAttribute - every attribute value whose definition is still
--                             active (tonnage, cycle time, insert count, ...).
--
--   RESET (per-physical-asset history / live state -- must start clean):
--     * Code / Name         - operator-supplied; identity is never cloned
--     * StatusCodeId        - forced to 'Active'. A duplicate of a Retired or
--                             Scrapped die is a NEW asset, not a retired one.
--     * ShotCount           - 0. Lifetime shot counter of the SOURCE steel.
--     * Tools.ToolAssignment - NOT copied. Mount history is per-physical-asset,
--                             and UQ_ToolAssignment_ActiveCell would reject a
--                             second tool mounted on the same cell anyway.
--     * CreatedAt / CreatedByUserId - stamped fresh from @AppUserId / UTC now.
--     * DeprecatedAt        - NULL. A clone of a retired die is not retired.
--     No LOT / ProductionEvent / genealogy rows reference the new tool: those
--     tables point AT Tools.Tool, so a new Id simply starts with none.
--
--   Deprecated-FK carry-forward guards (mirrors Tool_Create's validation, which
--   rejects a deprecated DieRankId / definition on user input):
--     * Source DieRank deprecated  -> new tool gets DieRankId = NULL, and the
--                                     success @Message says so.
--     * Attribute definition deprecated -> that attribute value is skipped, and
--                                     the success @Message reports the count.
--   Neither is an error: the source's configuration is still worth cloning.
--
--   The SOURCE may itself be deprecated. Duplicating a retired die to build its
--   replacement is the main reason this proc exists, and the Tools list feeds
--   the screen with includeDeprecated=1, so the UI can select one.
--
-- Parameters (input):
--   @SourceToolId BIGINT  - FK -> Tools.Tool. Required. Deprecated rows allowed.
--   @Code NVARCHAR(50)    - New tool Code. Required. Unique across ALL Tools
--                           (UQ_Tool_Code is a total constraint -- deprecated
--                           rows included), so the check here is total too.
--   @Name NVARCHAR(100)   - New tool Name. Required.
--   @AppUserId BIGINT     - User performing the action. Required for audit.
--
-- Result set:
--   Single row: Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success; NewId is the new Tools.Tool.Id. NULL on failure.
--   (No OUTPUT params -- per FDS-11-011.)
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType, Tools.ToolStatusCode, Tools.DieRank,
--           Tools.ToolCavity, Tools.ToolCavityStatusCode,
--           Tools.ToolAttribute, Tools.ToolAttributeDefinition
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--
-- Error Handling:
--   Every rejecting validation runs BEFORE BEGIN TRANSACTION, emits the status
--   row and RETURNs with no open transaction -- a ROLLBACK inside a proc that
--   was invoked via INSERT-EXEC throws Msg 3915, so the CATCH is the only legal
--   ROLLBACK site. This proc EXECs no sibling status-row proc for the same
--   reason (the Audit_* procs emit no result set, so they are safe); the Tool /
--   cavity / attribute inserts are INLINED mirrors of Tools.Tool_Create,
--   Tools.ToolCavity_SaveAll and Tools.ToolAttribute_SaveAll respectively.
--
-- Audit:
--   One ConfigLog row, EntityType 'Tool', EventType 'Created', EntityId = @NewId.
--   Description: <NewCode> - <NewName> . Duplicated from <SrcCode> - <SrcName>;
--                +N cavities, +M attributes
--   OldValue = resolved source snapshot, NewValue = resolved new snapshot, both
--   in the same shape so the ConfigChangeDetail popup diffs them cleanly.
--
-- Change Log:
--   2026-08-18 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_Duplicate
    @SourceToolId BIGINT,
    @Code         NVARCHAR(50),
    @Name         NVARCHAR(100),
    @AppUserId    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Result variables (returned via SELECT instead of OUTPUT)
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Tools.Tool_Duplicate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @SourceToolId AS SourceToolId,
                @Code         AS Code,
                @Name         AS Name
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Source snapshot
    DECLARE @SrcToolTypeId   BIGINT;
    DECLARE @SrcCode         NVARCHAR(50);
    DECLARE @SrcName         NVARCHAR(100);
    DECLARE @SrcDescription  NVARCHAR(500);
    DECLARE @SrcDieRankId    BIGINT;
    DECLARE @SrcShotLimit    INT;

    -- Carry-forward decisions
    DECLARE @ActiveToolStatusId   BIGINT;
    DECLARE @NewDieRankId         BIGINT = NULL;
    DECLARE @RankDropped          BIT    = 0;
    DECLARE @CavityCount          INT    = 0;
    DECLARE @AttributeCount       INT    = 0;
    DECLARE @AttributeSkipped     INT    = 0;

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @SourceToolId IS NULL OR @Code IS NULL OR @Name IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @SourceToolId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SET @Code = LTRIM(RTRIM(@Code));
        SET @Name = LTRIM(RTRIM(@Name));

        IF @Code = N'' OR @Name = N''
        BEGIN
            SET @Message = N'Code and Name cannot be blank.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @SourceToolId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Source lookup. Deprecated sources ARE allowed (see header) -- the row
        -- just has to exist.
        SELECT @SrcToolTypeId  = t.ToolTypeId,
               @SrcCode        = t.Code,
               @SrcName        = t.Name,
               @SrcDescription = t.Description,
               @SrcDieRankId   = t.DieRankId,
               @SrcShotLimit   = t.ShotLimit
        FROM Tools.Tool t
        WHERE t.Id = @SourceToolId;

        IF @SrcToolTypeId IS NULL
        BEGIN
            SET @Message = N'Source tool not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @SourceToolId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================
        -- Code unique across ALL Tools (deprecated included -- UQ_Tool_Code is
        -- a total constraint). Mirrors Tools.Tool_Create.
        IF EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = @Code)
        BEGIN
            SET @Message = N'A Tool with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @SourceToolId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @ActiveToolStatusId = Id
        FROM Tools.ToolStatusCode
        WHERE Code = N'Active';

        IF @ActiveToolStatusId IS NULL
        BEGIN
            SET @Message = N'ToolStatusCode ''Active'' is missing from the database.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @SourceToolId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Carry-forward decisions (no rejection -- see header)
        -- ====================
        IF @SrcDieRankId IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM Tools.DieRank
                       WHERE Id = @SrcDieRankId AND DeprecatedAt IS NULL)
                SET @NewDieRankId = @SrcDieRankId;
            ELSE
                SET @RankDropped = 1;
        END

        SELECT @CavityCount = COUNT(*)
        FROM Tools.ToolCavity
        WHERE ToolId = @SourceToolId AND DeprecatedAt IS NULL;

        SELECT @AttributeCount = COUNT(*)
        FROM Tools.ToolAttribute ta
        INNER JOIN Tools.ToolAttributeDefinition tad
                ON tad.Id = ta.ToolAttributeDefinitionId
        WHERE ta.ToolId = @SourceToolId AND tad.DeprecatedAt IS NULL;

        SELECT @AttributeSkipped = COUNT(*)
        FROM Tools.ToolAttribute ta
        INNER JOIN Tools.ToolAttributeDefinition tad
                ON tad.Id = ta.ToolAttributeDefinitionId
        WHERE ta.ToolId = @SourceToolId AND tad.DeprecatedAt IS NOT NULL;

        -- ====================
        -- Audit narrative (source half, captured PRE-mutation)
        -- ====================
        DECLARE @MidDot NVARCHAR(10) = Audit.ufn_MidDot();
        DECLARE @Dash   NVARCHAR(10) = NCHAR(8212);   -- em dash, ASCII-safe source
        DECLARE @Arrow  NVARCHAR(10) = NCHAR(8594);   -- right arrow, field-diff notation

        DECLARE @Subject NVARCHAR(600) = @Code + N' ' + @Dash + N' ' + @Name;
        DECLARE @SourceLabel NVARCHAR(600) =
            @SrcCode + CASE WHEN @SrcName IS NOT NULL
                            THEN N' ' + @Dash + N' ' + @SrcName ELSE N'' END;

        DECLARE @Action NVARCHAR(MAX) =
            N'Duplicated from ' + @SourceLabel
            + N'; +' + CAST(@CavityCount    AS NVARCHAR(10)) + N' cavities'
            + N', +' + CAST(@AttributeCount AS NVARCHAR(10)) + N' attributes'
            + CASE WHEN @RankDropped = 1
                   THEN N'; ~DieRank ' + @Arrow + N' null (rank deprecated)'
                   ELSE N'' END
            + CASE WHEN @AttributeSkipped > 0
                   THEN N'; -' + CAST(@AttributeSkipped AS NVARCHAR(10))
                        + N' attributes skipped (definition deprecated)'
                   ELSE N'' END;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + @MidDot + N' ' + @Action);

        -- Resolved-name FK sub-objects per the audit convention.
        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT
                t.Id,
                t.Code,
                t.Name,
                t.Description,
                JSON_QUERY((SELECT tt.Id, tt.Code, tt.Name FROM Tools.ToolType tt
                 WHERE tt.Id = t.ToolTypeId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))               AS ToolType,
                JSON_QUERY((SELECT dr.Id, dr.Code, dr.Name FROM Tools.DieRank dr
                 WHERE dr.Id = t.DieRankId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))               AS DieRank,
                JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Tools.ToolStatusCode sc
                 WHERE sc.Id = t.StatusCodeId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))               AS Status,
                t.ShotCount,
                t.ShotLimit,
                JSON_QUERY((SELECT c.CavityNumber, csc.Code AS Status, c.Description
                 FROM Tools.ToolCavity c
                 INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = c.StatusCodeId
                 WHERE c.ToolId = t.Id AND c.DeprecatedAt IS NULL
                 ORDER BY c.CavityNumber
                 FOR JSON PATH))                                      AS Cavities,
                JSON_QUERY((SELECT tad.Code AS AttributeCode, tad.Name AS AttributeName, ta.Value
                 FROM Tools.ToolAttribute ta
                 INNER JOIN Tools.ToolAttributeDefinition tad
                         ON tad.Id = ta.ToolAttributeDefinitionId
                 WHERE ta.ToolId = t.Id AND tad.DeprecatedAt IS NULL
                 ORDER BY tad.SortOrder, tad.Code
                 FOR JSON PATH))                                      AS Attributes
            FROM Tools.Tool t
            WHERE t.Id = @SourceToolId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        -- --- INLINE mirror of Tools.Tool_Create (identity + config carry-over).
        -- Inlined, not EXEC'd: Tool_Create emits its own status row, and this
        -- proc is itself captured via INSERT-EXEC. Status is forced Active and
        -- ShotCount defaults to 0 -- both are per-asset state, never cloned.
        INSERT INTO Tools.Tool
            (ToolTypeId, Code, Name, Description, DieRankId, StatusCodeId,
             ShotLimit, CreatedAt, CreatedByUserId)
        VALUES
            (@SrcToolTypeId, @Code, @Name, @SrcDescription, @NewDieRankId,
             @ActiveToolStatusId, @SrcShotLimit, SYSUTCDATETIME(), @AppUserId);

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- --- INLINE mirror of Tools.ToolCavity_SaveAll (insert leg only).
        -- The WHOLE cavity row is design: layout (CavityNumber + Description)
        -- AND status carry over as-is. A Closed / Scrapped cavity reflects a
        -- decision about the die DESIGN (a cavity blanked off in the drawing),
        -- not wear on one piece of steel, so the duplicate inherits it.
        INSERT INTO Tools.ToolCavity
            (ToolId, CavityNumber, StatusCodeId, Description,
             CreatedAt, CreatedByUserId)
        SELECT @NewId, c.CavityNumber, c.StatusCodeId, c.Description,
               SYSUTCDATETIME(), @AppUserId
        FROM Tools.ToolCavity c
        WHERE c.ToolId = @SourceToolId AND c.DeprecatedAt IS NULL;

        -- --- INLINE mirror of Tools.ToolAttribute_SaveAll (insert leg only).
        -- Values whose definition has since been deprecated are skipped, the
        -- same way Tool_Create rejects a deprecated FK on user input.
        INSERT INTO Tools.ToolAttribute
            (ToolId, ToolAttributeDefinitionId, Value,
             UpdatedAt, UpdatedByUserId)
        SELECT @NewId, ta.ToolAttributeDefinitionId, ta.Value,
               SYSUTCDATETIME(), @AppUserId
        FROM Tools.ToolAttribute ta
        INNER JOIN Tools.ToolAttributeDefinition tad
                ON tad.Id = ta.ToolAttributeDefinitionId
        WHERE ta.ToolId = @SourceToolId AND tad.DeprecatedAt IS NULL;

        -- Tools.ToolAssignment is deliberately NOT copied -- see header.

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                t.Id,
                t.Code,
                t.Name,
                t.Description,
                JSON_QUERY((SELECT tt.Id, tt.Code, tt.Name FROM Tools.ToolType tt
                 WHERE tt.Id = t.ToolTypeId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))               AS ToolType,
                JSON_QUERY((SELECT dr.Id, dr.Code, dr.Name FROM Tools.DieRank dr
                 WHERE dr.Id = t.DieRankId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))               AS DieRank,
                JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Tools.ToolStatusCode sc
                 WHERE sc.Id = t.StatusCodeId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))               AS Status,
                t.ShotCount,
                t.ShotLimit,
                JSON_QUERY((SELECT c.CavityNumber, csc.Code AS Status, c.Description
                 FROM Tools.ToolCavity c
                 INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = c.StatusCodeId
                 WHERE c.ToolId = t.Id AND c.DeprecatedAt IS NULL
                 ORDER BY c.CavityNumber
                 FOR JSON PATH))                                      AS Cavities,
                JSON_QUERY((SELECT tad.Code AS AttributeCode, tad.Name AS AttributeName, ta.Value
                 FROM Tools.ToolAttribute ta
                 INNER JOIN Tools.ToolAttributeDefinition tad
                         ON tad.Id = ta.ToolAttributeDefinitionId
                 WHERE ta.ToolId = t.Id AND tad.DeprecatedAt IS NULL
                 ORDER BY tad.SortOrder, tad.Code
                 FOR JSON PATH))                                      AS Attributes,
                JSON_QUERY((SELECT s.Id, s.Code, s.Name FROM Tools.Tool s
                 WHERE s.Id = @SourceToolId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))               AS DuplicatedFrom
            FROM Tools.Tool t
            WHERE t.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- Success audit INSIDE the transaction -- rolls back atomically.
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Tool',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Duplicated ' + @SrcCode + N'. Copied '
                     + CAST(@CavityCount    AS NVARCHAR(10)) + N' cavity(ies), '
                     + CAST(@AttributeCount AS NVARCHAR(10)) + N' attribute(s).'
                     + CASE WHEN @RankDropped = 1
                            THEN N' Die rank not carried over (deprecated).'
                            ELSE N'' END
                     + CASE WHEN @AttributeSkipped > 0
                            THEN N' ' + CAST(@AttributeSkipped AS NVARCHAR(10))
                                 + N' attribute(s) skipped (definition deprecated).'
                            ELSE N'' END;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Tool',
                @EntityId            = @SourceToolId,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; don't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
