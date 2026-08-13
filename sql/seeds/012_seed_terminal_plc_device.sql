-- ============================================================
-- Seed:        012_seed_terminal_plc_device.sql
-- Description: Location.TerminalPlcDevice mappings - binds each [MPP]PlcDevices UDT
--              instance to the terminal that runs its assembly-out validation, so the
--              PlcWatcher edge-dispatch resolves (without these rows every wired trigger
--              hits "no mapping -> ignored"; FAT-PLC-020, the #1 PLC-routing blocker).
--
--              Terminal resolved by Code (robust to identity drift). Device -> terminal
--              per the resolved mapping (device closure -> the line's non-METTS assembly-out
--              terminal; METTS ByCount terminals excluded). RPY station codes: FP=Fuel Pump,
--              CB=Comp Bracket, CH=Cam Holders (RPY_CH -> Line 1). Vision-through-scale lines
--              (5PA / RPY 66v) keep the scale device on their assembly-out terminal.
--
--              5A2 x4 + 5J6 have no Location line yet -> seeded DEPRECATED on the fallback
--              terminal (flagged, inert) pending line creation / confirmation.
--
--              Idempotent: MERGE on UdtInstancePath (the runtime lookup key), so a re-run
--              corrects drift (e.g. the pre-existing manual 59B row on the METTS terminal).
-- Depends on:  0038 (PlcDeviceType) + 011_seed_locations (terminals).
-- ============================================================
SET NOCOUNT ON;

DECLARE @map TABLE (
    DeviceCode      NVARCHAR(100) NOT NULL,
    UdtInstancePath NVARCHAR(400) NOT NULL,
    TypeCode        NVARCHAR(50)  NOT NULL,
    TerminalCode    NVARCHAR(100) NOT NULL,
    Sort            INT           NOT NULL,
    IsDeprecated    BIT           NOT NULL
);

INSERT INTO @map (DeviceCode, UdtInstancePath, TypeCode, TerminalCode, Sort, IsDeprecated) VALUES
 -- 5G0 serialized fronts/rears (MIP + co-located scale)
 (N'5G0_A1',           N'[MPP]PlcDevices/5G0_A1',           N'SerializedMipStation',    N'MA1-5GOF-ASER',      1, 0),
 (N'5G0_Front_Scale',  N'[MPP]PlcDevices/5G0_Front_Scale',  N'ScaleStation',            N'MA1-5GOF-ASER',      2, 0),
 (N'5G0_A2',           N'[MPP]PlcDevices/5G0_A2',           N'SerializedMipStation',    N'MA1-5GOR-ASER',      1, 0),
 (N'5G0_Rear_Scale',   N'[MPP]PlcDevices/5G0_Rear_Scale',   N'ScaleStation',            N'MA1-5GOR-ASER',      2, 0),
 -- scales on non-serialized assembly-out terminals
 (N'59B_1_FP_1',       N'[MPP]PlcDevices/59B_1_FP_1',       N'ScaleStation',            N'MA2-59B-AOUT2',      1, 0),
 (N'5PA_1_FP_1',       N'[MPP]PlcDevices/5PA_1_FP_1',       N'ScaleStation',            N'MA2-5PA-AOUT',       1, 0),  -- vision-through-scale
 (N'RPY_1_FP_1',       N'[MPP]PlcDevices/RPY_1_FP_1',       N'ScaleStation',            N'MA1-FPRPY-AOUT',     1, 0),  -- vision-through-scale
 (N'RPY_1_CB_1',       N'[MPP]PlcDevices/RPY_1_CB_1',       N'ScaleStation',            N'MA1-COMPBR-AOUT',    1, 0),  -- CB = Comp Bracket
 (N'6B2_1_FP_1',       N'[MPP]PlcDevices/6B2_1_FP_1',       N'ScaleStation',            N'MA2-RPY6B2-AOUT',    1, 0),
 -- vision / tray-disposition inspection cells
 (N'5K8_64A_OilPan',   N'[MPP]PlcDevices/5K8_64A_OilPan',   N'TrayInspectionStation',   N'MA2-64AOP-AOUT',     1, 0),
 (N'6C2_6MA_OilPan',   N'[MPP]PlcDevices/6C2_6MA_OilPan',   N'TrayInspectionStation',   N'MA2-6MAOP-AOUT',     1, 0),
 (N'6FB_CH',           N'[MPP]PlcDevices/6FB_CH',           N'TrayInspectionStation',   N'MA2-6FBCHOP-AOUT',   1, 0),
 (N'6MA_CH',           N'[MPP]PlcDevices/6MA_CH',           N'TrayInspectionStation',   N'MA2-6MACH-AOUT3',    1, 0),
 (N'6B2_CH',           N'[MPP]PlcDevices/6B2_CH',           N'TrayInspectionStation',   N'MA2-RPY6B2-AOUT',    2, 0),
 (N'RPY_CH',           N'[MPP]PlcDevices/RPY_CH',           N'TrayInspectionStation',   N'MA2-RPYCAM1-AOUT1',  1, 0),  -- CH = Cam Holders, Line 1
 (N'Sort_OilPan',      N'[MPP]PlcDevices/Sort_OilPan',      N'TrayInspectionStation',   N'INSP-SORT-T1',       1, 0),
 (N'Sort_Totes',       N'[MPP]PlcDevices/Sort_Totes',       N'TrayInspectionStation',   N'INSP-SORT-T1',       2, 0),
 -- No Location line yet -> deprecated on fallback (flagged, inert) pending line creation
 (N'5A2_L1_CamHolder', N'[MPP]PlcDevices/5A2_L1_CamHolder', N'NonSerializedMipStation', N'FALLBACK-TERMINAL',  1, 1),
 (N'5A2_L1_FuelPump',  N'[MPP]PlcDevices/5A2_L1_FuelPump',  N'NonSerializedMipStation', N'FALLBACK-TERMINAL',  2, 1),
 (N'5A2_L2_CamHolder', N'[MPP]PlcDevices/5A2_L2_CamHolder', N'NonSerializedMipStation', N'FALLBACK-TERMINAL',  3, 1),
 (N'5A2_L2_FuelPump',  N'[MPP]PlcDevices/5A2_L2_FuelPump',  N'NonSerializedMipStation', N'FALLBACK-TERMINAL',  4, 1),
 (N'5J6_OilPan',       N'[MPP]PlcDevices/5J6_OilPan',       N'TrayInspectionStation',   N'FALLBACK-TERMINAL',  5, 1);

-- Fail loudly if any terminal/type code does not resolve (rather than silently dropping the row).
IF EXISTS (SELECT 1 FROM @map m WHERE NOT EXISTS (SELECT 1 FROM Location.Location l WHERE l.Code = m.TerminalCode))
BEGIN RAISERROR('012 seed: a TerminalCode does not resolve in Location.Location.', 16, 1); RETURN; END
IF EXISTS (SELECT 1 FROM @map m WHERE NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType pt WHERE pt.Code = m.TypeCode))
BEGIN RAISERROR('012 seed: a TypeCode does not resolve in Location.PlcDeviceType.', 16, 1); RETURN; END

MERGE Location.TerminalPlcDevice AS tgt
USING (
    SELECT m.DeviceCode, m.UdtInstancePath, m.Sort,
           pt.Id   AS PlcDeviceTypeId,
           term.Id AS TerminalLocationId,
           CASE WHEN m.IsDeprecated = 1 THEN SYSUTCDATETIME() ELSE NULL END AS DeprecatedAt
    FROM @map m
    JOIN Location.PlcDeviceType pt   ON pt.Code = m.TypeCode
    JOIN Location.Location term      ON term.Code = m.TerminalCode
) AS src
ON tgt.UdtInstancePath = src.UdtInstancePath
WHEN MATCHED THEN UPDATE SET
    tgt.DeviceCode         = src.DeviceCode,
    tgt.PlcDeviceTypeId    = src.PlcDeviceTypeId,
    tgt.TerminalLocationId = src.TerminalLocationId,
    tgt.SortOrder          = src.Sort,
    tgt.DeprecatedAt       = src.DeprecatedAt,
    tgt.UpdatedAt          = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (TerminalLocationId, PlcDeviceTypeId, DeviceCode, UdtInstancePath, SortOrder, CreatedAt, DeprecatedAt)
    VALUES (src.TerminalLocationId, src.PlcDeviceTypeId, src.DeviceCode, src.UdtInstancePath, src.Sort, SYSUTCDATETIME(), src.DeprecatedAt);

PRINT '012 seed: TerminalPlcDevice mappings merged (17 active + 5 deprecated).';
