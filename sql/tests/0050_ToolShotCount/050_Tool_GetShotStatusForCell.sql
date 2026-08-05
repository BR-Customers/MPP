SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/050_Tool_GetShotStatusForCell.sql';
GO
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-SHOT-CELL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-SHOT-CELL';
GO
-- fixture: a near-limit Die tool mounted on any free Cell-tier location
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @Cell BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.Code = N'Cell' AND l.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = l.Id AND ta.ReleasedAt IS NULL)
    ORDER BY l.Id);
IF @Cell IS NULL RAISERROR(N'0050/050 fixture: no free Cell-tier location -- BLOCKED.', 16, 1);

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, ShotLimit, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-CELL', N'Shot cell test die', @Active, 950, 1000, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@Tool, @Cell, SYSUTCDATETIME(), 1);

DECLARE @S TABLE (ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(100),
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(9,2),
    IsNearLimit BIT, IsOverLimit BIT);
INSERT INTO @S EXEC Tools.Tool_GetShotStatusForCell @CellLocationId=@Cell;

DECLARE @cnt NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] mounted die returns one row', @Expected=N'1', @Actual=@cnt;
DECLARE @csc NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] ShotCount 950', @Expected=N'950', @Actual=@csc;
DECLARE @cnear NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] IsNearLimit 1', @Expected=N'1', @Actual=@cnear;

-- release the mount -> read returns empty
UPDATE Tools.ToolAssignment SET ReleasedAt = SYSUTCDATETIME(), ReleasedByUserId = 1
WHERE ToolId = @Tool AND ReleasedAt IS NULL;
DELETE FROM @S;
INSERT INTO @S EXEC Tools.Tool_GetShotStatusForCell @CellLocationId=@Cell;
DECLARE @cnt2 NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] no mount -> empty result set', @Expected=N'0', @Actual=@cnt2;

DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
GO
EXEC test.EndTestFile;
GO
