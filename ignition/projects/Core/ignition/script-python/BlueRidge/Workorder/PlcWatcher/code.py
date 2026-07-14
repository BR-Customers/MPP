"""BlueRidge.Workorder.PlcWatcher - shared PLC-watcher helpers + edge dispatch.

   The gateway watchers take the legacy EMMD engine's role; the stored procs take
   MESCore's (spec Sec 5). This module is the common surface every per-type watcher
   uses: instance-member tag read/write, the rising-edge guard, InterfaceLog
   wrapping, and the dispatch entrypoint the Designer project Tag Change scripts
   call.

   Edge model (durable across gateway restart, per the 2026-07-09 readiness note):
   the trigger is a *project Tag Change script* on each instance's trigger member,
   NOT module-memory edge state. That script is a one-liner:

       BlueRidge.Workorder.PlcWatcher.dispatch(str(event.tagPath),
                                               event.previousValue, event.currentValue)

   dispatch() rising-edge-guards, resolves the instance's terminal + device type
   (Location.TerminalPlcDevice.getByInstancePath), and routes to the matching
   *Watcher.handleEdge. Watcher modules are referenced fully-qualified at call time
   (Ignition project-library namespace) so there is no import cycle.

   All PLC-driven mutations attribute to the system AppUser
   (BlueRidge.Common.Util.systemAppUserId()). No business logic here or in the
   watchers -- choreography + proc calls only (matrices/thresholds live in SQL).
"""

import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Location.TerminalPlcDevice
import system.tag

_SYSTEM_NAME = "PLC"


# ---- instance-member tag I/O ------------------------------------------------
def memberPath(udtInstancePath, member):
    """The tag path of one member of a UDT instance, e.g.
       '[MPP]PlcDevices/5G0_A1' + 'DataReady' -> '[MPP]PlcDevices/5G0_A1/DataReady'."""
    return "%s/%s" % (udtInstancePath, member)


def readMember(udtInstancePath, member):
    """Read one instance member's value (unwrapped). None on bad quality."""
    qv = system.tag.readBlocking([memberPath(udtInstancePath, member)])[0]
    if qv is None or not qv.quality.isGood():
        return None
    return qv.value


def readMembers(udtInstancePath, members):
    """Read several members -> {member: value} (None where bad quality)."""
    paths = [memberPath(udtInstancePath, m) for m in members]
    qvs = system.tag.readBlocking(paths)
    out = {}
    for m, qv in zip(members, qvs):
        out[m] = qv.value if (qv is not None and qv.quality.isGood()) else None
    return out


def writeMember(udtInstancePath, member, value):
    """Write one instance member (MES -> PLC). Returns the write-result list."""
    return system.tag.writeBlocking([memberPath(udtInstancePath, member)], [value])


def writeMembers(udtInstancePath, valuesByMember):
    """Batch-write members. valuesByMember: {member: value}."""
    if not valuesByMember:
        return None
    members = list(valuesByMember.keys())
    paths = [memberPath(udtInstancePath, m) for m in members]
    vals = [valuesByMember[m] for m in members]
    return system.tag.writeBlocking(paths, vals)


def displayWritesEnabled(udtInstancePath):
    """True if this instance's HMI-display writes are enabled (spec Sec 5.1).
       Off by default; watchers check before writing display-only members
       (MESAlarmText/Type, PartType, ContainerName, ContainerCount-as-display)."""
    return bool(readMember(udtInstancePath, "WriteDisplayEnabled"))


def writeDisplay(udtInstancePath, valuesByMember):
    """Write HMI-display members ONLY when WriteDisplayEnabled is set. No-op
       otherwise (the Perspective terminal renders these from MES state instead)."""
    if not displayWritesEnabled(udtInstancePath):
        BlueRidge.Common.Util.log(
            "display writes suppressed (WriteDisplayEnabled=0) for %s" % udtInstancePath,
            level="debug")
        return None
    return writeMembers(udtInstancePath, valuesByMember)


# ---- edge guard -------------------------------------------------------------
def _val(qvOrVal):
    """Unwrap a QualifiedValue (tag-change payload) or pass a plain value."""
    try:
        return qvOrVal.value
    except AttributeError:
        return qvOrVal


def isRisingEdge(previousValue, currentValue):
    """Boolean rising-edge guard: act only on false->true. Legacy events fire on
       data-change then bail if 0, so the watcher must gate on the rising edge
       (spec Sec 3.3)."""
    return bool(_val(currentValue)) and not bool(_val(previousValue))


# ---- interface logging (FDS-01-014) -----------------------------------------
def logInterface(deviceCode, description, requestPayload=None,
                 responsePayload=None, ok=True, errorDescription=None):
    """Log one handshake transaction to Audit.InterfaceLog. Best-effort -- never
       raises into the watcher."""
    params = {
        "systemName":       "%s:%s" % (_SYSTEM_NAME, deviceCode or "?"),
        "direction":        "Inbound",
        "logEventTypeCode": "PlcHandshake",
        "description":      description,
        "requestPayload":   requestPayload,
        "responsePayload":  responsePayload,
        "errorCondition":   None if ok else "HandshakeFailed",
        "errorDescription": None if ok else errorDescription,
        "isHighFidelity":   True,
    }
    try:
        BlueRidge.Common.Db.execList("audit/Audit_LogInterfaceCall", params)
    except Exception as e:
        BlueRidge.Common.Util.log("logInterface failed: %s" % e, level="warn")


# ---- dispatch ---------------------------------------------------------------
def _splitPath(tagPath):
    """('[MPP]PlcDevices/5G0_A1', 'DataReady') from
       '[MPP]PlcDevices/5G0_A1/DataReady'."""
    s = str(tagPath)
    idx = s.rfind("/")
    if idx < 0:
        return (s, "")
    return (s[:idx], s[idx + 1:])


def resolveInstance(udtInstancePath):
    """The driving terminal + device type for an instance path, or None. dict:
       {TerminalLocationId, DeviceTypeCode, DeviceCode, ...}."""
    rows = BlueRidge.Location.TerminalPlcDevice.getByInstancePath(udtInstancePath)
    return rows[0] if rows else None


def dispatch(tagPath, previousValue, currentValue):
    """Entrypoint for a Designer project Tag Change script on a trigger member.
       Rising-edge only; resolves the instance's terminal + type and routes to the
       matching watcher. Fully guarded -- a tag-change script must never throw."""
    try:
        if not isRisingEdge(previousValue, currentValue):
            return
        instancePath, member = _splitPath(tagPath)
        row = resolveInstance(instancePath)
        if row is None:
            BlueRidge.Common.Util.log(
                "no TerminalPlcDevice mapping for %s (edge on %s ignored)"
                % (instancePath, member), level="warn")
            return
        code = row.get("DeviceTypeCode")
        terminalLocationId = row.get("TerminalLocationId")
        BlueRidge.Common.Util.log(
            "edge %s on %s -> %s (terminal %s)"
            % (member, instancePath, code, terminalLocationId))
        _route(code, instancePath, terminalLocationId, member)
    except Exception as e:
        BlueRidge.Common.Util.log(
            "dispatch error tagPath=%s: %s" % (tagPath, e), level="error")


def _route(deviceTypeCode, instancePath, terminalLocationId, member):
    """Route a rising edge to the per-type watcher. Watchers referenced fully-
       qualified (no import) to avoid a cycle."""
    if deviceTypeCode == "ScaleStation":
        BlueRidge.Workorder.ScaleWatcher.handleEdge(instancePath, terminalLocationId, member)
    elif deviceTypeCode == "SerializedMipStation":
        BlueRidge.Workorder.SerializedMipWatcher.handleEdge(instancePath, terminalLocationId, member)
    elif deviceTypeCode == "NonSerializedMipStation":
        BlueRidge.Workorder.NonSerializedMipWatcher.handleEdge(instancePath, terminalLocationId, member)
    elif deviceTypeCode == "TrayInspectionStation":
        BlueRidge.Workorder.TrayInspectionWatcher.handleEdge(instancePath, terminalLocationId, member)
    else:
        BlueRidge.Common.Util.log("unknown device type %s" % deviceTypeCode, level="warn")
