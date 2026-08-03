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


def recordShiftOutput(data, appUserId=None, terminalLocationId=None):
    """Record the operator-confirmed shift output (Workorder.DieCastShiftOutput_Record):
       fans the per-cavity-lot lines (and any tool-wide shot-loss) into the open
       accumulator baskets. data carries shiftId, toolId, lines ([{lotId,
       pieceDelta, scrapLines: [{defectCodeId, quantity}, ...]}, ...], JSON-
       encoded here for the proc's required @LinesJson), shotLoss ([{defectCodeId,
       quantity}, ...], JSON-encoded for the optional @ShotLossJson). Returns
       {Status, Message, NewId} (NewId is always None -- this proc fans out to
       N lots, there is no single 'the' new id)."""
    BlueRidge.Common.Util.log(
        "recordShiftOutput data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    lines = _u(d.get("lines")) or []
    shotLoss = _u(d.get("shotLoss")) or []
    params = {
        "shiftId":            d.get("shiftId"),
        "toolId":             d.get("toolId"),
        "linesJson":          BlueRidge.Common.Util.convertWrapperObjectToJson(lines),
        "shotLossJson":       BlueRidge.Common.Util.convertWrapperObjectToJson(shotLoss) if shotLoss else None,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/DieCastShiftOutput_Record", params)


def mapBreakdownInstances(rows):
    """Cavity-lot row instances for DieCastBody's shift-output repeater (Task
       12): one instance per Workorder.DieCast_GetShiftOutputBreakdown row,
       camelCased for the CavityLotRow sub-view's params. Presentation only --
       the proposed split and headroom are computed in SQL; this just
       reshapes columns (mirrors Lots.Lot.mapTrimInventoryInstances). Bind as
       a script transform on a property path to view.custom.breakdown (NOT a
       runScript call -- passing the already-fetched list through a runScript
       arg hits the QualifiedValue[] array bug, feedback_ignition_runscript_
       list_arg_qv_array). Returns list[dict] ([] on empty/None)."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    out = []
    for r in rows:
        r = r or {}
        out.append({
            "toolCavityId":       r.get("ToolCavityId"),
            "cavityNumber":       r.get("CavityNumber") or "",
            "lotId":              r.get("LotId"),
            "lotName":            r.get("LotName") or "",
            "isOpen":             bool(r.get("IsOpen")),
            "priorGoodThisShift": r.get("PriorGoodThisShift") or 0,
            "proposedGood":       r.get("ProposedGood") or 0,
            "maxHeadroom":        r.get("MaxHeadroom") or 0,
        })
    return out


def registerShotLoss(toolId, shiftId, defectCodeId, quantity, appUserId=None, terminalLocationId=None):
    """Record a shot-level defect (e.g. a short shot on the whole cycle) against
       EVERY currently-open basket on a tool -- builds a one-element shotLoss
       line with no per-cavity lines and calls recordShiftOutput /
       Workorder.DieCastShiftOutput_Record. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "registerShotLoss toolId=%s shiftId=%s defectCodeId=%s quantity=%s"
        % (toolId, shiftId, defectCodeId, quantity)
    )
    data = {
        "shiftId":  _u(shiftId),
        "toolId":   _u(toolId),
        "lines":    [],
        "shotLoss": [{"defectCodeId": _u(defectCodeId), "quantity": _u(quantity)}],
    }
    return recordShiftOutput(data, appUserId=appUserId, terminalLocationId=terminalLocationId)
