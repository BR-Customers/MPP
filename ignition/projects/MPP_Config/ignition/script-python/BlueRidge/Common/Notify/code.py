# =============================================================================
# Project Library:  BlueRidge.Common.Notify
#
# Author:           Blue Ridge Automation
# Created:          2026-05-12
# Version:          1.0
#
# Description:
#   Toast-notification API for MPP MES. Top-right stacking popups with
#   per-level styling, FIFO cap, optional auto-dismiss.
#
#   Public surface (called from any view event handler):
#       toast(title, message, level='info', ttl=None)
#           level   -> 'success' | 'info' | 'warning' | 'error'
#           ttl     -> seconds, None = persistent (must click X)
#                      Default: 8s for non-error, None for error.
#
#   Internal helpers (called by the popup-host view / toast-popup view):
#       _handle(view, payload)       message handler entry-point
#       _dismiss(view, instanceId)   remove from stack + close popup
#
# Architecture:
#   Caller in any view event:
#       BlueRidge.Common.Notify.toast(title, msg, level)
#         -> system.perspective.sendMessage('mpp-toast', payload, scope='session')
#         -> Header dock view subscribes to 'mpp-toast' and calls _handle(self, payload)
#         -> _handle updates session.custom.toastInstances, opens popup
#         -> Toast popup auto-dismisses (CSS-driven via now(500) polling) or
#            user click on close icon -> calls _dismiss(self, params.id)
#
# Layer:
#   View event  -> BlueRidge.Common.Notify.toast (this module)
#               -> system.perspective.* (Common layer)
#
# Change Log:
#   2026-05-12 - 1.0 - Initial version
# =============================================================================

logger = system.util.getLogger("BlueRidge.Common.Notify")

# ---- Tunables -------------------------------------------------------------
DEFAULT_TTL_SEC = 8
MAX_VISIBLE     = 5
STACK_TOP_START = 10        # px from top of viewport for first toast
STACK_TOP_STEP  = 110       # px between stacked toasts
TOAST_VIEW_PATH = "BlueRidge/Components/Popups/Toast"
MSG_HANDLER     = "mpp-toast"
SESSION_LIST    = "toastInstances"


# ---- Public API -----------------------------------------------------------

def toast(title, message, level="info", ttl=None):
    """
    Fire a toast notification. Safe to call from any view event handler.

    Args:
        title (str):   Headline text. Required.
        message (str): Body text. Required.
        level (str):   'success' | 'info' | 'warning' | 'error'.
                       Errors persist until user click; others auto-dismiss.
        ttl (int|None): Override auto-dismiss seconds. None means use the
                        level default (8s for non-error, persistent for error).

    Returns:
        None. Toasts are opened asynchronously via session message.
    """
    if level not in ("success", "info", "warning", "error"):
        logger.warnf("toast() called with invalid level=%s, coercing to 'info'", level)
        level = "info"

    effective_ttl = ttl
    if effective_ttl is None and level != "error":
        effective_ttl = DEFAULT_TTL_SEC

    payload = {
        "title":   title,
        "message": message,
        "level":   level,
        "ttl":     effective_ttl,
    }
    logger.debugf("toast level=%s ttl=%s title=%s", level, effective_ttl, title)
    system.perspective.sendMessage(MSG_HANDLER, payload, scope="session")


# ---- Internal helpers (called from host view + toast popup) ---------------

def _handle(view, payload):
    """
    Message-handler entry from the host view (e.g., Header dock).
    Maintains session.custom.toastInstances and opens a popup.
    """
    instances = _readInstances(view)
    instances = _cleanupStale(instances)
    instances = _enforceFifo(instances)

    new_top, new_id = _nextSlot(instances)
    new_entry = {
        "id":  new_id,
        "top": new_top,
        "ts":  system.date.now(),
    }
    instances.append(new_entry)
    _writeInstances(view, instances)

    system.perspective.openPopup(
        id=new_id,
        view=TOAST_VIEW_PATH,
        position={"right": 10, "top": new_top},
        params={
            "id":      new_id,
            "title":   payload.get("title", ""),
            "message": payload.get("message", ""),
            "level":   payload.get("level", "info"),
            "ttl":     payload.get("ttl"),
        },
        showCloseIcon=False,
        resizable=False,
        draggable=False,
        modal=False,
        overlayDismiss=False,
        viewportBound=False,
        style={
            "backgroundColor": "transparent",
            "border":          "none",
            "boxShadow":       "none",
            "padding":         "0",
        },
    )


def _dismiss(view, instanceId):
    """
    Remove a toast from the session stack and close its popup. Called from
    the toast popup view's close-button click handler and from its
    auto-dismiss onChange handler.
    """
    if not instanceId:
        return
    instances = _readInstances(view)
    filtered = [i for i in instances if i.get("id") != instanceId]
    _writeInstances(view, filtered)
    system.perspective.closePopup(id=instanceId)


# ---- Stack management -----------------------------------------------------

def _readInstances(view):
    """Pull a fresh mutable copy from session.custom.toastInstances."""
    raw = view.session.custom.toastInstances
    return list(raw) if raw else []


def _writeInstances(view, instances):
    """Persist the updated list back into session.custom.toastInstances."""
    view.session.custom.toastInstances = instances


def _cleanupStale(instances, max_age_min=2):
    """
    Drop entries older than max_age_min minutes. Defensive — popups should
    self-dismiss; stragglers here are a safety net.
    """
    cutoff = system.date.addMinutes(system.date.now(), -max_age_min)
    return [
        i for i in instances
        if i.get("ts") and system.date.isAfter(i["ts"], cutoff)
    ]


def _enforceFifo(instances, max_visible=MAX_VISIBLE):
    """
    FIFO cap. If we're at/over the limit, close the oldest popup(s) so the
    new arrival fits within MAX_VISIBLE.
    """
    if len(instances) < max_visible:
        return instances
    # Sort oldest -> newest by timestamp; the ones to drop are the front.
    sorted_instances = sorted(instances, key=lambda x: x.get("ts") or system.date.now())
    drop_count = len(sorted_instances) - (max_visible - 1)
    to_drop = sorted_instances[:drop_count]
    to_keep = sorted_instances[drop_count:]
    for entry in to_drop:
        system.perspective.closePopup(id=entry.get("id"))
    return to_keep


def _nextSlot(instances):
    """
    Compute the smallest available top offset (px) plus a unique instance id.
    Slots are STACK_TOP_START, +STACK_TOP_STEP, +2*STACK_TOP_STEP, ...
    """
    used = {int(i.get("top", 0)) for i in instances}
    candidates = range(
        STACK_TOP_START,
        STACK_TOP_START + STACK_TOP_STEP * (len(used) + 2),
        STACK_TOP_STEP
    )
    available = [c for c in candidates if c not in used]
    new_top = available[0] if available else STACK_TOP_START
    new_id  = "mpp-toast-{0}-{1}".format(new_top, system.date.toMillis(system.date.now()))
    return new_top, new_id
