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
   watcher -- *Watcher.handleEdge for the MIP/tray types, ScaleWatcher.onTriggerEdge
   for the IND570 scales (whose edge is the operator's physical button, not a
   device push). Watcher modules are referenced fully-qualified at call time
   (Ignition project-library namespace) so there is no import cycle.

   A trigger member is NOT necessarily one path segment -- the scale's is the
   folder-grouped 'Trigger/EnterKey' -- so the instance/member split is resolved
   against the mapping table rather than assumed. See _splitCandidates.

   All PLC-driven mutations attribute to the system AppUser
   (BlueRidge.Common.Util.systemAppUserId()). No business logic here or in the
   watchers -- choreography + proc calls only (matrices/thresholds live in SQL).
"""

import system.tag
import java.lang

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


# ---- terminal -> cell resolution --------------------------------------------
def zoneCellId(terminalLocationId):
    """The cell a terminal's LOTs actually live at: its ZONE (the parent line).

       M&A LOTs are line-resident -- they sit at the WorkCenter/line and the
       terminals hang off it -- so a queue read scoped to the TERMINAL's own
       Location always comes back empty and the watcher bails with
       'no active LOT' while the line is full of WIP. Every watcher that reads
       the FIFO queue must resolve the zone first. Mirrors the cell resolution in
       Assembly.resolvePlcCloseContext (Terminal_List.ZoneId).

       Returns the zone LocationId, or None when the terminal is unknown or has
       no zone (caller bails + logs, same as an empty queue)."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    if tid is None:
        return None
    term = BlueRidge.Location.Terminal.findById(
        BlueRidge.Location.Terminal.listAll(), tid)
    return (term or {}).get("ZoneId")


# ---- operator notification (gateway-scope safe) ------------------------------
def _looksLikeUuid(value):
    """True if value has UUID shape (36 chars, 4 hyphens). Cheap guard against
       malformed/pseudo entries in getSessionInfo()'s gateway-scope enumeration --
       2026-08-20: one entry (sid an 8-hex-char string, pid the literal string
       'session-props', neither a real UUID) threw java.lang.IllegalArgumentException
       on EVERY PLC completion, logged as a warn on every single call. The real
       operator session in the same enumeration sent fine (confirmed live: its
       terminal's view visibly refreshed right after) -- this just silences the
       noise from whatever the bogus entry is (unconfirmed source; a stale gateway
       web-status pseudo-session is the leading guess, not a real Perspective
       client), by skipping it before the exception rather than after."""
    s = "%s" % (value or "")
    return len(s) == 36 and s.count("-") == 4


def broadcastPageMessage(messageType, payload):
    """Send a page-scoped message to every open Perspective session/page.
       GATEWAY-scope system.perspective.sendMessage has no broadcast form -- a
       bare scope='page' call with no sessionId/pageId delivers to nothing
       (project rule: feedback_ignition_gateway_sendmessage_needs_session_page).
       So enumerate system.perspective.getSessionInfo() and target each; pages
       with no handler for messageType just ignore it. Skips non-UUID-shaped
       session/page entries (see _looksLikeUuid) instead of eating an exception
       per bad entry. Shared by Assembly.notifyInventoryChanged,
       PrintFailureGateway._pushToAllSessions, and notifyAlarm below -- one
       hardened enumeration instead of three copies. Never raises; best-effort."""
    try:
        for s in (system.perspective.getSessionInfo() or []):
            sid = s["id"]
            if not _looksLikeUuid(sid):
                continue
            for pid in (s["pageIds"] or []):
                if not _looksLikeUuid(pid):
                    continue
                try:
                    system.perspective.sendMessage(
                        messageType, payload=payload, scope="page",
                        sessionId=sid, pageId=pid)
                except (Exception, java.lang.Exception) as e:
                    BlueRidge.Common.Util.log(
                        "broadcastPageMessage %s send failed sid=%s pid=%s: %s"
                        % (messageType, sid, pid, e), level="warn")
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log(
            "broadcastPageMessage %s enumerate failed: %s" % (messageType, e),
            level="warn")


def notifyAlarm(terminalLocationId, title, message, level="error"):
    """Best-effort operator toast for a PLC-triggered rejection, scoped to the
       ONE session actually sitting at the failing terminal.

       Every watcher's failure branch previously only wrote MESAlarmText/Type
       onto the UDT instance -- an HMI-facing tag, gated behind
       WriteDisplayEnabled (off by default per spec), that Perspective never
       binds to anywhere (checked: AssemblySerialized has zero bindings to
       either member). So a PLC-triggered rejection was completely invisible in
       the MES UI, sim or real hardware alike -- confirmed nothing fired for a
       failed ByWeight tray close, a rejected serial, etc. (2026-08-20 finding).

       Broadcasts a 'plcAlarm' message (via the shared hardened enumeration) to
       every open session/page carrying terminalLocationId in the payload --
       same broadcast-and-let-the-receiver-filter shape as
       Assembly.notifyInventoryChanged (cellLocationId) and
       PrintFailureGateway._pushToAllSessions (terminalLocationId), both of
       which already rely on the RECEIVING view/handler to match before acting,
       not a server-side gateway-scope filter (an earlier draft of this tried
       to filter here on getSessionInfo()'s per-session 'custom' shape, which
       is unconfirmed in gateway scope -- moved the filter to where the
       shape IS confirmed: BlueRidge/Components/NotifyHost's new 'plcAlarm'
       handler compares payload.terminalLocationId against
       self.session.custom.terminal.terminalLocationId and only then calls
       Common.Notify.toast() -- so only the operator actually standing at that
       terminal sees it, not every open session plant-wide."""
    payload = {
        "title": title,
        "message": message,
        "level": level if level in ("success", "info", "warning", "error") else "error",
        "ttl": None if level == "error" else 8,
        "terminalLocationId": terminalLocationId,
    }
    broadcastPageMessage("plcAlarm", payload)


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
                 responsePayload=None, ok=True, errorDescription=None,
                 logEventTypeCode="PlcHandshake"):
    """Log one handshake transaction to Audit.InterfaceLog. Best-effort -- never
       raises into the watcher. logEventTypeCode defaults to PlcHandshake; the
       tray watcher passes PlcLineStop on a vision mismatch (FDS-10-005/010)."""
    params = {
        "systemName":       "%s:%s" % (_SYSTEM_NAME, deviceCode or "?"),
        "direction":        "Inbound",
        "logEventTypeCode": logEventTypeCode,
        "description":      description,
        "requestPayload":   requestPayload,
        "responsePayload":  responsePayload,
        "errorCondition":   None if ok else "HandshakeFailed",
        "errorDescription": None if ok else errorDescription,
        "isHighFidelity":   True,
    }
    try:
        # Silent proc (no result set) -> UpdateQuery NQ via execNonQuery.
        # execList would demand a result set and throw
        # "The statement did not return a result set".
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall", params)
    except (Exception, java.lang.Exception) as e:
        # Best-effort: MUST also catch Java (JDBC) throwables. Jython's
        # `except Exception` does NOT catch a java.lang.Throwable, so a bare
        # `except Exception` would let a DB error abort the watcher edge -- a
        # broken interface log must never break the handshake.
        BlueRidge.Common.Util.log("logInterface failed: %s" % e, level="warn")


# ---- dispatch ---------------------------------------------------------------
def _splitCandidates(tagPath):
    """Every plausible (instancePath, member) split of a trigger tag path,
       LONGEST instance path first. The caller takes the first that resolves to
       a TerminalPlcDevice row.

       This used to be a single rfind('/') split, which is correct only while
       every trigger member is one path segment ('DataReady', 'TrayLocked').
       The IND570 scale broke that: its trigger is the folder-grouped
       'Trigger/EnterKey' (HR4.8), so the naive split yields
       instancePath='[MPP]PlcDevices/<device>/Trigger' -- which matches no
       mapping row, so dispatch bailed at the 'no TerminalPlcDevice mapping'
       warn and the physical button did nothing at all. Probing candidates
       instead of assuming a depth keeps flat members on exactly the old path
       (one mapping lookup, first candidate) and costs one extra lookup per
       press for a nested one.

       The walk stops while the prefix still contains at least one '/', so the
       provider+folder root ('[MPP]PlcDevices') is never itself offered as an
       instance path. Returns [] for a path with no '/' at all."""
    s = str(tagPath)
    out = []
    idx = s.rfind("/")
    while idx > 0 and s.find("/") < idx:
        out.append((s[:idx], s[idx + 1:]))
        idx = s.rfind("/", 0, idx)
    return out


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
        instancePath, member, row = None, None, None
        for candidatePath, candidateMember in _splitCandidates(tagPath):
            row = resolveInstance(candidatePath)
            if row is not None:
                instancePath, member = candidatePath, candidateMember
                break
        if row is None:
            BlueRidge.Common.Util.log(
                "no TerminalPlcDevice mapping under %s (edge ignored)"
                % tagPath, level="warn")
            return
        code = row.get("DeviceTypeCode")
        terminalLocationId = row.get("TerminalLocationId")
        BlueRidge.Common.Util.log(
            "edge %s on %s -> %s (terminal %s)"
            % (member, instancePath, code, terminalLocationId))
        _route(code, instancePath, terminalLocationId, member)
    except (Exception, java.lang.Exception) as e:
        # Catch Java throwables too (see logInterface): a tag-change script
        # must never throw out to the gateway TagChangeScriptExecutor.
        BlueRidge.Common.Util.log(
            "dispatch error tagPath=%s: %s" % (tagPath, e), level="error")


def _route(deviceTypeCode, instancePath, terminalLocationId, member):
    """Route a rising edge to the per-type watcher. Watchers referenced fully-
       qualified (no import) to avoid a cycle."""
    if deviceTypeCode == "ScaleStation":
        # ScaleStation edge = the operator PHYSICAL button, surfaced as a latched
        # status bit (Trigger/EnterKey, HR4.8). The weight itself is polled, not
        # pushed. The screen button calls ScaleWatcher.captureAndClose directly --
        # both converge there. Spec rev 2 Sec 5.
        BlueRidge.Workorder.ScaleWatcher.onTriggerEdge(instancePath, terminalLocationId, member)
    elif deviceTypeCode == "SerializedMipStation":
        BlueRidge.Workorder.SerializedMipWatcher.handleEdge(instancePath, terminalLocationId, member)
    elif deviceTypeCode == "NonSerializedMipStation":
        BlueRidge.Workorder.NonSerializedMipWatcher.handleEdge(instancePath, terminalLocationId, member)
    elif deviceTypeCode == "TrayInspectionStation":
        BlueRidge.Workorder.TrayInspectionWatcher.handleEdge(instancePath, terminalLocationId, member)
    else:
        BlueRidge.Common.Util.log("unknown device type %s" % deviceTypeCode, level="warn")
