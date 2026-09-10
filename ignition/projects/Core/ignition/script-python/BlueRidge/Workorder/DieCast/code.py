"""BlueRidge.Workorder.DieCast - thin access to the die-cast per-cavity
   shift-output procs (Workorder.DieCast_GetShiftOutputBreakdown /
   Workorder.DieCastShiftOutput_Record). Wrappers only; the auto-breakdown
   math, per-line/shot-loss validation and the contribution-ledger + additive
   -scrap fan-out all live in the procs.

   Public surface:
     getShiftOutputBreakdown(toolId, shiftId, counterReading, cellLocationId) -> list[dict]
     recordShiftOutput(data, appUserId=None, terminalLocationId=None)        -> {Status, Message, NewId}
     registerShotLoss(toolId, shiftId, defectCodeId, quantity,
                       appUserId=None, terminalLocationId=None)              -> {Status, Message, NewId}
     getCounterContext(toolId, shiftId, cellLocationId)                      -> dict
     describeCounterContext(ctx)                                             -> str
     listAnchorReasons()                                                     -> list[{label, value}]
     recordCounterAnchor(toolId, shiftId, declaredReading, reasonId, ...)    -> {Status, Message, NewId}"""

# system.date.* raises Java Throwables, which `except Exception` does NOT catch
# in Jython -- describeCounterContext's timestamp guard needs the Java branch or
# a bad value takes the whole binding down.
import java.lang


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getShiftOutputBreakdown(toolId, shiftId, counterReading, cellLocationId=None):
    """Proposed per-cavity-lot good-piece counts for a PRESS COUNTER READING
       (Workorder.DieCast_GetShiftOutputBreakdown) -- the read-side proposal the
       recording flow presents to the operator for confirmation/adjustment
       before recordShiftOutput writes the contribution rows. Returns list[dict]
       ([] when the tool has no lots open/contributing this shift).

       counterReading IS A READING, NOT AN INCREMENT (proc v2.0, 2026-09-09).
       The press counter resets each shift, so every cavity carries a
       credited-through watermark starting at 0 and a basket's credit is
       (reading - watermark). A cavity that never rolled its basket has a
       watermark of 0 and is credited the whole reading -- exactly v1.3's
       behaviour. Uniform fan-out is not replaced; it becomes the case where
       nothing rolled over. A cavity that DID roll gets only the remainder,
       which v1.3 could not express at all.

       cellLocationId is the PRESS. The watermark is scoped by it, so a die
       moved to another press (or a changeover to another die on the same
       press) resets the chain. The proc falls back to the die's currently
       mounted cell when it is not supplied."""
    toolId = _u(toolId)
    shiftId = _u(shiftId)
    counterReading = _u(counterReading)
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log(
        "getShiftOutputBreakdown toolId=%s shiftId=%s counterReading=%s cellLocationId=%s"
        % (toolId, shiftId, counterReading, cellLocationId)
    )
    if toolId is None or shiftId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "workorder/DieCast_GetShiftOutputBreakdown",
        {"toolId": toolId, "shiftId": shiftId,
         "counterReading": counterReading, "cellLocationId": cellLocationId},
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
        "counterReading":     d.get("counterReading"),
        "cellLocationId":     cellLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/DieCastShiftOutput_Record", params)


_EMPTY_RELEASE_PREVIEW = {
    "lotId": None, "lotName": "", "toolCavityId": None, "toolId": None,
    "cavityNumber": "", "cavityName": "", "partNumber": "",
    "pieceCount": 0, "maxPieceCount": None,
    "creditedThrough": 0, "dieCreditedThrough": 0, "newShots": 0,
    "projectedPieceCount": 0, "belowStandardAfter": False,
    "readingState": "None", "found": False,
}


def getReleasePreview(lotId, shiftId=None, cellLocationId=None, counterReading=None,
                      _refreshToken=None):
    """Everything the Release dialog shows before the operator commits, for the
       reading they have typed so far (Workorder.DieCast_GetReleasePreview).

       The dialog exists because Lots.DieCastLot_Release derives the closing
       piece delta from a press-counter reading and the screen used to neither
       ask for the reading nor show what it did with it -- so closing a basket
       mid-shift either lost that cavity's shots since the last entry, or
       forced a trip through Record Shift Output that nothing on the screen
       asked for. Every number here comes from SQL; nothing is recomputed in a
       binding or a handler, so the preview and the write can never disagree.

       ALWAYS returns the full shape, never None (predeclare-bound-props rule):
       a not-found / not-open LOT comes back as _EMPTY_RELEASE_PREVIEW with
       found=False, so a nested read in a binding cannot go Quality-Bad.

       _refreshToken is UNUSED and deliberately so. A counter anchor recorded
       from inside the Release dialog changes the die watermark without
       changing any of this binding's real inputs, so the preview would keep
       quoting the number that had just been superseded. Bumping a token forces
       the re-read. Same trick as getBulkOpenRowInstances' _optionsToken."""
    lotId = _u(lotId)
    if lotId is None:
        return dict(_EMPTY_RELEASE_PREVIEW)
    reading = BlueRidge.Common.Util.toIntOrNone(_u(counterReading))
    try:
        row = BlueRidge.Common.Db.execOne("workorder/DieCast_GetReleasePreview", {
            "lotId": lotId,
            "shiftId": _u(shiftId),
            "cellLocationId": _u(cellLocationId),
            "counterReading": reading,
        })
    except Exception as e:
        BlueRidge.Common.Util.log("getReleasePreview failed: %s" % str(e))
        return dict(_EMPTY_RELEASE_PREVIEW)
    if not row:
        return dict(_EMPTY_RELEASE_PREVIEW)
    num = row.get("CavityNumber")
    out = dict(_EMPTY_RELEASE_PREVIEW)
    out.update({
        "lotId":               row.get("LotId"),
        "lotName":             row.get("LotName") or "",
        "toolCavityId":        row.get("ToolCavityId"),
        "cavityNumber":        num if num is not None else "",
        "cavityName":          cavityDisplayName(num, row.get("CavityDescription")),
        "partNumber":          row.get("PartNumber") or "",
        "pieceCount":          row.get("PieceCount") or 0,
        "maxPieceCount":       row.get("MaxPieceCount"),
        "creditedThrough":     row.get("CreditedThrough") or 0,
        "dieCreditedThrough":  row.get("DieCreditedThrough") or 0,
        "newShots":            row.get("NewShots") or 0,
        "projectedPieceCount": row.get("ProjectedPieceCount") or 0,
        "belowStandardAfter":  bool(row.get("BelowStandardAfter")),
        "readingState":        row.get("ReadingState") or "None",
        # proc v1.1 -- the dialog's counter-context binding and its anchor
        # popup both key off this. Leaving it unmapped is not visibly broken:
        # the context line just quietly reports "nothing recorded" while the
        # rest of the dialog quotes the real watermark.
        "toolId":              row.get("ToolId"),
        "found":               True,
    })
    return out


# =============================================================================
# Counter anchor (spec 2026-09-10; migration 0074)
# -----------------------------------------------------------------------------
# The shift's rolling counter total for a die, and the operator's ability to
# declare the true one. Both shot watermarks are MAX(reading) over the shift and
# a reading below the DIE watermark is refused, so a press counter reset -- or a
# wrong number typed earlier -- blocked the die for the rest of the shift with
# no way out. A MAX cannot be lowered by appending.
#
# EVERY DECISION IS IN SQL. Workorder.DieCastCounterAnchor_Record owns what a
# valid declaration is; the ufn_*ShotWatermark functions own how it is applied;
# Workorder.DieCast_GetCounterContext owns what the screen is told. These
# wrappers pass values through and shape them for bindings -- nothing here
# decides anything.
# =============================================================================

_EMPTY_COUNTER_CONTEXT = {
    "toolId": None, "shiftId": None, "cellLocationId": None,
    "dieCreditedThrough": 0, "sourceKind": "None", "recordedAt": None,
    "recordedBy": "", "reasonName": "", "note": "", "hasAnchor": False,
    "found": False,
}


def getCounterContext(toolId, shiftId, cellLocationId=None, _refreshToken=None):
    """The shift's rolling press-counter total for a die, and where that number
       came from (Workorder.DieCast_GetCounterContext).

       This is the number the operator could not see. It was computed everywhere
       it mattered but only ever DISPLAYED inside the Release dialog's red "that
       reading is behind ..." advisory -- so it first became visible at the
       moment it had already blocked them. Both die-cast entry points now state
       it as plain context before anything is typed.

       sourceKind is 'None' (nothing recorded this shift), 'Entry' (a recorded
       shift output or basket release), or 'Anchor' (an operator declaration --
       reasonName / note say why).

       ALWAYS returns the full shape, never None (predeclare-bound-props rule):
       the proc itself always returns exactly one row, and a failed call comes
       back as _EMPTY_COUNTER_CONTEXT, so a nested read in a binding cannot go
       Quality-Bad.

       _refreshToken is UNUSED: recording an anchor or a shift output moves the
       watermark without changing any real input of this binding, so a token
       bump is what forces the re-read. Same trick as getReleasePreview."""
    toolId = _u(toolId)
    if toolId is None:
        return dict(_EMPTY_COUNTER_CONTEXT)
    try:
        row = BlueRidge.Common.Db.execOne("workorder/DieCast_GetCounterContext", {
            "toolId": toolId,
            "shiftId": _u(shiftId),
            "cellLocationId": _u(cellLocationId),
        })
    except Exception as e:
        BlueRidge.Common.Util.log("getCounterContext failed: %s" % str(e))
        return dict(_EMPTY_COUNTER_CONTEXT)
    if not row:
        return dict(_EMPTY_COUNTER_CONTEXT)
    out = dict(_EMPTY_COUNTER_CONTEXT)
    out.update({
        "toolId":             row.get("ToolId"),
        "shiftId":            row.get("ShiftId"),
        "cellLocationId":     row.get("CellLocationId"),
        "dieCreditedThrough": row.get("DieCreditedThrough") or 0,
        "sourceKind":         row.get("SourceKind") or "None",
        "recordedAt":         row.get("RecordedAt"),
        "recordedBy":         row.get("RecordedBy") or "",
        "reasonName":         row.get("ReasonName") or "",
        "note":               row.get("Note") or "",
        "hasAnchor":          bool(row.get("HasAnchor")),
        "found":              True,
    })
    return out


def describeCounterContext(ctx):
    """The one-line context sentence both die-cast screens show above their
       reading field. PRESENTATION ONLY -- every number and every branch input
       was decided in SQL; this chooses wording.

       It lives here rather than in an expression binding because the expression
       language cannot express it cleanly: three-way branching plus a formatted
       timestamp, in a literal syntax that rejects escapes."""
    c = _u(ctx) or {}
    total = c.get("dieCreditedThrough") or 0
    kind = c.get("sourceKind") or "None"
    if kind == "None":
        return "Nothing recorded for this die yet this shift. Every cavity is credited from 0."

    who = c.get("recordedBy") or ""
    when = ""
    at = c.get("recordedAt")
    if at is not None:
        try:
            when = system.date.format(at, "HH:mm")
        except (Exception, java.lang.Exception):
            when = ""

    stamp = ""
    if when and who:
        stamp = " (recorded %s by %s)" % (when, who)
    elif when:
        stamp = " (recorded %s)" % when
    elif who:
        stamp = " (recorded by %s)" % who

    if kind == "Anchor":
        why = c.get("reasonName") or ""
        tail = (" %s" % why) if why else ""
        return "This die is at %s for the shift -- set by hand%s.%s" % (
            _thousands(total), stamp, tail)
    return "This die is at %s for the shift%s." % (_thousands(total), stamp)


def _thousands(n):
    """1234 -> '1,234'. Jython 2.7 has no format(n, ',d')."""
    try:
        n = int(n)
    except (TypeError, ValueError):
        return str(n)
    sign = "-" if n < 0 else ""
    digits = str(abs(n))
    groups = []
    while len(digits) > 3:
        groups.insert(0, digits[-3:])
        digits = digits[:-3]
    groups.insert(0, digits)
    return sign + ",".join(groups)


def listAnchorReasons():
    """Dropdown options for the counter-anchor reason
       (Workorder.DieCastCounterAnchorReason_List), as the {label, value} pairs
       ia.input.dropdown requires -- any other key shape silently breaks it."""
    try:
        rows = BlueRidge.Common.Db.execList("workorder/DieCastCounterAnchorReason_List", {})
    except Exception as e:
        BlueRidge.Common.Util.log("listAnchorReasons failed: %s" % str(e))
        return []
    return [{"label": r.get("Name") or r.get("Code"), "value": r.get("Id")}
            for r in (rows or [])]


def anchorReasonRequiresNote(reasonId):
    """True when the chosen reason carries no explanation of its own, so the
       dialog must require the note at the button instead of letting
       Workorder.DieCastCounterAnchor_Record reject. The rule is the proc's;
       this only reads what the proc's own list proc reports."""
    rid = BlueRidge.Common.Util.toIntOrNone(_u(reasonId))
    if rid is None:
        return False
    try:
        rows = BlueRidge.Common.Db.execList("workorder/DieCastCounterAnchorReason_List", {})
    except Exception as e:
        BlueRidge.Common.Util.log("anchorReasonRequiresNote failed: %s" % str(e))
        return False
    for r in (rows or []):
        if r.get("Id") == rid:
            return bool(r.get("RequiresNote"))
    return False


def recordCounterAnchor(toolId, shiftId, declaredReading, reasonId, note=None,
                        appUserId=None, terminalLocationId=None, cellLocationId=None):
    """Declare the true press-counter reading for a die on a press in a shift
       (Workorder.DieCastCounterAnchor_Record). Returns {Status, Message, NewId}.

       FORWARD-ONLY, and the proc's Message says so: this sets where crediting
       resumes from and moves nothing already recorded -- not the pieces on the
       baskets, not Tools.Tool.ShotCount. Surface that Message rather than
       inventing a cheerier one."""
    BlueRidge.Common.Util.log(
        "recordCounterAnchor toolId=%s shiftId=%s declaredReading=%s reasonId=%s cellLocationId=%s"
        % (toolId, shiftId, declaredReading, reasonId, cellLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    note = _u(note)
    if note is not None:
        note = str(note).strip() or None
    params = {
        "toolId":             _u(toolId),
        "shiftId":            _u(shiftId),
        "declaredReading":    BlueRidge.Common.Util.toIntOrNone(_u(declaredReading)),
        "reasonId":           _u(reasonId),
        "appUserId":          appUserId,
        "note":               note,
        "cellLocationId":     _u(cellLocationId),
        "terminalLocationId": _u(terminalLocationId),
    }
    return BlueRidge.Common.Db.execMutation("workorder/DieCastCounterAnchor_Record", params)


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

       EVERY ROW IS KEPT (2026-09-09), reversing backlog 2.4's "a basket
       released mid-shift is reference-only noise". MPP records scrap ONCE, at
       end of shift, from a paper form -- so a basket closed at 10am still
       needs its scrap entered at 3pm, and a row that is not on screen cannot
       receive it. Proc v2.1 is cavity-driven, so the list now also carries
       cavities with NO basket at all (Closed / Scrapped, or simply unopened);
       those still report the shots that ran and the part they are configured
       to cut, so their scrap is recordable too."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    out = []
    for r in rows:
        r = r or {}
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
            # v2.0 reading chain -- context so the operator never subtracts
            "creditedThrough":    r.get("CreditedThrough") or 0,
            "newShots":           r.get("NewShots") or 0,
            # v2.1 cavity-driven
            "cavityStatusCode":   r.get("CavityStatusCode") or "Active",
            "configuredPart":     r.get("ConfiguredPartNumber") or "",
            "hasBasket":          r.get("LotId") is not None,
        })
    return out


def openRowsOnly(rows):
    """The still-OPEN baskets from a DieCast_GetShiftOutputBreakdown result.

       NO LONGER USED BY THE SHIFT-OUTPUT SCREEN (2026-09-09). Kept because the
       filter itself is still a correct, useful predicate, but the screen must
       now show closed baskets so their scrap can be entered at shift end, and
       basketless cavities so an out-of-service cavity is visible at all.
       Reintroducing this call would silently re-hide both.

       backlog 2.4 (superseded): operators recording shift output only need the
       baskets they can still add to; a basket released mid-shift is
       reference-only noise.

       Filtered HERE (read side) rather than in the proc on purpose: the proc's
       documented contract is 'one row per LOT open at ANY point during the
       shift window', which the reconciliation/assertion consumers (the 0045
       test suite's multi-lot cavity-handoff assertions) depend on, and which
       is genuinely the right answer for a shift-reconciliation read. Narrowing
       the proc would be a semantic regression for every other caller, so the
       screen narrows its own view of it instead."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    return [r for r in rows if r and r.get("IsOpen")]


def registerShotLoss(toolId, shiftId, defectCodeId, quantity, appUserId=None, terminalLocationId=None):
    """Record a shot-level defect (e.g. a short shot on the whole cycle) against
       EVERY currently-open basket on a tool -- builds a one-element shotLoss
       line with no per-cavity lines and calls recordShiftOutput /
       Workorder.DieCastShiftOutput_Record. Returns {Status, Message, NewId}.

       NO COUNTER READING IS SENT (2026-09-09). backlog 3.2 threaded the loss
       quantity through @GrossShots so the lost cycles would advance
       Tools.Tool.ShotCount, and left this note: "If MPP instead reads gross
       straight off the machine counter, this bump double-counts and should be
       REVERTED rather than patched."

       That condition is now confirmed -- MPP reads a press counter that resets
       each shift -- so the bump is reverted, which restores the 2026-08-04
       tool-shot-count design's original choice. The press counter already
       counts every cycle the die ran, lost shots included, so those cycles
       reach ShotCount via the next reading. Sending the loss QUANTITY as a
       READING would be far worse than double-counting: a quantity of 5 would
       be read as "the counter now says 5" and rejected as behind the
       watermark, or would corrupt the chain outright.

       A shot loss is therefore purely a RejectEvent fan-out across every
       currently-open basket. It moves no watermark and no shot count."""
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
        # deliberately NO counterReading -- see the docstring above
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
        # EVERY non-deprecated cavity (2026-09-10), not just the Active ones.
        # ToolCavity_ListActiveByTool filtered on StatusCode = 'Active', so a
        # Closed or Scrapped cavity simply was not on the grid -- the operator
        # saw 11 rows on a 12-cavity die with no explanation, which reads as a
        # broken screen rather than as a cavity that is out of service. The row
        # renders its state and offers nothing; Lots.DieCastLot_Open rejects a
        # non-Active cavity server-side regardless.
        cavities = BlueRidge.Common.Db.execList(
            "parts/ToolCavity_ListByTool", {"toolId": toolId, "includeDeprecated": False}) or []
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
        # Lots.Lot_GetOpenByTool is cavity-driven since v2.0, so a row with a
        # NULL LotId means "this cavity has NO basket" -- keying on the row
        # itself would mark every cavity already-open.
        if r.get("LotId") is None:
            continue
        openByCavity["%s" % r.get("ToolCavityId")] = r

    out = []
    for c in (cavities or []):
        c = c or {}
        cavityId = c.get("Id")
        num = c.get("CavityNumber")
        existing = openByCavity.get("%s" % cavityId)
        statusCode = c.get("StatusCode") or "Active"
        out.append({
            "toolCavityId":       cavityId,
            "cavityNumber":       num if num is not None else "",
            "cavityName":         cavityDisplayName(num, c.get("Description")),
            "cavityOrdinalLabel": "Cavity %s" % (num if num is not None else "?"),
            "cavityStatusCode":   statusCode,
            "isActive":           (statusCode == "Active"),
            "alreadyOpen":        existing is not None,
            "openLotName":        (existing or {}).get("LotName") or "",
            "openPieceCount":     (existing or {}).get("PieceCount") or 0,
            # overlaid by the repeater transform -- shaped here so every key the
            # row's params traverse always exists (predeclare-bound-props rule).
            "itemId":             None,
            # 0072: the part this cavity is configured to cut. The operator no
            # longer picks it -- the row DISPLAYS this and locks the dropdown so
            # a configured cavity cannot be opened against the wrong part.
            # It is deliberately NOT copied into the draft: the draft is the
            # record of what the OPERATOR entered, and seeding it made all 12
            # untouched rows count as pending submissions (the "OPEN 12
            # BASKET(S)" button on an empty grid, 2026-09-10). The proc resolves
            # the cavity's part itself when the row carries none.
            "configuredItemId":   c.get("ItemId"),
            "configuredPart":     c.get("ItemPartNumber") or "",
            "scannedLtt":         "",
            "resultState":        "",
            "resultMessage":      "",
            "itemOptions":        [],
            "seedToken":          seedToken if seedToken is not None else 0,
        })
    return out


def bulkOpenPending(draft):
    """How many cavity rows the operator has actually staged to open.

       The count on the OPEN N BASKET(S) button. It is the number of draft
       entries carrying a SCANNED TICKET -- the same intent test
       _bulkOpenIntents uses, so the button can never promise a different
       number of baskets than the submit will attempt. Counting anything else
       is what produced "OPEN 12 BASKET(S)" on a grid nobody had touched."""
    draft = BlueRidge.Common.Util.extractQualifiedValues(draft) or {}
    n = 0
    for k in draft.keys():
        d = draft.get(k) or {}
        if ("%s" % (d.get("scannedLtt") or "")).strip() != "":
            n += 1
    return n


def foldBulkOpenRowChange(draft, payload):
    """Fold one BulkOpenRow's report into the authoritative draft map.

       Returns {"draft": {...}, "pending": N} -- the caller writes both back.

       Rows report on every keystroke AND on every repeater rebuild, and the
       rebuild report is what keeps the draft honest: a cavity that is now
       already-open, or is not Active, has its entry REMOVED here. Without that
       the draft kept entries for cavities the operator can no longer even see
       (their row is read-only), and the button went on counting them -- the
       "OPEN 11 BASKET(S)" with every slot full, 2026-09-10. A row cannot
       report its own emptiness through the value-changed path, because writing
       null over null fires no onChange, so the rebuild report has to be
       unconditional and this fold has to be able to delete."""
    draft = BlueRidge.Common.Util.extractQualifiedValues(draft) or {}
    draft = dict(draft)
    payload = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
    key = "%s" % payload.get("toolCavityId")
    ltt = ("%s" % (payload.get("scannedLtt") or "")).strip()
    itemId = payload.get("itemId")
    unusable = bool(payload.get("alreadyOpen")) or (payload.get("isActive") is False)
    if unusable or (ltt == "" and itemId is None):
        if key in draft:
            del draft[key]
    else:
        draft[key] = {"toolCavityId": payload.get("toolCavityId"),
                      "itemId": itemId, "scannedLtt": ltt}
    return {"draft": draft, "pending": bulkOpenPending(draft)}


def _bulkOpenIntents(rows):
    """Normalize the raw draft rows into the submission set.

       THE LTT IS THE INTENT (2026-09-10). A row is submitted when it carries a
       scanned ticket, and only then. Until 0072 the part was operator input, so
       "either field touched" was a fair reading of intent; now the part comes
       from the cavity's configuration and is on screen without anyone touching
       anything, which made every cavity on the die look submitted. A basket
       cannot exist without a ticket, so the ticket is the one unambiguous
       signal that the operator means to open one.

       A ticket with no resolvable part is still a validation FAILURE and not a
       silent skip -- it just fails in Lots.DieCastLot_Open, which is the only
       place that knows whether the cavity has a configured part.
       Returns list[dict{toolCavityId, itemId, lotName}]."""
    out = []
    for r in (rows or []):
        r = _u(r) or {}
        cavityId = r.get("toolCavityId")
        if cavityId is None:
            continue
        lotName = ("%s" % (r.get("scannedLtt") or "")).strip()
        if lotName == "":
            continue
        out.append({"toolCavityId": cavityId, "itemId": r.get("itemId"), "lotName": lotName})
    return out


def submitBulkOpen(rows, toolId, cellLocationId, appUserId=None, terminalLocationId=None):
    """Open every filled cavity row in one operator action.

       rows: [{toolCavityId, itemId, scannedLtt}, ...] straight off the view's
       bulkOpenDraft (already extractQualifiedValues'd by the caller).

       Returns
         {Status, Message, Rejected, Opened, Failed,
          Rows: {"<toolCavityId>": {state: "ok"|"error", message: str}},
          CrtLots: [lotName, ...]}
       Status is 1 when at least one basket opened. Rejected=True means a
       batch-level gate fired and NOTHING was written. CrtLots names the
       baskets that opened CRT-active, in cavity submission order, so the
       screen can raise ONE notice for the whole submit (design D9) instead
       of one dialog per cavity."""
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
    openedLotIds = []
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
            openedLotIds.append(res.get("NewId"))
        else:
            failed += 1

    if failed == 0:
        message = "Opened %s basket(s)." % opened
    elif opened == 0:
        message = "No baskets opened - %s row(s) failed. See each row for why." % failed
    else:
        message = ("Opened %s of %s basket(s) - %s row(s) failed and were left "
                   "untouched. See each row for why." % (opened, opened + failed, failed))
    # Cosmetic read-back, computed into a LOCAL first and never inline in the
    # return dict: every basket above has already committed in its own
    # transaction, so an exception raised while building the reply would cost
    # the operator the per-row results, the draft pruning and the outcome
    # toast for work the database has already done. crtNamesFor fails open per
    # LOT; belt-and-braces here so this reply cannot depend on a presentation
    # read at all.
    try:
        crtLots = BlueRidge.Lots.Lot.crtNamesFor(openedLotIds)
    except Exception as e:
        BlueRidge.Common.Util.log(
            "submitBulkOpen: CRT read-back failed (%s) - notice suppressed; the "
            "baskets opened above are unaffected." % e, level="warn")
        crtLots = []
    return {"Status": 1 if opened else 0, "Message": message, "Rejected": False,
            "Opened": opened, "Failed": failed, "Rows": results,
            "CrtLots": crtLots}
