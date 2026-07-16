-- =============================================
-- Migration:   0039_plc_handshake_audit.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-14
-- Description: Audit LogEventType seeds for the PLC-integration gateway watchers
--              (Plan 3). Every handshake transaction logs to Audit.InterfaceLog
--              (FDS-01-014); a tray-inspection vision mismatch records a line-stop
--              (FDS-10-005/010). Additive lookup rows only; no schema change.
--                * 67 PlcHandshake - interface-log event for a processed handshake.
--                * 68 PlcLineStop  - wrong-part line-stop on vision mismatch.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 67 OR Code = N'PlcHandshake')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (67, N'PlcHandshake', N'PLC Handshake',
         N'A PLC/MIP/scale handshake transaction was processed by a gateway watcher (Audit.InterfaceLog).');
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 68 OR Code = N'PlcLineStop')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (68, N'PlcLineStop', N'PLC Line Stop',
         N'A tray-inspection vision code mismatched the expected LOT PLC recipe; the line was stopped (FDS-10-005/010).');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0039_plc_handshake_audit')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0039_plc_handshake_audit',
        N'PLC handshake audit seeds: LogEventType 67 PlcHandshake, 68 PlcLineStop (Plan 3 watchers).');
GO
