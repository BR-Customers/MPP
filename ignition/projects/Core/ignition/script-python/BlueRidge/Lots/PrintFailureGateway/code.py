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
                    "maxAttempts":     1,
                })
        if len(stranded) > _STRAND_ALARM_THRESHOLD:
            msg = "print sweep: %d stranded shipping labels (supervisor/IT)" % len(stranded)
            BlueRidge.Common.Util.log(msg, level="warn")
            _pushToAllSessions({"level": "critical", "strandedCount": len(stranded), "message": msg})
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("sweepTick failed: %s" % str(e), level="debug")


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
                "level":              "error",
            })
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("broadcastTick failed: %s" % str(e), level="debug")
