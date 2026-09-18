"""BlueRidge.Parts.ItemLocation - eligibility reads plus the Line Inventory
   Tolerances popup's list/save (listConsumptionForLine, getToleranceInstances,
   setMaxQuantity, saveMaxAndNotify). No longer read-only as of the 2026-09-17
   Line Inventory sidebar work.

   Wrappers only; no business logic -- every rule (consumption point only,
   > 0, not below Min) lives in the procs. Arc 2 Phase 4 (Movement Scan
   FDS-02-012)."""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def checkEligibility(itemId, locationId):
    """Advisory eligibility read (Direct U BomDerived). Returns
       {IsEligible, Path} ('Direct'/'BomDerived'/None) or None. The
       authoritative gate is Lots.Lot_MoveToValidated; this drives UI feedback."""
    BlueRidge.Common.Util.log("itemId=%s locationId=%s" % (itemId, locationId))
    return BlueRidge.Common.Db.execOne(
        "parts/ItemLocation_CheckEligibility",
        {"itemId": _u(itemId), "locationId": _u(locationId)},
    )


def checkEligibilityOrEmpty(itemId, locationId):
    """Binding-safe variant: always returns a fully-shaped dict
       {IsEligible, Path} (never None) for pre-declared bound custom props."""
    r = checkEligibility(itemId, locationId)
    if not r:
        return {"IsEligible": False, "Path": None}
    return r


def listConsumptionForLine(locationId, _refreshToken=None):
    """Consumption parts for the Tolerances popup (Parts.ItemLocation_ListConsumptionForLine
       v1.1): ItemLocationId, ItemId, Description, Available, MaxQuantity, MinQuantity,
       RowLocationCode, LineLocationCode. RowLocationCode is where the consumption row
       that set Max actually lives; LineLocationCode is the line the popup was opened
       for. They differ when Max was set on an ancestor Area, in which case editing it
       here changes every line under that Area. Returns [] when there is no location."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "parts/ItemLocation_ListConsumptionForLine", {"locationId": locationId}) or []


def getToleranceInstances(locationId, _refreshToken=None):
    """Flex-repeater instances for Components/PlantFloor/LineTolerances. Display only.

       sharedNote flags a row whose Max lives on an ancestor Area rather than this
       line (RowLocationCode != LineLocationCode) -- saving it there changes every
       line under that Area, not just this one."""
    out = []
    for r in listConsumptionForLine(locationId):
        r = r or {}
        mx = r.get("MaxQuantity")
        rowLoc = r.get("RowLocationCode") or ""
        lineLoc = r.get("LineLocationCode") or ""
        sharedNote = ("Shared: " + rowLoc) if (rowLoc and rowLoc != lineLoc) else ""
        out.append({
            "itemLocationId": r.get("ItemLocationId"),
            "description":    r.get("Description") or "",
            "availableText":  BlueRidge.Lots.Lot._thousands(r.get("Available") or 0),
            "maxText":        "not set" if mx is None else BlueRidge.Lots.Lot._thousands(mx),
            "maxQuantity":    mx,
            "sharedNote":     sharedNote,
        })
    return out


def setMaxQuantity(itemLocationId, maxQuantity, appUserId=None):
    """Parts.ItemLocation_SetMaxQuantity. maxQuantity None clears Max. The proc owns
       every rule (consumption point only, > 0, not below Min). Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "parts/ItemLocation_SetMaxQuantity",
        {"itemLocationId": _u(itemLocationId), "maxQuantity": _u(maxQuantity),
         "appUserId": appUserId})


def saveMaxAndNotify(itemLocationId, rawValue, appUserId=None):
    """Tolerances popup save: a blank value clears Max; a non-number is refused here
       (input parsing, not a business rule); everything else is the proc's call.
       Toasts the outcome and, on success, tells the page to recolour.

       CALLERS MUST PASS appUserId=session.custom.appUserId. This path is not
       routed through Common.Util._currentAppUserId() -- that helper reads
       system.perspective.getSessionInfo(), which returns a LIST, so it always
       falls back to the dev user (Id 2) and every Tolerances save gets
       misattributed. Fixing _currentAppUserId itself is separate, wider work;
       until then, this proc follows the same explicit-appUserId pattern as
       Lots.Lot.checkInAndNotify."""
    raw = ("%s" % (_u(rawValue) if _u(rawValue) is not None else "")).strip().replace(",", "")
    if raw == "":
        value = None
    else:
        try:
            value = int(raw)
        except (ValueError, TypeError):
            BlueRidge.Common.Notify.toast("Invalid number", "Enter a whole number, or clear Max.", "warning")
            return {"Status": 0, "Message": "Invalid number"}
    res = setMaxQuantity(itemLocationId, value, appUserId)
    BlueRidge.Common.Ui.notifyResult(res, "Max saved")
    if res and res.get("Status"):
        system.perspective.sendMessage("inventoryChanged", payload={}, scope="page")
    return res
