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


def _checkWrite(deviceCode, members, qualityCodes):
    """Turn system.tag.writeBlocking's per-path QualityCode list into
    {"ok": bool, "message": str}. writeBlocking does NOT raise on a bad path (a
    typo'd device, an unimported UDT instance, or an MPP_Sim device that was never
    added in Config -> OPC Client -> Devices all write successfully from the
    caller's point of view -- the call returns normally, quality is just Bad).
    Nothing upstream ever checked this, so every Fire/Set button on the Sim panel
    was indistinguishable between "wrote fine, nothing to see because a human has
    to judge the downstream effect" and "the write silently landed nowhere" -- the
    exact "we don't see it execute anything" report. This is the one place both
    writeMember and writeMembers funnel through, so every caller gets the check."""
    bad = [m for m, qc in zip(members, qualityCodes) if not qc.isGood()]
    if not bad:
        return {"ok": True, "message": ""}
    return {"ok": False, "message": "Write failed for %s on %s -- tag not found or "
            "MPP_Sim device not running (Config -> OPC Client -> Devices). See "
            "ignition/tags/README.md for the commissioning steps." % (bad, deviceCode)}


def writeMember(deviceCode, member, value):
    """Write one UDT-instance member (OPC -> the MPP_Sim writeable tag).
    Returns {"ok": bool, "message": str}; ok=False with no device selected."""
    if not deviceCode:
        return {"ok": False, "message": "No device selected."}
    BlueRidge.Common.Util.log("device=%s member=%s value=%s" % (deviceCode, member, value))
    qc = system.tag.writeBlocking([_memberPath(deviceCode, member)], [value])
    return _checkWrite(deviceCode, [member], qc)


def writeMembers(deviceCode, valuesByMember):
    """Batch-write several members. valuesByMember: {member: value}.
    Returns {"ok": bool, "message": str}; ok=False with no device selected."""
    if not deviceCode or not valuesByMember:
        return {"ok": False, "message": "No device selected."}
    members = list(valuesByMember.keys())
    paths = [_memberPath(deviceCode, m) for m in members]
    vals = [valuesByMember[m] for m in members]
    BlueRidge.Common.Util.log("device=%s members=%s" % (deviceCode, members))
    qc = system.tag.writeBlocking(paths, vals)
    return _checkWrite(deviceCode, members, qc)


def pulse(deviceCode, member):
    """Set a boolean trigger member True (the rising edge the watcher acts on).
    The watcher/PLC resets it; the panel just asserts it.
    Returns {"ok": bool, "message": str}."""
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


def _seedThenPulse(deviceCode, seedValues, pulseMember):
    """Write the seed members, then pulse the trigger, and report ok only if BOTH
    writes landed. A failed seed write with a successful pulse would otherwise
    read as ok=True while the watcher picks up stale/default seed values -- a
    second, subtler flavor of the same "looks fine, nothing really happened"
    failure this module exists to catch."""
    seedResult = writeMembers(deviceCode, seedValues)
    pulseResult = pulse(deviceCode, pulseMember)
    if seedResult["ok"] and pulseResult["ok"]:
        return {"ok": True, "message": ""}
    messages = [m["message"] for m in (seedResult, pulseResult) if not m["ok"]]
    return {"ok": False, "message": " ".join(messages)}


def fireScale(deviceCode, netWeight, metFlag):
    """Seed the scale read tags then pulse NET_DataReady (weight-ready handshake)."""
    return _seedThenPulse(deviceCode,
        {"NET_NetWeightValue": _toFloat(netWeight), "NET_TargetWeightMetFlag": bool(metFlag)},
        "NET_DataReady")


def setScaleTarget(deviceCode, targetWeight):
    """Write the target weight then pulse TRG_SendMessage (commit target change)."""
    return _seedThenPulse(deviceCode, {"TRG_TargetWeightValue": _toFloat(targetWeight)},
        "TRG_SendMessage")


def fireSerialized(deviceCode, partSN, interlock):
    """Seed PartSN + interlock then pulse DataReady (serialized-MIP add)."""
    return _seedThenPulse(deviceCode,
        {"PartSN": partSN or "", "HardwareInterlockEnforced": bool(interlock)}, "DataReady")


def fireInspection(deviceCode, visionPartNumber, dispositions):
    """Seed VisionPartNumber + the 18 disposition slots then pulse
    InspectionComplete. dispositions: a list of up to 18 booleans."""
    vals = {"VisionPartNumber": _toInt(visionPartNumber)}
    disp = dispositions or []
    for i in range(18):
        vals["PartDisposition%02d" % (i + 1)] = bool(disp[i]) if i < len(disp) else False
    return _seedThenPulse(deviceCode, vals, "InspectionComplete")
