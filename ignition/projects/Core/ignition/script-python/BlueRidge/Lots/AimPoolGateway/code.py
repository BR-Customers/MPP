"""BlueRidge.Lots.AimPoolGateway - AIM Shipper-ID pool gateway logic (Arc 2 Phase 7; FDS-07-010).

   - topupTick(): per part below TopupThreshold, AIM GetNextNumber over HTTP up to
     TargetBufferDepth. SIM: no AIM endpoint in dev -> no-op; the 028 dev seed pre-fills
     the pool. Real AIM HTTP wiring is commissioning (A6).
   - alarmTick(): read per-part depth vs AimPoolConfig thresholds; fire warning/critical
     session alarms on rising-edge crossings, clear on recovery. FUNCTIONAL (uses the
     existing AimPool.getDepth + AimPoolConfig.get reads).
   - placeOnHold/releaseFromHold/update(): AIM HTTP handlers. SIM: log the InterfaceLog
     attempt + return a not-configured status (no HTTP in dev).

   Driven by the MPP AimPoolTopupTimer / AimPoolAlarmTimer gateway timers + the AimHold/
   AimUpdate message handlers (commissioning). Fully guarded -- a timer must never throw.
"""
import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Lots.AimPool
import BlueRidge.Lots.AimPoolConfig

# rising-edge alarm state per part: {partNumber: "ok"|"warning"|"critical"}
_alarmState = {}


def topupTick():
    # SIM: real AIM GetNextNumber HTTP fetch is a commissioning activity (no endpoint in
    # dev). The 028 seed pre-fills the pool so Container_Complete can claim. No-op here.
    return


def alarmTick():
    """Compare per-part pool depth to AimPoolConfig thresholds; fire a session alarm on a
       rising-edge crossing into warning/critical, clear on recovery to ok."""
    try:
        cfgRows = BlueRidge.Lots.AimPoolConfig.get() or []
        cfg = cfgRows[0] if cfgRows else {}
        warn = cfg.get("AlarmWarningDepth") or 20
        crit = cfg.get("AlarmCriticalDepth") or 10
        for row in (BlueRidge.Lots.AimPool.getDepth() or []):
            part = row.get("PartNumber")
            depth = row.get("Depth") or 0
            level = "critical" if depth <= crit else ("warning" if depth <= warn else "ok")
            prev = _alarmState.get(part, "ok")
            if level != prev and level != "ok":
                msg = "AIM pool %s for %s: %d remaining" % (level, part, depth)
                try:
                    system.perspective.sendMessage(
                        "aim-pool-alarm",
                        payload={"partNumber": part, "level": level, "depth": depth, "message": msg},
                        scope="session")
                except Exception:
                    pass
                BlueRidge.Common.Util.log(msg)
            _alarmState[part] = level
    except Exception as e:
        BlueRidge.Common.Util.log("alarmTick error: %s" % e, level="error")


def _logAim(action, aimShipperId, ok, err=None):
    params = {
        "systemName": "AIM", "direction": "Outbound", "logEventTypeCode": "LabelDispatched",
        "description": "AIM %s %s" % (action, aimShipperId or ""),
        "requestPayload": "%s | %s" % (action, aimShipperId or ""),
        "responsePayload": "OK" if ok else None,
        "errorCondition": None if ok else "AimCallFailed", "errorDescription": err, "isHighFidelity": True}
    try:
        BlueRidge.Common.Db.execList("audit/Audit_LogInterfaceCall", params)
    except Exception as e:
        BlueRidge.Common.Util.log("_logAim failed: %s" % str(e), level="debug")


def placeOnHold(aimShipperId):
    """AIM PlaceOnHold for a shipped container's Shipper ID (FDS-07-008). SIM in dev."""
    _logAim("PlaceOnHold", aimShipperId, False, "AIM endpoint not configured (dev)")
    return {"Status": 0, "Message": "AIM endpoint not configured (dev)."}


def releaseFromHold(aimShipperId):
    _logAim("ReleaseFromHold", aimShipperId, False, "AIM endpoint not configured (dev)")
    return {"Status": 0, "Message": "AIM endpoint not configured (dev)."}


def update(aimShipperId, serialsJson=None):
    """AIM Update (Sort Cage re-pack, new serials per FRS Appendix L). SIM in dev."""
    _logAim("Update", aimShipperId, False, "AIM endpoint not configured (dev)")
    return {"Status": 0, "Message": "AIM endpoint not configured (dev)."}
