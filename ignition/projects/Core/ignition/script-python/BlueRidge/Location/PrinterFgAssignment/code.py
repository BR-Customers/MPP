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
