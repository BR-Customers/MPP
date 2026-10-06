-- ============================================================
-- Migration:   0105_plcdevicetype_scalestation_eprint.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Description: Location.PlcDeviceType += ScaleStationEPrint -> ByWeight.
--
--   WHY. The IND570 terminals carry no PLC option card, so the Modbus TCP
--   register map behind the ScaleStation type cannot be read from them. They
--   publish their print template on the secondary Ethernet port instead
--   (EPrint demand output), which Ignition's TCP driver exposes as a Message
--   tag. That is a different UDT (ignition/tags/udt/ScaleStationEPrint.json)
--   and a different watcher (BlueRidge.Workorder.ScaleEPrintWatcher), and
--   PlcWatcher routes on PlcDeviceType.Code -- so it needs its own type row.
--
--   ScaleStation is left exactly as it is. The two types sit side by side;
--   which one a terminal uses is decided by its TerminalPlcDevice row.
--
--   ClosureMethodCode = ByWeight, same as ScaleStation, so a terminal mapped
--   to an EPrint scale is offered ByWeight by Location.Terminal_GetClosureContext
--   and accepted by Location.Terminal_SetClosureMethod without either proc
--   changing.
--
--   Spec: docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md
-- ============================================================
IF EXISTS (SELECT 1 FROM Location.PlcDeviceType WHERE Code = N'ScaleStationEPrint')
BEGIN
    PRINT 'Migration 0105: PlcDeviceType ScaleStationEPrint already present -- no change.';
END
ELSE
BEGIN
    INSERT INTO Location.PlcDeviceType (Code, Name, Description, ClosureMethodCode)
    VALUES (N'ScaleStationEPrint', N'Scale Station (EPrint)',
            N'IND570 weight indicator read over the TCP driver (EPrint demand output); no PLC option card',
            N'ByWeight');
    PRINT 'Migration 0105: PlcDeviceType ScaleStationEPrint added.';
END
GO

IF NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType
               WHERE Code = N'ScaleStationEPrint' AND ClosureMethodCode = N'ByWeight')
    THROW 51000, 'Migration 0105: ScaleStationEPrint -> ByWeight did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0105_plcdevicetype_scalestation_eprint')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0105_plcdevicetype_scalestation_eprint',
            N'Location.PlcDeviceType += ScaleStationEPrint (ByWeight): IND570 scales read over the TCP driver, beside the Modbus ScaleStation type. Apply with Parts.ContainerConfig_JudgeWeight v1.0.');
GO
PRINT 'Migration 0105 (plcdevicetype_scalestation_eprint) applied.';
GO
