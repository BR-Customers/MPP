"""BlueRidge.Parts.ItemLocation - thin read access to ItemLocation eligibility.

   Wrappers only; no business logic. Arc 2 Phase 4 (Movement Scan FDS-02-012)."""


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
    """Consumption parts for the Tolerances popup (Parts.ItemLocation_ListConsumptionForLine):
       ItemLocationId, ItemId, Description, Available, MaxQuantity, MinQuantity,
       RowLocationCode. Returns [] when there is no location."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "parts/ItemLocation_ListConsumptionForLine", {"locationId": locationId}) or []


def getToleranceInstances(locationId, _refreshToken=None):
    """Flex-repeater instances for Components/PlantFloor/LineTolerances. Display only."""
    out = []
    for r in listConsumptionForLine(locationId):
        r = r or {}
        mx = r.get("MaxQuantity")
        out.append({
            "itemLocationId": r.get("ItemLocationId"),
            "description":    r.get("Description") or "",
            "availableText":  BlueRidge.Lots.Lot._thousands(r.get("Available") or 0),
            "maxText":        "not set" if mx is None else BlueRidge.Lots.Lot._thousands(mx),
            "maxQuantity":    mx,
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
