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
