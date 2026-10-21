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
     traceTree(lotId, containerId)                   -> genealogy NodeRow rows + super-lot markers
     serialRows(containerId)                         -> container serial-table rows (incl. removed)
     loadDetail(matchType, matchedEntityId, serial)  -> serial / container panel payloads"""

import system
import java.lang


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


def traceTree(lotId, containerId=None, _refreshToken=None):
    """The LOT's genealogy (Lot_GetGenealogyTree, Both directions -- the tree
       read itself is untouched) as GenealogyViewer/NodeRow params, plus the
       super-lot markers for every node, the LOT itself and the container on
       the container panel, from ONE ControlledRun_ListMarkers read (piece 6).
       Always shaped:
         {'genealogy': [{LotId, LotName, ItemCode, Depth, Direction, MarkersJson}],
          'lotMarkersJson': str, 'containerMarkersJson': str}"""
    lotId = BlueRidge.Common.Util.toIntOrNone(_u(lotId))
    containerId = BlueRidge.Common.Util.toIntOrNone(_u(containerId))
    rows = []
    if lotId is not None:
        rows = BlueRidge.Lots.Lot.getGenealogyTree(lotId, "Both") or []
    marked = BlueRidge.Quality.ControlledRun.markLotNodes(rows, lotId, containerId)
    nodes = []
    for r in marked["nodes"]:
        nodes.append({
            "LotId":       r.get("LotId"),
            "LotName":     r.get("LotName") or "",
            "ItemCode":    r.get("ItemCode") or "",
            "Depth":       r.get("Depth") or 0,
            "Direction":   r.get("Direction") or "",
            "MarkersJson": r.get("MarkersJson") or "",
        })
    return {
        "genealogy": nodes,
        "lotMarkersJson": marked["rootMarkersJson"],
        "containerMarkersJson": marked["containerMarkersJson"],
    }


def _date(value, pattern="MM/dd"):
    """A proc time (already Eastern) as display text; '' for None."""
    if value is None or value == "":
        return ""
    try:
        return system.date.format(value, pattern)
    except (Exception, java.lang.Exception):
        return ("%s" % value)[:10]


# Display keys the container panel binds, beside Container_GetTraceDetail's columns.
_CONTAINER_DISPLAY = {"ReplacedSerialText": "", "ReplacedSerialVoidText": "",
                      "ReworkText": "", "SerialChangesText": ""}


def _containerDisplay(detail):
    """Container_GetTraceDetail row + the panel's display strings, formatted
       from what SQL returned (piece 6, mock 4): the voided serial and its void
       date, the repack date + initials, and the serial-move counts."""
    d = dict(detail or {})
    d.update(_CONTAINER_DISPLAY)
    dot = u" \u00b7 "
    if d.get("ReplacedSerial"):
        d["ReplacedSerialText"] = u"%s" % d.get("ReplacedSerial")
        voided = _date(d.get("ReplacedSerialVoidedAt"))
        d["ReplacedSerialVoidText"] = (u"void %s" % voided) if voided else u""
    if d.get("ReworkOpenedAt") is not None:
        d["ReworkText"] = dot.join([x for x in (_date(d.get("ReworkOpenedAt")),
                                                d.get("ReworkOpenedByInitials") or "") if x])
    scrapped = d.get("ScrappedSerialCount") or 0
    movedOut = d.get("MovedOutSerialCount") or 0
    movedIn = d.get("MovedInSerialCount") or 0
    if scrapped or movedOut or movedIn:
        d["SerialChangesText"] = dot.join([u"%d scrapped" % scrapped,
                                           u"%d moved out" % movedOut,
                                           u"%d moved in" % movedIn])
    return d


def serialRows(containerId):
    """Serial-table rows for the trace container panel, from
       Container_ListSerials @IncludeRemoved = 1 (piece 6, spec 6b): a serial
       scrapped out or moved away stays listed, struck through, with SQL's
       RemovedReason and the date; a serial a repack moved in says where from.
       SerialNumber and State are ALWAYS {'value', 'style'} table-cell objects
       (empty style when plain) so each column holds one type and sorts.
       TrayPosition is blank on a serial moved to another container: the
       position SQL returns is the one in THAT container.
       Columns: SerialNumber, TrayPosition, ProducingLotName, State."""
    out = []
    for r in BlueRidge.Lots.Container.listSerials(containerId, includeRemoved=True):
        r = r or {}
        serial = r.get("SerialNumber") or ""
        reason = r.get("RemovedReason") or ""
        tray = r.get("TrayPosition")
        if r.get("RemovedAt") is not None or reason:
            # SQL's reason with the date after its first word:
            # 'Scrapped (Porosity)' -> 'Scrapped 10/15 (Porosity)',
            # 'Moved to container 20044' -> 'Moved 10/15 to container 20044'.
            when = _date(r.get("RemovedAt"))
            head, _, tail = reason.partition(u" ")
            text = u" ".join([x for x in (head, when, tail) if x]) or u"Removed"
            if reason.startswith(u"Moved"):
                tray = None
            serialCell = {"value": serial,
                          "style": {"textDecoration": "line-through",
                                    "color": "var(--mpp-text-secondary)"}}
            stateCell = {"value": text, "style": {"color": "var(--pf-status-bad-fg)"}}
        elif r.get("MovedInFromContainerName"):
            when = _date(r.get("MovedInAt"))
            text = u" ".join([x for x in (u"Moved in", when, u"from container",
                                          u"%s" % r.get("MovedInFromContainerName")) if x])
            serialCell = {"value": serial, "style": {}}
            stateCell = {"value": text, "style": {"color": "var(--mpp-accent-60)"}}
        else:
            serialCell = {"value": serial, "style": {}}
            stateCell = {"value": u"Packed", "style": {"color": "var(--pf-status-good-fg)"}}
        out.append({
            "SerialNumber":     serialCell,
            "TrayPosition":     tray,
            "ProducingLotName": r.get("ProducingLotName") or "",
            "State":            stateCell,
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
        "containerDetail": _containerDisplay(BlueRidge.Lots.Container._EMPTY_TRACE_DETAIL),
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
        out["containerDetail"] = _containerDisplay(
            BlueRidge.Lots.Container.getTraceDetailOrEmpty(containerId))
        out["containerSerials"] = serialRows(containerId)
        out["containerHolds"] = BlueRidge.Lots.Container.listHolds(containerId)
    return out
