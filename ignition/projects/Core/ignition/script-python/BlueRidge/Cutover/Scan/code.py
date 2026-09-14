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
# =============================================================================

import java.lang


def _u(value):
    """Local shorthand for extractQualifiedValues. Every public function here
       deep-unwraps its inputs at entry -- a value arriving from a
       Perspective binding (a dropdown's props.value, a button's payload) is
       a QualifiedValue / Java Map, not a bare Python value, and an `is None`
       guard does not catch it."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


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
            BlueRidge.Common.Util.log("getState: session read failed: %s" % str(e))
            raw = None
    else:
        BlueRidge.Common.Util.log(
            "getState called with no session -- returning the empty shape. "
            "Callers must pass the session object.")
    st = _u(raw) or {}
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


def stepCastDate(days, session):
    """Move the cast date by whole days, capped at today. Seeded from the last
       basket scanned, so consecutive baskets are zero or one tap."""
    days = _u(days)
    BlueRidge.Common.Util.log("stepCastDate ENTER days=%s" % days)
    st = getState(session)
    cur = st["entry"].get("castDate") or system.date.now()
    nxt = system.date.addDays(cur, days)
    if system.date.isAfter(system.date.midnight(nxt),
                           system.date.midnight(system.date.now())):
        return cur
    st["entry"]["castDate"] = nxt
    _write(st, session)
    # Read straight back through the same path the bindings use. If this does not
    # echo what we just wrote, the session-prop write was dropped -- which is what
    # three consecutive taps all writing the same day already implies.
    back = getState(session)["entry"].get("castDate")
    BlueRidge.Common.Util.log(
        "stepCastDate WROTE %s ; READBACK %s ; match=%s ; type=%s"
        % (nxt, back, (back == nxt), type(nxt)))
    return nxt
