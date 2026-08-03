"""BlueRidge.Lots.AimPoolGateway - AIM Shipper-ID pool gateway logic (Arc 2 Phase 7; FDS-07-010).

   - topupTick(): refill the GLOBAL AIM shipper-ID pool toward TargetBufferDepth when
     below TopupThreshold, fetching one serial at a time via AimHttp.nextSerial() and
     pooling it via AimPool.topup(). AIM's nextserial.csv is per COMPANY CODE and takes
     no part parameter, so there is no per-part loop (FDS-07-010 adapted to the verified
     contract). Stops at target, on first failure, or at a hard per-tick cap.
   - alarmTick(): TWO INDEPENDENT rising-edge session alarms, each with its own state so
     one recovering never clears the other - pool DEPTH vs AlarmWarningDepth /
     AlarmCriticalDepth (existing), and post BACKLOG AGE (oldest row from
     AimPool.listUnposted(1)) vs PostWarningAgeMinutes / PostCriticalAgeMinutes (new).
     Payload carries kind: "depth" | "backlog" so a consumer can tell them apart.
   - placeOnHold/releaseFromHold/update(): AIM HTTP handlers. SIM: log the InterfaceLog
     attempt + return a not-configured status (no HTTP in dev).

   Driven by the MPP AimPoolTopupTimer / AimPoolAlarmTimer gateway timers + the AimHold/
   AimUpdate message handlers (commissioning). Fully guarded -- a timer must never throw.
"""

# rising-edge alarm state, one var per INDEPENDENT condition: "ok"|"warning"|"critical".
# See alarmTick docstring - depth and backlog-age must never clear each other.
_alarmState = "ok"
_backlogAlarmState = "ok"


def topupTick():
    """Refill the AIM shipper-ID pool toward TargetBufferDepth.

       The pool is GLOBAL: AIM's nextserial.csv issues serials per COMPANY CODE and
       accepts no part parameter, so FDS-07-010's per-part loop does not apply.

       Fetches one ID per AIM call, stopping at the target, on the first failure, or
       at a hard per-tick cap so a misconfigured endpoint cannot spin. Never raises -
       a timer must not throw."""
    from java.lang import Throwable
    _MAX_PER_TICK = 25
    try:
        cfgRows = BlueRidge.Lots.AimPoolConfig.get() or []
        cfg = cfgRows[0] if cfgRows else {}
        target = cfg.get("TargetBufferDepth") or 50
        threshold = cfg.get("TopupThreshold") or 30

        depthRows = BlueRidge.Lots.AimPool.getDepth() or []
        depth = (depthRows[0].get("Depth") if depthRows else 0) or 0
        if depth >= threshold:
            return {"fetched": 0, "depth": depth}

        fetched = 0
        while depth + fetched < target and fetched < _MAX_PER_TICK:
            res = BlueRidge.Lots.AimHttp.nextSerial()
            if not res.get("ok"):
                BlueRidge.Common.Util.log(
                    "topupTick stopping: %s" % res.get("error"), level="warn")
                break
            up = BlueRidge.Lots.AimPool.topup(res.get("serial"))
            if not (up and up.get("Status")):
                BlueRidge.Common.Util.log(
                    "topupTick could not pool %s: %s"
                    % (res.get("serial"), up and up.get("Message")), level="warn")
                break
            fetched += 1
        if fetched:
            BlueRidge.Common.Util.log("topupTick fetched %d (depth was %d)" % (fetched, depth))
        return {"fetched": fetched, "depth": depth + fetched}
    except Throwable, t:
        BlueRidge.Common.Util.log("topupTick failed: %s" % t, level="error")
        return {"fetched": 0, "depth": 0}
    except Exception, e:
        BlueRidge.Common.Util.log("topupTick failed: %s" % e, level="error")
        return {"fetched": 0, "depth": 0}


def _sendAlarm(payload):
    """Best-effort session broadcast; a message-bus hiccup must not break the caller."""
    try:
        system.perspective.sendMessage("aim-pool-alarm", payload=payload, scope="session")
    except:
        pass


def alarmTick():
    """Two INDEPENDENT rising-edge session alarms, each cleared only by its own
       recovery to "ok" - a crossing on one condition must never touch the other's
       state:

       - pool DEPTH vs AlarmWarningDepth / AlarmCriticalDepth (existing).
       - post BACKLOG AGE, using the oldest row's AgeMinutes from
         AimPool.listUnposted(1), vs PostWarningAgeMinutes / PostCriticalAgeMinutes
         (new). listUnposted(1) is used deliberately - the oldest row is always first
         (oldest-first order), so there is no need to pull the whole backlog to find
         a maximum.

       Never raises - a timer must not throw."""
    from java.lang import Throwable
    global _alarmState, _backlogAlarmState
    try:
        cfgRows = BlueRidge.Lots.AimPoolConfig.get() or []
        cfg = cfgRows[0] if cfgRows else {}

        # -- pool depth (existing) --
        warn = cfg.get("AlarmWarningDepth") or 20
        crit = cfg.get("AlarmCriticalDepth") or 10
        depthRows = BlueRidge.Lots.AimPool.getDepth() or []
        depthRow = depthRows[0] if depthRows else {}
        depth = depthRow.get("Depth") or 0
        level = "critical" if depth <= crit else ("warning" if depth <= warn else "ok")
        if level != _alarmState and level != "ok":
            msg = "AIM pool %s: %d remaining" % (level, depth)
            _sendAlarm({"kind": "depth", "level": level, "depth": depth, "message": msg})
            BlueRidge.Common.Util.log(msg)
        _alarmState = level

        # -- post backlog age (new) --
        ageWarn = cfg.get("PostWarningAgeMinutes") or 30
        ageCrit = cfg.get("PostCriticalAgeMinutes") or 120
        unpostedRows = BlueRidge.Lots.AimPool.listUnposted(1) or []
        oldest = unpostedRows[0] if unpostedRows else {}
        ageMinutes = oldest.get("AgeMinutes") or 0
        backlogLevel = ("critical" if ageMinutes >= ageCrit
                         else ("warning" if ageMinutes >= ageWarn else "ok"))
        if backlogLevel != _backlogAlarmState and backlogLevel != "ok":
            msg = "AIM post backlog %s: oldest unposted %d min (shipper id %s)" % (
                backlogLevel, ageMinutes, oldest.get("AimShipperId"))
            _sendAlarm({"kind": "backlog", "level": backlogLevel,
                        "ageMinutes": ageMinutes, "message": msg})
            BlueRidge.Common.Util.log(msg)
        _backlogAlarmState = backlogLevel
    except Throwable, t:
        BlueRidge.Common.Util.log("alarmTick error: %s" % t, level="error")
    except Exception, e:
        BlueRidge.Common.Util.log("alarmTick error: %s" % e, level="error")


def _logAim(action, aimShipperId, ok, err=None):
    params = {
        "systemName": "AIM", "direction": "Outbound", "logEventTypeCode": "LabelDispatched",
        "description": "AIM %s %s" % (action, aimShipperId or ""),
        "requestPayload": "%s | %s" % (action, aimShipperId or ""),
        "responsePayload": "OK" if ok else None,
        "errorCondition": None if ok else "AimCallFailed", "errorDescription": err, "isHighFidelity": True}
    try:
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall", params)
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
