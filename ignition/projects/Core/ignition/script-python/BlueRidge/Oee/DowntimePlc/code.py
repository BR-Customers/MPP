"""BlueRidge.Oee.DowntimePlc - PLC-driven downtime ingestion (Arc 2 Phase 8, D2).

   A per-machine stop/run edge watcher driven by the DowntimePlcWatcher gateway
   timer. On a STOP edge it opens a PLC-source DowntimeEvent with no reason (the
   operator classifies it later via Downtime Entry -- B7 late-binding); on a RUN
   edge it closes the open PLC event.

   Real PLC tag wiring (TOPServer) is a commissioning activity. Until then _WATCH
   is empty and the watcher is a safe no-op. To SIMULATE / commission: create BIT
   tags (e.g. [default]Sim/Downtime/<cell>/Stopped) and add one _WATCH entry per
   machine. PLC-recorded events are attributed to the system user (AppUser 1)
   since there is no operator; DowntimeEvent_End requires a user.
"""
import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Oee.DowntimeEvent
import system.tag

# Commissioning config -- one entry per watched machine:
#   {"cellLocationId": <BIGINT Location.Location.Id>, "stopTag": "[default].../Stopped"}
_WATCH = []

# System user that PLC-driven events are attributed to (no operator present).
_SYSTEM_APP_USER_ID = 1

# Edge state across ticks. Module-level dict persists for the gateway timer's life.
_lastStopped = {}

# Lazily-resolved 'PLC' DowntimeSourceCode id (cached).
_plcSourceId = None


def _plcId():
    global _plcSourceId
    if _plcSourceId is None:
        for r in (BlueRidge.Common.Db.execList("oee/DowntimeSourceCode_List") or []):
            if r.get("Code") == "PLC":
                _plcSourceId = r.get("Id")
                break
    return _plcSourceId


def tickWatcher():
    """Poll each configured machine's stop tag; open/close PLC downtime on edges."""
    if not _WATCH:
        return
    plc = _plcId()
    if plc is None:
        BlueRidge.Common.Util.log("PLC DowntimeSourceCode not found; skipping watcher tick")
        return

    quals = system.tag.readBlocking([w["stopTag"] for w in _WATCH])
    for i, w in enumerate(_WATCH):
        cellId = w["cellLocationId"]
        qv = quals[i]
        if qv is None or not qv.quality.isGood():
            continue
        stopped = bool(qv.value)
        prev = _lastStopped.get(cellId, False)
        if stopped and not prev:
            BlueRidge.Oee.DowntimeEvent.start(cellId, downtimeSourceCodeId=plc, appUserId=_SYSTEM_APP_USER_ID)
        elif (not stopped) and prev:
            for ev in (BlueRidge.Oee.DowntimeEvent.getOpenByLocation(cellId) or []):
                if ev.get("SourceCode") == "PLC":
                    BlueRidge.Oee.DowntimeEvent.end(ev.get("DowntimeEventId"), appUserId=_SYSTEM_APP_USER_ID)
                    break
        _lastStopped[cellId] = stopped
