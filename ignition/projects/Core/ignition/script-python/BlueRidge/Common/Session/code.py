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
        "operatorPresenceTimeoutSeconds": p.get("OperatorPresenceTimeoutSeconds") or 1800,
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
    return pol.get("operatorPresenceTimeoutSeconds") or 1800


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


# A stashed intent is only replayable for this long. The ElevationModal can be
# dismissed (close icon / overlay) without any event, which leaves the stash
# behind; without a deadline the NEXT successful elevation -- even one raised for
# an unrelated reason, e.g. the header's Supervisor Access button -- would replay
# it. Several replayable actions are irreversible (DowntimeVoid), so the stash is
# both time-boxed and consumed exactly once (see dispatchElevatedAction).
PENDING_ACTION_TTL_MS = 120000


def requireElevation(session, code, label, params=None):
    """Style-2 gate for a param-carrying protected action. If already elevated, act
    immediately; otherwise stash the intent and open the ElevationModal (the
    app-shell elevationResult handler replays the stash on success)."""
    if isElevated(session):
        dispatchElevatedAction(session, code, params)
    else:
        session.custom.pendingElevatedAction = {
            "code": code, "params": params, "expiresAt": nowMs() + PENDING_ACTION_TTL_MS}
        system.perspective.openPopup(
            "mpp-elevation-modal", "BlueRidge/Components/PlantFloor/ElevationModal",
            params={"actionCode": code, "actionLabel": label,
                    "popupId": "mpp-elevation-modal", "replyMessage": "elevationResult"},
            modal=True, showCloseIcon=True, overlayDismiss=True)


# Explicit actionCode -> page-message replay map. NEVER eval, never a computed
# message name: a protected action re-enters its OWN handler, which re-tests
# isElevated (now True) and proceeds. Adding a gated action = one entry here plus
# the requireElevation guard at the top of that handler.
_ELEVATED_REPLAY_MESSAGES = {
    "DowntimeReason":  "dtReasonSelected",           # Downtime Manager - change/clear a reason
    "DowntimeEdit":    "dtEditRequested",            # Downtime Manager - open the time/remarks editor
    "DowntimeVoid":    "dtVoidRequested",            # Downtime Manager - void an event
    "SortCageMigrate": "sortCageMigrateAuthorized",  # Sort Cage - re-containerize a serial
}


def dispatchElevatedAction(session, code, params):
    """Explicit code -> action map for param-carrying protected actions. NEVER eval.
    Access-only codes (SupervisorAccess / nav / config launch) have no follow-up.
    Param-carrying codes replay through _ELEVATED_REPLAY_MESSAGES: the stashed
    payload is re-sent as the originating page message, so the requesting view's
    own handler runs the action with the elevation window now open.

    Replay is page-scoped and fires from the AppHeader elevationResult handler --
    AppHeader is a shared TOP dock, so every Perspective page carries it.

    A replay is CONSUMED (stash cleared) and REFUSED once PENDING_ACTION_TTL_MS
    has passed, so a prompt the operator dismissed can never be resurrected by a
    later, unrelated elevation."""
    p = BlueRidge.Common.Util.extractQualifiedValues(params) or {}
    messageType = _ELEVATED_REPLAY_MESSAGES.get(code)
    if messageType:
        pend = BlueRidge.Common.Util.extractQualifiedValues(
            session.custom.pendingElevatedAction) or {}
        # Only a stash for THIS code can veto: a direct (already-elevated) call
        # must not be refused by some other action's leftover deadline.
        expiresAt = pend.get("expiresAt") if pend.get("code") == code else None
        session.custom.pendingElevatedAction = None   # one-shot: never replay twice
        if expiresAt is not None and expiresAt < nowMs():
            BlueRidge.Common.Util.log(
                "dispatchElevatedAction: stale intent discarded for code=%s" % code,
                level="warn")
            return
        system.perspective.sendMessage(messageType, payload=p, scope="page")
        return
    if code and code != "SupervisorAccess":
        BlueRidge.Common.Util.log(
            "dispatchElevatedAction: no handler wired for code=%s (params=%s)" % (code, p))
