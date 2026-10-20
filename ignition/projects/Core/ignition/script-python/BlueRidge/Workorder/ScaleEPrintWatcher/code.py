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
       UNDER: 0 OVER: 0 OK: 1
                            only on a head printing Template 3 (its own
                            Target Table verdict, st0105/6/7); no line
                            break after it. A SECOND OPINION: logged and
                            compared in SQL, never acted on

       LastReceiveTime moves -> tag-change -> PlcWatcher.dispatchMessage
           -> onReceive: is this a real, new, recent press?
           -> read Message straight from the device
           -> parse the net line
           -> SQL judges it against ContainerConfig          [the verdict]
           -> Ok: Assembly.plcCompleteTray(terminal, "ByWeight")
              anything else: refuse, tell the operator, log, close nothing

   No verdict is computed here. Parsing a printed line is transport; whether
   18.20 lb is a good tray is Parts.ContainerConfig_JudgeWeight's decision.

   THE SCALE'S FLAGS (option C, 2026-10-19). When the head prints its own
   UNDER / OVER / OK flags they go to the same proc, which classifies them
   (ScaleVerdict) and compares them with its own verdict (FlagsAgree). The MES
   verdict alone decides the close. When SQL returns a FlagsMessage -- the
   two judges disagree, the scale has no active target, or the flags do not
   read as one verdict -- a warning row is logged for supervisors and
   engineers. No toast: operators do not read the scale display, and the
   usual cause is a Target Table record not switched at a part changeover.

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
import system.util


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
# Template 3's flags, from Malaki's exported Template3.txt (office head
# B913444851): line 4 is `UNDER: ` st0105 ` OVER: ` st0106 ` OK: ` st0107 with
# NO trailing CRLF. His how-to doc showed them on the N line instead, so they
# are matched anywhere in the message. Each value is ONE digit, 0 or 1.
#
# Verified 2026-10-19 against real prints from that head on Dev (74 bytes each;
# Audit.InterfaceLog Id 38). Production heads run their own TaskExpert
# programs; confirm each one's print before relying on its flags.
_FLAGS = re.compile(r"UNDER:\s*(\d+)\s+OVER:\s*(\d+)\s+OK:\s*(\d+)")
_FLAGS_HINT = re.compile(r"UNDER:|OVER:|OK:")


def parse(message):
    """Pull the net weighment out of one printed template.

       Returns {"ok": True, "net": float, "netText": str, "uom": str,
                "cam": 0 | 1 | None,
                "flags": {"under": 0|1, "over": 0|1, "ok": 0|1} | None,
                "flagsState": "absent" | "read" | "unreadable"}
            or {"ok": False, "reason": str}.

       Exactly ONE net line is required. None means this was not a weighment
       record; more than one means two presses were run together into a single
       message, and picking either would be a guess.

       The flags are optional and NEVER make a record unreadable: they are a
       second opinion, and only the net line decides whether a weighment can
       be judged. Absent (a Template 1 head) is flags None, flagsState
       'absent'. Present but malformed is flags None, flagsState 'unreadable',
       so the log can tell the two apart: only part of the line, a value that
       is not a single 0 or 1, more than one flag set, or the line twice.
       All three 0 is READ, not malformed: the scale has no active target,
       which SQL reports as its own state (ScaleVerdict 'NoTarget')."""
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
    flags, flagsState = _parseFlags(text)
    return {"ok": True, "net": float(netText), "netText": netText, "uom": uom,
            "cam": int(cam.group(1)) if cam else None,
            "flags": flags, "flagsState": flagsState}


def template3Record(gross, tare, net, under, over, ok):
    """The exact record an IND570 head on Template 3 prints for one press,
       for the dev simulator (BlueRidge.Sim.fireScaleEPrint): weights right-
       justified width 10, unit left-justified width 3, CRLF after the three
       weight lines, NO line break after the flags. Byte-identical in length
       (74) to the office head's real prints of 2026-10-19."""
    return ("%10.1f %-3s\r\n%10.1f %-3sT \r\n%10.1f %-3sN \r\nUNDER: %d OVER: %d OK: %d"
            % (gross, EXPECTED_UOM, tare, EXPECTED_UOM, net, EXPECTED_UOM, under, over, ok))


def _parseFlags(text):
    """(flags dict or None, 'absent' | 'read' | 'unreadable'). Never raises a
       refusal: see parse()."""
    found = _FLAGS.findall(text)
    if not found:
        return None, ("unreadable" if _FLAGS_HINT.search(text) else "absent")
    if len(found) > 1:
        return None, "unreadable"
    values = found[0]
    if any(v not in ("0", "1") for v in values) or sum(int(v) for v in values) > 1:
        return None, "unreadable"
    return {"under": int(values[0]), "over": int(values[1]),
            "ok": int(values[2])}, "read"


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


def _num(value):
    """A DB decimal (BigDecimal) or None as a JSON-safe float or None."""
    return None if value is None else float("%s" % value)


def _encode(body):
    """The RequestPayload: one JSON object (spec 2026-10-19 scale station 4).
       Keys a press did not reach are left out; 'v' versions the shape so the
       press-log read can skip rows written before it."""
    return system.util.jsonEncode(body)


def _refuse(device, terminalLocationId, title, message, body, level="error", itemId=None):
    """One refusal: an InterfaceLog row and a toast at this terminal. Returns
       the status dict so a caller can `return _refuse(...)`."""
    W = BlueRidge.Workorder.PlcWatcher
    W.logInterface(device, title, requestPayload=_encode(body), ok=False,
                   errorDescription=message,
                   locationId=terminalLocationId, itemId=itemId)
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

       Every outcome -- close, refusal, failure -- is then announced once as
       a page-scoped 'scalePressRecorded' so the terminal's screen re-reads
       its press log. A failed broadcast never undoes or masks the press.

       Returns {"Status": 1|0, "Message": str, "ContainerId": id or None}."""
    try:
        return _handle(instancePath, terminalLocationId, message)
    finally:
        try:
            BlueRidge.Workorder.PlcWatcher.broadcastPageMessage(
                "scalePressRecorded", {"terminalLocationId": terminalLocationId})
        except (Exception, java.lang.Exception) as e:
            BlueRidge.Common.Util.log("scalePressRecorded broadcast failed: %s" % e, level="warn")


def _handle(instancePath, terminalLocationId, message):
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]

    if message is None:
        return _refuse(device, terminalLocationId, "Scale weighment not read",
                       "The scale sent a weighment but it could not be read "
                       "back. Check the scale's network connection and press "
                       "the button again.", {"v": 1})

    parsed = parse(message)
    if not parsed["ok"]:
        return _refuse(device, terminalLocationId, "Scale weighment not understood",
                       parsed["reason"], {"v": 1, "raw": message})

    body = {"v": 1, "net": parsed["net"], "uom": parsed["uom"], "cam": parsed["cam"],
            "flags": parsed["flags"], "flagsState": parsed["flagsState"]}

    if parsed["uom"].lower() != EXPECTED_UOM:
        return _refuse(device, terminalLocationId, "Scale is in the wrong units",
                       "The scale reported %s, but this system expects %s. "
                       "Have the scale's units checked before weighing again."
                       % (parsed["uom"], EXPECTED_UOM), body)

    ctx = BlueRidge.Workorder.Assembly.resolvePlcCloseContext(terminalLocationId, "ByWeight")
    if ctx.get("error"):
        return _refuse(device, terminalLocationId, "Tray not closed",
                       ctx["error"], body)
    itemId = ctx["finishedGoodItemId"]

    verdict = BlueRidge.Parts.ContainerConfig.judgeWeight(
        itemId, "ByWeight", parsed["net"], scaleFlags=parsed["flags"]) or {}
    agree = verdict.get("FlagsAgree")
    body.update({"verdict": verdict.get("Verdict"),
                 "low": _num(verdict.get("LowLimit")), "high": _num(verdict.get("HighLimit")),
                 "scaleVerdict": verdict.get("ScaleVerdict"),
                 "agree": None if agree is None else bool(agree)})

    # The scale's second opinion. SQL decided whether it is worth a look
    # (FlagsMessage); this only files it. It is logged BEFORE the close or
    # refusal so it is on record whichever way the press goes, and it raises
    # no toast and changes nothing about what happens next.
    if verdict.get("FlagsMessage"):
        W.logInterface(device, "Scale flags warning", requestPayload=_encode(body),
                       ok=True, errorDescription=verdict.get("FlagsMessage"),
                       locationId=terminalLocationId, itemId=itemId,
                       errorCondition=("ScaleFlagsMismatch"
                                       if verdict.get("FlagsAgree") in (0, False)
                                       else "ScaleFlags%s" % verdict.get("ScaleVerdict")))

    if verdict.get("Verdict") != "Ok":
        # Under / Over is the ordinary checkweigh reject and clears itself on
        # the next good tray; anything else is a configuration fault that
        # stays on screen until someone deals with it.
        level = "warning" if verdict.get("Verdict") in ("Under", "Over") else "error"
        return _refuse(device, terminalLocationId, "Tray not closed",
                       verdict.get("Message") or "The tray weight could not be judged.",
                       body, level=level, itemId=itemId)

    result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId, "ByWeight")
    ok = bool(result and result.get("Status"))
    W.logInterface(device, "ByWeight tray close", requestPayload=_encode(body),
                   responsePayload=system.util.jsonEncode(result or {}), ok=ok,
                   errorDescription=None if ok else (result or {}).get("Message"),
                   locationId=terminalLocationId, itemId=itemId,
                   lotId=(result or {}).get("FinishedGoodLotId") if ok else None)
    if not ok:
        msg = (result or {}).get("Message") or "Tray close failed"
        W.notifyAlarm(terminalLocationId, "ByWeight tray close failed", msg)
        return {"Status": 0, "Message": msg, "ContainerId": None}

    return {"Status": 1, "Message": "Tray closed",
            "ContainerId": result.get("ContainerId")}
