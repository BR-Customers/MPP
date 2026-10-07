"""BlueRidge.Lots.LotNote - free-text notes against a LOT (Lots.LotNote, 0107).

Append-only: there is an add and a list, and deliberately nothing else. Any
signed-in user may write a note; a note changes nothing about the LOT.

Because a PIN is an identifier and not a credential, attribution on a note is
only as strong as the sign-in behind it. So every note carries as much of the
moment as the session can give -- buildContext() -- alongside the typed
who/where columns and the LOT snapshot the proc stamps itself.
"""

from java.lang import Throwable


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


# session.custom keys left OUT of the stored context. Everything else under
# session.custom goes in, so a key added later is captured without a change
# here. These three are bulk or transient UI state with no evidential value:
# the cutover entry form, the toast queue, and a stashed elevation intent.
_SESSION_CUSTOM_SKIP = ("cutover", "toastInstances", "pendingElevatedAction")

# Read by name only if session.custom cannot be enumerated.
_SESSION_CUSTOM_FALLBACK = ("appUserId", "user", "terminal", "cell", "printer",
                            "elevatedUntil", "elevatedHardUntil", "lotTrail")

_MAX_DEPTH = 6


def _plain(value, depth=0):
    """Reduce a Perspective / Java value to plain JSON-encodable Python.

       Property reads hand back live wrapper objects, and extractQualifiedValues
       does not unwrap the Immutable* collections, so this walks by DUCK TYPE
       (keys() / iteration) rather than by class. Dates become ISO strings.
       Anything unrecognised becomes its string form -- context is evidence,
       and a lossy value beats a lost note."""
    if depth > _MAX_DEPTH:
        return "%s" % (value,)
    try:
        if hasattr(value, "getValue") and hasattr(value, "getQuality"):
            return _plain(value.getValue(), depth)
    except (Exception, Throwable):
        pass
    if value is None or isinstance(value, (bool, int, long, float)):
        return value
    if isinstance(value, basestring):
        return value
    if hasattr(value, "getTime"):
        try:
            return system.date.format(value, "yyyy-MM-dd'T'HH:mm:ss.SSSZ")
        except (Exception, Throwable):
            return "%s" % (value,)
    if hasattr(value, "keys"):
        out = {}
        try:
            for key in value.keys():
                try:
                    out["%s" % key] = _plain(value[key], depth + 1)
                except (Exception, Throwable):
                    out["%s" % key] = None
        except (Exception, Throwable):
            return "%s" % (value,)
        return out
    try:
        return [_plain(item, depth + 1) for item in value]
    except (Exception, Throwable):
        return "%s" % (value,)


def _read(fn):
    """Evaluate one context lookup; a missing prop yields None, never a throw."""
    try:
        return _plain(fn())
    except (Exception, Throwable):
        return None


def buildContext(session, pagePath=None, extra=None):
    """Everything worth knowing about where a note came from, as a plain dict.

         session  - Perspective session id, client address/host, device and
                    user agent, and the authenticated AD account if any
         custom   - session.custom minus _SESSION_CUSTOM_SKIP: the terminal and
                    its zone, the cell, the signed-in user, the elevation
                    clocks, the printer, the LOT trail, ...
         elevated - whether an elevation window was open (also a typed column)
         page     - the page path the note was typed on
         view     - whatever the calling view adds (LOT Detail passes the
                    active tab)

       Never raises: a lookup that fails is recorded as None and the rest of
       the context still goes in."""
    ctx = {
        "capturedAt": _read(lambda: system.date.now()),
        "session": {
            "id":        _read(lambda: session.props.id),
            "address":   _read(lambda: session.props.address),
            "host":      _read(lambda: session.props.host),
            "device":    _read(lambda: session.props.device),
            "userAgent": _read(lambda: session.props.userAgent),
            "authUser":  _read(lambda: session.props.auth.user.userName),
            "timeZone":  _read(lambda: session.props.timeZoneId),
        },
        "elevated": BlueRidge.Common.Session.isElevated(session),
        "page": _read(lambda: pagePath),
        "view": _read(lambda: extra),
    }
    custom = {}
    try:
        for key in session.custom.keys():
            name = "%s" % key
            if name in _SESSION_CUSTOM_SKIP:
                continue
            custom[name] = _read(lambda k=key: session.custom[k])
    except (Exception, Throwable) as e:
        # The wrapper would not enumerate: fall back to the keys that matter.
        custom["_error"] = "%s" % (e,)
        for name in _SESSION_CUSTOM_FALLBACK:
            custom[name] = _read(lambda k=name: session.custom[k])
    ctx["custom"] = custom
    return ctx


def add(lotId, noteText, appUserId=None, terminalLocationId=None, wasElevated=False, context=None):
    """Write one note (Lots.LotNote_Add). context is a dict (or None); it is
       JSON-encoded here. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "add lotId=%s appUserId=%s terminalLocationId=%s wasElevated=%s"
        % (lotId, appUserId, terminalLocationId, wasElevated))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    contextJson = None
    if context is not None:
        try:
            contextJson = system.util.jsonEncode(context)
        except (Exception, Throwable) as e:
            # The proc wraps non-JSON as {"Unparsed": ...}; say why it is here.
            contextJson = "context could not be encoded: %s" % (e,)
    params = {
        "lotId":              _u(lotId),
        "noteText":           _u(noteText),
        "appUserId":          appUserId,
        "terminalLocationId": _u(terminalLocationId),
        "wasElevated":        bool(wasElevated),
        "contextJson":        contextJson,
    }
    return BlueRidge.Common.Db.execMutation("lots/LotNote_Add", params)


def addFromSession(session, lotId, noteText, pagePath=None, extra=None):
    """The view-facing add: resolves the user, terminal, elevation state and
       context from the session, so the LOT Detail event stays a one-liner and
       any later entry point records exactly the same things."""
    terminalLocationId = _read(lambda: session.custom.terminal.terminalLocationId)
    return add(
        lotId, noteText,
        appUserId=BlueRidge.Common.Session.currentAppUserId(session),
        terminalLocationId=terminalLocationId,
        wasElevated=BlueRidge.Common.Session.isElevated(session),
        context=buildContext(session, pagePath, extra))


def listByLot(lotId, _refreshToken=None):
    """Every note on a LOT, newest first. [] when there are none."""
    lotId = _u(lotId)
    if not lotId:
        return []
    # Never raises. LotDetail.load() calls this mid-sequence, and a throw here
    # would skip everything after it (scrap summary, hold, the panel loads) --
    # a notes read must not be able to blank the rest of the screen.
    try:
        return BlueRidge.Common.Db.execList("lots/LotNote_ListByLot", {"lotId": lotId})
    except (Exception, Throwable) as e:
        BlueRidge.Common.Util.log("listByLot failed lotId=%s: %s" % (lotId, e), level="error")
        return []


def mapInstances(rows):
    """LOT Detail Notes repeater instances: one {'row': {...}} per note, with
       the display strings precomputed here (see Lot.mapHistoryInstances for why
       date math is not left to the row view's expressions).

         ByLine       'JP - Jane Operator'
         WhenLine     '10/06 14:02  -  3h ago'
         WhereLine    'Terminal (Trim Line 2)'   or 'Terminal not recorded'
         SnapshotLine 'LOT was Good - 120 pcs - at Trim Line 2'"""
    rows = _u(rows) or []
    stamped = []
    for r in rows:
        r = dict(r or {})
        r["EventAt"] = r.get("CreatedAt")
        stamped.append(r)
    out = []
    for inst in BlueRidge.Lots.Lot.mapHistoryInstances(stamped):
        r = inst["row"]
        initials = r.get("ByInitials") or ""
        name = r.get("ByDisplayName") or ""
        if initials and name:
            byLine = "%s - %s" % (initials, name)
        else:
            byLine = initials or name or "Unknown user"
        whenLine = r.get("EventAtDisplay") or ""
        if r.get("EventAgo"):
            whenLine = "%s  -  %s" % (whenLine, r.get("EventAgo"))
        terminal = r.get("TerminalName") or ""
        zone = r.get("TerminalZoneName") or ""
        if terminal and zone:
            whereLine = "%s (%s)" % (terminal, zone)
        else:
            whereLine = terminal or "Terminal not recorded"
        snapshot = "LOT was %s - %s pcs - at %s" % (
            r.get("LotStatusCode") or "?", r.get("LotPieceCount"), r.get("LotLocationName") or "?")
        out.append({"row": {
            "Id":           r.get("Id"),
            "NoteText":     r.get("NoteText") or "",
            "ByLine":       byLine,
            "WhenLine":     whenLine,
            "WhereLine":    whereLine,
            "SnapshotLine": snapshot,
            "WasElevated":  bool(r.get("WasElevated")),
        }})
    return out
