-- =============================================
-- 2026-08-18_publish_operation_templates.sql
--
-- Root cause of "no matching operation template" on the shop floor:
--   Seeds 022/024/026/027 INSERT Parts.OperationTemplate rows WITHOUT
--   PublishedAt, so every seeded template is a Draft. The route-role resolver
--   (Core NQ parts/OperationTemplate_GetForRouteRole) enforces the FAT-OQ-030
--   publish gate -- "a Draft OperationTemplate (PublishedAt IS NULL) must never
--   resolve into execution" -- so it returns an empty result for EVERY part and
--   EVERY role. Not 59B-specific; nothing can run.
--
-- Fix: publish the Draft templates through the normal proc (audited).
--
-- Idempotent: OperationTemplate_Publish rejects an already-published row, and
-- the cursor only selects Drafts, so a re-run is a no-op.
--
-- Usage:
--   sqlcmd -S <host> -d <db> -I -C -b -i 2026-08-18_publish_operation_templates.sql
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

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

PRINT N'--- Draft OperationTemplates before ---';
SELECT ot.Code AS Code, oty.Code AS Role,
       ISNULL(CONVERT(NVARCHAR(23), ot.PublishedAt), N'DRAFT') AS PublishedAt
FROM Parts.OperationTemplate ot
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE ot.DeprecatedAt IS NULL
ORDER BY ot.Code;

DECLARE @Id BIGINT, @Code NVARCHAR(50), @Ok BIT, @Msg NVARCHAR(500);
DECLARE @n INT = 0, @f INT = 0;
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT Id, Code FROM Parts.OperationTemplate
    WHERE PublishedAt IS NULL AND DeprecatedAt IS NULL
    ORDER BY Code;

OPEN c;
FETCH NEXT FROM c INTO @Id, @Code;
WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM @R;
    INSERT INTO @R (Status, Message)
    EXEC Parts.OperationTemplate_Publish @Id = @Id, @AppUserId = @AppUserId;

    SET @Ok = NULL; SET @Msg = NULL;
    SELECT TOP 1 @Ok = Status, @Msg = Message FROM @R;

    IF @Ok = 1
    BEGIN
        SET @n += 1;
        PRINT N'  published  ' + @Code;
    END
    ELSE
    BEGIN
        SET @f += 1;
        PRINT N'  FAILED     ' + @Code + N'  ->  ' + ISNULL(@Msg, N'(no result row)');
    END

    FETCH NEXT FROM c INTO @Id, @Code;
END
CLOSE c;
DEALLOCATE c;

PRINT N'--------------------------------------------------------';
PRINT N'  published: ' + CONVERT(NVARCHAR(5), @n) + N'   failed: ' + CONVERT(NVARCHAR(5), @f);
PRINT N'--------------------------------------------------------';

PRINT N'--- after ---';
SELECT ot.Code AS Code, oty.Code AS Role,
       ISNULL(CONVERT(NVARCHAR(23), ot.PublishedAt), N'DRAFT') AS PublishedAt
FROM Parts.OperationTemplate ot
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE ot.DeprecatedAt IS NULL
ORDER BY ot.Code;
