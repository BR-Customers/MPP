-- =============================================
-- 2026-08-17_drop_trim_steps_for_untrimmed_parts.sql
--
-- Purpose:
--   The six parts the plant manager's changeover notes take off trim entirely
--   (6MD manifold plate + every oil pan part except the 6MA oil pan) still carry
--   TrimIn / TrimOut steps in their published route. Because the route -- not
--   eligibility -- drives the terminal queue, they would still be routed through
--   a trim shop they are no longer eligible at. This drops those two steps.
--
--   Companion to 2026-08-17_prod_trim_eligibility_correction.sql, which fixed
--   the eligibility half.
--
--   Before:  DieCast -> TrimIn -> TrimOut -> MachiningIn -> AssemblyOut
--   After:   DieCast -> MachiningIn -> AssemblyOut
--
--   Still route-legal: the OriginMint (DieCast) stays first, and there is
--   exactly one ConsumeMint (AssemblyOut) and it stays last -- the two rules
--   Parts.RouteTemplate_Publish enforces.
--
-- Method:
--   Published routes are immutable by design, so this uses the normal
--   versioning path rather than touching Parts.RouteStep directly:
--       RouteTemplate_CreateNewVersion  (draft vN+1, steps copied)
--     -> RouteStep_Remove x2            (sequence auto-compacts)
--     -> RouteTemplate_Publish          (validates legality, deprecates vN)
--
--   Idempotent: a part whose active published route already has no trim steps
--   is skipped. Safe to re-run.
--
--   No outer transaction -- each proc owns its own transaction and audit write,
--   so a partial run is safe to resume.
--
-- Usage:
--   DryRun=1 (default) prints the plan and changes nothing. DryRun=0 executes.
--
--   sqlcmd -S <host> -d <db> -I -C -b -v DryRun=1 \
--          -i 2026-08-17_drop_trim_steps_for_untrimmed_parts.sql
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DryRun BIT = TRY_CONVERT(BIT, N'$(DryRun)');
IF @DryRun IS NULL SET @DryRun = 1;

DECLARE @AppUserId BIGINT;
SELECT TOP 1 @AppUserId = Id
FROM Location.AppUser
WHERE DeprecatedAt IS NULL
  AND AdAccount IN (N'admin1', N'dev.user', N'system.bootstrap')
ORDER BY CASE AdAccount WHEN N'admin1' THEN 0 WHEN N'dev.user' THEN 1 ELSE 2 END;

IF @AppUserId IS NULL
BEGIN
    RAISERROR(N'ABORT: could not resolve an AppUser to attribute the change to.', 16, 1);
    RETURN;
END

-- The six parts that carry no trim eligibility.
DECLARE @Parts TABLE (PartNumber NVARCHAR(100) PRIMARY KEY);
INSERT INTO @Parts (PartNumber) VALUES
   (N'17145-6MDA')       -- 6MD Manifold Plate Raw
  ,(N'11200-5J6-A000')   -- 5J6-1 Oil Pan Raw
  ,(N'1120A-64AA')       -- 64A Oil Pan Raw
  ,(N'11200-6FB-A000')   -- 6FB Oil Pan Raw
  ,(N'11221-64AA-A010')  -- Baffle Plate A
  ,(N'11222-64A-A001');  -- Baffle Plate B

-- Guard: none of these may carry trim eligibility (the companion script must
-- have run first), otherwise the two halves would disagree.
IF EXISTS (
    SELECT 1
    FROM @Parts p
    JOIN Parts.Item i          ON i.PartNumber = p.PartNumber AND i.DeprecatedAt IS NULL
    JOIN Parts.ItemLocation il ON il.ItemId = i.Id AND il.DeprecatedAt IS NULL
    JOIN Location.Location l   ON l.Id = il.LocationId
    WHERE l.Code IN (N'TRIM1', N'TRIM2'))
BEGIN
    RAISERROR(N'ABORT: one of these parts still has trim eligibility. Run the eligibility correction first.', 16, 1);
    RETURN;
END

-- ---------------------------------------------------------------
-- Work list: active published routes that still carry a trim step.
-- ---------------------------------------------------------------
DECLARE @Work TABLE (
    Seq         INT IDENTITY(1,1) PRIMARY KEY,
    RouteId     BIGINT,
    PartNumber  NVARCHAR(100),
    Descr       NVARCHAR(200),
    VersionNo   INT,
    TrimSteps   INT
);

INSERT INTO @Work (RouteId, PartNumber, Descr, VersionNo, TrimSteps)
SELECT rt.Id, i.PartNumber, ISNULL(i.Description, N''), rt.VersionNumber,
       (SELECT COUNT(*)
        FROM Parts.RouteStep rs
        JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
        JOIN Parts.OperationType     oty ON oty.Id = ot.OperationTypeId
        WHERE rs.RouteTemplateId = rt.Id AND oty.Code IN (N'TrimIn', N'TrimOut'))
FROM @Parts p
JOIN Parts.Item i          ON i.PartNumber = p.PartNumber AND i.DeprecatedAt IS NULL
JOIN Parts.RouteTemplate rt ON rt.ItemId = i.Id
                           AND rt.DeprecatedAt IS NULL
                           AND rt.PublishedAt IS NOT NULL
WHERE EXISTS (
    SELECT 1
    FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
    JOIN Parts.OperationType     oty ON oty.Id = ot.OperationTypeId
    WHERE rs.RouteTemplateId = rt.Id AND oty.Code IN (N'TrimIn', N'TrimOut'));

DECLARE @PlanCount INT = (SELECT COUNT(*) FROM @Work);

PRINT N'--------------------------------------------------------';
PRINT N'  DROP TRIM ROUTE STEPS   DryRun=' + CONVERT(NVARCHAR(1), @DryRun);
PRINT N'  Routes to re-version: ' + CONVERT(NVARCHAR(10), @PlanCount);
PRINT N'--------------------------------------------------------';

SELECT Seq, PartNumber, Descr, VersionNo AS CurrentVersion, TrimSteps
FROM @Work ORDER BY Descr;

IF @DryRun = 1
BEGIN
    PRINT N'DRY RUN - nothing was changed. Re-run with -v DryRun=0 to apply.';
    RETURN;
END

-- ---------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------
DECLARE @Seq INT, @RouteId BIGINT, @Pn NVARCHAR(100), @NewRouteId BIGINT,
        @StepId BIGINT, @Now DATETIME2(3), @Ok BIT, @Msg NVARCHAR(500),
        @Removed INT, @Done INT = 0, @Failed INT = 0;

-- Capture shapes must match each proc's result set exactly; a mismatch throws
-- inside the proc's own transaction and its CATCH rollback is illegal under
-- INSERT-EXEC (Msg 3915).
DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Seq, RouteId, PartNumber FROM @Work ORDER BY Seq;
OPEN c;
FETCH NEXT FROM c INTO @Seq, @RouteId, @Pn;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Now = SYSUTCDATETIME();
    SET @NewRouteId = NULL;
    SET @Removed = 0;

    -- 1. Draft a new version (steps are copied from the published one)
    DELETE FROM @R3;
    INSERT INTO @R3 (Status, Message, NewId)
    EXEC Parts.RouteTemplate_CreateNewVersion
         @ParentRouteTemplateId = @RouteId, @EffectiveFrom = @Now, @AppUserId = @AppUserId;
    SELECT TOP 1 @Ok = Status, @Msg = Message, @NewRouteId = NewId FROM @R3;

    IF @Ok <> 1 OR @NewRouteId IS NULL
    BEGIN
        SET @Failed += 1;
        PRINT N'  FAILED  new version for ' + @Pn + N'  ->  ' + ISNULL(@Msg, N'(no result)');
        FETCH NEXT FROM c INTO @Seq, @RouteId, @Pn;
        CONTINUE;
    END

    -- 2. Strip the trim steps from the draft. Remove one at a time and
    --    re-resolve: RouteStep_Remove compacts sibling SequenceNumbers, so ids
    --    must be looked up fresh each pass.
    WHILE @Ok = 1
    BEGIN
        SET @StepId = NULL;
        SELECT TOP 1 @StepId = rs.Id
        FROM Parts.RouteStep rs
        JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
        JOIN Parts.OperationType     oty ON oty.Id = ot.OperationTypeId
        WHERE rs.RouteTemplateId = @NewRouteId AND oty.Code IN (N'TrimIn', N'TrimOut')
        ORDER BY rs.SequenceNumber DESC;

        IF @StepId IS NULL BREAK;

        DELETE FROM @R2;
        INSERT INTO @R2 (Status, Message)
        EXEC Parts.RouteStep_Remove @Id = @StepId, @AppUserId = @AppUserId;
        SELECT TOP 1 @Ok = Status, @Msg = Message FROM @R2;

        IF @Ok = 1 SET @Removed += 1;
    END

    IF @Ok <> 1
    BEGIN
        SET @Failed += 1;
        PRINT N'  FAILED  step removal for ' + @Pn + N'  ->  ' + ISNULL(@Msg, N'(no result)');
        FETCH NEXT FROM c INTO @Seq, @RouteId, @Pn;
        CONTINUE;
    END

    -- 3. Publish the draft (validates route legality, deprecates the old version)
    DELETE FROM @R2;
    INSERT INTO @R2 (Status, Message)
    EXEC Parts.RouteTemplate_Publish
         @Id = @NewRouteId, @AppUserId = @AppUserId, @EffectiveFrom = @Now, @Name = NULL;
    SELECT TOP 1 @Ok = Status, @Msg = Message FROM @R2;

    IF @Ok = 1
    BEGIN
        SET @Done += 1;
        PRINT N'  OK  ' + @Pn + N'  -  ' + CONVERT(NVARCHAR(3), @Removed) + N' trim steps dropped, new version published.';
    END
    ELSE
    BEGIN
        SET @Failed += 1;
        PRINT N'  FAILED  publish for ' + @Pn + N'  ->  ' + ISNULL(@Msg, N'(no result)');
    END

    FETCH NEXT FROM c INTO @Seq, @RouteId, @Pn;
END
CLOSE c;
DEALLOCATE c;

PRINT N'--------------------------------------------------------';
PRINT N'  Re-versioned: ' + CONVERT(NVARCHAR(10), @Done) + N'   Failed: ' + CONVERT(NVARCHAR(10), @Failed);
PRINT N'--------------------------------------------------------';

-- ---------------------------------------------------------------
-- Verification: the resulting active route for each part.
-- ---------------------------------------------------------------
SELECT i.PartNumber, ISNULL(i.Description, N'') AS Descr, rt.VersionNumber AS Ver,
       STUFF((SELECT N' -> ' + oty2.Code
              FROM Parts.RouteStep rs2
              JOIN Parts.OperationTemplate ot2  ON ot2.Id  = rs2.OperationTemplateId
              JOIN Parts.OperationType     oty2 ON oty2.Id = ot2.OperationTypeId
              WHERE rs2.RouteTemplateId = rt.Id
              ORDER BY rs2.SequenceNumber FOR XML PATH(N'')), 1, 4, N'') AS ActiveRoute
FROM @Parts p
JOIN Parts.Item i           ON i.PartNumber = p.PartNumber AND i.DeprecatedAt IS NULL
JOIN Parts.RouteTemplate rt ON rt.ItemId = i.Id AND rt.DeprecatedAt IS NULL AND rt.PublishedAt IS NOT NULL
ORDER BY i.Description;
