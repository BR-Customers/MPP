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
     listOpen(_t) / openCount(_t) / listByLot(lotId, _t)"""


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


def listByLot(lotId, _refreshToken=None):
    lid = _int(lotId)
    if lid is None:
        return []
    return BlueRidge.Common.Db.execList("lots/VendorReturn_ListByLot", {"lotId": lid}) or []
