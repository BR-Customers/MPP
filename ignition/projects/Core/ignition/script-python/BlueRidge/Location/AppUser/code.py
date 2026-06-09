"""BlueRidge.Location.AppUser - thin access to operator / AD auth procs.

   Wrappers only; no business logic."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getByInitials(initials):
    """Resolve an AppUser by shop-floor initials. Returns a dict or None."""
    BlueRidge.Common.Util.log("initials=%s" % initials)
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_GetByInitials",
        {"initials": initials},
    )


def authenticateAd(adAccount, actionCode=None, terminalLocationId=None, appUserId=None):
    """Authenticate / elevate an AD account for a protected action.
       Returns {Status, Message, AppUserId, IgnitionRole}."""
    BlueRidge.Common.Util.log(
        "adAccount=%s actionCode=%s terminalLocationId=%s appUserId=%s"
        % (adAccount, actionCode, terminalLocationId, appUserId)
    )
    params = {
        "adAccount":          adAccount,
        "actionCode":         actionCode,
        "terminalLocationId": terminalLocationId,
        "appUserId":          appUserId,
    }
    return BlueRidge.Common.Db.execMutation("location/AppUser_AuthenticateAd", params)


def getRoles(appUserId):
    """List the Ignition roles granted to an AppUser. Returns list[dict]."""
    BlueRidge.Common.Util.log("appUserId=%s" % appUserId)
    return BlueRidge.Common.Db.execList(
        "location/AppUser_GetRoles",
        {"appUserId": appUserId},
    )
