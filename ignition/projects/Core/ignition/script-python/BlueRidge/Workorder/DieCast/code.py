"""BlueRidge.Workorder.DieCast - thin access to the die-cast per-cavity
   shift-output procs (Workorder.DieCast_GetShiftOutputBreakdown /
   Workorder.DieCastShiftOutput_Record). Wrappers only; the auto-breakdown
   math, per-line/shot-loss validation and the contribution-ledger + additive
   -scrap fan-out all live in the procs.

   Public surface:
     getShiftOutputBreakdown(toolId, shiftId, grossShots)                    -> list[dict]
     recordShiftOutput(data, appUserId=None, terminalLocationId=None)        -> {Status, Message, NewId}
     registerShotLoss(toolId, shiftId, defectCodeId, quantity,
                       appUserId=None, terminalLocationId=None)              -> {Status, Message, NewId}"""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getShiftOutputBreakdown(toolId, shiftId, grossShots):
    """Proposed per-cavity-lot good-piece counts for an entered shot count
       (Workorder.DieCast_GetShiftOutputBreakdown) -- the read-side proposal the
       recording flow presents to the operator for confirmation/adjustment
       before recordShiftOutput writes the contribution rows. Returns list[dict]
       ([] when the tool has no lots open/contributing this shift).

       grossShots IS ADDITIVE -- IT IS THIS ENTRY, NOT A SHIFT TOTAL (proc v1.3,
       2026-08-19). Operators count shots SINCE THEIR LAST ENTRY, so the number
       passed here is already the increment. Gross is die-wide and each cavity
       yields one part per shot, so every OPEN lot proposes the same entered
       number; a lot already released this shift keeps its recorded credit.
       Nothing is apportioned and no prior claim is subtracted -- the old
       cumulative "remainder of gross" behaviour zeroed the proposal whenever
       prior claims on a cavity exceeded the entry."""
    toolId = _u(toolId)
    shiftId = _u(shiftId)
    grossShots = _u(grossShots)
    BlueRidge.Common.Util.log(
        "getShiftOutputBreakdown toolId=%s shiftId=%s grossShots=%s"
        % (toolId, shiftId, grossShots)
    )
    if toolId is None or shiftId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "workorder/DieCast_GetShiftOutputBreakdown",
        {"toolId": toolId, "shiftId": shiftId, "grossShots": grossShots},
    )


def recordShiftOutput(data, appUserId=None, terminalLocationId=None, cellLocationId=None):
    """Record the operator-confirmed shift output (Workorder.DieCastShiftOutput_Record):
       fans the per-cavity-lot lines (and any tool-wide shot-loss) into the open
       accumulator baskets. data carries shiftId, toolId, lines ([{lotId,
       pieceDelta, scrapLines: [{defectCodeId, quantity}, ...]}, ...], JSON-
       encoded here for the proc's required @LinesJson), shotLoss ([{defectCodeId,
       quantity}, ...], JSON-encoded for the optional @ShotLossJson), and the
       optional cellLocationId (FAT #19: the die-cast MACHINE/cell location the
       parts were added at -- stamped on the DieCastPieceContributed audit op's
       @LocationId; the explicit kwarg wins, else data['cellLocationId']).
       Returns {Status, Message, NewId} (NewId is always None -- this proc fans
       out to N lots, there is no single 'the' new id)."""
    BlueRidge.Common.Util.log(
        "recordShiftOutput data=%s appUserId=%s terminalLocationId=%s cellLocationId=%s"
        % (data, appUserId, terminalLocationId, cellLocationId)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    if cellLocationId is None:
        cellLocationId = d.get("cellLocationId")
    lines = _u(d.get("lines")) or []
    shotLoss = _u(d.get("shotLoss")) or []
    params = {
        "shiftId":            d.get("shiftId"),
        "toolId":             d.get("toolId"),
        "linesJson":          BlueRidge.Common.Util.convertWrapperObjectToJson(lines),
        "shotLossJson":       BlueRidge.Common.Util.convertWrapperObjectToJson(shotLoss) if shotLoss else None,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "grossShots":         d.get("grossShots"),
        "cellLocationId":     cellLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/DieCastShiftOutput_Record", params)


def cavityDisplayName(cavityNumber, cavityDescription):
    """The operator-facing name of a die cavity.

       DECISION (2026-08-19, backlog 2.2): Tools.ToolCavity.Description IS the
       cavity's name; Tools.ToolCavity.CavityNumber is only its ordinal (the
       (ToolId, CavityNumber) uniqueness key). So the Description wins whenever
       it is populated, and the bare ordinal 'Cavity <N>' is the fallback for a
       cavity nobody has named yet. Same source the Open-Basket cavity dropdown
       already reads (Parts.Tool.getCavitiesForDropdown), so the two surfaces
       agree on what a cavity is called."""
    desc = ("%s" % (cavityDescription or "")).strip()
    if desc:
        return desc
    return "Cavity %s" % (cavityNumber if cavityNumber is not None else "?")


def mapBreakdownInstances(rows):
    """Cavity-lot row instances for DieCastBody's shift-output repeater (Task
       12): one instance per Workorder.DieCast_GetShiftOutputBreakdown row,
       camelCased for the CavityLotRow sub-view's params. Presentation only --
       the proposed split and headroom are computed in SQL; this just
       reshapes columns (mirrors Lots.Lot.mapTrimInventoryInstances). Bind as
       a script transform on a property path to view.custom.breakdown (NOT a
       runScript call -- passing the already-fetched list through a runScript
       arg hits the QualifiedValue[] array bug, feedback_ignition_runscript_
       list_arg_qv_array). Returns list[dict] ([] on empty/None).

       Released/closed lots are already filtered out upstream by the view's
       computeBreakdown (backlog 2.4) -- openRowsOnly below is the same filter,
       re-applied here so a stray closed row can never reach the row view."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    out = []
    for r in rows:
        r = r or {}
        if not r.get("IsOpen"):
            continue
        num = r.get("CavityNumber")
        desc = r.get("CavityDescription") or ""
        out.append({
            "toolCavityId":       r.get("ToolCavityId"),
            "cavityNumber":       num if num is not None else "",
            "cavityDescription":  desc,
            "cavityName":         cavityDisplayName(num, desc),
            "cavityOrdinalLabel": "Cavity %s" % (num if num is not None else "?"),
            "hasCavityName":      bool(("%s" % desc).strip()),
            "lotId":              r.get("LotId"),
            "lotName":            r.get("LotName") or "",
            "isOpen":             bool(r.get("IsOpen")),
            "priorGoodThisShift": r.get("PriorGoodThisShift") or 0,
            "proposedGood":       r.get("ProposedGood") or 0,
            "maxHeadroom":        r.get("MaxHeadroom") or 0,
        })
    return out


def openRowsOnly(rows):
    """The still-OPEN baskets from a DieCast_GetShiftOutputBreakdown result.

       backlog 2.4: operators recording shift output only need the baskets they
       can still add to; a basket released mid-shift is reference-only noise.

       Filtered HERE (read side) rather than in the proc on purpose: the proc's
       documented contract is 'one row per LOT open at ANY point during the
       shift window', which the reconciliation/assertion consumers (the 0045
       test suite's multi-lot cavity-handoff assertions) depend on, and which
       is genuinely the right answer for a shift-reconciliation read. Narrowing
       the proc would be a semantic regression for every other caller, so the
       screen narrows its own view of it instead."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    return [r for r in rows if r and r.get("IsOpen")]


def priorGoodSnapshot(rows):
    """{lotId(str): PriorGoodThisShift(int)} for the rows a breakdown preview
       was computed from -- the concurrency baseline for backlog 3.3 (two
       terminals on ONE die cast machine). submitShiftOutput re-reads the
       breakdown and compares against this snapshot; any difference means a
       PEER terminal recorded output for the same (tool, shift) since the
       preview was computed, so the preview's proposed split is stale and
       submitting it would double-count."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    out = {}
    for r in rows:
        r = r or {}
        if r.get("LotId") is None:
            continue
        out["%s" % r.get("LotId")] = BlueRidge.Common.Util.toIntOrNone(
            r.get("PriorGoodThisShift")) or 0
    return out


def registerShotLoss(toolId, shiftId, defectCodeId, quantity, appUserId=None, terminalLocationId=None):
    """Record a shot-level defect (e.g. a short shot on the whole cycle) against
       EVERY currently-open basket on a tool -- builds a one-element shotLoss
       line with no per-cavity lines and calls recordShiftOutput /
       Workorder.DieCastShiftOutput_Record. Returns {Status, Message, NewId}.

       backlog 3.2 (2026-08-19): the lost shots now ALSO advance the die's
       materialized shot counter (Tools.Tool.ShotCount). A shot-loss quantity is
       a count of CYCLES the die ran and lost -- one lost shot spoils one piece
       in every open cavity, which is exactly why the proc fans the RejectEvent
       across every open lot -- so those cycles are die wear and must be counted.
       They are threaded through the existing @GrossShots parameter, which is
       the proc's one shot-counter increment path (no SQL change needed).

       NOTE FOR REVIEW: the 2026-08-04 tool-shot-count design deliberately chose
       'shot-loss path does NOT increment -- gross already counts those cycles,
       a separate bump would double-count'. That holds only if the shift-end
       gross the operator types INCLUDES the cycles they already registered as
       shot loss. MPP reports the counter not moving, so the field convention is
       evidently the other way round (gross = cycles not already accounted for).
       If MPP instead reads gross straight off the machine counter, this bump
       double-counts and should be reverted rather than patched -- flagged for
       Hunter."""
    BlueRidge.Common.Util.log(
        "registerShotLoss toolId=%s shiftId=%s defectCodeId=%s quantity=%s"
        % (toolId, shiftId, defectCodeId, quantity)
    )
    qty = BlueRidge.Common.Util.toIntOrNone(_u(quantity))
    data = {
        "shiftId":    _u(shiftId),
        "toolId":     _u(toolId),
        "lines":      [],
        "shotLoss":   [{"defectCodeId": _u(defectCodeId), "quantity": qty}],
        "grossShots": qty,
    }
    return recordShiftOutput(data, appUserId=appUserId, terminalLocationId=terminalLocationId)

# =============================================================================
# Bulk open of die-cast baskets (backlog 3.4, 2026-08-19)
# -----------------------------------------------------------------------------
# One row per ACTIVE cavity of the mounted die, each row carrying its own part
# selection + scanned LTT, submitted together. Replaces the one-basket-at-a-time
# Open Basket form on DieCastBody.
#
# DECISION - per-row calls, NOT a bulk stored procedure:
#   * Lots.DieCastLot_Open already owns the whole open contract (9 validations
#     plus the LOT / LotStatusHistory / LotGenealogyClosure / LotMovement /
#     audit mint). A bulk proc could not EXEC it -- CLAUDE.md's FDS-11-011 rule:
#     a proc captured via INSERT-EXEC may not EXEC another status-row proc -- so
#     it would have to INLINE the whole thing as a commented mirror, creating a
#     second copy of the open logic that must stay in sync forever.
#   * PARTIAL SUBMISSION is a hard requirement (an operator rarely has all N
#     tickets). Per-row calls give it for free: each call is its own
#     transaction, so cavity 3 failing leaves 1 and 2 committed and 4 and 5
#     still attempted. A single-transaction bulk proc would have to choose
#     between all-or-nothing (wrong) or per-row SAVEPOINT bookkeeping (complex).
#   * Per-row {Status, Message} IS the per-row outcome the screen needs, in the
#     proc's own precise wording, with no second message vocabulary to maintain.
#   * N is a die's cavity count (1-10 here), submitted once per changeover, so N
#     round-trips costs nothing.
#   Cost accepted: no cross-row atomicity. That is the requirement, not a defect.
#
# The ONE thing per-row calls cannot see is the batch itself, so the two
# batch-level gates live here, ahead of every write:
#   * duplicate LTT across rows  -> reject the WHOLE submission, write nothing
#     (a repeated ticket means a mis-scan; you cannot tell which row is right).
#   * nothing filled in at all   -> reject, write nothing.
# Everything else is per-row and never blocks a sibling row.
# =============================================================================


def getBulkOpenRowInstances(toolId, seedToken=None, _optionsToken=None):
    """Bulk-open repeater instances for DieCastBody: ONE row per non-deprecated
       ACTIVE cavity of the mounted die, in CavityNumber order (the order
       Tools.ToolCavity_ListActiveByTool returns).

       A cavity that already holds an open accumulator basket comes back with
       alreadyOpen=True plus the open LOT's name/count; the row renders
       read-only and the screen never offers it, because Lots.DieCastLot_Open
       enforces one-open-basket-per-(Tool, ToolCavity) server-side and would
       reject it anyway.

       itemId / scannedLtt / resultState / resultMessage / itemOptions come back
       EMPTY here and are overlaid by the repeater binding's script transform
       from the view's own bulkOpenDraft / bulkOpenResult / itemOptions -- those
       are container props and must never cross a runScript arg
       (feedback_ignition_immutable_map_unwrap).

       seedToken is echoed into every instance so the row view can tell a
       rebuild from a re-render and reseed its local inputs. _optionsToken is
       ignored: the binding passes len(itemOptions) purely so the expression
       re-evaluates once the item dropdown's options arrive.

       Scalar args only, fetches inside. Returns list[dict] ([] when no die is
       mounted or the die has no active cavities)."""
    toolId = _u(toolId)
    seedToken = _u(seedToken)
    BlueRidge.Common.Util.log("getBulkOpenRowInstances toolId=%s" % toolId)
    if toolId is None:
        return []
    try:
        cavities = BlueRidge.Common.Db.execList(
            "parts/ToolCavity_ListActiveByTool", {"toolId": toolId}) or []
    except Exception as e:
        BlueRidge.Common.Util.log("getBulkOpenRowInstances cavities failed: %s" % str(e))
        return []
    try:
        openRows = BlueRidge.Lots.Lot.getOpenByTool(toolId) or []
    except Exception as e:
        BlueRidge.Common.Util.log("getBulkOpenRowInstances openByTool failed: %s" % str(e))
        openRows = []
    openByCavity = {}
    for r in openRows:
        r = r or {}
        openByCavity["%s" % r.get("ToolCavityId")] = r

    out = []
    for c in (cavities or []):
        c = c or {}
        cavityId = c.get("Id")
        num = c.get("CavityNumber")
        existing = openByCavity.get("%s" % cavityId)
        out.append({
            "toolCavityId":       cavityId,
            "cavityNumber":       num if num is not None else "",
            "cavityName":         cavityDisplayName(num, c.get("Description")),
            "cavityOrdinalLabel": "Cavity %s" % (num if num is not None else "?"),
            "alreadyOpen":        existing is not None,
            "openLotName":        (existing or {}).get("LotName") or "",
            "openPieceCount":     (existing or {}).get("PieceCount") or 0,
            # overlaid by the repeater transform -- shaped here so every key the
            # row's params traverse always exists (predeclare-bound-props rule).
            "itemId":             None,
            "scannedLtt":         "",
            "resultState":        "",
            "resultMessage":      "",
            "itemOptions":        [],
            "seedToken":          seedToken if seedToken is not None else 0,
        })
    return out


def _bulkOpenIntents(rows):
    """Normalize the raw draft rows into the submission set.

       A row counts as SUBMITTED as soon as the operator touched either field.
       A completely untouched row is not part of the submission at all (it is
       not a failure -- the operator simply had no ticket for that cavity); a
       half-filled row IS submitted and fails on its missing half, per the
       requirement that a row with no part is a validation failure and not a
       silent skip. Returns list[dict{toolCavityId, itemId, lotName}]."""
    out = []
    for r in (rows or []):
        r = _u(r) or {}
        cavityId = r.get("toolCavityId")
        if cavityId is None:
            continue
        itemId = r.get("itemId")
        lotName = ("%s" % (r.get("scannedLtt") or "")).strip()
        if itemId is None and lotName == "":
            continue
        out.append({"toolCavityId": cavityId, "itemId": itemId, "lotName": lotName})
    return out


def submitBulkOpen(rows, toolId, cellLocationId, appUserId=None, terminalLocationId=None):
    """Open every filled cavity row in one operator action.

       rows: [{toolCavityId, itemId, scannedLtt}, ...] straight off the view's
       bulkOpenDraft (already extractQualifiedValues'd by the caller).

       Returns
         {Status, Message, Rejected, Opened, Failed,
          Rows: {"<toolCavityId>": {state: "ok"|"error", message: str}}}
       Status is 1 when at least one basket opened. Rejected=True means a
       batch-level gate fired and NOTHING was written."""
    rows = _u(rows) or []
    toolId = _u(toolId)
    cellLocationId = _u(cellLocationId)
    appUserId = _u(appUserId)
    terminalLocationId = _u(terminalLocationId)
    BlueRidge.Common.Util.log(
        "submitBulkOpen toolId=%s cellLocationId=%s rows=%s"
        % (toolId, cellLocationId, len(rows)))

    empty = {"Status": 0, "Message": "", "Rejected": True,
             "Opened": 0, "Failed": 0, "Rows": {}}

    intents = _bulkOpenIntents(rows)
    if not intents:
        empty["Message"] = ("Nothing to open - scan a LTT and pick a part on at "
                            "least one cavity row first.")
        return empty
    if toolId is None or cellLocationId is None:
        empty["Message"] = ("No die is mounted on this cell - a basket can only "
                            "be opened against a mounted die.")
        return empty
    if appUserId is None:
        empty["Message"] = "No operator is signed in at this terminal."
        return empty

    # ---- batch gate: the same LTT scanned onto two cavities. Reject the whole
    # submission BEFORE any write -- a repeated ticket is a mis-scan and there
    # is no way to know which of the two rows was the intended one.
    counts = {}
    for i in intents:
        if i["lotName"]:
            counts[i["lotName"]] = counts.get(i["lotName"], 0) + 1
    dupes = sorted([k for k in counts.keys() if counts[k] > 1])
    if dupes:
        empty["Message"] = ("LTT %s scanned on more than one cavity - nothing "
                            "was opened. Correct the duplicate and submit again."
                            % ", ".join(dupes))
        return empty

    # ---- per-row open. Each call is its own transaction: a failure here never
    # rolls back a sibling row that already committed.
    results = {}
    opened = 0
    failed = 0
    templateCache = {}
    for i in intents:
        key = "%s" % i["toolCavityId"]
        if not i["lotName"]:
            results[key] = {"state": "error", "message": "Scan this basket's LTT."}
            failed += 1
            continue
        if i["itemId"] is None:
            results[key] = {"state": "error", "message": "Select the part for this cavity."}
            failed += 1
            continue
        # Same gate the single-open form applied (2026-07-06 Jacques): a part
        # with no die-cast operation template on its route cannot run. The proc
        # rejects it too, but with a route-shaped message; keep the operator
        # wording. Cached so a family die does not re-query per row.
        if i["itemId"] not in templateCache:
            templateCache[i["itemId"]] = BlueRidge.Parts.OperationTemplate.getActiveTemplateIdForRoute(
                i["itemId"], "DieCast")
        if templateCache[i["itemId"]] is None:
            results[key] = {"state": "error",
                            "message": "This part has no die-cast operation template on its route."}
            failed += 1
            continue
        res = BlueRidge.Lots.Lot.openDieCast({
            "itemId":             i["itemId"],
            "currentLocationId":  cellLocationId,
            "toolId":             toolId,
            "toolCavityId":       i["toolCavityId"],
            "lotName":            i["lotName"],
            "appUserId":          appUserId,
            "terminalLocationId": terminalLocationId,
        }) or {}
        ok = bool(res.get("Status"))
        results[key] = {"state": "ok" if ok else "error",
                        "message": res.get("Message") or ""}
        if ok:
            opened += 1
        else:
            failed += 1

    if failed == 0:
        message = "Opened %s basket(s)." % opened
    elif opened == 0:
        message = "No baskets opened - %s row(s) failed. See each row for why." % failed
    else:
        message = ("Opened %s of %s basket(s) - %s row(s) failed and were left "
                   "untouched. See each row for why." % (opened, opened + failed, failed))
    return {"Status": 1 if opened else 0, "Message": message, "Rejected": False,
            "Opened": opened, "Failed": failed, "Rows": results}
