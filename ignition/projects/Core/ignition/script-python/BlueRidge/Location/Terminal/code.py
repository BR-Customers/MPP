"""BlueRidge.Location.Terminal - thin read access to terminal resolution procs.

   Wrappers only; no business logic. Calls route View -> here ->
   BlueRidge.Common.Db -> system.db.*."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getByIpAddress(ipAddress):
    """Resolve the terminal (and its zone / default screen / mode) for the
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
