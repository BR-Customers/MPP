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
DEFAULT_TTL_SEC = 8        # non-error auto-dismiss (matches toast() docstring)
MAX_VISIBLE     = 5
STACK_TOP_START = 10        # px from top of viewport for first toast
STACK_GAP       = 12        # px between stacked toasts (height now varies per toast)
TOAST_WIDTH     = 500
TOAST_MIN_HEIGHT = 96       # single-line title + single-line message + padding
TOAST_MAX_HEIGHT = 320      # cap so one very long message can't dominate the stack
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

def _estimateHeight(title, message):
    """
    Rough px height for THIS toast's content, so the popup (and the next
    toast's stack offset) scale with how much text is actually in it instead
    of assuming every toast is one line. Perspective popups don't auto-size to
    content, so this is the only lever -- an approximation from character
    count, not a real text-layout measurement.

    Tuned against the Toast view's own CSS (.psc-toast padding
    var(--mpp-space-4/5) = 16/24px, .psc-toast-title fs-md ~22px/1.2 line,
    .psc-toast-msg fs-base ~20px/1.3 line) and its content column width
    (TOAST_WIDTH minus icon/padding/close-icon, ~360px at 500px total).
    """
    title_chars_per_line   = 28
    message_chars_per_line = 46
    title_line_px          = 28
    message_line_px        = 26
    vertical_padding_px    = 40   # top+bottom padding + icon/content top offset

    title_lines = max(1, -(-len(title or "") // title_chars_per_line))      # ceil div
    message_lines = max(1, -(-len(message or "") // message_chars_per_line))

    height = vertical_padding_px + (title_lines * title_line_px) + (message_lines * message_line_px)
    return max(TOAST_MIN_HEIGHT, min(TOAST_MAX_HEIGHT, height))


def _handle(view, payload):
    """
    Message-handler entry from the host view (e.g., Header dock).
    Maintains session.custom.toastInstances and opens a popup.
    """
    instances = _readInstances(view)
    instances = _cleanupStale(instances)
    instances = _enforceFifo(instances)

    title = payload.get("title", "")
    message = payload.get("message", "")
    height = _estimateHeight(title, message)
    new_top, new_id = _nextSlot(instances)
    new_entry = {
        "id":     new_id,
        "top":    new_top,
        "height": height,
        "ts":     system.date.now(),
    }
    instances.append(new_entry)
    _writeInstances(view, instances)

    system.perspective.openPopup(
        id=new_id,
        view=TOAST_VIEW_PATH,
        position={"right": 10, "top": new_top, "width": TOAST_WIDTH, "height": height},
        params={
            "id":      new_id,
            "title":   title,
            "message": message,
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
    Compute this toast's top offset (px) plus a unique instance id.

    Toasts now vary in height (see _estimateHeight), so a fixed step would
    either waste space under short toasts or -- the bug this replaces --
    undershoot under long ones and let the next toast overlap it. Stack
    strictly bottom-of-the-last-one instead: sum every currently-visible
    instance's own height + STACK_GAP, in list order. Simplification versus
    the old slot-reuse scheme: a toast that closes early leaves a gap that
    later arrivals don't backfill (they still just append past the current
    bottom) -- acceptable; avoiding overlap matters more than avoiding a gap.
    """
    top = STACK_TOP_START
    for i in instances:
        top += int(i.get("height") or TOAST_MIN_HEIGHT) + STACK_GAP
    new_id = "mpp-toast-{0}-{1}".format(top, system.date.toMillis(system.date.now()))
    return top, new_id
