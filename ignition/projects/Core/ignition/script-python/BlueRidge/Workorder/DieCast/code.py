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
    """Proposed per-cavity-lot good-piece split for a shift's gross shot count
       (Workorder.DieCast_GetShiftOutputBreakdown) -- the read-side proposal the
       shift-end recording flow presents to the operator for confirmation/
       adjustment before recordShiftOutput writes the contribution rows.
       Returns list[dict] ([] when the tool has no lots open/contributing this
       shift)."""
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
