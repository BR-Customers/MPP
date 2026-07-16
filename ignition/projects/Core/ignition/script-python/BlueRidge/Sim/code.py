# BlueRidge.Sim -- PLC Sim Panel helpers (dev-only harness; spec Sec 7.1)
#
# Low-level tag I/O + scenario seeds for the /dev/sim/plc panel. The panel drives
# the MPP_Sim writeable tags THROUGH the UDT instance members (writing an OPC
# member writes through to the simulator device), so the watcher (Plan 3) reads
# exactly what the panel wrote. View customMethods marshal view.custom -> these.

# Tag provider holding the PlcDevices UDT instances (Plan 2 Task 3). If the MPP
# provider is named differently at commissioning, change PROVIDER here only.
PROVIDER = "[MPP]"
DEVICE_FOLDER = "PlcDevices"

# Device -> UDT type. Mirrors reference/.../integration_manifest.csv (the same 22
# active devices the generator emits). Dev-harness list; keep in sync with the
# manifest if devices are added/removed.
_DEVICES = [
    ("59B_1_FP_1", "ScaleStation"), ("5PA_1_FP_1", "ScaleStation"),
    ("6B2_1_FP_1", "ScaleStation"), ("RPY_1_FP_1", "ScaleStation"),
    ("RPY_1_CB_1", "ScaleStation"), ("5G0_Front_Scale", "ScaleStation"),
    ("5G0_Rear_Scale", "ScaleStation"),
    ("5A2_L1_CamHolder", "NonSerializedMipStation"),
    ("5A2_L1_FuelPump", "NonSerializedMipStation"),
    ("5A2_L2_CamHolder", "NonSerializedMipStation"),
    ("5A2_L2_FuelPump", "NonSerializedMipStation"),
    ("5G0_A1", "SerializedMipStation"), ("5G0_A2", "SerializedMipStation"),
    ("5J6_OilPan", "TrayInspectionStation"),
    ("5K8_64A_OilPan", "TrayInspectionStation"),
    ("6B2_CH", "TrayInspectionStation"), ("6C2_6MA_OilPan", "TrayInspectionStation"),
    ("6FB_CH", "TrayInspectionStation"), ("6MA_CH", "TrayInspectionStation"),
    ("RPY_CH", "TrayInspectionStation"), ("Sort_OilPan", "TrayInspectionStation"),
    ("Sort_Totes", "TrayInspectionStation"),
]

_TYPE_SHORT = {
    "ScaleStation": "Scale",
    "SerializedMipStation": "Serialized MIP",
    "NonSerializedMipStation": "Non-Serialized MIP",
    "TrayInspectionStation": "Tray Inspection",
}

# Scenario seeds (spec Sec 7.1) -- (title, expectedOutcome) per UDT type.
_SCENARIOS = {
    "ScaleStation": [
        ("Set target weight + TRG_SendMessage", "TRG_* written; echo confirmed on the scale"),
        ("DataReady rising edge, MetFlag=False", "weight recorded; no container close"),
        ("DataReady rising edge, MetFlag=True", "weight recorded; container close + label"),
        ("UOM mismatch", "handled gracefully (no bad write)"),
        ("Simultaneous scale + MIP DataReady (5G0)", "correct handshake ordering"),
    ],
    "SerializedMipStation": [
        ("Happy path valid PartSN (>=6)", "PartValid=True; ContainerCount increments"),
        ("Invalid PartSN (<6)", "PartValid=False; MESAlarmText set"),
        ("HardwareInterlockEnforced=False (blank SN)", "auto-generated serial accepted"),
        ("Duplicate SN", "rejected; PartValid=False"),
        ("ContainerCountRequest rising edge", "current count written back to PLC"),
        ("Container reaches configured limit", "Container_Complete fires"),
    ],
    "NonSerializedMipStation": [
        ("Happy path DataReady", "Assembly_CompleteTray mints FG LOT; PartValid=True"),
        ("BOM shortage", "MESAlarm raised; no mint"),
        ("Tray container full", "new container opens"),
    ],
    "TrayInspectionStation": [
        ("TrayLocked rising edge", "front-of-queue Item.PlcId written as PartNumber (vision recipe)"),
        ("InspectionComplete all-pass", "tray added to container"),
        ("InspectionComplete some-fail", "per-slot pass/fail recorded; only passes added"),
        ("VisionPartNumber mismatches active LOT", "line-stop"),
        ("Disposition read while InspectionComplete=0", "bail (rising-edge guard test)"),
    ],
}


def getDeviceOptions():
    """[{label, value}] for the left-rail device dropdown (grouped label, value =
    device code). Sorted by type then code."""
    BlueRidge.Common.Util.log("running")
    rows = sorted(_DEVICES, key=lambda d: (d[1], d[0]))
    return [{"label": "%s  -  %s" % (code, _TYPE_SHORT.get(t, t)), "value": code}
            for code, t in rows]


def getDeviceType(deviceCode):
    """UDT type of a device code (drives which control panel shows). '' if unknown."""
    for code, t in _DEVICES:
        if code == deviceCode:
            return t
    return ""


def getScenariosForDeviceType(deviceType):
    """Hard-coded scenario seeds for the tracker (spec Sec 7.1).
    Returns [{index, title, expectedOutcome, deviceType}]."""
    BlueRidge.Common.Util.log("deviceType=%s" % deviceType)
    out = []
    for i, (title, expected) in enumerate(_SCENARIOS.get(deviceType, [])):
        out.append({"index": i, "title": title, "expectedOutcome": expected,
                    "deviceType": deviceType})
    return out


def _memberPath(deviceCode, member):
    return "%s%s/%s/%s" % (PROVIDER, DEVICE_FOLDER, deviceCode, member)


def writeMember(deviceCode, member, value):
    """Write one UDT-instance member (OPC -> the MPP_Sim writeable tag). No-op on
    a blank device."""
    if not deviceCode:
        return None
    BlueRidge.Common.Util.log("device=%s member=%s value=%s" % (deviceCode, member, value))
    return system.tag.writeBlocking([_memberPath(deviceCode, member)], [value])


def writeMembers(deviceCode, valuesByMember):
    """Batch-write several members, then return. valuesByMember: {member: value}."""
    if not deviceCode or not valuesByMember:
        return None
    paths, vals = [], []
    for member, value in valuesByMember.items():
        paths.append(_memberPath(deviceCode, member))
        vals.append(value)
    BlueRidge.Common.Util.log("device=%s members=%s" % (deviceCode, list(valuesByMember.keys())))
    return system.tag.writeBlocking(paths, vals)


def pulse(deviceCode, member):
    """Set a boolean trigger member True (the rising edge the watcher acts on).
    The watcher/PLC resets it; the panel just asserts it."""
    return writeMember(deviceCode, member, True)


# ---- higher-level handshake helpers (view customMethods call these) ----------
def _toFloat(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _toInt(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def fireScale(deviceCode, netWeight, metFlag):
    """Seed the scale read tags then pulse NET_DataReady (weight-ready handshake)."""
    writeMembers(deviceCode, {"NET_NetWeightValue": _toFloat(netWeight),
                              "NET_TargetWeightMetFlag": bool(metFlag)})
    return pulse(deviceCode, "NET_DataReady")


def setScaleTarget(deviceCode, targetWeight):
    """Write the target weight then pulse TRG_SendMessage (commit target change)."""
    writeMembers(deviceCode, {"TRG_TargetWeightValue": _toFloat(targetWeight)})
    return pulse(deviceCode, "TRG_SendMessage")


def fireSerialized(deviceCode, partSN, interlock):
    """Seed PartSN + interlock then pulse DataReady (serialized-MIP add)."""
    writeMembers(deviceCode, {"PartSN": partSN or "",
                              "HardwareInterlockEnforced": bool(interlock)})
    return pulse(deviceCode, "DataReady")


def fireInspection(deviceCode, visionPartNumber, dispositions):
    """Seed VisionPartNumber + the 18 disposition slots then pulse
    InspectionComplete. dispositions: a list of up to 18 booleans."""
    vals = {"VisionPartNumber": _toInt(visionPartNumber)}
    disp = dispositions or []
    for i in range(18):
        vals["PartDisposition%02d" % (i + 1)] = bool(disp[i]) if i < len(disp) else False
    writeMembers(deviceCode, vals)
    return pulse(deviceCode, "InspectionComplete")
