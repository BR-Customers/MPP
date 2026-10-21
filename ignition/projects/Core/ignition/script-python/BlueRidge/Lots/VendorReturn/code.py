"""BlueRidge.Lots.VendorReturn - return received material to the vendor (super-lot piece 5).

   An operator MARKS a quantity of a received LOT for return; a supervisor
   CONFIRMS it (the pieces physically leave) or CANCELS it (the marked
   quantity is restored). What may be marked, the quantity taken from the LOT
   and what a return does to a super-lot's results are all decided in the
   Lots.VendorReturn_* procs.

   THIN WRAPPERS ONLY. Every mutation takes the appUserId the view resolved
   (BlueRidge.Common.Session.currentAppUserId(self.session)); never defaulted
   here.

   Public surface:
     mark(lotId, quantity, remarks, appUserId, terminalLocationId)
     confirm(vendorReturnId, appUserId, terminalLocationId)
     cancel(vendorReturnId, cancelRemarks, appUserId, terminalLocationId)
     listOpen(_t) / openCount(_t) / listByLot(lotId, _t)
     getEligibilityOrEmpty(lotId, _t...)  whether the LOT can be returned + why not (SQL decides)

   Display shaping (no rules -- StateCode / CanCancel come from SQL):
     listByLotInstances(lotId, _t)   LOT Detail "Vendor return" tab rows
     listOpenInstances(_t)           Supervisor Dashboard popup rows"""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _int(value):
    return BlueRidge.Common.Util.toIntOrNone(_u(value))


# ---- mutations --------------------------------------------------------------

def mark(lotId, quantity, remarks, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("VendorReturn.mark lotId=%s qty=%s" % (lotId, quantity))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/VendorReturn_Mark", {
        "lotId": _int(lotId), "quantity": _int(quantity), "remarks": (_u(remarks) or None),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def confirm(vendorReturnId, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("VendorReturn.confirm vendorReturnId=%s" % vendorReturnId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/VendorReturn_Confirm", {
        "vendorReturnId": _int(vendorReturnId), "appUserId": appUserId,
        "terminalLocationId": _u(terminalLocationId)})


def cancel(vendorReturnId, cancelRemarks, appUserId, terminalLocationId):
    """cancelRemarks is required; the proc refuses a blank one."""
    BlueRidge.Common.Util.log("VendorReturn.cancel vendorReturnId=%s" % vendorReturnId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("lots/VendorReturn_Cancel", {
        "vendorReturnId": _int(vendorReturnId), "cancelRemarks": _u(cancelRemarks),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


# ---- reads -------------------------------------------------------------------

def listOpen(_refreshToken=None):
    """Marked-but-unconfirmed returns, oldest first as SQL orders them."""
    return BlueRidge.Common.Db.execList("lots/VendorReturn_ListOpen", {}) or []


def openCount(_refreshToken=None):
    """How many returns await confirmation (0 hides the badge)."""
    try:
        return len(listOpen())
    except:
        return 0


_EMPTY_ELIGIBILITY = {"LotId": None, "CanReturnToVendor": False, "Reason": ""}


def getEligibilityOrEmpty(lotId, _statusToken=None, _countToken=None):
    """Binding source for the LOT Detail "Vendor return" tab: may this LOT be
    returned to a vendor, and if not, the refusal text VendorReturn_Mark would
    give. The rule lives in SQL (Lots.ufn_LotReturnableToVendor via
    Lots.VendorReturn_GetEligibility); nothing is decided here. Always the full
    shape -- never None -- so the bound custom prop never goes Quality-Bad. The
    token args only make the binding re-run when the LOT's status or count
    changes."""
    lid = _int(lotId)
    if not lid:
        return dict(_EMPTY_ELIGIBILITY)
    row = BlueRidge.Common.Db.execOne("lots/VendorReturn_GetEligibility", {"lotId": lid})
    if not row:
        return dict(_EMPTY_ELIGIBILITY)
    return {"LotId": row.get("LotId"),
            "CanReturnToVendor": bool(row.get("CanReturnToVendor")),
            "Reason": row.get("Reason") or ""}


def listByLot(lotId, _refreshToken=None):
    lid = _int(lotId)
    if lid is None:
        return []
    return BlueRidge.Common.Db.execList("lots/VendorReturn_ListByLot", {"lotId": lid}) or []


# ---- display shaping ----------------------------------------------------------
# Flex-repeater instances, one {"row": {...}} each, with every time already
# formatted: a Date serializes to a string on the repeater param hop, so a
# dateFormat in the child view would render the raw value (same reason as
# Lots.Lot.mapScrapEventInstances). The procs return times in Eastern already.

_DOT = u" \u00b7 "


def _when(value, pattern="MM/dd HH:mm"):
    v = _u(value)
    if v is None or v == "":
        return ""
    try:
        return system.date.format(v, pattern)
    except:
        return ("%s" % v)[:16]


def _stamp(at, initials):
    return _DOT.join([x for x in (_when(at), initials or "") if x])


def listByLotInstances(lotId, _refreshToken=None):
    """Rows for the LOT Detail "Vendor return" tab, newest first. Always a list."""
    out = []
    for r in listByLot(lotId):
        state = r.get("StateCode") or ""
        if state == "Confirmed":
            stateText = "Returned " + _stamp(r.get("ConfirmedAt"), r.get("ConfirmedByInitials"))
        elif state == "Cancelled":
            stateText = _DOT.join([x for x in ("Cancelled", r.get("CancelRemarks") or "") if x])
        else:
            stateText = "Waiting to go back"
        out.append({"row": {
            "vendorReturnId": r.get("VendorReturnId"),
            "lotId":          _int(lotId),
            "quantity":       int(r.get("Quantity") or 0),
            "marked":         _stamp(r.get("MarkedAt"), r.get("MarkedByInitials")),
            "remarks":        r.get("Remarks") or "",
            "stateCode":      state,
            "stateText":      stateText,
            "canCancel":      bool(r.get("CanCancel")),
        }})
    return out


def listOpenInstances(_refreshToken=None):
    """Rows for the dashboard's "Parts to return" popup, oldest first. Always a list."""
    out = []
    for r in listOpen():
        out.append({"row": {
            "vendorReturnId": r.get("VendorReturnId"),
            "lotId":          r.get("LotId"),
            "lotName":        r.get("LotName") or "",
            "part":           r.get("ItemPartNumber") or "",
            "vendorLot":      r.get("VendorLotNumber") or "",
            "quantity":       int(r.get("Quantity") or 0),
            "marked":         _stamp(r.get("MarkedAt"), r.get("MarkedByInitials")),
            "remarks":        r.get("Remarks") or "",
            "where":          r.get("CurrentLocationName") or "",
        }})
    return out
