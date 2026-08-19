-- =============================================
-- File: 0020_PlantFloor_Foundation/032_Terminal_VisionAppUrl.sql
-- Desc: FAT day-1 item 8. The vision station is configured on the Terminal as a bare
--       IP ('VisionAppIp'); the embed URL is COMPOSED at read time by
--       Location.ufn_VisionAppUrl and surfaced by Terminal_GetClosureContext under the
--       unchanged result-column name VisionAppUrl (so Perspective needs no edit).
--
--       Covers the composer directly (every input shape) and end-to-end through the
--       proc, including the two regressions that matter:
--         * a value that already carries a scheme is passed through UNCHANGED -- this
--           is what makes the 0059 rename non-breaking for a terminal configured under
--           the old free-text VisionAppUrl attribute;
--         * blank/absent -> NULL, so the inline-frame binds nothing rather than
--           'http:///'.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/032_Terminal_VisionAppUrl.sql';
GO

-- ---- A. the composer, in isolation ----
DECLARE @r NVARCHAR(400);

SET @r = Location.ufn_VisionAppUrl(N'172.17.20.37');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] bare IP -> http://<ip>/',
     @Expected = N'http://172.17.20.37/', @Actual = @r;

SET @r = Location.ufn_VisionAppUrl(N'172.17.20.37:8080');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] IP:port -> http://<ip>:<port>/',
     @Expected = N'http://172.17.20.37:8080/', @Actual = @r;

SET @r = Location.ufn_VisionAppUrl(N'172.17.20.37/app');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] IP/path keeps the path, no extra slash',
     @Expected = N'http://172.17.20.37/app', @Actual = @r;

SET @r = Location.ufn_VisionAppUrl(N'172.17.20.37:8080/app');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] IP:port/path composes intact',
     @Expected = N'http://172.17.20.37:8080/app', @Actual = @r;

SET @r = Location.ufn_VisionAppUrl(N'  172.17.20.37  ');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] surrounding whitespace trimmed',
     @Expected = N'http://172.17.20.37/', @Actual = @r;

-- Back-compat: a full URL (either scheme) survives untouched.
SET @r = Location.ufn_VisionAppUrl(N'http://vision.mppnet.com/station/4');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] existing http URL passed through unchanged',
     @Expected = N'http://vision.mppnet.com/station/4', @Actual = @r;

SET @r = Location.ufn_VisionAppUrl(N'https://vision.mppnet.com/station/4');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] https URL passed through unchanged',
     @Expected = N'https://vision.mppnet.com/station/4', @Actual = @r;

-- Blank shapes must yield NULL, never 'http:///'.
SET @r = Location.ufn_VisionAppUrl(NULL);
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] NULL in -> NULL out',
     @Expected = NULL, @Actual = @r;

SET @r = Location.ufn_VisionAppUrl(N'');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] empty string -> NULL',
     @Expected = NULL, @Actual = @r;

SET @r = Location.ufn_VisionAppUrl(N'   ');
EXEC test.Assert_IsEqual @TestName = N'[VisUfn] whitespace-only -> NULL',
     @Expected = NULL, @Actual = @r;
GO

-- ---- B. end to end through Terminal_GetClosureContext ----
DELETE la
FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code = N'TEST-VISION-TERM';
DELETE FROM Location.Location WHERE Code = N'TEST-VISION-TERM';
GO

DECLARE @Parent BIGINT = (SELECT TOP 1 Id FROM Location.Location
                          WHERE LocationTypeDefinitionId <> 7 AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.Location (Code, Name, LocationTypeDefinitionId, ParentLocationId, CreatedAt)
VALUES (N'TEST-VISION-TERM', N'Vision test terminal', 7, @Parent, SYSUTCDATETIME());
GO

-- (B1) no attribute value at all -> NULL (the embed binds nothing)
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-VISION-TERM');
CREATE TABLE #Ctx1 (CurrentClosureMethod NVARCHAR(20), VisionAppUrl NVARCHAR(400), ClosureCapabilities NVARCHAR(100));
INSERT INTO #Ctx1 EXEC Location.Terminal_GetClosureContext @TerminalLocationId = @Term;
DECLARE @V1 NVARCHAR(400) = (SELECT VisionAppUrl FROM #Ctx1);
EXEC test.Assert_IsEqual @TestName = N'[VisCtx] unset VisionAppIp -> NULL VisionAppUrl',
     @Expected = NULL, @Actual = @V1;
DROP TABLE #Ctx1;
GO

-- (B2) bare IP -> composed URL on the unchanged result column
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-VISION-TERM');
DECLARE @IpDef BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppIp'
                           AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
VALUES (@Term, @IpDef, N'172.17.20.37', SYSUTCDATETIME());

CREATE TABLE #Ctx2 (CurrentClosureMethod NVARCHAR(20), VisionAppUrl NVARCHAR(400), ClosureCapabilities NVARCHAR(100));
INSERT INTO #Ctx2 EXEC Location.Terminal_GetClosureContext @TerminalLocationId = @Term;
DECLARE @V2 NVARCHAR(400) = (SELECT VisionAppUrl FROM #Ctx2);
EXEC test.Assert_IsEqual @TestName = N'[VisCtx] bare IP composes to http://<ip>/',
     @Expected = N'http://172.17.20.37/', @Actual = @V2;
DROP TABLE #Ctx2;
GO

-- (B3) a legacy full-URL value still resolves unchanged (0059 rename is non-breaking)
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-VISION-TERM');
DECLARE @IpDef BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppIp'
                           AND DeprecatedAt IS NULL ORDER BY Id);
UPDATE Location.LocationAttribute
SET    AttributeValue = N'http://legacy.vision/app'
WHERE  LocationId = @Term AND LocationAttributeDefinitionId = @IpDef;

CREATE TABLE #Ctx3 (CurrentClosureMethod NVARCHAR(20), VisionAppUrl NVARCHAR(400), ClosureCapabilities NVARCHAR(100));
INSERT INTO #Ctx3 EXEC Location.Terminal_GetClosureContext @TerminalLocationId = @Term;
DECLARE @V3 NVARCHAR(400) = (SELECT VisionAppUrl FROM #Ctx3);
EXEC test.Assert_IsEqual @TestName = N'[VisCtx] legacy full URL survives the rename',
     @Expected = N'http://legacy.vision/app', @Actual = @V3;
DROP TABLE #Ctx3;
GO

-- ---- C. the definition itself was renamed exactly once ----
DECLARE @NewCount NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppIp' AND DeprecatedAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VisDef] exactly one active VisionAppIp definition',
     @Expected = N'1', @Actual = @NewCount;

DECLARE @OldCount NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppUrl' AND DeprecatedAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VisDef] no active VisionAppUrl definition remains',
     @Expected = N'0', @Actual = @OldCount;
GO

-- ---- teardown ----
DELETE la
FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code = N'TEST-VISION-TERM';
DELETE FROM Location.Location WHERE Code = N'TEST-VISION-TERM';
GO

EXEC test.EndTestFile;
GO
