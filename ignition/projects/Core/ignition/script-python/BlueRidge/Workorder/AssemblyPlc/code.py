"""BlueRidge.Workorder.AssemblyPlc - PLC/MIP-driven assembly ingestion (Arc 2 Phase 6).

   Drives the serialized-line MIP handshake (AssemblyMipHandler) and the non-serialized
   OPC count (NonSerializedLineHandler), polled by the MPP AssemblyMipWatcher gateway
   timer. Per-piece serialized flow on a PLC DataReady rising edge:
     1. read PartSN (or mint via SerializedPart.mint when the MES mints the serial),
     2. validate uniqueness + write PartValid back,
     3. ContainerSerial.serialAdd (HardwareInterlockBypassed=1 if the interlock is off),
     4. ConsumptionEvent.recordWithBomCheck per BOM component consumed,
     5. on tray-full -> Container.trayClose; on container-full -> Container.complete
        (claims an AIM ID from the pool).
   Non-serialized lines use OPC PartDisposition + operator/scale counts -> trayClose.

   SIM-READY: _WATCH is empty so the watcher is a safe no-op until commissioning. Real
   TOPServer/MIP/OmniServer tag wiring + the per-line tag map are a commissioning activity
   (consolidated handoff). PLC-driven actions are attributed to the system AppUser (1).
"""
import BlueRidge.Common.Util
import BlueRidge.Lots.Container
import BlueRidge.Lots.SerializedPart
import BlueRidge.Workorder.Consumption
import system.tag

# Commissioning config -- one entry per watched assembly line, e.g.:
#   {"cellLocationId": <BIGINT>, "serialized": True,
#    "dataReadyTag": "[default]MIP/<cell>/DataReady",
#    "partSnTag": "[default]MIP/<cell>/PartSN",
#    "partValidTag": "[default]MIP/<cell>/PartValid",
#    "interlockTag": "[default]MIP/<cell>/HardwareInterlockEnable"}
_WATCH = []

_SYSTEM_APP_USER_ID = 1

# Edge state across ticks (per cell). Module-level dicts persist for the timer's life.
_lastDataReady = {}


def tickWatcher():
    """Poll each watched line's MIP/OPC edges and drive the per-piece flow.
       No-op until _WATCH is configured at commissioning. Fully guarded -- a gateway
       timer must never throw uncaught."""
    if not _WATCH:
        return
    try:
        readyTags = [w["dataReadyTag"] for w in _WATCH if w.get("dataReadyTag")]
        quals = system.tag.readBlocking(readyTags) if readyTags else []
        qi = 0
        for w in _WATCH:
            if not w.get("dataReadyTag"):
                continue
            cellId = w["cellLocationId"]
            qv = quals[qi] if qi < len(quals) else None
            qi += 1
            if qv is None or not qv.quality.isGood():
                continue
            ready = bool(qv.value)
            prev = _lastDataReady.get(cellId, False)
            if ready and not prev:
                _handlePiece(w)
            _lastDataReady[cellId] = ready
    except Exception as e:
        BlueRidge.Common.Util.log("tickWatcher error: %s" % e, level="error")


def _handlePiece(w):
    """One serialized piece: resolve/mint serial -> add to the open container -> consume
       per BOM. Commissioning supplies the real tag reads + container/BOM resolution; this
       is the orchestration skeleton (only runs when _WATCH is populated)."""
    # Real implementation (commissioning): read PartSN + interlock from the PLC, resolve
    # the open container at the cell (Container.getOpenByCell), mint/validate the serial,
    # ContainerSerial.serialAdd, ConsumptionEvent.recordWithBomCheck, and close tray /
    # complete container on the fill thresholds. Left as a no-op skeleton until the MIP
    # touchpoint tag map is available.
    BlueRidge.Common.Util.log("MIP piece edge at cell %s (commissioning no-op)" % w.get("cellLocationId"), level="debug")
