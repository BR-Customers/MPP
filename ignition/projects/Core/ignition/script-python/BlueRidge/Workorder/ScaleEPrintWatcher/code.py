"""BlueRidge.Workorder.ScaleEPrintWatcher - assembly checkweigh scales read over
   EPrint demand output (IND570 with NO PLC option card).

   Spec: docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md
   UDT:  ignition/tags/udt/ScaleStationEPrint.json  (Message, MessageBytes,
         LastReceiveTime -- a mirror of the TCP driver's own tags)

   Sits BESIDE ScaleWatcher (the Modbus build), not in place of it. Which one
   runs for a terminal is decided by its TerminalPlcDevice row's device type.

   SHAPE. The terminal pushes; the MES never asks. The operator presses the
   scale's button, the terminal prints its template onto the socket, and the
   whole template arrives as ONE Message value:

        35.13 lb            gross
        16.93 lb T          tare
        18.20 lb N          net        <- the only line acted on
       CAM=1                only on a head whose template was extended by
                            Add-IND570CameraField.ps1; absent on a
                            weight-only scale, and not gated on here

       LastReceiveTime moves -> tag-change -> PlcWatcher.dispatchMessage
           -> onReceive: is this a real, new, recent press?
           -> read Message straight from the device
           -> parse the net line
           -> SQL judges it against ContainerConfig          [the verdict]
           -> Ok: Assembly.plcCompleteTray(terminal, "ByWeight")
              anything else: refuse, tell the operator, log, close nothing

   No verdict is computed here. Parsing a printed line is transport; whether
   18.20 lb is a good tray is Parts.ContainerConfig_JudgeWeight's decision.

   WHY THE TRIGGER IS THE RECEIVE STAMP, NOT Message. Two trays of the same
   weight print the same text, and a tag whose value did not change raises no
   change event -- the second tray would never close. The stamp moves on
   every receipt.
"""

import java.lang
import re
import threading

import system.date
import system.opc
import system.tag


# The unit every terminal is commissioned in. A different unit on the wire is
# not converted: it means the terminal is set up differently from what was
# verified, and quietly converting would hide that.
EXPECTED_UOM = "lb"

# A stamp older than this is not a press happening now. It is the driver
# re-presenting its last receipt -- after a reconnect, a quality blip, or a
# tag-provider restart -- and acting on it would close a tray nobody weighed.
_MAX_AGE_SEC = 30

# instancePath -> the last receive stamp acted on or deliberately skipped, as
# epoch millis. Guards the duplicate events one receipt can raise (the script
# subscribes to value, quality AND timestamp changes). Module memory is lost
# on a script reload, which is why the recency test above exists as well:
# neither guard alone covers both a duplicate and a restart.
_lastSeen = {}
_lastSeenLock = threading.Lock()

# "<number> <unit> N", the net line. The lookahead lets N be followed by
# whitespace, end of text, or the CAM= field with no separator between.
_NET = re.compile(r"(?<![\w.])(-?\d+(?:\.\d+)?)\s*([A-Za-z]+)[ \t]+N(?=\s|$|CAM=)")
_CAM = re.compile(r"CAM=([01])")


def parse(message):
    """Pull the net weighment out of one printed template.

       Returns {"ok": True, "net": float, "netText": str, "uom": str,
                "cam": 0 | 1 | None}
            or {"ok": False, "reason": str}.

       Exactly ONE net line is required. None means this was not a weighment
       record; more than one means two presses were run together into a single
       message, and picking either would be a guess."""
    text = "" if message is None else "%s" % message
    found = _NET.findall(text)
    if len(found) == 0:
        return {"ok": False,
                "reason": "The scale's printout has no net weight line."}
    if len(found) > 1:
        return {"ok": False,
                "reason": "The scale's printout has %d net weight lines; "
                          "expected one." % len(found)}
    netText, uom = found[0]
    cam = _CAM.search(text)
    return {"ok": True, "net": float(netText), "netText": netText, "uom": uom,
            "cam": int(cam.group(1)) if cam else None}


def _claim(instancePath, stamp, initialChange):
    """True when this receive stamp is a new press that should be acted on.

       The subscription's own first event is recorded and skipped: it reports
       whatever the driver already held, which is the PREVIOUS press."""
    try:
        millis = stamp.getTime()
    except AttributeError:
        return False

    _lastSeenLock.acquire()
    try:
        if _lastSeen.get(instancePath) == millis:
            return False
        _lastSeen[instancePath] = millis
    finally:
        _lastSeenLock.release()

    if initialChange:
        return False
    age = system.date.secondsBetween(stamp, system.date.now())
    if age > _MAX_AGE_SEC:
        BlueRidge.Common.Util.log(
            "receive stamp on %s is %ss old -- not a live press, ignored"
            % (instancePath, age), level="warn")
        return False
    return True


def _readMessage(instancePath):
    """Read Message directly from the device, not from the tag.

       The receive stamp and the message are two separate subscribed tags, so
       when the stamp's change event fires the Message TAG may still hold the
       previous press. Acting on that would judge the last tray's weight
       against this tray. A direct OPC read asks the driver itself.

       Returns the text, or None when it cannot be read at good quality --
       there is deliberately no fallback to the tag value."""
    cfg = system.tag.readBlocking([
        "%s/Message.OpcServer" % instancePath,
        "%s/Message.OpcItemPath" % instancePath,
    ])
    server = cfg[0].value
    itemPath = cfg[1].value
    if not server or not itemPath:
        return None
    qv = system.opc.readValue("%s" % server, "%s" % itemPath)
    if qv is None or not qv.quality.isGood() or qv.value is None:
        return None
    return "%s" % qv.value


def _refuse(device, terminalLocationId, title, message, payload, level="error"):
    """One refusal: an InterfaceLog row and a toast at this terminal. Returns
       the status dict so a caller can `return _refuse(...)`."""
    W = BlueRidge.Workorder.PlcWatcher
    W.logInterface(device, title, requestPayload=payload, ok=False,
                   errorDescription=message)
    W.notifyAlarm(terminalLocationId, title, message, level=level)
    return {"Status": 0, "Message": message, "ContainerId": None}


def onReceive(instancePath, terminalLocationId, stamp, initialChange=False):
    """Routed here by PlcWatcher.dispatchMessage when LastReceiveTime changes.
       Returns the status dict, or None when the event was not a new press."""
    if not _claim(instancePath, stamp, initialChange):
        return None
    return handleMessage(instancePath, terminalLocationId,
                         _readMessage(instancePath))


def handleMessage(instancePath, terminalLocationId, message):
    """Judge one printed weighment and close the tray if SQL says it is Ok.

       Public so the simulator and the script console can drive the whole path
       with a typed message and no hardware.

       Returns {"Status": 1|0, "Message": str, "ContainerId": id or None}."""
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]

    if message is None:
        return _refuse(device, terminalLocationId, "Scale weighment not read",
                       "The scale sent a weighment but it could not be read "
                       "back. Check the scale's network connection and press "
                       "the button again.", None)

    parsed = parse(message)
    if not parsed["ok"]:
        return _refuse(device, terminalLocationId, "Scale weighment not understood",
                       parsed["reason"], message)

    payload = "net=%s uom=%s cam=%s" % (parsed["netText"], parsed["uom"], parsed["cam"])

    if parsed["uom"].lower() != EXPECTED_UOM:
        return _refuse(device, terminalLocationId, "Scale is in the wrong units",
                       "The scale reported %s, but this system expects %s. "
                       "Have the scale's units checked before weighing again."
                       % (parsed["uom"], EXPECTED_UOM), payload)

    ctx = BlueRidge.Workorder.Assembly.resolvePlcCloseContext(terminalLocationId, "ByWeight")
    if ctx.get("error"):
        return _refuse(device, terminalLocationId, "Tray not closed",
                       ctx["error"], payload)

    verdict = BlueRidge.Parts.ContainerConfig.judgeWeight(
        ctx["finishedGoodItemId"], "ByWeight", parsed["net"]) or {}
    payload = "%s item=%s verdict=%s low=%s high=%s" % (
        payload, ctx["finishedGoodItemId"], verdict.get("Verdict"),
        verdict.get("LowLimit"), verdict.get("HighLimit"))

    if verdict.get("Verdict") != "Ok":
        # Under / Over is the ordinary checkweigh reject and clears itself on
        # the next good tray; anything else is a configuration fault that
        # stays on screen until someone deals with it.
        level = "warning" if verdict.get("Verdict") in ("Under", "Over") else "error"
        return _refuse(device, terminalLocationId, "Tray not closed",
                       verdict.get("Message") or "The tray weight could not be judged.",
                       payload, level=level)

    result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId, "ByWeight")
    ok = bool(result and result.get("Status"))
    W.logInterface(device, "ByWeight tray close", requestPayload=payload,
                   responsePayload=str(result), ok=ok,
                   errorDescription=None if ok else (result or {}).get("Message"))
    if not ok:
        msg = (result or {}).get("Message") or "Tray close failed"
        W.notifyAlarm(terminalLocationId, "ByWeight tray close failed", msg)
        return {"Status": 0, "Message": msg, "ContainerId": None}

    return {"Status": 1, "Message": "Tray closed",
            "ContainerId": result.get("ContainerId")}
