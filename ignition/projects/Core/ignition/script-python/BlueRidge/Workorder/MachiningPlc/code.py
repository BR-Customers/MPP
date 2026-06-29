"""BlueRidge.Workorder.MachiningPlc - PLC-driven Machining OUT auto-complete (Arc 2 Phase 5, FDS-06-008).

   A per-cell OperationComplete edge watcher driven by the MachiningOpCompleteWatcher
   gateway timer. On a rising OperationComplete edge it resolves the active machined LOT
   at the Cell and calls Workorder.MachiningOut_AutoComplete -- which writes the closing
   checkpoint ProductionEvent and auto-moves the LOT to the coupled downstream Cell when
   CoupledDownstreamCellLocationId is set (else leaves it for an operator Movement Scan).

   Only NON-sublotting lines (RequiresSubLotSplit=0) are watched here; sublotting lines
   drive Machining OUT through the operator MachiningOut_RecordSplit screen instead.

   Real PLC tag wiring (TOPServer) is a commissioning activity. Until then _WATCH is empty
   and the watcher is a safe no-op. To SIMULATE / commission: create BIT tags (e.g.
   [default]Sim/Machining/<cell>/OperationComplete) and add one _WATCH entry per
   non-sublotting Machining Cell. PLC-driven completions are attributed to the system
   user (AppUser 1) since there is no operator.
"""
import BlueRidge.Common.Util
import BlueRidge.Lots.Lot
import BlueRidge.Workorder.Machining
import system.tag

# Commissioning config -- one entry per watched non-sublotting Machining Cell:
#   {"cellLocationId": <BIGINT Location.Location.Id>, "completeTag": "[default].../OperationComplete"}
_WATCH = []

# System user that PLC-driven completions are attributed to (no operator present).
_SYSTEM_APP_USER_ID = 1

# Edge state across ticks. Module-level dict persists for the gateway timer's life.
_lastComplete = {}


def tickWatcher():
    """Poll each configured cell's OperationComplete tag; auto-complete on a rising edge."""
    if not _WATCH:
        return
    quals = system.tag.readBlocking([w["completeTag"] for w in _WATCH])
    for i, w in enumerate(_WATCH):
        cellId = w["cellLocationId"]
        qv = quals[i]
        if qv is None or not qv.quality.isGood():
            continue
        complete = bool(qv.value)
        prev = _lastComplete.get(cellId, False)
        if complete and not prev:
            # rising edge: resolve the active machined LOT at this Cell + auto-complete
            queue = BlueRidge.Lots.Lot.getWipQueueByLocation(cellId) or []
            if queue:
                lotId = queue[0].get("Id")
                if lotId is not None:
                    BlueRidge.Workorder.Machining.autoComplete(
                        lotId, cellId, appUserId=_SYSTEM_APP_USER_ID)
        _lastComplete[cellId] = complete
