-- verify_demo_parts.sql -- parts, routes, BOMs and dies of the MPP_MES_Demo sample plant.
SET NOCOUNT ON;
IF DB_NAME() <> N'MPP_MES_Demo' BEGIN RAISERROR('verify_demo_parts: must run against MPP_MES_Demo', 16, 1); RETURN; END
DECLARE @r TABLE (Seq INT IDENTITY, Ok BIT, Check_ NVARCHAR(200));
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Parts.Item WHERE PartNumber IN (N'HSG-410', N'HSG-410-M', N'HSG-440', N'HSG-440-M', N'CVR-220', N'BRK-230', N'SEAL-01', N'FG-4100', N'FG-4400', N'FG-2200')) = 10 THEN 1 ELSE 0 END, N'10 sample parts';
INSERT @r SELECT CASE WHEN (SELECT COUNT(DISTINCT rt.ItemId) FROM Parts.RouteTemplate rt WHERE rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL) = 9 THEN 1 ELSE 0 END, N'9 published routes (all but SEAL-01)';
INSERT @r SELECT CASE WHEN (SELECT ot.Code FROM Parts.RouteStep rs JOIN Parts.RouteTemplate rt ON rt.Id = rs.RouteTemplateId JOIN Parts.Item i ON i.Id = rt.ItemId JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    WHERE i.PartNumber = N'HSG-410-M' AND rt.PublishedAt IS NOT NULL) = N'AssemblyOut' THEN 1 ELSE 0 END, N'SubAssembly route is AssemblyOut';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Parts.Bom b WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL) = 5 THEN 1 ELSE 0 END, N'5 published BOMs';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Tools.ToolCavity c JOIN Tools.Tool t ON t.Id = c.ToolId WHERE t.Code = N'D-220') = 4
    AND (SELECT COUNT(DISTINCT c.ItemId) FROM Tools.ToolCavity c JOIN Tools.Tool t ON t.Id = c.ToolId WHERE t.Code = N'D-220') = 2 THEN 1 ELSE 0 END, N'family die D-220: 4 cavities over 2 parts';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Tools.ToolAssignment a JOIN Location.Location l ON l.Id = a.CellLocationId WHERE a.ReleasedAt IS NULL AND l.Code IN (N'P-01', N'P-02', N'P-03')) = 3 THEN 1 ELSE 0 END, N'a die mounted on each press';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Parts.ItemLocation il JOIN Parts.Item i ON i.Id = il.ItemId JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'FG-2200' AND l.Code = N'L-2') THEN 1 ELSE 0 END, N'FG-2200 eligible at L-2';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Parts.ContainerConfig cc JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber LIKE N'FG-%') = 3 THEN 1 ELSE 0 END, N'container config per finished good';
SELECT CASE Ok WHEN 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Check_ AS Result FROM @r ORDER BY Seq;
IF EXISTS (SELECT 1 FROM @r WHERE Ok = 0) RAISERROR('verify_demo_parts: one or more checks FAILED', 16, 1);
