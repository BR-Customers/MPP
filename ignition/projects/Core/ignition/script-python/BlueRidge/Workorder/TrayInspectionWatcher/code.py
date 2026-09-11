"""BlueRidge.Workorder.TrayInspectionWatcher - tray-inspection handshake.

   The FIFO-validation core of the PLC integration (spec Sec 4.3/4.4, 5).

   Two handshake protocols share the TrayInspectionStation UDT. Which one a
   device speaks is per-instance configuration: the UDT's `Protocol` memory
   member. Blank / missing = SkuVerify, so an instance imported before the
   member existed keeps its original behaviour.

   SkuVerify  (vision SKU-ID cells: the *_OilPan devices)
     TrayLocked rising edge -> recipe select: the expected finished good's
       Item.PlcId written as PartNumber (the PLC selects the vision recipe
       before it inspects). The trigger is acked (reset) by the MES.
     InspectionComplete rising edge -> read VisionPartNumber, compare to the
       expected PlcId.
         mismatch -> LINE STOP: OkToContinue stays false, PlcLineStop logged,
                     operator alarm.
         match    -> OkToContinue = true, then the ByVision tray close.

   SlcTray  (MicroLogix tray cells wired DIRECT to the AB driver: 6MA_CH)
     Mirrors the PLC's own host interface (the MPPMACH ladder's "LAD 4 - HOST"
     file; address map + rung references in
     notes/2026-09-10_6ma-ch-camera-plc-host-interface.md):
       N7:0  TrayLocked          PLC -> MES  re-asserted EVERY scan while the
                                             tray is locked; cleared by the PLC
       N7:1  OkToContinue        MES -> PLC  "ok to trigger": the camera will
                                             NOT fire until this goes 1; the
                                             PLC clears it when the tray leaves
       N7:2  PartNumber          MES -> PLC  vision recipe number
       N7:30 InspectionComplete  PLC -> MES  "send done"; cleared by the PLC
       N7:10..27 PartDisposition01..18  PLC -> MES  the tray VERDICT, all
             written identically: 1 on camera PASS, 0 on FAIL. The ladder
             symbols read "PART# n BAD TO HOST" but rung 9 moves 1 into every
             word on PASS and rung 6 moves 0 on FAIL -- trust the logic, not
             the label.
     TrayLocked rising edge -> write the recipe, THEN OkToContinue = true.
     InspectionComplete rising edge -> read the verdict.
         all dispositions 1 -> ByVision tray close.
         all dispositions 0 -> the PLC already routed the tray to the reject
                               side; nothing is booked (a re-inspected tray
                               would otherwise count twice).
         anything else      -> not the protocol we expected; alarm, no close.
     The MES writes NEITHER trigger. Legacy never did (the EMMD catalog marks
     both read-only), and TrayLocked is re-asserted every scan -- an MES reset
     would bounce straight back and every bounce is a fresh rising edge.

   The comparisons here are protocol decoding of PLC words, not business rules.
   The finished good, pack-out and tray close all resolve through
   Assembly.resolvePlcCloseContext / plcCompleteTray -- the same path the
   operator ByCount button uses.
"""

import java.lang

PROTOCOL_SKU_VERIFY = "SkuVerify"
PROTOCOL_SLC_TRAY = "SlcTray"

_DISPOSITIONS = ["PartDisposition%02d" % i for i in range(1, 19)]


def handleEdge(instancePath, terminalLocationId, member):
    if member not in ("TrayLocked", "InspectionComplete"):
        return
    protocol = _protocol(instancePath)
    if protocol == PROTOCOL_SLC_TRAY:
        if member == "TrayLocked":
            _slcOnTrayLocked(instancePath, terminalLocationId)
        else:
            _slcOnInspectionComplete(instancePath, terminalLocationId)
    elif protocol == PROTOCOL_SKU_VERIFY:
        if member == "TrayLocked":
            _onTrayLocked(instancePath, terminalLocationId)
        else:
            _onInspectionComplete(instancePath, terminalLocationId)
    else:
        W = BlueRidge.Workorder.PlcWatcher
        msg = "Unknown tray Protocol '%s' (expected %s or %s)" % (
            protocol, PROTOCOL_SKU_VERIFY, PROTOCOL_SLC_TRAY)
        W.logInterface(_device(instancePath), "%s ignored" % member,
                       requestPayload="terminal=%s" % terminalLocationId,
                       ok=False, errorDescription=msg)
        W.notifyAlarm(terminalLocationId, "PLC device misconfigured", msg)


# ---- shared -------------------------------------------------------------------
def _device(instancePath):
    return instancePath.rsplit("/", 1)[-1]


def _protocol(instancePath):
    """The instance's handshake protocol. A missing member reads as bad quality
       -> None -> SkuVerify, so pre-existing instances are unaffected."""
    value = BlueRidge.Workorder.PlcWatcher.readMember(instancePath, "Protocol")
    value = ("%s" % value).strip() if value is not None else ""
    return value or PROTOCOL_SKU_VERIFY


def _writeOk(result):
    """True when a single-tag writeBlocking result came back Good."""
    try:
        return bool(result) and result[0].isGood()
    except (Exception, java.lang.Exception):
        return False


def _expectedRecipe(terminalLocationId):
    """(context, plcId, errorMessage) for the tray this terminal is building.

       The recipe is the FINISHED GOOD's Item.PlcId -- the same finished good
       the tray close will mint (open container's item, else the recommended
       FG at the line), via Assembly.resolvePlcCloseContext. It used to be the
       Item of the oldest open LOT on the line, which on a multi-component
       assembly (6MA cam holder: ten castings + dowel pins) is whichever
       component happened to arrive first. Fails closed: on any error the
       caller alarms and does not release the tray."""
    ctx = BlueRidge.Workorder.Assembly.resolvePlcCloseContext(terminalLocationId, "ByVision")
    if ctx.get("error"):
        return (None, None, ctx["error"])
    row = BlueRidge.Parts.Item.getPlcId(ctx.get("finishedGoodItemId"))
    plcId = row.get("PlcId") if row else None
    if plcId is None:
        return (ctx, None, "Item.PlcId (PLC / Vision Recipe ID) is not set on finished good %s"
                % ctx.get("finishedGoodItemId"))
    return (ctx, plcId, None)


def _closeTray(instancePath, terminalLocationId, recipe):
    """Record the tray close: mint the FG LOT + consume BOM via the shared PLC
       close (the SAME Assembly_CompleteTray path the operator ByCount button
       uses). Piece count = the finished good's configured ByVision
       PartsPerTray; the container auto-completes (AIM + label) when full. A
       resolution/DB failure alarms the HMI; the tray has already physically
       passed inspection."""
    W = BlueRidge.Workorder.PlcWatcher
    result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId, "ByVision")
    ok = bool(result and result.get("Status"))
    W.logInterface(_device(instancePath), "ByVision tray close",
                   requestPayload="terminal=%s recipe=%s" % (terminalLocationId, recipe),
                   responsePayload=str(result), ok=ok,
                   errorDescription=None if ok else (result or {}).get("Message"))
    if not ok:
        msg = (result or {}).get("Message") or "Tray close failed"
        W.writeDisplay(instancePath, {"MESAlarmType": 1, "MESAlarmText": msg})
        W.notifyAlarm(terminalLocationId, "ByVision tray close failed", msg)
        return result
    # The tray booked, but a FULL container whose completion was refused (empty
    # AIM pool, ...) stays open -- no serial, no label -- and the very next tray
    # is rejected as "Container is full". plcCompleteTray reports that only
    # inside ContainerComplete, so without this the operator hears nothing until
    # a tray later, and then not the cause. (Label print failures alarm on their
    # own in Container.complete.)
    cc = result.get("ContainerComplete")
    if cc is not None and not cc.get("Status"):
        msg = "%s Fix it, then press Complete at the terminal." % (
            cc.get("Message") or "Container completion failed.")
        W.logInterface(_device(instancePath), "Container completion refused",
                       requestPayload="container=%s" % result.get("ContainerId"),
                       responsePayload=str(cc), ok=False, errorDescription=msg)
        W.notifyAlarm(terminalLocationId, "Container not completed", msg)
    return result


# ---- SkuVerify ------------------------------------------------------------------
def _onTrayLocked(instancePath, terminalLocationId):
    W = BlueRidge.Workorder.PlcWatcher
    device = _device(instancePath)
    # Ack the trigger immediately (mirrors ScaleWatcher/NonSerializedMipWatcher/
    # SerializedMipWatcher -- every other watcher resets its trigger member back
    # to False as part of handling the edge). This watcher never did, so the
    # member latched True after the FIRST tray/inspection and every subsequent
    # pulse (write True again) was never seen as a rising edge again -- a
    # one-shot-then-permanently-silent device, easy to mistake for "nothing
    # happened" on click N+1 (2026-08-20, found practicing ByVision closures).
    # SkuVerify only: an SlcTray PLC owns its triggers (see module docstring).
    W.writeMember(instancePath, "TrayLocked", False)
    ctx, plcId, err = _expectedRecipe(terminalLocationId)
    if err:
        W.logInterface(device, "Tray locked -> recipe select failed",
                       requestPayload="terminal=%s" % terminalLocationId,
                       ok=False, errorDescription=err)
        BlueRidge.Common.Util.log("tray %s: %s -- cannot select recipe"
                                  % (instancePath, err), level="warn")
        W.notifyAlarm(terminalLocationId, "Recipe select failed", err)
        return
    # Select the vision recipe in the PLC (control write, not display).
    W.writeMember(instancePath, "PartNumber", plcId)
    W.logInterface(device, "Tray locked -> recipe select",
                   requestPayload="item=%s" % ctx.get("finishedGoodItemId"),
                   responsePayload="PartNumber=%s" % plcId, ok=True)


def _onInspectionComplete(instancePath, terminalLocationId):
    W = BlueRidge.Workorder.PlcWatcher
    device = _device(instancePath)
    # Ack the trigger immediately (see _onTrayLocked) -- same one-shot latch bug.
    W.writeMember(instancePath, "InspectionComplete", False)
    ctx, expected, err = _expectedRecipe(terminalLocationId)
    vision = W.readMember(instancePath, "VisionPartNumber")

    if err:
        W.logInterface(device, "Inspection complete (no expected recipe)",
                       requestPayload="vision=%s" % vision, ok=False,
                       errorDescription=err)
        return

    # Data comparison of two integers -- expected recipe vs. what vision read.
    if vision is None or int(vision) != int(expected):
        # LINE STOP -- leave the tray locked (do not release), alarm + record.
        reason = "Vision %s != expected recipe %s (item %s)" % (
            vision, expected, ctx.get("finishedGoodItemId"))
        W.logInterface(device, "Vision mismatch -> line stop",
                       requestPayload="item=%s expected=%s vision=%s"
                       % (ctx.get("finishedGoodItemId"), expected, vision),
                       ok=False, errorDescription=reason, logEventTypeCode="PlcLineStop")
        W.writeDisplay(instancePath, {"MESAlarmType": 2, "MESAlarmText": reason})
        BlueRidge.Common.Util.log("tray %s LINE STOP: %s" % (instancePath, reason), level="warn")
        W.notifyAlarm(terminalLocationId, "LINE STOP - vision mismatch", reason)
        return

    # Match -> release the tray (physical handshake first; the DB record follows).
    W.writeMember(instancePath, "OkToContinue", True)
    W.logInterface(device, "Inspection complete -> tray released",
                   requestPayload="item=%s recipe=%s" % (ctx.get("finishedGoodItemId"), expected),
                   responsePayload="OkToContinue=True", ok=True)
    _closeTray(instancePath, terminalLocationId, expected)


# ---- SlcTray --------------------------------------------------------------------
def _slcOnTrayLocked(instancePath, terminalLocationId):
    """Recipe, then the go-ahead. No trigger write: the PLC re-asserts N7:0
       every scan and clears it itself once the tray is gone."""
    W = BlueRidge.Workorder.PlcWatcher
    device = _device(instancePath)
    ctx, plcId, err = _expectedRecipe(terminalLocationId)
    if err:
        # Fail closed: without OkToContinue the camera never fires and the
        # tray stays locked -- the operator sees why instead of an unbookable
        # tray going through.
        W.logInterface(device, "Tray locked -> NOT released (recipe select failed)",
                       requestPayload="terminal=%s" % terminalLocationId,
                       ok=False, errorDescription=err)
        BlueRidge.Common.Util.log("tray %s: %s -- tray held" % (instancePath, err), level="warn")
        W.notifyAlarm(terminalLocationId, "Tray held - recipe select failed", err)
        return
    # Two separate writes, recipe first: the PLC loads a changed recipe into
    # the vision controller before it honours the trigger.
    if not _writeOk(W.writeMember(instancePath, "PartNumber", plcId)):
        msg = "Could not write recipe %s to the PLC" % plcId
        W.logInterface(device, "Tray locked -> recipe write failed",
                       requestPayload="item=%s" % ctx.get("finishedGoodItemId"),
                       ok=False, errorDescription=msg)
        W.notifyAlarm(terminalLocationId, "Tray held - PLC write failed", msg)
        return
    if not _writeOk(W.writeMember(instancePath, "OkToContinue", True)):
        msg = "Could not write OkToContinue to the PLC"
        W.logInterface(device, "Tray locked -> release write failed",
                       requestPayload="item=%s recipe=%s" % (ctx.get("finishedGoodItemId"), plcId),
                       ok=False, errorDescription=msg)
        W.notifyAlarm(terminalLocationId, "Tray held - PLC write failed", msg)
        return
    W.logInterface(device, "Tray locked -> recipe + ok to inspect",
                   requestPayload="item=%s" % ctx.get("finishedGoodItemId"),
                   responsePayload="PartNumber=%s OkToContinue=True" % plcId, ok=True)


def _slcOnInspectionComplete(instancePath, terminalLocationId):
    """Read the PLC's tray verdict; book the tray only on a clean PASS."""
    W = BlueRidge.Workorder.PlcWatcher
    device = _device(instancePath)
    values = W.readMembers(instancePath, _DISPOSITIONS)
    bits = [values.get(m) for m in _DISPOSITIONS]
    shown = "".join("-" if b is None else ("1" if b else "0") for b in bits)
    readable = [b for b in bits if b is not None]

    if readable and all(readable) and len(readable) == len(bits):
        _closeTray(instancePath, terminalLocationId, "dispositions=%s" % shown)
        return

    if readable and not any(readable) and len(readable) == len(bits):
        # The PLC has already sent the tray to the reject side. Nothing to book.
        W.logInterface(device, "Inspection complete -> tray FAILED (not booked)",
                       requestPayload="terminal=%s" % terminalLocationId,
                       responsePayload="dispositions=%s" % shown, ok=True)
        W.notifyAlarm(terminalLocationId, "Tray failed vision",
                      "The camera rejected this tray. It was not counted.",
                      level="warning")
        return

    # Mixed, or members unreadable -- not the whole-tray verdict this protocol
    # expects. Refuse to guess in either direction.
    msg = ("Unexpected tray verdict %s (expected all 1 = pass or all 0 = fail; "
           "'-' = unreadable). Tray not booked." % shown)
    W.logInterface(device, "Inspection complete -> verdict unreadable",
                   requestPayload="terminal=%s" % terminalLocationId,
                   responsePayload="dispositions=%s" % shown,
                   ok=False, errorDescription=msg)
    BlueRidge.Common.Util.log("tray %s: %s" % (instancePath, msg), level="warn")
    W.notifyAlarm(terminalLocationId, "Tray verdict unreadable", msg)
