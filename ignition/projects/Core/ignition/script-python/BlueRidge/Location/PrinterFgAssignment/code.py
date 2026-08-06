"""BlueRidge.Location.PrinterFgAssignment - FG<->printer bindings for a
   multi-printer assembly-out station (printer-cards). Thin wrappers; no
   business logic (validation/reconcile is in the SaveAll proc).

   Change Log:
       2026-08-06 - Initial version (printer-cards feature)."""


def listForStation(stationTerminalLocationId):
    """One row per child Printer of the station terminal, LEFT-joined to its FG
       assignment (unassigned printers appear). Always a list."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(stationTerminalLocationId)
    BlueRidge.Common.Util.log("listForStation stationTerminalLocationId=%s" % tid)
    if tid is None:
        return []
    return BlueRidge.Common.Db.execList(
        "location/PrinterFgAssignment_ListForStation", {"stationTerminalLocationId": tid})


def childPrinterCount(stationTerminalLocationId):
    """Number of child printers at the station (>1 activates the card panel)."""
    return len(listForStation(stationTerminalLocationId) or [])


def listCardsForStation(stationTerminalLocationId, cellLocationId):
    """Card rows for the panel: listForStation enriched with each assigned FG's
       OPEN-container fill at the cell (Container.getOpenByCell, matched on ItemId).
       Each row gets OpenContainerId / FillAccum / FillTarget / IsFull (0 when the
       printer is unassigned or its FG has no open container). Always a list, so a
       runScript-bound panel prop is never overwritten with null."""
    tid  = BlueRidge.Common.Util.extractQualifiedValues(stationTerminalLocationId)
    cell = BlueRidge.Common.Util.extractQualifiedValues(cellLocationId)
    cards = listForStation(tid) or []
    openByItem = {}
    for c in (BlueRidge.Lots.Container.getOpenByCell(cell) or []):
        c = c or {}
        openByItem[c.get("ItemId")] = c
    out = []
    for r in cards:
        r = dict(r or {})
        oc = openByItem.get(r.get("AssignedItemId")) or {}
        accum  = oc.get("AccumulatedParts")
        target = oc.get("TargetParts")
        r["OpenContainerId"] = oc.get("Id")
        r["FillAccum"]  = accum if accum is not None else 0
        r["FillTarget"] = target if target is not None else 0
        r["IsFull"]     = 1 if (oc.get("Id") is not None and target is not None
                                and accum is not None and accum >= target) else 0
        out.append(r)
    return out


def saveAll(stationTerminalLocationId, assignments, appUserId=None):
    """Full-replace the station's FG<->printer assignments. `assignments` is a
       list of {PrinterLocationId, ItemId|None, SortOrder}. Returns {Status,
       Message, NewId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    tid = BlueRidge.Common.Util.extractQualifiedValues(stationTerminalLocationId)
    rows = BlueRidge.Common.Util.extractQualifiedValues(assignments) or []
    params = {
        "stationTerminalLocationId": tid,
        "appUserId": appUserId,
        "assignmentsJson": system.util.jsonEncode(rows),
    }
    return BlueRidge.Common.Db.execMutation("location/PrinterFgAssignment_SaveAll", params)
