# =============================================================================
# Project Library:  BlueRidge.Location.ClosureMode
#
# Author:           Blue Ridge Automation
# Created:          2026-07-17
# Version:          1.0
#
# Description:
#   Assembly-out closure-mode CHANGEOVER. Elevates for the protected
#   'Changeover' action (supervisor AD), then calls the
#   Location.Terminal_SetClosureMethod mutation with the elevated appUserId.
#
#   Per-action elevation is STATELESS: elevate() returns the elevated
#   appUserId but does NOT set session.custom.appUserId, so the returned id is
#   passed straight to the proc (never relied upon from session state).
#
# Public surface:
#   changeover(terminalLocationId, newMethod, adAccount, password)
#       -> {Status, Message}
# =============================================================================

import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Location.AppUser


def changeover(terminalLocationId, newMethod, adAccount, password):
    """Elevate for 'Changeover', then set the terminal's closure mode.
       Returns the mutation's {Status, Message} (or a Status=0 dict when
       elevation fails)."""
    terminalLocationId = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    newMethod = BlueRidge.Common.Util.extractQualifiedValues(newMethod)

    el = BlueRidge.Location.AppUser.elevate(adAccount, password, "Changeover", terminalLocationId)
    if not el or not el.get("success"):
        return {"Status": 0, "Message": (el or {}).get("message") or "Elevation failed."}

    return BlueRidge.Common.Db.execMutation(
        "location/Terminal_SetClosureMethod",
        {
            "terminalLocationId": terminalLocationId,
            "newMethod":          newMethod,
            "appUserId":          el.get("appUserId"),
        },
    )
