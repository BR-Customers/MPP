"""BlueRidge.Workorder.ScaleDigiWatcher - assembly checkweigh scales read through
   a Digi One SP on the IND570's serial port.

   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md
   Findings: notes/2026-11-19_digi-one-sp-scale-capture.md
   UDT:  ignition/tags/udt/ScaleStationEPrint.json (reused: the same three TCP
         driver members). The PlcDeviceType ScaleStationDigi, not the UDT,
         routes a device here (PlcWatcher.dispatchMessage).

   Sits BESIDE ScaleEPrintWatcher, which is legacy and is not edited. Every
   production scale goes through a Digi box (Jacques, 2026-11-19).

   SHAPE. The head runs its compiled TaskExpert program, which sends ONE record
   per GOOD press on the serial port and nothing for a bad weight (it turns the
   stack light red instead):

        (NET)15.5<UOM>LB<TWM>1<Part>TEST3   CR LF LF

   The TCP driver is Character Based on CR, so each message carries the
   previous record's two LFs at its front; the Digi breaks the record into
   1-4 byte packets, which the driver reassembles up to the CR. The data is in
   MessageBytes -- the Message string tag reads blank.

   WHO DECIDES (Jacques, 2026-11-19).
     - The scale decides GOOD: TWM=1 closes the tray. The MES still judges the
       net weight against ContainerConfig and logs a warning when it disagrees;
       it never blocks.
     - The scale decides the PART: <Part> is looked up as an MES PartNumber.
       A different part than the running one switches the station's running
       part (Location.Terminal_SetScaleRunningPart, audited), which refuses
       while another part's box is open -- a box never mixes parts.
     - A code that matches no part: closes as the running part when that part
       is already settled (an open box, or an operator override); otherwise
       the press is HELD (Workorder.ScalePendingPress) and the operator picks
       the part on the scale station screen, which closes the tray.

   Every new InterfaceLog warning's ErrorCondition starts with 'ScaleFlags' so
   Workorder.ScaleStation_GetPressLog keeps it out of the press log.
"""

import java.lang
import re

import system.opc
import system.tag
import system.util


EXPECTED_UOM = "lb"
SOURCE_SCALE = "Scale"
SOURCE_RUNNING = "Running"
SOURCE_PICKED = "Picked"
SOURCE_LEARNED = "Learned"

# (NET)<number><UOM><letters><TWM><digit><Part><rest of the line>
_RECORD = re.compile(r"^\(NET\)\s*(-?\d+(?:\.\d+)?)\s*<UOM>\s*([A-Za-z]+)\s*"
                     r"<TWM>\s*(\d)\s*<Part>([^\r\n]*)$")
_MARK = "(NET)"


def decodeBytes(raw):
    """MessageBytes as text. The driver hands back a Java byte[] (signed
       values in Jython) or a list of ints; each is one ASCII byte."""
    if raw is None:
        return None
    return "".join([chr(int(b) & 0xFF) for b in raw])


def parse(message):
    """One Digi record.

       Returns {"ok": True, "net": float, "netText": str, "uom": str,
                "twm": int, "part": str}
            or {"ok": False, "reason": str}.

       Leading / trailing CR, LF and whitespace are the driver's framing and
       are stripped. Exactly ONE record is required: two would be two presses
       run together, and acting on either would be a guess. TWM is parsed, not
       judged -- the watcher decides what a 0 means."""
    text = ("" if message is None else "%s" % message).strip()
    count = text.count(_MARK)
    if count == 0:
        return {"ok": False, "reason": "The scale sent no weighment record."}
    if count > 1:
        return {"ok": False,
                "reason": "The scale sent %d weighment records at once; expected one." % count}
    m = _RECORD.match(text)
    if not m:
        return {"ok": False,
                "reason": "The scale's record could not be read: %s" % text[:80]}
    netText, uom, twm, part = m.groups()
    return {"ok": True, "net": float(netText), "netText": netText, "uom": uom,
            "twm": int(twm), "part": part.strip()}


def _encode(body):
    return system.util.jsonEncode(body)


def _num(value):
    """A DB decimal (BigDecimal) or None as a JSON-safe float or None."""
    return None if value is None else float("%s" % value)


def _refuse(device, terminalLocationId, title, message, body, level="error", itemId=None):
    """One refusal: an InterfaceLog row and a toast at this terminal."""
    W = BlueRidge.Workorder.PlcWatcher
    W.logInterface(device, title, requestPayload=_encode(body), ok=False,
                   errorDescription=message, locationId=terminalLocationId, itemId=itemId)
    W.notifyAlarm(terminalLocationId, title, message, level=level)
    return {"Status": 0, "Message": message, "ContainerId": None}


def _warn(device, terminalLocationId, title, condition, message, body, itemId=None):
    """A supervisor-facing warning row (no toast). The ScaleFlags* condition
       keeps it out of the press log."""
    BlueRidge.Workorder.PlcWatcher.logInterface(
        device, title, requestPayload=_encode(body), ok=True, errorDescription=message,
        locationId=terminalLocationId, itemId=itemId, errorCondition=condition)


def _readMessage(instancePath):
    """Read MessageBytes directly from the device, not from the tag: the
       receive stamp and the bytes are separate subscribed tags, so when the
       stamp's change event fires the tag may still hold the PREVIOUS press
       (seen in the Digi history, 2026-11-19). Returns the text, or None when
       it cannot be read at good quality -- no fallback to the tag value."""
    cfg = system.tag.readBlocking([
        "%s/MessageBytes.OpcServer" % instancePath,
        "%s/MessageBytes.OpcItemPath" % instancePath,
    ])
    server = cfg[0].value
    itemPath = cfg[1].value
    if not server or not itemPath:
        return None
    qv = system.opc.readValue("%s" % server, "%s" % itemPath)
    if qv is None or not qv.quality.isGood() or qv.value is None:
        return None
    return decodeBytes(qv.value)


def onReceive(instancePath, terminalLocationId, stamp, initialChange=False):
    """Routed here by PlcWatcher.dispatchMessage when LastReceiveTime changes.
       The duplicate / initial-change / stale-stamp guard is the EPrint
       watcher's, called rather than copied. None when not a new press."""
    if not BlueRidge.Workorder.ScaleEPrintWatcher._claim(instancePath, stamp, initialChange):
        return None
    return handleMessage(instancePath, terminalLocationId, _readMessage(instancePath))


def handleMessage(instancePath, terminalLocationId, message):
    """Act on one Digi record. Public so the simulator and the script console
       can drive the whole path with a typed record and no hardware.

       Every outcome is announced once as a page-scoped 'scalePressRecorded'
       so the scale station screen re-reads its press log and held press.

       Returns {"Status": 1|0, "Message": str, "ContainerId": id or None},
       plus "Held": True when the press was held for the operator."""
    try:
        return _handle(instancePath, terminalLocationId, message)
    finally:
        try:
            BlueRidge.Workorder.PlcWatcher.broadcastPageMessage(
                "scalePressRecorded", {"terminalLocationId": terminalLocationId})
        except (Exception, java.lang.Exception) as e:
            BlueRidge.Common.Util.log("scalePressRecorded broadcast failed: %s" % e, level="warn")


def _handle(instancePath, terminalLocationId, message):
    device = instancePath.rsplit("/", 1)[-1]
    S = BlueRidge.Workorder.ScaleStation
    sysUser = BlueRidge.Common.Util.systemAppUserId()

    if message is None:
        return _refuse(device, terminalLocationId, "Scale weighment not read",
                       "The scale sent a weighment but it could not be read back. Check "
                       "the scale's network connection and press the button again.", {"v": 2})

    parsed = parse(message)
    if not parsed["ok"]:
        return _refuse(device, terminalLocationId, "Scale weighment not understood",
                       parsed["reason"], {"v": 2, "raw": message})

    part = parsed["part"]
    body = {"v": 2, "net": parsed["net"], "uom": parsed["uom"], "twm": parsed["twm"],
            "scalePart": part}

    if parsed["uom"].lower() != EXPECTED_UOM:
        return _refuse(device, terminalLocationId, "Scale is in the wrong units",
                       "The scale reported %s, but this system expects %s. Have the scale's "
                       "units checked before weighing again." % (parsed["uom"], EXPECTED_UOM), body)

    if parsed["twm"] != 1:
        return _refuse(device, terminalLocationId, "Scale did not pass this tray",
                       "The scale reported the target weight as not met (TWM=%s). Nothing "
                       "was closed." % parsed["twm"], body)

    pending = S.getPendingPressOrEmpty(terminalLocationId) or {}
    if pending.get("Id") is not None:
        return _refuse(device, terminalLocationId, "Tray waiting for its part",
                       "A tray is waiting for its part. Choose it on the screen, then "
                       "press the scale button again.", body, level="warning")

    running = S.getRunningPartOrEmpty(terminalLocationId) or {}
    # The ONE rule, in SQL (Workorder.ScalePartCode_Resolve, 2026-11-20): an
    # exact active part number, else this terminal's learned code.
    item = S.resolveScalePart(terminalLocationId, part) if part else None
    learned = bool(item) and item.get("Source") == SOURCE_LEARNED

    if learned and not item.get("Eligible"):
        # A learned part that can no longer run here: ask again, and the pick
        # re-teaches the code. Not 'settled' by an open box or override -- the
        # scale named a part, just not one that can run.
        return _hold(device, terminalLocationId, body, parsed, part, sysUser,
                     "The scale sent '%s', learned as %s, which cannot run here now; the tray "
                     "waits for the operator to choose its part." % (part, item.get("PartNumber")))

    if item:
        itemId = item.get("ItemId")
        body["partSource"] = SOURCE_LEARNED if learned else SOURCE_SCALE
        if running.get("ItemId") != itemId:
            switched = S.setRunningPart(terminalLocationId, itemId, appUserId=sysUser) or {}
            if not switched.get("Status"):
                return _refuse(device, terminalLocationId, "Tray not closed",
                               switched.get("Message") or "The scale's part could not be run here.",
                               body, itemId=itemId)
        return closeAs(device, terminalLocationId, body, itemId)

    # The code is no MES part. Settled already (a box is open, or an operator
    # chose the part): close as that part and say so. Otherwise the MES would
    # only be guessing: hold the press for the operator to pick.
    if running.get("ItemId") is not None and (
            running.get("OpenContainerId") is not None or _operatorOverride(running)):
        body["partSource"] = SOURCE_RUNNING
        _warn(device, terminalLocationId, "Scale part not recognised", "ScaleFlagsPartUnknown",
              "The scale sent part '%s', which is not a part number; closed as %s."
              % (part, running.get("PartNumber")), body, itemId=running.get("ItemId"))
        return closeAs(device, terminalLocationId, body, running.get("ItemId"))

    return _hold(device, terminalLocationId, body, parsed, part, sysUser,
                 "The scale sent part '%s', which is not a part number; the tray waits for the "
                 "operator to choose its part." % part)


def _hold(device, terminalLocationId, body, parsed, part, sysUser, why):
    """Hold the press for the operator's pick (Workorder.ScalePendingPress_Hold)."""
    S = BlueRidge.Workorder.ScaleStation
    held = S.holdPress(terminalLocationId, parsed["net"], parsed["uom"], part, appUserId=sysUser) or {}
    if not held.get("Status"):
        return _refuse(device, terminalLocationId, "Tray not closed",
                       held.get("Message") or "The tray could not be held.", body, level="warning")
    _warn(device, terminalLocationId, "Scale press held for part choice", "ScaleFlagsHeld",
          why, dict(body, heldId=held.get("NewId")))
    BlueRidge.Workorder.PlcWatcher.notifyAlarm(
        terminalLocationId, "Choose the part for this tray",
        "The scale sent '%s', which is not a part here. Choose the part on the screen to "
        "close the tray." % part, level="warning")
    return {"Status": 0, "Message": "Tray held until its part is chosen.", "ContainerId": None,
            "Held": True}


def _operatorOverride(running):
    """True when the running part is an override a PERSON chose. An override
       the scale set itself (SYS, after a matched code) is not: once the scale
       sends a code that matches nothing, its earlier choice is stale, and
       closing as it could mint the wrong part (decided 2026-11-19)."""
    return running.get("Source") == "Override" and ("%s" % (running.get("OverrideSetBy") or "")).upper() != "SYS"


def closeAs(device, terminalLocationId, body, itemId):
    """Close one tray at the station's running part (already itemId), with the
       MES weight judgement as a cross-check that never blocks. Shared by a
       live press and a held-press pick. Returns {Status, Message, ContainerId,
       FinishedGoodLotId}."""
    W = BlueRidge.Workorder.PlcWatcher
    verdict = BlueRidge.Parts.ContainerConfig.judgeWeight(itemId, "ByWeight", body.get("net")) or {}
    mes = verdict.get("Verdict")
    body.update({"verdict": "Ok", "scaleVerdict": "Ok", "mesVerdict": mes,
                 "low": _num(verdict.get("LowLimit")), "high": _num(verdict.get("HighLimit")),
                 "agree": (mes == "Ok") if mes in ("Ok", "Under", "Over") else None})
    if mes != "Ok":
        _warn(device, terminalLocationId, "Scale passed a weight the MES would not",
              "ScaleFlagsMesMismatch",
              "The scale passed %s %s; the MES judged it %s. %s"
              % (body.get("net"), body.get("uom"), mes, verdict.get("Message") or ""),
              body, itemId=itemId)

    result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId, "ByWeight") or {}
    ok = bool(result.get("Status"))
    W.logInterface(device, "ByWeight tray close", requestPayload=_encode(body),
                   responsePayload=system.util.jsonEncode(result), ok=ok,
                   errorDescription=None if ok else result.get("Message"),
                   locationId=terminalLocationId, itemId=itemId,
                   lotId=result.get("FinishedGoodLotId") if ok else None)
    if not ok:
        msg = result.get("Message") or "Tray close failed"
        W.notifyAlarm(terminalLocationId, "ByWeight tray close failed", msg)
        return {"Status": 0, "Message": msg, "ContainerId": None, "FinishedGoodLotId": None}
    return {"Status": 1, "Message": "Tray closed", "ContainerId": result.get("ContainerId"),
            "FinishedGoodLotId": result.get("FinishedGoodLotId")}


def pickPart(pendingId, terminalLocationId, itemId, appUserId):
    """The operator picked the part for the terminal's held press: close that
       tray as the picked part. Called from the scale station screen
       (ScaleStation.applyPendingPick) with the signed-in operator.

       Claim first (Pending -> Closed, conditional in SQL), so a double tap or a
       second screen closes nothing. If the part switch or the close is then
       refused, the claim is released and the press waits again. On a close the
       outcome is stamped (_Complete), which writes the pick's audit row.

       Returns {Status, Message, ContainerId}."""
    try:
        return _pick(pendingId, terminalLocationId, itemId, appUserId)
    finally:
        try:
            BlueRidge.Workorder.PlcWatcher.broadcastPageMessage(
                "scalePressRecorded", {"terminalLocationId": terminalLocationId})
        except (Exception, java.lang.Exception) as e:
            BlueRidge.Common.Util.log("scalePressRecorded broadcast failed: %s" % e, level="warn")


def _pick(pendingId, terminalLocationId, itemId, appUserId):
    S = BlueRidge.Workorder.ScaleStation
    held = S.getPendingPressOrEmpty(terminalLocationId) or {}
    if held.get("Id") is None or ("%s" % held.get("Id")) != ("%s" % pendingId):
        return {"Status": 0, "Message": "This tray has already been dealt with.", "ContainerId": None}

    claimed = S.claimPress(pendingId, appUserId=appUserId) or {}
    if not claimed.get("Status"):
        return {"Status": 0, "Message": claimed.get("Message") or "This tray has already been dealt with.",
                "ContainerId": None}

    # From here the press is claimed (no longer Pending). Every way out that did
    # not close the tray must put it back, including an exception (a deadlock
    # victim or timeout in the close), or the held tray would vanish from the
    # screen with no tray closed.
    closed = False
    try:
        running = S.getRunningPartOrEmpty(terminalLocationId) or {}
        if running.get("ItemId") != itemId:
            switched = S.setRunningPart(terminalLocationId, itemId, appUserId=appUserId) or {}
            if not switched.get("Status"):
                _release(pendingId, terminalLocationId, appUserId)
                return {"Status": 0, "Message": switched.get("Message") or "That part cannot run here.",
                        "ContainerId": None}

        device = (S.scaleInstancePath(terminalLocationId) or "scale").rsplit("/", 1)[-1]
        body = {"v": 2, "net": _num(held.get("NetWeight")), "uom": held.get("Uom"), "twm": 1,
                "scalePart": held.get("ScalePartCode"), "partSource": SOURCE_PICKED, "heldId": pendingId}
        result = closeAs(device, terminalLocationId, body, itemId)
        if not result.get("Status"):
            _release(pendingId, terminalLocationId, appUserId)
            return result
        closed = True
        S.completePress(pendingId, itemId, result.get("FinishedGoodLotId"), appUserId=appUserId)
        return result
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("held-press pick %s failed: %s" % (pendingId, e), level="error")
        if not closed:
            _release(pendingId, terminalLocationId, appUserId)
            return {"Status": 0, "Message": "The tray could not be closed: %s" % e, "ContainerId": None}
        # The tray closed; only stamping the outcome failed. Do not release it.
        return {"Status": 1, "Message": "Tray closed (the held press record was not updated: %s)" % e,
                "ContainerId": None}


def _release(pendingId, terminalLocationId, appUserId):
    """Put a claimed press back to Pending. A release that fails is not
       ignored: the press would otherwise be stranded with no tray closed."""
    try:
        r = BlueRidge.Workorder.ScaleStation.releasePress(pendingId, appUserId=appUserId) or {}
        ok, why = bool(r.get("Status")), r.get("Message")
    except (Exception, java.lang.Exception) as e:
        ok, why = False, "%s" % e
    if not ok:
        BlueRidge.Workorder.PlcWatcher.notifyAlarm(
            terminalLocationId, "Held tray could not be put back",
            "The tray was not closed and its held weighment could not be restored (%s). Weigh "
            "the tray again; a supervisor can check held press %s." % (why, pendingId), level="error")


def discardPress(pendingId, terminalLocationId, appUserId):
    """Discard the terminal's held press (no tray closed, audited in SQL).
       Returns {Status, Message}."""
    try:
        return BlueRidge.Workorder.ScaleStation.discardPress(pendingId, appUserId=appUserId) or {
            "Status": 0, "Message": "The held tray could not be discarded."}
    finally:
        try:
            BlueRidge.Workorder.PlcWatcher.broadcastPageMessage(
                "scalePressRecorded", {"terminalLocationId": terminalLocationId})
        except (Exception, java.lang.Exception) as e:
            BlueRidge.Common.Util.log("scalePressRecorded broadcast failed: %s" % e, level="warn")


def digiRecord(net, part, twm=1, uom="LB"):
    """The record exactly as the TCP driver delivers it for one press (the
       previous record's LFs in front, CR at the end), for the dev simulator
       (BlueRidge.Sim.fireScaleDigi)."""
    return "\n\n(NET)%.1f<UOM>%s<TWM>%d<Part>%s\r" % (float(net), uom, int(twm), part)
