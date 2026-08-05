SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/020_Tool_reads_shot_fields.sql';
GO
-- cleanup (idempotent)
DELETE FROM Tools.Tool WHERE Code = N'TEST-SHOT-RD';
GO
-- fixture: a Die-type tool with a near-limit shot count
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @Active BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, ShotLimit, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-RD', N'Shot read test die', @Active, 950, 1000, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

-- Tool_Get: full-width capture (must match the proc's SELECT column-for-column)
DECLARE @G TABLE (
    Id BIGINT, ToolTypeId BIGINT, ToolTypeCode NVARCHAR(50), ToolTypeName NVARCHAR(100),
    HasCavities BIT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
    DieRankId BIGINT, DieRankCode NVARCHAR(20), DieRankName NVARCHAR(100),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), CreatedByUserId BIGINT,
    UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(9,2),
    IsNearLimit BIT, IsOverLimit BIT);
INSERT INTO @G EXEC Tools.Tool_Get @Id = @Tool;

DECLARE @sc NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] ShotCount 950', @Expected=N'950', @Actual=@sc;
DECLARE @sl NVARCHAR(20) = (SELECT CAST(ShotLimit AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] ShotLimit 1000', @Expected=N'1000', @Actual=@sl;
DECLARE @rem NVARCHAR(20) = (SELECT CAST(ShotsRemaining AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] ShotsRemaining 50', @Expected=N'50', @Actual=@rem;
DECLARE @near NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] IsNearLimit 1', @Expected=N'1', @Actual=@near;

-- Tool_List: INSERT-EXEC needs the full result shape; capture then filter to our fixture row.
DECLARE @L TABLE (
    Id BIGINT, ToolTypeId BIGINT, ToolTypeCode NVARCHAR(50), ToolTypeName NVARCHAR(100),
    HasCavities BIT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
    DieRankId BIGINT, DieRankCode NVARCHAR(20), DieRankName NVARCHAR(100),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), CreatedByUserId BIGINT,
    UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(9,2),
    IsNearLimit BIT, IsOverLimit BIT);
INSERT INTO @L EXEC Tools.Tool_List @ToolTypeId = NULL, @StatusCode = NULL, @IncludeDeprecated = 1;
DECLARE @lNear NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM @L WHERE Code = N'TEST-SHOT-RD');
EXEC test.Assert_IsEqual @TestName=N'[Tool_List] fixture row IsNearLimit 1', @Expected=N'1', @Actual=@lNear;

DELETE FROM Tools.Tool WHERE Id = @Tool;
GO
EXEC test.EndTestFile;
GO
