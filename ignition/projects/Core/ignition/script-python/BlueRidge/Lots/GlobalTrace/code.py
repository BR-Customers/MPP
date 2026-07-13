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
import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Lots.Lot
import BlueRidge.Workorder.ProductionEvent


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
       {matchType, lotId, lotName, part, detail}."""
    rows = resolve(searchText, _refreshToken) or []
    out = []
    for r in rows:
        r = r or {}
        out.append({
            "matchType": r.get("MatchType") or "",
            "lotId":     r.get("LotId"),
            "lotName":   r.get("LotName") or "",
            "part":      r.get("ItemPartNumber") or "",
            "detail":    r.get("Detail") or "",
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
