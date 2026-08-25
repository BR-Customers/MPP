"""BlueRidge.Lots.GlobalTrace - Global Trace entry point (Arc 2 Phase 9,
   FDS-12-001/012/013). Lots.GlobalTrace_Resolve maps ONE scanned/typed identifier
   (LOT name, serial, container id, AIM shipper id, LOT-name prefix) to candidate
   LOT rows; the Global Trace view then composes the full read-only trace from the
   EXISTING per-stream reads (Lot.get / getHistory / getGenealogyTree /
   getScrapSummaryOrEmpty, ProductionEvent.listByLot) - recon spec delta 2 dropped
   the multi-result-set GetFullTrace.

   Public surface:
     resolve(searchText, _refreshToken=None)         -> list[dict] (raw proc rows)
     resolveForTable(searchText, _refreshToken=None) -> CandidateRow repeater instances
     productionEventRows(lotId, _refreshToken=None)  -> table rows, dates preformatted
     genealogyRows(lotId, _refreshToken=None)        -> table rows (Relation/LotName/...)"""

import system


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def resolve(searchText, _refreshToken=None):
    """Candidate LOT rows for one scanned/typed identifier. Row shape: MatchType
       (Lot|Serial|Container|Shipper), MatchedEntityId, LotId, LotName,
       ItemPartNumber, Detail. Multiple rows = the FDS-12-013 disambiguation list;
       empty/blank input or no match = []. _refreshToken is ignored (runScript
       re-read arg)."""
    searchText = _u(searchText)
    BlueRidge.Common.Util.log("resolve searchText=%s" % searchText)
    if searchText is None or ("%s" % searchText).strip() == "":
        return []
    return BlueRidge.Common.Db.execList(
        "lots/GlobalTrace_Resolve", {"searchText": searchText})


def resolveForTable(searchText, _refreshToken=None):
    """Binding-safe candidate list for the Global Trace CandidateRow repeater -
       always a list, one flat param dict per candidate:
       {matchType, matchedEntityId, lotId, lotName, part, detail}.

       matchedEntityId is what the match resolved TO, and it differs per
       matchType: SerializedPart.Id for 'Serial', Container.Id for 'Container',
       ShippingLabel.Id for 'Shipper', Lot.Id for 'Lot'. The detail panels
       (loadDetail) dispatch on the pair."""
    rows = resolve(searchText, _refreshToken) or []
    out = []
    for r in rows:
        r = r or {}
        out.append({
            "matchType":       r.get("MatchType") or "",
            "matchedEntityId": r.get("MatchedEntityId"),
            "lotId":           r.get("LotId"),
            "lotName":         r.get("LotName") or "",
            "part":            r.get("ItemPartNumber") or "",
            "detail":          r.get("Detail") or "",
        })
    return out


def productionEventRows(lotId, _refreshToken=None):
    """Production-event table rows for the trace view, chronological, with EventAt
       PRE-FORMATTED in Python (dates do not survive the table-data hop reliably).
       Columns: Event, At, Shots, Scrap, Weight, By, Remarks."""
    lotId = _u(lotId)
    if not lotId:
        return []
    rows = BlueRidge.Workorder.ProductionEvent.listByLot(lotId) or []
    out = []
    for r in rows:
        r = r or {}
        ev = r.get("EventAt")
        disp = ""
        if ev is not None:
            try:
                disp = system.date.format(ev, "MM/dd HH:mm")
            except:
                disp = ("%s" % ev)[:16]
        weight = r.get("WeightValue")
        weightDisp = ""
        if weight is not None:
            weightDisp = "%s %s" % (weight, r.get("WeightUomCode") or "")
        out.append({
            "Event":   r.get("OperationTemplateName") or r.get("OperationTemplateCode") or "",
            "At":      disp,
            "Shots":   r.get("ShotCount"),
            "Scrap":   r.get("ScrapCount"),
            "Weight":  weightDisp,
            "By":      r.get("ByUser") or "",
            "Remarks": r.get("Remarks") or "",
        })
    return out


def genealogyRows(lotId, _refreshToken=None):
    """Genealogy summary rows for the trace view (Lot_GetGenealogyTree, Both
       directions). Depth is informational, not authoritative shortest-path.
       Columns: Relation, LotName, Item, Depth."""
    lotId = _u(lotId)
    if not lotId:
        return []
    rows = BlueRidge.Lots.Lot.getGenealogyTree(lotId, "Both") or []
    out = []
    for r in rows:
        r = r or {}
        out.append({
            "Relation": r.get("Direction") or "",
            "LotName":  r.get("LotName") or "",
            "Item":     r.get("ItemCode") or "",
            "Depth":    r.get("Depth"),
        })
    return out


def loadDetail(matchType, matchedEntityId, serialNumber=None):
    """Dispatch a resolver hit to its entity-specific detail payload
       (FDS-12-002 / FDS-12-003).

       resolve() above returns MatchType + MatchedEntityId; this turns one of
       those hits into the four blocks the Global Trace panels bind. Every block
       is ALWAYS fully shaped, so the caller can assign each in one property
       write -- a None would replace the view's shaped default and error on the
       first nested read.

       'Shipper' routes to the container panel via the label's container:
       MatchedEntityId is the ShippingLabel row for that match type."""
    matchType = _u(matchType)
    matchedEntityId = _u(matchedEntityId)
    BlueRidge.Common.Util.log(
        "loadDetail matchType=%s matchedEntityId=%s" % (matchType, matchedEntityId))

    out = {
        "serialDetail": dict(BlueRidge.Lots.SerializedPart._EMPTY_TRACE_DETAIL),
        "containerDetail": dict(BlueRidge.Lots.Container._EMPTY_TRACE_DETAIL),
        "containerSerials": [],
        "containerHolds": [],
    }

    containerId = None

    if matchType == "Serial":
        out["serialDetail"] = BlueRidge.Lots.SerializedPart.getTraceDetailOrEmpty(
            _u(serialNumber))
        containerId = out["serialDetail"].get("ContainerId")
    elif matchType == "Container":
        containerId = matchedEntityId
    elif matchType == "Shipper":
        row = BlueRidge.Common.Db.execOne(
            "lots/ShippingLabel_GetContainerId", {"shippingLabelId": matchedEntityId})
        containerId = row.get("ContainerId") if row else None

    if containerId:
        out["containerDetail"] = BlueRidge.Lots.Container.getTraceDetailOrEmpty(containerId)
        out["containerSerials"] = BlueRidge.Lots.Container.listSerials(containerId)
        out["containerHolds"] = BlueRidge.Lots.Container.listHolds(containerId)
    return out
