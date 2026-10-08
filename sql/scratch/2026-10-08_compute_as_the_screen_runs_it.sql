SET NOCOUNT ON;
DECLARE @Press NVARCHAR(50) = N'DC3-M304', @ShiftLabel NVARCHAR(40) = N'10-07 Third Shift', @Reading INT = 367, @DieWide INT = 42;
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = @Press);
DECLARE @Tool BIGINT = (SELECT TOP 1 ToolId FROM Tools.ToolAssignment WHERE CellLocationId = @Cell AND ReleasedAt IS NULL);
DECLARE @Shift BIGINT = (SELECT TOP 1 s.Id FROM Oee.Shift s JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
                         WHERE CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name = @ShiftLabel ORDER BY s.ActualStart DESC);
SELECT N'0 INPUTS' AS Section, @Cell AS CellId, @Tool AS ToolId, (SELECT Name FROM Tools.Tool WHERE Id = @Tool) AS Die, @Shift AS ShiftId,
       (SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('Workorder.ufn_CavityShotWatermark')) LIKE '%@Readingless%' THEN 'v4.0' ELSE 'v3.0' END) AS Fn;
EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId = @Tool, @ShiftId = @Shift, @CounterReading = @Reading, @CellLocationId = @Cell, @DieWideShots = @DieWide;
