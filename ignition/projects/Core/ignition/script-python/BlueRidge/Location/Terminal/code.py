"""BlueRidge.Location.Terminal - thin read access to terminal resolution procs.

   Wrappers only; no business logic. Calls route View -> here ->
   BlueRidge.Common.Db -> system.db.*.

   Read surface:
       getByIpAddress(ipAddress)                      -> dict | None
       listAll()                                      -> list[dict]
       findById(terminals, terminalId)                -> dict | None
       findByCode(terminals, code)                    -> dict | None
       listContextCells(terminalLocationId)           -> list[dict]
       getContextCellsForDropdown(terminalLocationId) -> list[{label, value, code, name}]

   Change Log:
       2026-06-11 - Add listContextCells + getContextCellsForDropdown
                    (location/Terminal_ListContextCells NQ access layer)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getByIpAddress(ipAddress):
    """Resolve the terminal (and its zone / default screen) for the
       caller's IP. Returns a dict or None when no terminal matches."""
    BlueRidge.Common.Util.log("ipAddress=%s" % ipAddress)
    return BlueRidge.Common.Db.execOne(
        "location/Terminal_GetByIpAddress",
        {"ipAddress": ipAddress},
    )


def listAll():
    """List every configured terminal. Returns list[dict].

       Always returns a list (Common.Db.execList never returns None) so the
       runScript-bound view.custom.terminals default ([]) on the Terminal
       Selector is never overwritten with null."""
    BlueRidge.Common.Util.log("listing terminals")
    return BlueRidge.Common.Db.execList("location/Terminal_List")


def findById(terminals, terminalId):
    """Find a terminal row in an already-loaded list by TerminalId.

       The Terminal Selector table's selection payload carries only the
       fields defined as table columns (TerminalId/Code/Name/ZoneName) -
       DefaultScreen, ZoneId and IsFallback are stripped. This re-resolves
       the FULL Terminal_List row from view.custom.terminals without a DB
       round-trip, same as findByCode does for the scan path.

       Returns the matching dict, or None if no terminal matches."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(terminals) or []
    if terminalId is None:
        return None
    for r in rows:
        r = r or {}
        if r.get("TerminalId") == terminalId:
            return r
    return None


def findByCode(terminals, code):
    """Find a terminal row in an already-loaded list by TerminalCode
       (case-insensitive). Used by the Terminal Selector scan handler so
       a scanned barcode resolves to its row without a DB round-trip.

       The `terminals` arg arrives from view.custom (Java-wrapped), so it
       is unwrapped to plain dicts before matching.

       Returns the matching dict, or None if no terminal matches."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(terminals) or []
    target = (code or "").strip().upper()
    if not target:
        return None
    for r in rows:
        r = r or {}
        if (r.get("TerminalCode") or "").strip().upper() == target:
            return r
    return None


def listContextCells(terminalLocationId):
    """Eligible location-context rows for a shared-flavor view at the given
       terminal: active descendant EQUIPMENT cells of the terminal's parent
       (Terminal/Printer kinds excluded by the proc). Returns list[dict]
       (LocationId, Code, Name, Kind); always a list, empty when the
       terminal is unknown or its parent has no equipment cells."""
    BlueRidge.Common.Util.log("terminalLocationId=%s" % terminalLocationId)
    if terminalLocationId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "location/Terminal_ListContextCells",
        {"terminalId": terminalLocationId},
    )


def getContextCellsForDropdown(terminalLocationId):
    """listContextCells shaped for ia.input.dropdown + scan matching:
       [{label: '<Code> - <Name>', value: LocationId, code, name}].
       Always returns a list (never None) so the runScript-bound
       view.custom.cells default ([]) is never overwritten with null."""
    rows = listContextCells(terminalLocationId) or []
    out = []
    for r in rows:
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        out.append({
            "label": ("%s - %s" % (code, name)).strip(" -"),
            "value": r.get("LocationId"),
            "code":  code,
            "name":  name,
        })
    return out
