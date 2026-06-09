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
    """List every configured terminal. Returns list[dict]."""
    BlueRidge.Common.Util.log("listing terminals")
    return BlueRidge.Common.Db.execList("location/Terminal_List")
