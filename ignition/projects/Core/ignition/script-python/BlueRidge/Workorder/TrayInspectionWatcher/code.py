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

   SlcTray  (MicroLogix tray cells running the MPPMACH ladder)
     Mirrors the MPPMACH ladder's host interface ("LAD 4 - HOST"; address map +
     rung references in notes/2026-09-10_6ma-ch-camera-plc-host-interface.md).
     MPPMACH is PLC 172.17.20.30 / vision 172.17.20.32 -- NOT 6MA_CH, which
     this protocol was first written for on a structural guess and which runs
     a different ladder (see SlcPassPulse). Not yet verified on a live PLC.
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

   SlcPassPulse  (any PLC whose only per-tray signal to the host is a pass pulse)
     The PLC runs the cell on its own -- the camera fires without the MES, the
     tray/cart is released (or not) entirely on the PLC's own logic, and the
     only thing the host ever hears is "this one passed." Nothing the MES does
     can hold one back. Shared by every real ladder decoded so far under this
     name; they agree on the shape but differ on addresses and on whether
     VisionPartNumber exists at all:
       6MA_CH       (processor "6MA", 172.17.21.213) -- ladder decoded in
                    notes/2026-09-11_6ma-ch-real-ladder-slcpasspulse.md.
                    TrayLocked=I:0.0/0, InspectionComplete=N7:10 ("PASSED TO
                    HOST COMPUTER"), VisionPartNumber=N16:2, PartNumber=N7:2.
       6C2_6MA_OilPan / 5J6_OilPan / 5K8_64A_OilPan
                    (the oil-pan cart-scanner family; ladders decoded in
                    notes/2026-09-15_6ma-oilpan-plc-address-validation.md).
                    TrayLocked=cart-present input, InspectionComplete=N7:10
                    ("CART GOOD"/"CART DONE AND GOOD TO FLEXWARE", gated on
                    the vision controller's own good/bad discrete pair --
                    confirmed by decoded symbol comments, not inferred),
                    PartNumber=N7:2. VisionPartNumber=N16:2 on the two
                    cart-scanners that share their camera across multiple
                    lines (6C2_6MA_OilPan, 5J6_OilPan); 5K8_64A_OilPan's
                    ladder carries no N16 word anywhere -- confirmed by a
                    direct search of the decoded program stream, not just an
                    unmapped tag -- so it has no vision-program register to
                    compare against at all. Its instance sets
                    VisionMatchOptional=1 for exactly that reason (see below).
     TrayLocked rising edge -> write the finished good's Item.PlcId to
       PartNumber if it differs. Logged, never alarmed (the booking below is
       where the operator hears about a problem).
     InspectionComplete rising edge -> a tray/cart just passed.
       VisionPartNumber reads a value -> book only when it equals the
         finished good's PlcId. Anything else is a master tray / rabbit test,
         an HMI part override, or a changeover the recipe has not reached
         yet. Warn and do not book. Then sync the recipe.
       VisionPartNumber reads None (bad quality / unmapped) ->
         VisionMatchOptional=1 -> nothing to compare against on this PLC by
           design. Book on the pass alone.
         VisionMatchOptional=0 (default) -> we cannot tell whether this is a
           master tray or a changeover. Warn and do not book -- unreadable is
           not the same as "no register exists," and must fail closed.
     No other writes on 6MA_CH: N7:1 (OkToContinue) and N7:30 have no effect
     or cannot be observed on that ladder.

   Observe-only (any protocol): set the instance's DisableWriteback memory
   member and the watcher still reads and books but writes NOTHING to the PLC
   -- no recipe, no go-ahead, no trigger acks. Each skipped write is logged to
   InterfaceLog as "<member> write suppressed". For running beside the legacy
   host, which then keeps owning the handshake. On SkuVerify/SlcTray cells
   that means the MES relies on that host to release trays and ack triggers.

   No vision-program register (SlcPassPulse only): set the instance's
   VisionMatchOptional memory member and a booking whose VisionPartNumber
   reads None is trusted on the pass alone instead of refused. A missing
   member reads as bad quality -> None -> False, so every instance that
   already has a real VisionPartNumber wired keeps requiring the match --
   this only changes behaviour where explicitly set True, and should be set
   True only after confirming (by decoding the real ladder, not by the tag
   simply being unmapped in Ignition) that the PLC has no such register at all.

   The comparisons here are protocol decoding of PLC words, not business rules.
   The finished good, pack-out and tray close all resolve through
   Assembly.resolvePlcCloseContext / plcCompleteTray -- the same path the
   operator ByCount button uses.
"""

import java.lang

PROTOCOL_SKU_VERIFY = "SkuVerify"
PROTOCOL_SLC_TRAY = "SlcTray"
PROTOCOL_SLC_PASS_PULSE = "SlcPassPulse"

_DISPOSITIONS = ["PartDisposition%02d" % i for i in range(1, 19)]


def handleEdge(instancePath, terminalLocationId, member):
    if member not in ("TrayLocked", "InspectionComplete"):
        return
    protocol = _protocol(instancePath)
    if protocol == PROTOCOL_SLC_PASS_PULSE:
        if member == "TrayLocked":
            _pulseOnTrayPresent(instancePath, terminalLocationId)
        else:
            _pulseOnTrayPassed(instancePath, terminalLocationId)
    elif protocol == PROTOCOL_SLC_TRAY:
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
        msg = "Unknown tray Protocol '%s' (expected %s, %s or %s)" % (
            protocol, PROTOCOL_SKU_VERIFY, PROTOCOL_SLC_TRAY, PROTOCOL_SLC_PASS_PULSE)
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


def _writebackDisabled(instancePath):
    """The instance's DisableWriteback memory member. A missing member reads as
       bad quality -> None -> False, so instances without it write as before."""
    return bool(BlueRidge.Workorder.PlcWatcher.readMember(instancePath, "DisableWriteback"))


def _visionMatchOptional(instancePath):
    """The instance's VisionMatchOptional memory member. A missing member reads
       as bad quality -> None -> False, so every existing SlcPassPulse instance
       keeps requiring a VisionPartNumber match before booking -- unchanged.
       Set True only on a station whose PLC has no vision-program register at
       all (confirmed by decoding the real ladder, e.g. 5K8_64A_OilPan/
       64A_OILP.RSS carries no N16 word anywhere) -- there is nothing to
       compare against, so the pass alone is trusted. Leave False on any
       station that DOES have VisionPartNumber wired: a transient bad-quality
       read there still means "we can't tell if this is a master tray or a
       changeover," and must still refuse the booking, not silently accept it."""
    return bool(BlueRidge.Workorder.PlcWatcher.readMember(instancePath, "VisionMatchOptional"))


def _plcWrite(instancePath, member, value, detail=None):
    """Every MES -> PLC write in this module goes through here.

       Returns True (written, Good quality), False (the write failed) or None
       (suppressed: DisableWriteback is set). Observe-only is for running
       beside the legacy host, which keeps owning the handshake -- two hosts
       writing N7:2 at a changeover would flip the vision program back and
       forth. A suppressed write is logged with what the MES WOULD have
       written, so a parallel run shows every point where the two disagree."""
    W = BlueRidge.Workorder.PlcWatcher
    if _writebackDisabled(instancePath):
        W.logInterface(_device(instancePath),
                       "%s write suppressed (DisableWriteback)" % member,
                       requestPayload=detail or "%s=%s" % (member, value), ok=True)
        return None
    return _writeOk(W.writeMember(instancePath, member, value))


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
    _plcWrite(instancePath, "TrayLocked", False)
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
    _plcWrite(instancePath, "PartNumber", plcId)
    W.logInterface(device, "Tray locked -> recipe select",
                   requestPayload="item=%s" % ctx.get("finishedGoodItemId"),
                   responsePayload="PartNumber=%s" % plcId, ok=True)


def _onInspectionComplete(instancePath, terminalLocationId):
    W = BlueRidge.Workorder.PlcWatcher
    device = _device(instancePath)
    # Ack the trigger immediately (see _onTrayLocked) -- same one-shot latch bug.
    _plcWrite(instancePath, "InspectionComplete", False)
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
    _plcWrite(instancePath, "OkToContinue", True)
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
    if _plcWrite(instancePath, "PartNumber", plcId) is False:
        msg = "Could not write recipe %s to the PLC" % plcId
        W.logInterface(device, "Tray locked -> recipe write failed",
                       requestPayload="item=%s" % ctx.get("finishedGoodItemId"),
                       ok=False, errorDescription=msg)
        W.notifyAlarm(terminalLocationId, "Tray held - PLC write failed", msg)
        return
    if _plcWrite(instancePath, "OkToContinue", True) is False:
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


# ---- SlcPassPulse -----------------------------------------------------------------
def _sameNumber(a, b):
    """Two PLC words / ids compared as integers. None or junk never matches."""
    try:
        return a is not None and b is not None and int(a) == int(b)
    except (ValueError, TypeError):
        return False


def _pulseSyncRecipe(instancePath, terminalLocationId, trigger, plcId=None, itemId=None):
    """Point the PLC's recipe word (N7:2) at the finished good's PlcId. Writes
       only when it differs, so a steady line costs one read per tray and no
       write. The PLC itself pushes a changed N7:2 to the vision controller.
       Logged, never alarmed: the cell keeps running regardless, and a recipe
       the vision system never got shows up as a refused booking, which does
       alarm."""
    W = BlueRidge.Workorder.PlcWatcher
    device = _device(instancePath)
    if plcId is None:
        ctx, plcId, err = _expectedRecipe(terminalLocationId)
        if err:
            W.logInterface(device, "%s -> recipe not synced" % trigger,
                           requestPayload="terminal=%s" % terminalLocationId,
                           ok=False, errorDescription=err)
            return
        itemId = ctx.get("finishedGoodItemId")
    current = W.readMember(instancePath, "PartNumber")
    if _sameNumber(current, plcId):
        return
    ok = _plcWrite(instancePath, "PartNumber", plcId,
                   detail="item=%s PartNumber %s -> %s" % (itemId, current, plcId))
    if ok is None:
        return
    W.logInterface(device, "%s -> recipe %s" % (trigger, "written" if ok else "write FAILED"),
                   requestPayload="item=%s" % itemId,
                   responsePayload="PartNumber %s -> %s" % (current, plcId), ok=ok,
                   errorDescription=None if ok else "Could not write recipe %s to the PLC" % plcId)


def _pulseOnTrayPresent(instancePath, terminalLocationId):
    """Tray arrived (I:0.0/0). Get the recipe right before the camera fires.
       Replay-safe (PlcWatcher._REPLAY_SAFE): it only ever converges N7:2."""
    _pulseSyncRecipe(instancePath, terminalLocationId, "Tray present")


def _pulseOnTrayPassed(instancePath, terminalLocationId):
    """N7:10 rose: the PLC has sent a good tray down the good side. Book it,
       unless the vision controller was not running this finished good's
       program -- then it was a master tray / rabbit test or an override, and
       booking it would mint parts that were never built. Not replay-safe: an
       N7:10 already high at gateway start is dropped by dispatch rather than
       booked twice."""
    W = BlueRidge.Workorder.PlcWatcher
    device = _device(instancePath)
    ctx, expected, err = _expectedRecipe(terminalLocationId)
    if err:
        W.logInterface(device, "Tray passed -> NOT booked (no finished good)",
                       requestPayload="terminal=%s" % terminalLocationId,
                       ok=False, errorDescription=err)
        W.notifyAlarm(terminalLocationId, "Tray passed but not booked", err)
        return
    itemId = ctx.get("finishedGoodItemId")
    loaded = W.readMember(instancePath, "VisionPartNumber")

    if loaded is None:
        if _visionMatchOptional(instancePath):
            # This station's PLC has no vision-program register to compare
            # against (VisionMatchOptional=1) -- the pass alone is the whole
            # signal. Book it.
            W.logInterface(device, "Tray passed -> booked (no vision program to check)",
                           requestPayload="item=%s" % itemId, ok=True)
            _closeTray(instancePath, terminalLocationId, expected)
            return
        msg = ("Tray passed but not booked: the vision program (VisionPartNumber, "
               "N16:2) could not be read.")
        W.logInterface(device, "Tray passed -> NOT booked (vision program unreadable)",
                       requestPayload="item=%s expected=%s" % (itemId, expected),
                       ok=False, errorDescription=msg)
        W.notifyAlarm(terminalLocationId, "Tray not booked", msg)
        return

    if not _sameNumber(loaded, expected):
        msg = ("The camera passed this tray on vision program %s, but this finished "
               "good needs program %s. Not booked (master tray, HMI part override, "
               "or a changeover still loading)." % (loaded, expected))
        W.logInterface(device, "Tray passed -> NOT booked (vision program mismatch)",
                       requestPayload="item=%s expected=%s loaded=%s" % (itemId, expected, loaded),
                       ok=False, errorDescription=msg)
        W.notifyAlarm(terminalLocationId, "Tray not booked", msg, level="warning")
        _pulseSyncRecipe(instancePath, terminalLocationId, "Program mismatch",
                         plcId=expected, itemId=itemId)
        return

    _closeTray(instancePath, terminalLocationId, expected)
