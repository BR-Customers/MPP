-- verify_demo_config.sql -- checks the MPP_MES_Demo sample-plant configuration.
-- Run: sqlcmd -S localhost -E -C -I -b -d MPP_MES_Demo -i tools\sales-kit\demo-db\verify_demo_config.sql
-- Prints PASS/FAIL per check; raises an error (non-zero exit with -b) if any check fails.
SET NOCOUNT ON;
DECLARE @r TABLE (Seq INT IDENTITY, Ok BIT, Check_ NVARCHAR(200));

IF DB_NAME() <> N'MPP_MES_Demo' BEGIN RAISERROR('verify_demo_config: must run against MPP_MES_Demo', 16, 1); RETURN; END

INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Location.Location c JOIN Location.Location a ON a.Id = c.ParentLocationId
    WHERE a.Code = N'DC' AND c.LocationTypeDefinitionId = 8 AND c.DeprecatedAt IS NULL) = 3 THEN 1 ELSE 0 END, N'3 press cells under DC';

INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Location.LocationAttribute la
    JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
    WHERE ad.AttributeName = N'IpAddress' AND la.AttributeValue = N'127.0.0.1') = 1
  AND EXISTS (SELECT 1 FROM Location.LocationAttribute la JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
    JOIN Location.Location l ON l.Id = la.LocationId WHERE ad.AttributeName = N'IpAddress' AND la.AttributeValue = N'127.0.0.1' AND l.Code = N'DC-T1')
  THEN 1 ELSE 0 END, N'only DC-T1 holds 127.0.0.1';

INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'FALLBACK-TERMINAL' AND ParentLocationId = (SELECT Id FROM Location.Location WHERE Code = N'SITE')) THEN 1 ELSE 0 END, N'fallback terminal under SITE';

INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Location.AppUser WHERE Pin IN (N'04218', N'40218', N'31570', N'02693', N'58104', N'77342') AND DeprecatedAt IS NULL) = 6 THEN 1 ELSE 0 END, N'six operators with demo PINs (leading zeros kept)';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Oee.ShiftSchedule WHERE Name IN (N'First Shift', N'Second Shift') AND DeprecatedAt IS NULL) = 2 THEN 1 ELSE 0 END, N'First and Second Shift schedules';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL) THEN 1 ELSE 0 END, N'a shift is open';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Quality.DefectCode WHERE DeprecatedAt IS NULL AND Code IN (N'DC-POR', N'DC-SHS', N'DC-CLD', N'DC-FLS', N'TR-DMG', N'TR-BRR', N'MA-DIM', N'MA-THR', N'MA-ASM')) = 9 THEN 1 ELSE 0 END, N'nine demo defect codes';
INSERT @r SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM Location.Location WHERE Name LIKE N'%Madison%' OR Code LIKE N'MPP%') THEN 1 ELSE 0 END, N'no MPP / Madison locations';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL) = 8 THEN 1 ELSE 0 END, N'8 terminals (DC, TRIM, L1 x3, L2 x2, fallback)';

SELECT CASE Ok WHEN 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Check_ AS Result FROM @r ORDER BY Seq;
IF EXISTS (SELECT 1 FROM @r WHERE Ok = 0) RAISERROR('verify_demo_config: one or more checks FAILED', 16, 1);
