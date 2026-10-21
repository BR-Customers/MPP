"""BlueRidge.Lots.ContainerRework - container repack (super-lot piece 4).

   A completed container is opened for rework, has parts scrapped out of it, is
   topped up with loose pieces from another container, and comes back complete
   with a NEW shipper serial; an emptied container is voided.

   THIN WRAPPERS ONLY. What may be done to a container now, where pieces may
   go, what a scrap does to a super-lot's results and how a piece move is
   recorded in the genealogy are all decided in the Lots.ContainerRework_*
   procs and returned as columns (CanOpen, CanScrapOrMove, CanSetFilling,
   CanSetProcessing, CanCompleteHere, CanVoid, ShortBy, Room).

   WHO: every mutation takes the appUserId the view resolved - the Quality
   sign-in user on the super-lot page, the PIN operator at a line. Never
   defaulted here.

   Completing a reworked container is NOT reimplemented: completeHere() resumes
   it and calls BlueRidge.Lots.Container.complete, the one definition of
   "complete, claim a serial, print the label, post to AIM".

   Spec: docs/superpowers/specs/2026-10-12-controlled-run-container-repack-design.md

   Public surface:
     get(containerId) / getOrEmpty(containerId, _t)
     open / scrap / applyRecordedScrap / move / setStage / resume / void / completeHere
     trayInstances / serialInstances / targetOptions / recordedScrapOptions / lineOptions
     waitingInstances(locationId, popupId, _t) / waitingCount(locationId, _t)"""

_EMPTY = {
    "ContainerId": None, "StatusCode": "", "StatusName": "", "ItemId": None, "PartNumber": "",
    "ItemDescription": "", "CurrentLocationId": None, "CurrentLocationName": "", "IsSerialized": False,
    "TargetParts": 0, "Pieces": 0, "ShortBy": 0, "LiveAimShipperId": "", "OriginalAimShipperId": "",
    "ReworkOpenedAt": None, "ReworkOpenedByInitials": "", "RunNumber": "", "ControlledRunId": None,
    "MemberId": None, "InRework": False, "CanOpen": False, "CanScrapOrMove": False, "CanSetFilling": False,
    "CanSetProcessing": False, "CanCompleteHere": False, "CanVoid": False,
}


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _int(value):
    return BlueRidge.Common.Util.toIntOrNone(_u(value))


def get(containerId):
    cid = _int(containerId)
    if cid is None:
        return None
    return BlueRidge.Common.Db.execOne("lots/ContainerRework_Get", {"containerId": cid})


def getOrEmpty(containerId, _refreshToken=None):
    """Binding twin of get(): always the full shape, never None."""
    out = dict(_EMPTY)
    row = get(containerId)
    if row:
        for k in row:
            if row.get(k) is not None:
                out[k] = row.get(k)
    return out


# ---- mutations --------------------------------------------------------------

def open(containerId, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("ContainerRework.open containerId=%s" % containerId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/ContainerRework_Open", {
        "containerId": _int(containerId), "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def scrap(containerTrayId, defectCodeId, quantity, containerSerialId, remarks, appUserId, terminalLocationId):
    """Real scrap out of a tray. A serialized part: pass the serial, quantity is 1."""
    BlueRidge.Common.Util.log("ContainerRework.scrap trayId=%s qty=%s serialId=%s" % (containerTrayId, quantity, containerSerialId))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/ContainerRework_Scrap", {
        "containerTrayId": _int(containerTrayId), "defectCodeId": _int(defectCodeId), "quantity": _int(quantity),
        "containerSerialId": _int(containerSerialId), "controlledRunResultId": None,
        "remarks": (_u(remarks) or None), "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def applyRecordedScrap(containerTrayId, controlledRunResultId, containerSerialId, appUserId, terminalLocationId):
    """Apply a scrap that was only RECORDED on the Results tab to a tray. The
       defect and the quantity are the recorded ones (the proc reads them)."""
    BlueRidge.Common.Util.log("ContainerRework.applyRecordedScrap trayId=%s resultId=%s" % (containerTrayId, controlledRunResultId))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/ContainerRework_Scrap", {
        "containerTrayId": _int(containerTrayId), "defectCodeId": None, "quantity": None,
        "containerSerialId": _int(containerSerialId), "controlledRunResultId": _int(controlledRunResultId),
        "remarks": None, "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def move(fromContainerTrayId, toContainerId, quantity, containerSerialId, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("ContainerRework.move trayId=%s to=%s qty=%s serialId=%s"
                              % (fromContainerTrayId, toContainerId, quantity, containerSerialId))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/ContainerRework_MovePieces", {
        "fromContainerTrayId": _int(fromContainerTrayId), "toContainerId": _int(toContainerId),
        "quantity": _int(quantity), "containerSerialId": _int(containerSerialId),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def setStage(containerId, stageCode, locationId, appUserId, terminalLocationId):
    """stageCode 'Filling' (refill-ready) | 'Processing'. locationId sends it somewhere."""
    BlueRidge.Common.Util.log("ContainerRework.setStage containerId=%s stage=%s locationId=%s" % (containerId, stageCode, locationId))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/ContainerRework_SetStage", {
        "containerId": _int(containerId), "stageCode": _u(stageCode), "locationId": _int(locationId),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def resume(containerId, cellLocationId, appUserId, terminalLocationId):
    """Make a refill-ready container the open container at a cell (the line picks it up)."""
    BlueRidge.Common.Util.log("ContainerRework.resume containerId=%s cellLocationId=%s" % (containerId, cellLocationId))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/ContainerRework_Resume", {
        "containerId": _int(containerId), "cellLocationId": _int(cellLocationId),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def void(containerId, remarks, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("ContainerRework.void containerId=%s" % containerId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/ContainerRework_Void", {
        "containerId": _int(containerId), "remarks": _u(remarks),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def completeHere(containerId, appUserId, terminalLocationId):
    """Complete a full, refill-ready container where it stands: resume it at its
       own location, then run the ordinary completion (new serial, label, AIM
       post). If the completion is refused the container goes back to
       refill-ready, so it is never left as a stray open container.
       Returns the completion result {Status, Message, ShippingLabelId, AimShipperId, ...}."""
    BlueRidge.Common.Util.log("ContainerRework.completeHere containerId=%s" % containerId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    row = get(containerId) or {}
    here = row.get("CurrentLocationId")
    if here is None:
        return {"Status": 0, "Message": "Container not found."}
    res = resume(containerId, here, appUserId, terminalLocationId)
    if not res or not res.get("Status"):
        return res
    # Container_Complete re-raises from its CATCH, so a failure can arrive as an
    # exception as well as a Status 0. Either way the container must go back.
    from java.lang import Throwable
    try:
        done = BlueRidge.Lots.Container.complete(_int(containerId), operatorConfirmed=True,
                                                 appUserId=appUserId, terminalLocationId=_u(terminalLocationId))
    except (Exception, Throwable) as e:
        BlueRidge.Common.Util.log("completeHere: completion raised for container %s: %s" % (containerId, e), level="error")
        done = {"Status": 0, "Message": "The container could not be completed: %s" % e}
    if not done or not done.get("Status"):
        back = setStage(containerId, "Filling", None, appUserId, terminalLocationId)
        if not back or not back.get("Status"):
            BlueRidge.Common.Util.log(
                "completeHere: container %s could not be returned to refill-ready: %s"
                % (containerId, (back or {}).get("Message")), level="error")
    return done


# ---- display shaping (rows SQL already judged) -------------------------------

def trayInstances(containerId, selectedTrayId, _refreshToken=None):
    cid = _int(containerId)
    if cid is None:
        return []
    sel = _int(selectedTrayId)
    out = []
    for r in (BlueRidge.Common.Db.execList("lots/ContainerRework_ListTrays", {"containerId": cid}) or []):
        out.append({
            "trayId":   r.get("ContainerTrayId"),
            "position": int(r.get("TrayPosition") or 0),
            "lot":      r.get("LotName") or "",
            "pieces":   int(r.get("Pieces") or 0),
            "tagged":   bool(r.get("CrtActive")),
            "movedFrom": r.get("MovedFromLotName") or "",
            "selected": r.get("ContainerTrayId") == sel,
        })
    return out


def serialInstances(containerId, selectedSerialId, _refreshToken=None):
    cid = _int(containerId)
    if cid is None:
        return []
    sel = _int(selectedSerialId)
    out = []
    for r in (BlueRidge.Common.Db.execList("lots/ContainerRework_ListSerials", {"containerId": cid}) or []):
        out.append({
            "serialId": r.get("ContainerSerialId"),
            "serial":   r.get("SerialNumber") or "",
            "trayId":   r.get("ContainerTrayId"),
            "position": int(r.get("TrayPosition") or 0),
            "lot":      r.get("ProducingLotName") or "",
            "selected": r.get("ContainerSerialId") == sel,
        })
    return out


def targetOptions(containerId, _refreshToken=None):
    """[{label, value}] of refill-ready containers of the same part with room."""
    cid = _int(containerId)
    if cid is None:
        return []
    out = []
    for r in (BlueRidge.Common.Db.execList("lots/ContainerRework_ListTargets", {"containerId": cid}) or []):
        room = r.get("Room")
        label = "Container %s" % r.get("ContainerId")
        if room is not None:
            label += " - room for %d" % int(room)
        if r.get("CurrentLocationName"):
            label += " (%s)" % r.get("CurrentLocationName")
        out.append({"label": label, "value": r.get("ContainerId")})
    return out


def recordedScrapOptions(controlledRunId, memberId, _refreshToken=None):
    """[{label, value}] of scrap RECORDED on the Results tab for this container
       and not yet applied to a tray (IsApplied comes from SQL)."""
    rid, mid = _int(controlledRunId), _int(memberId)
    if rid is None or mid is None:
        return []
    out = []
    for r in (BlueRidge.Quality.ControlledRun.listResults(rid, False) or []):
        if r.get("MemberId") == mid and r.get("DispositionCode") == "Scrap" and not r.get("IsApplied"):
            out.append({"label": "%d x %s %s" % (int(r.get("Quantity") or 0), r.get("DefectCode") or "",
                                                r.get("DefectDescription") or ""),
                        "value": r.get("ResultId")})
    return out


def lineOptions():
    """[{label, value}] of lines a refill-ready container can be sent to."""
    return BlueRidge.Quality.ControlledRun.locationOptions()


def _waiting(locationId):
    lid = _int(locationId)
    if lid is None:
        return []
    return BlueRidge.Common.Db.execList("lots/ContainerRework_ListAtLocation", {"locationId": lid}) or []


def waitingCount(locationId, _refreshToken=None):
    """How many refill-ready containers wait at this line (0 hides the button)."""
    try:
        return len(_waiting(locationId))
    except:
        return 0


def waitingInstances(locationId, popupId, _refreshToken=None):
    out = []
    for r in _waiting(locationId):
        target = r.get("TargetParts")
        out.append({
            "containerId": r.get("ContainerId"),
            "part":        r.get("PartNumber") or "",
            "description": r.get("ItemDescription") or "",
            "fill":        ("%d of %d" % (int(r.get("Pieces") or 0), int(target))) if target is not None
                           else ("%d pieces" % int(r.get("Pieces") or 0)),
            "shortBy":     int(r.get("ShortBy") or 0),
            "runNumber":   r.get("RunNumber") or "",
            "locationId":  _int(locationId),
            "popupId":     _u(popupId) or "",
        })
    return out
