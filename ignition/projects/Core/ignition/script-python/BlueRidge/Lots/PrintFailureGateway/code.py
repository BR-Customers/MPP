"""BlueRidge.Lots.PrintFailureGateway - shipping-label print-failure lifecycle (Arc 2 Phase 7; FDS-07-006b; Brief D).

   - sweepTick() (every ~5 min): find stranded ShippingLabel rows (ZplContent persisted but
     PrintedAt NULL AND PrintFailedAt NULL AND older than ~60s -- a Gateway restart between
     the Container_Complete commit and the async dispatch), re-fire ShippingDispatcher for
     each. If dispatch cannot even start (no endpoint / no ZPL), mark the row failed so it
     surfaces on the banner instead of re-sweeping forever; a successful async dispatch marks
     the row itself. Supervisor/IT alarm when more than a threshold are stranded at once.
   - broadcastTick() (every ~5 s): find failed prints (PrintFailedAt NOT NULL AND
     BannerAcknowledgedAt NULL) and broadcast 'print-failure-alert' to sessions; the
     PrintFailureBanner component filters by its terminal.

   Both ticks are fully guarded -- a gateway timer must NEVER throw.
   SIM/HARDWARE-GATED: no networked Zebra in dev, so dispatch fails fast; the lifecycle
   (mark failed, sweep, banner) is exercised regardless.
"""

import java.lang

_STRAND_ALARM_THRESHOLD = 5

# A terminal session runs for weeks and this list is rewritten on a 5-second
# timer, so it is capped rather than grown. Fifty failed labels at one terminal
# is already far past the point where somebody has been called.
_SEEN_CAP = 50


def _pushToAllSessions(payload):
    """Deliver a 'print-failure-alert' to every open session/page.

       system.perspective.sendMessage from GATEWAY scope has NO broadcast form -- a bare
       scope='session'/'page' call with no sessionId/pageId delivers to nothing (project
       rule: feedback_ignition_gateway_sendmessage_needs_session_page). So enumerate every
       session + page and target each explicitly; the PrintFailureBanner's session-scoped
       handler filters by terminalLocationId.

       Routes through PlcWatcher.broadcastPageMessage -- the shared, hardened enumeration
       (skips non-UUID-shaped session/page entries rather than eating an exception per bad
       one; see its docstring, 2026-08-20)."""
    BlueRidge.Workorder.PlcWatcher.broadcastPageMessage("print-failure-alert", payload)


def sweepTick():
    """Re-dispatch stranded shipping labels; flip un-startable ones to failed; alarm on a pile-up."""
    try:
        stranded = BlueRidge.Common.Db.execList("lots/ShippingLabel_GetStranded") or []
        for row in stranded:
            sid = row.get("Id")
            disp = BlueRidge.Lots.ShippingDispatcher.dispatch(
                shippingLabelId=sid,
                terminalLocationId=row.get("TerminalLocationId"))
            # dispatch() returns Status 1 once the async worker is launched (it will mark the
            # row). Status 0 means it could not start (no endpoint / no ZPL) -- flip to failed
            # so the operator sees it on the banner rather than an endless re-sweep.
            if not (disp and disp.get("Status")):
                BlueRidge.Common.Db.execMutation("lots/ShippingLabel_MarkDispatch", {
                    "shippingLabelId": sid,
                    "success":         0,
                    "errorText":       (disp or {}).get("Message") or "Stranded: dispatch could not start.",
                    # Forwarded, not guessed: only the no-printer-on-this-station
                    # case has a taxonomy name, and dispatch() is what knows.
                    "errorCondition":  (disp or {}).get("ErrorCondition"),
                    "maxAttempts":     1,
                })
        if len(stranded) > _STRAND_ALARM_THRESHOLD:
            msg = "print sweep: %d stranded shipping labels (supervisor/IT)" % len(stranded)
            BlueRidge.Common.Util.log(msg, level="warn")
            _pushToAllSessions({"level": "critical", "strandedCount": len(stranded), "message": msg})
    except (Exception, java.lang.Exception) as e:
        # warn, not debug. Both ticks swallowed their own failures at debug,
        # which meant a timer that was doing nothing at all looked identical to
        # a timer with nothing to do. That is what made the 2026-10-01
        # broadcastPageMessage defect take an afternoon to see.
        BlueRidge.Common.Util.log("sweepTick failed: %s" % str(e), level="warn")


def broadcastTick():
    """Push a 'print-failure-alert' per failed-unacknowledged label; the terminal banner filters."""
    try:
        failed = BlueRidge.Common.Db.execList("lots/ShippingLabel_GetForBanner") or []
        for row in failed:
            _pushToAllSessions({
                "shippingLabelId":    row.get("Id"),
                "containerId":        row.get("ContainerId"),
                "terminalLocationId": row.get("TerminalLocationId"),
                "aimShipperId":       row.get("AimShipperId"),
                "error":              row.get("LastPrintError"),
                # The taxonomy name the dispatch worker persisted. It is what
                # lets the terminal turn a raw socket error into an instruction
                # (LabelTransport.operatorGuidance keys on it); without it every
                # async failure read as the generic "tell a supervisor".
                "errorCondition":     row.get("LastPrintErrorCondition"),
                "level":              "error",
            })
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("broadcastTick failed: %s" % str(e), level="warn")


# ---------------------------------------------------------------------------
# Terminal side -- what the PrintFailureBanner does with one broadcast.
# ---------------------------------------------------------------------------

def decideAlert(terminal, payload, seen, guidance):
    """Decide what ONE 'print-failure-alert' means at ONE terminal. Pure.
       Self-contained (no BlueRidge.*, no system.*, no java) so the tests can
       exec it -- and pure because broadcastTick re-fires every 5 seconds for
       every failed-unacknowledged label, which makes "have we already told this
       terminal about this label" the decision the whole path hinges on.

       guidance is passed IN, already resolved by
       LabelTransport.operatorGuidance, so the failure taxonomy stays owned by
       the one module that owns it and this function stays testable.

       Returns {relevant, alert, notice, seen, detail}:
         relevant -- False when the payload belongs to a different terminal.
                     Nothing else in the result may be acted on.
         alert    -- the banner state: {visible, text, shippingLabelId}.
         notice   -- the guidance to show as a MODAL, or None. Non-None only the
                     FIRST time this terminal sees a given label: the modal is a
                     one-time interruption, the banner is the standing reminder.
                     A five-second modal loop in front of someone holding a
                     basket would be worse than the silence it replaced.
         seen     -- the label ids this terminal has been shown a modal for,
                     capped, to write back over the view property.
         detail   -- the technical line for the modal's small print. It exists
                     to be read down a phone to a supervisor, so it names the
                     label and the raw fault rather than restating the
                     operator's sentence."""
    p = payload or {}
    term = terminal or {}

    # Filter exactly as the pre-existing handler did: a payload that names a
    # terminal belongs to that terminal only. One that names NONE (sweepTick's
    # stranded pile-up alarm) is for whoever is looking, and a session with no
    # terminal context -- an unregistered IP falls back facility-wide -- sees
    # everything. Showing it is the safe side here: a failure nobody is told
    # about is the exact bug this path exists to fix.
    target = p.get("terminalLocationId")
    mine = term.get("terminalLocationId")
    if target is not None and mine is not None and "%s" % mine != "%s" % target:
        return {"relevant": False, "alert": None, "notice": None,
                "seen": list(seen or []), "detail": ""}

    sid = p.get("shippingLabelId")
    aim = p.get("aimShipperId")
    err = ("%s" % (p.get("error") or "")).strip()

    # An explicit message wins: sweepTick composes its own sentence for the
    # pile-up alarm, which is not about any single label.
    text = ("%s" % (p.get("message") or "")).strip()
    if not text:
        text = (guidance or {}).get("title") or "A shipping label failed to print."
        if aim:
            text = "%s -- shipping label %s" % (text, aim)

    detail = "Shipping label %s" % (sid if sid is not None else "(unknown)")
    if aim:
        detail = "%s / %s" % (detail, aim)
    detail = "%s - %s" % (detail, err or "no error recorded")

    # Compare as strings: JDBC hands the id back as a Long and the view property
    # round-trips it as something else. A type mismatch here would silently
    # re-open the modal on every single tick, forever.
    shown = ["%s" % s for s in (seen or [])]
    isNew = sid is not None and "%s" % sid not in shown
    newSeen = list(seen or [])
    if isNew:
        newSeen = (newSeen + [sid])[-_SEEN_CAP:]

    return {"relevant": True,
            "alert": {"visible": True, "text": text, "shippingLabelId": sid},
            "notice": guidance if isNew else None,
            "seen": newSeen,
            "detail": detail}


def handleAlert(session, payload, seen):
    """PrintFailureBanner's message handler, in one call. Returns the banner's
       new state ({alert, seen}) or None when the alert is not for this
       terminal, and opens the modal itself on a label this terminal has not
       been shown yet.

       operatorGuidance is resolved here and ALSO inside printFailureNotice.
       That is deliberate: it is a pure dict builder, and keeping
       Ui.printFailureNotice as the single thing that knows the popup's id and
       path is worth one free call. Never throws -- a message handler that
       raises on a gateway thread is invisible to the operator."""
    try:
        p = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
        cond = p.get("errorCondition")
        err = p.get("error")
        # seen arrives as the LIVE view.custom.seen property, which reads back as
        # a PropertyTreeScriptWrapper$ArrayWrapper -- NOT a list, and
        # extractQualifiedValues does not detach it (isinstance(.., list) is
        # False, so it falls through untouched). Iterating it is what detaches
        # it, so do that here at the boundary rather than leaving decideAlert
        # holding a live handle into the property document.
        try:
            shown = list(seen) if seen is not None else []
        except (Exception, java.lang.Exception):
            shown = []
        d = decideAlert(
            BlueRidge.Common.Util.extractQualifiedValues(session.custom.terminal),
            p,
            shown,
            BlueRidge.Lots.LabelTransport.operatorGuidance(cond, err))
        if not d["relevant"]:
            return None
        if d["notice"] is not None:
            BlueRidge.Common.Ui.printFailureNotice(cond, err, d["detail"])
        return {"alert": d["alert"], "seen": d["seen"]}
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("handleAlert failed: %s" % str(e), level="warn")
        return None
