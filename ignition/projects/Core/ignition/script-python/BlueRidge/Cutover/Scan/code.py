# =============================================================================
# Project Library:  BlueRidge.Cutover.Scan
#
# Author:           Blue Ridge Automation
# Created:          2026-09-12
# Version:          1.0
#
# Description:
#   All behaviour for the inventory cutover scan screen. The screen is hosted
#   by a nested ia.container.breakpt (outer breakpoint 900 / desktop large
#   child, inner breakpoint 500 / tablet large child + phone small child) --
#   only the active branch renders, so per-size view.custom state would be
#   destroyed the instant the viewport crossed a breakpoint. The scan session
#   is genuinely session-scoped anyway (one operator, one line, one walk of
#   the rack), so it lives in session.custom.cutover instead. Three size
#   views (Task 11) are presentation only, calling these functions as
#   one-liners and binding to session.custom.cutover.* -- the repo's standing
#   three-layer rule (View -> entity script -> Common helpers), not a special
#   case for this screen.
#
#   No business logic lives here. Every domain question (route position,
#   die/cavity eligibility, status-transition legality, MaxLotSize) is asked
#   of SQL through the Task 9 wrappers; this module only calls them, shapes
#   session state, and formats messages.
#
# Public surface:
#   loadSession(lineLocationId, itemId, entryRoleCode, machineNumber, session)
#                          -> {Status, Message}
#   addBasket(appUserId, terminalLocationId, session)
#                          -> {Status, Message, NewId}
#   addBox(appUserId, terminalLocationId, session)
#                          -> {Status, Message, NewId}
#   voidEntry(lotId, appUserId, session)
#                          -> {Status, Message}
#   stepCastDate(days, session) -> the new date, capped at today
#   getState()             -> the full session.custom.cutover shape, every
#                             key always present (first-paint safe)
#
# Layer:
#   View -> BlueRidge.Cutover.Scan (this module)
#        -> BlueRidge.Lots.Lot / BlueRidge.Parts.Item / BlueRidge.Location.Location
#           / BlueRidge.Parts.RouteTemplate / BlueRidge.Tools.Tool
#   Views never call system.db.* or the entity wrappers directly for this
#   screen -- everything routes through here so the three size views cannot
#   triplicate the logic.
#
# Deviations from the task-10 brief (verified against the real wrapper
# signatures before writing this file -- see task-10-report.md):
#   - BlueRidge.Parts.Item has no getById; the real read is getOne(itemId).
#   - BlueRidge.Location.Location has no getById; the real read is
#     getOne(locationId), and it returns LOWERCASE keys (name/code/id/...),
#     not PascalCase -- lineName reads line.get("name"), not line.get("Name").
#   - BlueRidge.Lots.Lot.updateStatus's real signature is
#     updateStatus(data, appUserId=None, terminalLocationId=None) where data
#     carries {lotId, newLotStatusId, reason, rowVersion} -- it takes a
#     LotStatusCode Id, not a status-code string, and does not take the
#     reason/appUserId as bare positional args. Lots.Lot had no
#     status-code-to-Id resolver (only getOriginTypeIdByCode, for LOT
#     origins), so this module's change also adds the sibling
#     BlueRidge.Lots.Lot.getStatusIdByCode(code), same shape as
#     getOriginTypeIdByCode, to resolve 'Closed' before calling updateStatus.
#     RowVersion is intentionally omitted (passed implicitly as None/absent):
#     Lots.Lot_UpdateStatus treats a NULL @RowVersion as an explicit
#     Phase-1 opt-out of the optimistic-lock check (see that proc's header),
#     and this screen never reads a LOT's RowVersion back from Lot_Create.
#
# Change Log:
#   2026-09-12 - 1.0 - Initial version (Task 10: scan logic as a Core script
#                      module; loadSession, addBasket, addBox, voidEntry,
#                      stepCastDate, getState).
#   2026-09-13 - 1.1 - FIX: every control on the screen was inert because
#                      getState() handed back LIVE PropertyTreeScriptWrapper
#                      views of session.custom.cutover rather than detached
#                      Python. Added _plain() and routed getState through it.
#                      See _plain's docstring for the mechanism. (The
#                      java.util.Date theory recorded in PROJECT_STATUS was
#                      wrong -- a Date round-trips through a session custom
#                      prop correctly; verified live.)
# =============================================================================

import java.lang


def _u(value):
    """Local shorthand for extractQualifiedValues. Every public function here
       deep-unwraps its inputs at entry -- a value arriving from a
       Perspective binding (a dropdown's props.value, a button's payload) is
       a QualifiedValue / Java Map, not a bare Python value, and an `is None`
       guard does not catch it."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _plain(value):
    """DETACH a Perspective property-tree value into plain Python.

       session.custom.cutover does NOT hand back a dict -- it hands back a
       com.inductiveautomation.perspective.gateway.script.PropertyTreeScriptWrapper
       $ObjectWrapper, a LIVE VIEW into the session's property document. It
       quacks enough like a dict (.get / .keys / .items / [k]) that code which
       copies it looks correct and is not: every nested value copied out is
       still a live view, so

           st = getState(session)          # st["entry"] is a LIVE wrapper
           st["entry"]["castDate"] = nxt   # mutates the live tree (queued)
           session.custom.cutover = st     # replaces the tree with a snapshot
                                           # rebuilt from those same wrappers

       ends with the nested write clobbered by the wholesale replace. That is
       the bug that made every control on this screen inert while the screen
       itself rendered perfectly: cavity tiles, both cast-date arrows, the LTT
       and count clears after a basket -- all of them mutate nested state.

       extractQualifiedValues does NOT cover this: it only recurses into a
       Python dict / list / tuple, and an ObjectWrapper is none of those
       (verified: isinstance(raw, dict) is False).

       So every read of session state goes through here first. Duck-typed
       rather than isinstance-checked because the wrapper classes are internal
       and differ between object and array nodes -- .items() means mapping,
       iterable means sequence, anything else (including java.util.Date) is a
       leaf and is returned untouched.

       BlueRidge.Lots.LotTrail._plain solves the same hazard by round-tripping
       through system.util.jsonEncode/jsonDecode. That is NOT usable here:
       entry.castDate is a java.util.Date and a JSON round-trip would return it
       as a string, which then fails Lot_Create's :castDate (sqlType 8,
       DateTime). A Date DOES survive a session custom prop untouched --
       verified live 2026-09-13, write and read-back matched -- so the leaf is
       left alone."""
    if value is None or isinstance(value, (bool, int, long, float, basestring)):
        return value
    items = getattr(value, "items", None)
    if items is not None and callable(items):
        return dict([(k, _plain(v)) for k, v in value.items()])
    try:
        seq = list(value)
    except (TypeError, Exception, java.lang.Exception):
        return value
    return [_plain(v) for v in seq]


_EMPTY = {
    "session": {"lineLocationId": None, "lineName": "", "destinationLocationId": None,
                "destinationName": "", "entryRoleCode": "MachiningIn",
                "entryRouteSequence": None, "itemId": None, "partNumber": "",
                "partDescription": "", "toolId": None, "toolCode": "",
                "toolIsAmbiguous": False, "machineNumber": ""},
    "entry": {"lotName": "", "toolCavityId": None, "cavityCode": "",
              "castDate": None, "pieceCount": ""},
    "purchased": {"partNumber": "", "partDescription": "", "itemId": None,
                  "qty": "", "vendorLot": ""},
    "cavityOptions": [], "toolOptions": [], "rows": [],
    "totals": {"baskets": 0, "pieces": 0}, "mode": "cast",
}


def getState(session=None):
    """The whole cutover session state, always fully shaped -- merged over
       _EMPTY so a first-paint binding that traverses a nested path (before
       any session has been loaded, or against a key a future version adds)
       never hits a missing property, which renders a red Perspective
       Component Error rather than a blank/default value. Never-throw: this
       is called from bindings on every render, so a bad read must fall back
       to the empty shape, not raise into the component."""
    # Read through the SESSION OBJECT the caller already holds.
    #
    # This used to be system.perspective.getSessionInfo()["custom"], which is
    # wrong and failed on EVERY call with "list indices must be integers":
    # getSessionInfo() returns a LIST of every session on the gateway, not the
    # current one. The never-throw guard then swallowed it and handed back the
    # empty shape, so getState could never see existing state -- addBasket read
    # the operator's typed LTT and piece count out of that empty shape and got
    # blanks. Silent, because the guard is doing exactly what it was built to do.
    #
    # There is no way to identify "this" session from that list, so without a
    # session object the honest answer is the empty shape, logged.
    raw = None
    if session is not None:
        try:
            raw = session.custom.cutover
        except (Exception, java.lang.Exception) as e:
            BlueRidge.Common.Util.log("getState: session read failed: %s" % str(e), level="warn")
            raw = None
    else:
        BlueRidge.Common.Util.log(
            "getState called with no session -- returning the empty shape. "
            "Callers must pass the session object.", level="warn")
    st = _plain(_u(raw))
    if not isinstance(st, dict):
        st = {}
    # Shallow dict(_EMPTY) would share the nested dicts (session/entry/
    # purchased/totals) across every call -- one session's edits would then
    # mutate the module-level default for every other session. Copy each
    # nested dict too.
    out = {
        "session": dict(_EMPTY["session"]),
        "entry": dict(_EMPTY["entry"]),
        "purchased": dict(_EMPTY["purchased"]),
        "cavityOptions": list(_EMPTY["cavityOptions"]),
        "toolOptions": list(_EMPTY["toolOptions"]),
        "rows": list(_EMPTY["rows"]),
        "totals": dict(_EMPTY["totals"]),
        "mode": _EMPTY["mode"],
    }
    for k, v in st.items():
        out[k] = v
    return out


def _write(state, session):
    """ONE assignment. Key-by-key writes let a binding re-evaluate between
       sequential writes and see half-built state -- this codebase has
       previously latched a stuck dirty flag from exactly that race."""
    session.custom.cutover = state


def _guard(fn):
    """Turn an UNEXPECTED exception into the status row every caller already
       knows how to render.

       Without this, a DB-level failure is completely silent to the operator.
       The view does

           res = BlueRidge.Cutover.Scan.addBasket(...)
           BlueRidge.Common.Ui.notifyResult(res, "Basket added", ...)

       so if addBasket RAISES, the gateway event script dies on the spot and
       notifyResult never runs: no toast, no error, the button just does
       nothing. That is exactly what happened on 2026-09-13 when Lot_Create hit
       'Invalid object name Lots.ufn_CrtForMint' on a Dev database that was
       behind on migrations 0064-0066 -- the operator got no feedback at all
       and the only evidence was a stack trace in wrapper.log.

       Business-rule failures already return Status 0 and are NOT exceptions;
       this only catches the unexpected. The message is surfaced verbatim
       because on the plant floor the alternative -- a generic "something went
       wrong" -- tells the person standing at the terminal nothing they can
       relay."""
    def wrapped(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except (Exception, java.lang.Exception) as e:
            BlueRidge.Common.Util.log(
                "%s FAILED: %s" % (fn.__name__, str(e)), level="error")
            return {"Status": 0,
                    "Message": "%s failed: %s" % (fn.__name__, str(e)),
                    "NewId": None}
    wrapped.__name__ = fn.__name__
    wrapped.__doc__ = fn.__doc__
    return wrapped


@_guard
def loadSession(lineLocationId, itemId, entryRoleCode, machineNumber, session):
    """Latch the scan session. Every domain question is asked of SQL; this only
       assembles the answers. Returns {Status, Message}."""
    lineLocationId = _u(lineLocationId)
    itemId = _u(itemId)
    entryRoleCode = _u(entryRoleCode)
    machineNumber = _u(machineNumber)

    item = BlueRidge.Parts.Item.getOne(itemId) or {}
    line = BlueRidge.Location.Location.getOne(lineLocationId) or {}
    dest = BlueRidge.Location.Location.getStockDestinationOrEmpty(lineLocationId)
    # EntryRouteSequence is a CASTINGS-ONLY mechanism (design spec 3.4). A
    # SubAssembly's route is a single ConsumeMint step with nothing earlier to
    # skip, and a purchased component has no route at all -- both surface
    # correctly through Lot_GetComponentsAtCell with no entry point. So "this
    # part has no step for the entry role" is NORMAL for everything that is not
    # a casting, and must not block the session: it just means the LOT is
    # created with EntryRouteSequence NULL, which is exactly today's behaviour
    # for every LOT in the plant.
    seq = BlueRidge.Parts.RouteTemplate.getSequenceForItemRole(itemId, entryRoleCode)

    tools = BlueRidge.Tools.Tool.listForItem(itemId)
    toolId, toolCode, ambiguous = None, "", False
    if len(tools) == 1:
        toolId, toolCode = tools[0].get("Id"), tools[0].get("Code")
    elif len(tools) > 1:
        ambiguous = True

    cavities = BlueRidge.Tools.Tool.listCavitiesForItemTool(itemId, toolId) if toolId else []

    st = getState(session)
    st["session"] = {
        "lineLocationId": lineLocationId, "lineName": line.get("name") or "",
        "destinationLocationId": dest.get("DestinationLocationId"),
        "destinationName": dest.get("DestinationName") or "",
        "entryRoleCode": entryRoleCode, "entryRouteSequence": seq,
        "itemId": itemId, "partNumber": item.get("PartNumber") or "",
        "partDescription": item.get("Description") or "",
        "toolId": toolId, "toolCode": toolCode, "toolIsAmbiguous": ambiguous,
        "machineNumber": machineNumber or "",
    }
    st["toolOptions"], st["cavityOptions"] = tools, cavities
    st["rows"], st["totals"] = [], {"baskets": 0, "pieces": 0}
    _write(st, session)
    return {"Status": 1, "Message": "Session ready"}


@_guard
def addBasket(appUserId, terminalLocationId, session):
    """Create one migrated casting LOT. The scanned LTT becomes the LOT name
       verbatim -- no re-tagging. Returns {Status, Message, NewId}. A success
       Message may carry an advisory note (e.g. an over-size basket) --
       Item.MaxLotSize is informational only (2026-09-12): the LOT still
       creates, so callers must surface Message on success too, not just on
       failure."""
    appUserId = _u(appUserId)
    terminalLocationId = _u(terminalLocationId)

    st = getState(session)
    s, e = st["session"], st["entry"]

    lotName = (e.get("lotName") or "").strip()
    if not lotName:
        return {"Status": 0, "Message": "Scan the LTT barcode."}
    if e.get("toolCavityId") is None:
        return {"Status": 0, "Message": "Tap the cavity shown on the tag."}
    if e.get("castDate") is None:
        return {"Status": 0, "Message": "Set the cast date from the tag."}
    try:
        pieces = int(("%s" % e.get("pieceCount")).strip())
    except (ValueError, TypeError):
        return {"Status": 0, "Message": "Enter a whole number."}
    if pieces <= 0:
        return {"Status": 0, "Message": "Enter how many are in the basket."}

    res = BlueRidge.Lots.Lot.create({
        "itemId": s.get("itemId"),
        "lotOriginTypeId": BlueRidge.Lots.Lot.getOriginTypeIdByCode("Manufactured"),
        "currentLocationId": s.get("destinationLocationId"),
        "pieceCount": pieces,
        "toolId": s.get("toolId"),
        "toolCavityId": e.get("toolCavityId"),
        "entryRouteSequence": s.get("entryRouteSequence"),
        "castDate": e.get("castDate"),
    }, appUserId, terminalLocationId, lotName)
    if not (res and res.get("Status")):
        return res

    # Only the LTT and the count clear. Cavity and cast date LATCH, because
    # baskets come off the rack grouped by both.
    e["lotName"], e["pieceCount"] = "", ""
    rows = list(st.get("rows") or [])
    rows.insert(0, {"LotId": res.get("NewId"), "LotName": lotName,
                    "PartNumber": s.get("partNumber"), "CavityCode": e.get("cavityCode"),
                    "CastDate": e.get("castDate"), "PieceCount": pieces})
    st["entry"], st["rows"] = e, rows
    st["totals"] = {"baskets": len(rows),
                    "pieces": sum([r.get("PieceCount") or 0 for r in rows])}
    _write(st, session)
    return res


@_guard
def addBox(appUserId, terminalLocationId, session):
    """Create one received purchased-component LOT. The box has no LTT, so the
       LOT name is minted server-side and the supplier lot goes to
       VendorLotNumber. Returns {Status, Message, NewId}."""
    appUserId = _u(appUserId)
    terminalLocationId = _u(terminalLocationId)

    st = getState(session)
    s, p = st["session"], st["purchased"]

    itemId = p.get("itemId")
    if itemId is None:
        row = BlueRidge.Parts.Item.getByPartNumber((p.get("partNumber") or "").strip())
        if row is None:
            return {"Status": 0,
                    "Message": "No active item matches '%s'." % p.get("partNumber")}
        itemId = row.get("Id")
    try:
        qty = int(("%s" % p.get("qty")).strip())
    except (ValueError, TypeError):
        return {"Status": 0, "Message": "Enter a whole number."}
    if qty <= 0:
        return {"Status": 0, "Message": "Enter how many are in the box."}

    res = BlueRidge.Lots.Lot.create({
        "itemId": itemId,
        "lotOriginTypeId": BlueRidge.Lots.Lot.getOriginTypeIdByCode("Received"),
        "currentLocationId": s.get("destinationLocationId"),
        "pieceCount": qty,
        "vendorLotNumber": (p.get("vendorLot") or "").strip() or None,
    }, appUserId, terminalLocationId)
    if not (res and res.get("Status")):
        return res

    rows = list(st.get("rows") or [])
    rows.insert(0, {"LotId": res.get("NewId"), "LotName": res.get("MintedLotName"),
                    "PartNumber": p.get("partNumber"), "CavityCode": "",
                    "CastDate": None, "PieceCount": qty})
    st["purchased"] = {"partNumber": "", "partDescription": "", "itemId": None,
                       "qty": "", "vendorLot": ""}
    st["rows"] = rows
    st["totals"] = {"baskets": len(rows),
                    "pieces": sum([r.get("PieceCount") or 0 for r in rows])}
    _write(st, session)
    return res


@_guard
def voidEntry(lotId, appUserId, session):
    """Undo a mis-scanned entry. The LOT is CLOSED with a cutover-correction
       reason, never deleted -- nothing in the plant holds trustworthy inventory
       to reconcile against, so the correction itself is the record.

       Lots.Lot_UpdateStatus takes a LotStatusCode Id (@NewLotStatusId), not a
       code string, and only permits Good -> Closed in Phase 1 (every LOT this
       screen creates starts at Good, so that is exactly this transition)."""
    lotId = _u(lotId)
    appUserId = _u(appUserId)

    closedId = BlueRidge.Lots.Lot.getStatusIdByCode("Closed")
    if closedId is None:
        return {"Status": 0, "Message": "LOT status codes unavailable."}

    res = BlueRidge.Lots.Lot.updateStatus({
        "lotId": lotId,
        "newLotStatusId": closedId,
        "reason": "Voided during inventory cutover scan (mis-scan correction).",
    }, appUserId)
    if not (res and res.get("Status")):
        return res
    st = getState(session)
    rows = [r for r in (st.get("rows") or []) if r.get("LotId") != lotId]
    st["rows"] = rows
    st["totals"] = {"baskets": len(rows),
                    "pieces": sum([r.get("PieceCount") or 0 for r in rows])}
    _write(st, session)
    return res


# ---------------------------------------------------------------------------
# Camera scanning
# ---------------------------------------------------------------------------
# A native/barcode scan does not return to the component that asked for it --
# Perspective fires ONE project-wide session event. BlueRidge.Common.Barcode
# routes it here by the action's context {"screen": "cutover", "field": "..."}.
# See that module's header for the full path a scan takes.
#
# field key -> (state section, key in that section)
# field key -> (state section, key in that section, AIAG data identifier or None)
#
# MPP's purchased-part labels are AIAG / ANSI MH10.8.2: each barcode is prefixed
# with a DATA IDENTIFIER naming the field, and the label prints that identifier
# in parentheses beside the caption -- "Part Number (P)", "Quantity (Q)",
# "PO Number (A)". So the part-number barcode reads P90701-5R0-3000, not
# 90701-5R0-3000, and scanning it raw put a leading 'P' in the field (observed
# 2026-09-13; the operator deleted it by hand, which is how a near-identical
# part number got picked by mistake).
#
# Only strip an identifier the FIELD declares. A blind "drop the first letter"
# would corrupt any value that legitimately starts with one -- the LTT and the
# vendor lot are printed without identifiers and carry None here, so they are
# never touched.
_SCAN_TARGETS = {
    "lotName":            ("entry", "lotName", None),
    "purchasedPartNumber": ("purchased", "partNumber", "P"),
    "purchasedQty":       ("purchased", "qty", "Q"),
    "vendorLot":          ("purchased", "vendorLot", None),
}

# Fields bound to a numeric-entry-field rather than a text-field. A scan arrives
# as text; writing "5000 EA" into props.value renders as nothing useful, so the
# digits are taken and the rest dropped.
#
# ASSUMPTION, flagged 2026-09-13: a quantity barcode is digits, possibly with a
# prefix or a unit suffix. If MPP's labels encode something structured (a
# GS1 AI, a check digit) this is the place that has to learn it -- it is
# deliberately one line so replacing it is cheap.
_SCAN_NUMERIC = ("purchasedQty",)


def applyScan(session, text, field):
    """Put one scanned value into the field that asked for it.

       This is a read-modify-write of nested session state, which is exactly
       the shape that silently loses the write unless getState() has detached
       the property tree first -- see _plain(). Do not "simplify" this to
       session.custom.cutover.entry.lotName = text; that direct form does work,
       but it diverges from every other mutation on this screen and the next
       person to add a wholesale write beside it would clobber it."""
    target = _SCAN_TARGETS.get(field)
    if target is None:
        BlueRidge.Common.Util.log(
            "applyScan: unknown field '%s' (known: %s)"
            % (field, ", ".join(sorted(_SCAN_TARGETS))), level="warn")
        return {"Status": 0, "Message": "Nothing on this screen scans into '%s'." % field}

    section, key, dataId = target

    # Strip this field's AIAG data identifier when the scan carries it. Guarded
    # on a non-empty remainder so a one-character scan cannot become "".
    raw = text
    if dataId and text.startswith(dataId) and len(text) > len(dataId):
        text = text[len(dataId):].strip()

    value = text
    if field in _SCAN_NUMERIC:
        digits = "".join([c for c in text if c.isdigit()])
        if not digits:
            return {"Status": 0, "Message": "That barcode has no number in it."}
        value = int(digits)
    st = getState(session)
    st[section][key] = value
    _write(st, session)
    # WARN, not debug: the raw scan is the only record of what the barcode
    # actually carried, and the barcode's shape is exactly what is still being
    # learned here (an MPP part label was found to carry a 'P' prefix on
    # 2026-09-13). Drop this to debug once the label formats are settled.
    BlueRidge.Common.Util.log(
        "applyScan %s.%s <- %r (raw scan %r)" % (section, key, value, raw),
        level="warn")
    return {"Status": 1, "Message": "Scanned."}


def stepCastDate(days, session):
    """Move the cast date by whole days, capped at today. Seeded from the last
       basket scanned, so consecutive baskets are zero or one tap."""
    days = _u(days)
    st = getState(session)
    cur = st["entry"].get("castDate") or system.date.now()
    nxt = system.date.addDays(cur, days)
    if system.date.isAfter(system.date.midnight(nxt),
                           system.date.midnight(system.date.now())):
        return cur
    st["entry"]["castDate"] = nxt
    _write(st, session)
    return nxt

