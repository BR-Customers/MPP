# =============================================================================
# Project Library:  BlueRidge.Workorder.DieCastReconciliation
#
# Thin glue for the die cast shift reconciliation screen: one function per
# named query, nothing else.
#
# THERE IS NO DOMAIN LOGIC IN THIS MODULE AND NONE MAY BE ADDED. The blocking
# checks, the totals arithmetic and the confirmation's change groups are all
# decided in SQL -- the Save computes them, and its @PreviewOnly = 1 mode hands
# them back as PlanJson. A helper here that "just totals the rejects" is the
# start of a second implementation of the Save, and the first time the two
# disagree a correctly entered press sheet becomes unsaveable.
#
# Layer: View -> this module -> BlueRidge.Common.Db.* -> system.db.*
# =============================================================================

# Fully-shaped empties. A binding-bound custom property is REPLACED by its
# binding's result the instant it evaluates, so a shaped default on the view is
# not enough -- the source has to return the full shape on the empty path too,
# or a nested read errors the component. (feedback_ignition_predeclare_bound_custom_props)
_EMPTY_HEADER = {
    "ShiftId": None, "ShiftLabel": "", "StartEt": None, "EndEt": None, "IsOpen": False,
    "CellLocationId": None, "PressCode": "", "PressName": "",
    "ToolId": None, "AssetNumber": "", "DieName": "",
    "ActiveCavities": 0, "DieShotCount": 0,
    "RecordedTotalShots": 0, "RecordedWarmUpShots": 0,
    "RecordedNoGood": 0, "RecordedGood": 0,
    "HasShiftEndNumber": False, "Stamp": "",
    "LastReconciledAtEt": None, "LastReconciledBy": "",
}

_EMPTY_LTT = {
    "Ltt": "", "Result": "Error", "LotId": None, "ToolCavityId": None, "CavityCode": "",
    "ItemId": None, "PartNumber": "", "PieceCount": 0,
    "Message": "The LTT could not be checked. Try again.",
}


def listShifts(cellLocationId, days=7):
    """The landing list for one press: one row per shift x die."""
    BlueRidge.Common.Util.log("cellLocationId=%s days=%s" % (cellLocationId, days))
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastShiftReconciliation_ListShifts",
        {"cellLocationId": cellLocationId, "days": days})


def listUnreconciled(days=7):
    """Plant-wide. Carries BOTH claims: IsAlerting = 1 is a real finding
    (production recorded, no shift-end number); IsAlerting = 0 is an idle die,
    which fires over every weekend and prep window. The TILE COUNTS ONLY THE
    ALERTING ROWS -- merging the two is explicitly forbidden (spec sec 6.4)."""
    BlueRidge.Common.Util.log("days=%s" % days)
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastShift_ListUnreconciled", {"days": days})


def listFlagged(days=7):
    """listUnreconciled filtered to the ALERTING claim, which is the only thing
    the dashboard tile and its drill-through ever count.

    It lives here rather than in a per-view script transform because BOTH the
    landing tile and the supervisor dashboard tile need exactly this list, and
    two copies of the filter is two places for the two tiles to drift apart and
    disagree about the same number. Projection, not domain logic -- IsAlerting
    is decided in SQL and this only selects on it."""
    return [r for r in listUnreconciled(days) if r.get("IsAlerting")]


def getHeader(shiftId, cellLocationId, toolId):
    """The banner, the Recorded column, die life, the active-cavity count and
    the stale-guard Stamp. None when the shift/press/die does not exist."""
    BlueRidge.Common.Util.log("shiftId=%s cell=%s tool=%s" % (shiftId, cellLocationId, toolId))
    return BlueRidge.Common.Db.execOne(
        "workorder/DieCastShiftReconciliation_GetHeader",
        {"shiftId": shiftId, "cellLocationId": cellLocationId, "toolId": toolId})


def getHeaderOrEmpty(shiftId, cellLocationId, toolId):
    """Binding-only sibling of getHeader: ALWAYS the full shape, so a view that
    traverses view.custom.header.ShiftLabel never reads through a None."""
    row = getHeader(shiftId, cellLocationId, toolId)
    if not row:
        return dict(_EMPTY_HEADER)
    out = dict(_EMPTY_HEADER)
    out.update(row)
    return out


def _listThree(nq, shiftId, cellLocationId, toolId):
    return BlueRidge.Common.Db.execList(
        nq, {"shiftId": shiftId, "cellLocationId": cellLocationId, "toolId": toolId})


def listEntries(shiftId, cellLocationId, toolId):
    """What is on record, grouped into entries. ContributionIds / RejectIds are
    comma-separated id lists and are what a move acts on -- the grouping itself
    is presentation only, so a wrong grouping can never produce a wrong write."""
    return _listThree("workorder/DieCastShiftReconciliation_ListEntries",
                      shiftId, cellLocationId, toolId)


def listLots(shiftId, cellLocationId, toolId):
    return _listThree("workorder/DieCastShiftReconciliation_ListLots",
                      shiftId, cellLocationId, toolId)


def listRejects(shiftId, cellLocationId, toolId):
    """GRAIN IS (DefectCode, Part, Approver). One defect code on one part
    approved by two people is TWO rows, each carrying only that person's
    quantity; an unapproved line is its own NULL-approver row. A per-defect
    total is summed on the screen and never read off one row. Do not flatten
    this -- the earlier grain named the wrong person."""
    return _listThree("workorder/DieCastShiftReconciliation_ListRejects",
                      shiftId, cellLocationId, toolId)


def listMoveTargets(shiftId, cellLocationId, toolId):
    """The closed shifts within two of this one. LEGITIMATELY RETURNS FEWER
    THAN FOUR ROWS at the ends of history -- render whatever arrives, never pad
    and never pre-select."""
    return _listThree("workorder/DieCastShiftReconciliation_ListMoveTargets",
                      shiftId, cellLocationId, toolId)


def listCavities(shiftId, toolId):
    """TWO parameters -- this proc has no @CellLocationId, unlike its siblings.
    The die alone identifies the cavity set; the press adds nothing.

    The die's cavities and parts AS OF THE SHIFT -- the same set the Save
    resolves. Feeds the reject block's Part dropdown and the LTT bar's cavity
    picker. Do not substitute a resolved-as-of-now list from anywhere else:
    the Save would then refuse a cavity the screen offered."""
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastShiftReconciliation_ListCavities",
        {"shiftId": shiftId, "toolId": toolId})


def listReasons():
    return BlueRidge.Common.Db.execList("workorder/DieCastReconciliationReason_List")


def reasonOptions():
    """[{label, value}] for ia.input.dropdown."""
    return [{"label": r.get("Name"), "value": r.get("Id")} for r in listReasons()]


def resolveLtt(ltt, toolId):
    """Called AS EACH LTT IS TYPED OR SCANNED, never at save.

    Result is one of: NewLot | SameDie | Foreign | Invalid | Error.
    Message is operator-ready prose; render it verbatim rather than composing
    a second sentence from the parts."""
    BlueRidge.Common.Util.log("ltt=%s toolId=%s" % (ltt, toolId))
    row = BlueRidge.Common.Db.execOne(
        "lots/DieCastLot_ResolveLtt", {"ltt": ltt, "toolId": toolId})
    if not row:
        out = dict(_EMPTY_LTT)
        out["Ltt"] = ltt
        return out
    out = dict(_EMPTY_LTT)
    out.update(row)
    return out


def _saveParams(payload, appUserId, terminalLocationId, previewOnly):
    d = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
    return {
        "shiftId":            d.get("shiftId"),
        "cellLocationId":     d.get("cellLocationId"),
        "toolId":             d.get("toolId"),
        "reasonId":           d.get("reasonId"),
        "note":               d.get("note"),
        "actualJson":         system.util.jsonEncode(d.get("actual") or {}),
        "movesJson":          system.util.jsonEncode(d.get("moves") or []),
        "lotsJson":           system.util.jsonEncode(d.get("lots") or []),
        "rejectsJson":        system.util.jsonEncode(d.get("rejects") or []),
        "loadedStamp":        d.get("loadedStamp"),
        "appUserId":          BlueRidge.Common.Util.requireAppUserId(appUserId),
        "terminalLocationId": terminalLocationId,
        "previewOnly":        previewOnly,
    }


def preview(payload, appUserId, terminalLocationId):
    """Run every check and build the plan WITHOUT writing. Returns the same
    four columns as save; PlanJson is the plan that WOULD be applied.

    A preview binds because the stale guard makes it bind: between a preview
    and its save either nothing moved and the plan is identical, or the save
    refuses outright. There is no third outcome. So the confirmation panel may
    render this plan as fact."""
    return BlueRidge.Common.Db.execMutation(
        "workorder/DieCastShiftReconciliation_Save",
        _saveParams(payload, appUserId, terminalLocationId, True))


def save(payload, appUserId, terminalLocationId, previewOnly=False):
    """The one write in this feature."""
    # Log from the EXTRACTED params, never from the raw payload: a payload from
    # a view can be a QualifiedValue or a Perspective ImmutableMap, and .get()
    # raises on both. _saveParams does the extraction; borrowing its result
    # keeps this trace safe without extracting twice.
    params = _saveParams(payload, appUserId, terminalLocationId, bool(previewOnly))
    BlueRidge.Common.Util.log("shiftId=%s previewOnly=%s"
                              % (params.get("shiftId"), previewOnly))
    return BlueRidge.Common.Db.execMutation(
        "workorder/DieCastShiftReconciliation_Save", params)


def planFrom(result):
    """Decode PlanJson off a save/preview result into a dict. Returns a fully
    shaped empty plan when the proc refused (PlanJson is NULL on a refusal),
    so a confirmation view binding to $.totals never reads through a None."""
    empty = {"shiftLabel": "", "pressCode": "", "dieName": "", "assetNumber": "",
             "activeCavities": 0, "hasReduction": False,
             "dieLife": {"before": 0, "delta": 0, "after": 0},
             "totals": {"piecesAdded": 0, "piecesRemoved": 0, "newLots": 0,
                        "countsCorrected": 0, "countsStanding": 0, "rowsMoved": 0},
             "moves": [], "lots": [], "scrap": []}
    raw = (result or {}).get("PlanJson")
    if not raw:
        return empty
    try:
        out = dict(empty)
        out.update(system.util.jsonDecode(raw))
        return out
    except (Exception, java.lang.Exception):
        BlueRidge.Common.Util.log("PlanJson did not decode", level="error")
        return empty


import java.lang
