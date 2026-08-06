# =============================================================================
# Project Library:  BlueRidge.Common.Session
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.1
#
# Description:
#   Session-derived attribution accessors. Today this module is a thin
#   re-export of BlueRidge.Common.Util._currentAppUserId so existing call
#   sites that imported BlueRidge.Common.Session keep working while new
#   code calls Util directly.
#
#   Once initials-presence + AD elevation are wired in, the underlying
#   Util._currentAppUserId resolves from session.custom.appUserId and
#   this shim still returns the correct value -- no caller changes.
#
# Public surface:
#   getCurrentUserId()  -> long (AppUser.Id for the active session)
#
# Change Log:
#   2026-05-13 - 1.0 - Initial dev placeholder (returns hardcoded id)
#   2026-05-14 - 1.1 - Delegates to BlueRidge.Common.Util._currentAppUserId
#                      so the dev fallback + future session resolution
#                      live in one place.
# =============================================================================


def getCurrentUserId():
    """
    AppUser.Id attribution for the active session.

    Thin shim around BlueRidge.Common.Util._currentAppUserId. New code
    should call Util directly; this remains so existing call sites keep
    working.

    Returns:
        long: AppUser.Id of the current user. Dev fallback while
              initials/AD wiring is pending.
    """
    return BlueRidge.Common.Util._currentAppUserId()


# =============================================================================
# Time-boxed elevation + idle-timeout helpers (spec 2026-08-04).
#
# All functions take the `session` object as a parameter and mutate/read
# session.custom.* on it -- NEVER system.perspective.getSessionInfo() (that API
# returns a LIST; the historic _currentAppUserId bug). Call from a view script
# that has self.session.
# =============================================================================
import java.lang


def nowMs():
    """Current time in epoch-ms (Date.now() equivalent for Jython)."""
    return system.date.toMillis(system.date.now())


def loadPolicyIntoSession(session):
    """Seed session.custom.policy from the global SessionPolicy row."""
    p = BlueRidge.Location.SessionPolicy.getPolicy() or {}
    session.custom.policy = {
        "operatorPresenceTimeoutSeconds": p.get("OperatorPresenceTimeoutSeconds") or 180,
        "elevationTimeoutSeconds":        p.get("ElevationTimeoutSeconds") or 300,
    }


def isElevated(session):
    """True while a rolling elevation window is open."""
    try:
        until = session.custom.elevatedUntil
        return until is not None and until > nowMs()
    except Exception:
        return False


def _elevationSeconds(session):
    try:
        return (session.custom.policy or {}).get("elevationTimeoutSeconds") or 300
    except Exception:
        return 300


def beginElevatedWindow(session, payload):
    """Replaced-identity elevation: the supervisor BECOMES the session user and a
    rolling window opens. payload = AppUser.elevate() result
    {appUserId, displayName, ignitionRole}."""
    p = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
    session.custom.user = {
        "appUserId":    p.get("appUserId"),
        "displayName":  p.get("displayName") or "",
        "ignitionRole": p.get("ignitionRole") or "",
        "initials":     "",
    }
    session.custom.appUserId = p.get("appUserId")
    session.custom.elevatedUntil = nowMs() + _elevationSeconds(session) * 1000


def touchElevation(session):
    """Push the rolling elevation deadline forward on activity."""
    if isElevated(session):
        session.custom.elevatedUntil = nowMs() + _elevationSeconds(session) * 1000


def activeTimeoutSeconds(session):
    """The timeout that governs right now: elevation window if elevated, else
    operator-presence."""
    pol = session.custom.policy or {}
    if isElevated(session):
        return pol.get("elevationTimeoutSeconds") or 300
    return pol.get("operatorPresenceTimeoutSeconds") or 180


def resetTerminal(session):
    """Drop elevation AND operator; return to the default screen + prompt initials.
    Same path the elevation-idle expiry takes (#11)."""
    try:
        old = session.custom.user
        oldId = old["appUserId"] if old else None
    except Exception:
        oldId = None
    try:
        term = session.custom.terminal
        termId = term["terminalLocationId"] if term else None
    except Exception:
        termId = None
    try:
        BlueRidge.Location.AppUser.logOperatorChange(oldId, None, termId)
    except (Exception, java.lang.Exception):
        pass
    session.custom.user = {"appUserId": None, "displayName": "", "ignitionRole": "", "initials": ""}
    session.custom.appUserId = None
    session.custom.elevatedUntil = None
    session.custom.pendingElevatedAction = None
    try:
        dflt = (session.custom.terminal or {}).get("defaultScreen") or "/shop-floor"
    except Exception:
        dflt = "/shop-floor"
    system.perspective.navigate(dflt)
    system.perspective.openPopup(
        "mpp-initials", "BlueRidge/Components/Popups/InitialsEntry",
        params={"popupId": "mpp-initials"}, modal=True, showCloseIcon=False, overlayDismiss=False)


def requireElevation(session, code, label, params=None):
    """Style-2 gate for a param-carrying protected action. If already elevated, act
    immediately; otherwise stash the intent and open the ElevationModal (the
    app-shell elevationResult handler replays the stash on success)."""
    if isElevated(session):
        dispatchElevatedAction(session, code, params)
    else:
        session.custom.pendingElevatedAction = {"code": code, "params": params}
        system.perspective.openPopup(
            "mpp-elevation-modal", "BlueRidge/Components/PlantFloor/ElevationModal",
            params={"actionCode": code, "actionLabel": label,
                    "popupId": "mpp-elevation-modal", "replyMessage": "elevationResult"},
            modal=True, showCloseIcon=True, overlayDismiss=True)


def dispatchElevatedAction(session, code, params):
    """Explicit code -> action map for param-carrying protected actions. NEVER eval.
    Access-only codes (SupervisorAccess / nav / config launch) have no follow-up.
    Param-carrying codes (e.g. MoveOverride) get a branch here as their popups
    migrate to requireElevation."""
    p = BlueRidge.Common.Util.extractQualifiedValues(params) or {}
    # if code == "MoveOverride": <wired when MoveOverride migrates to requireElevation>
    if code and code != "SupervisorAccess":
        BlueRidge.Common.Util.log(
            "dispatchElevatedAction: no handler wired for code=%s (params=%s)" % (code, p))
