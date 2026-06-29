"""BlueRidge.Lots.Shipping - thin access to the Phase 7 shipping procs.

   Wrappers only; no business logic. Arc 2 Phase 7 (Shipping Dock / Sort Cage
   re-pack). All three route through BlueRidge.Common.Db.execMutation (status-row
   procs). appUserId defaults to the current operator via
   BlueRidge.Common.Util._currentAppUserId() when None. Each entry logs at default
   INFO."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def ship(shippingLabelId, appUserId=None, terminalLocationId=None):
    """Ship a Complete container via its shipping label -- validates not-on-hold +
       not-void, flips the container to Shipped. Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "ship shippingLabelId=%s appUserId=%s" % (shippingLabelId, appUserId))
    params = {"shippingLabelId": shippingLabelId, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/Container_Ship", params)


def voidLabel(shippingLabelId, voidReason=None, appUserId=None, terminalLocationId=None):
    """Void a shipping label (Sort Cage re-pack). Marks IsVoid; rejects an
       already-void label. Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "voidLabel shippingLabelId=%s appUserId=%s" % (shippingLabelId, appUserId))
    params = {"shippingLabelId": shippingLabelId, "voidReason": voidReason,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/ShippingLabel_Void", params)


def reprintLabel(shippingLabelId, printReasonCode=None, appUserId=None, terminalLocationId=None):
    """Reprint a shipping label -- appends a new label row (Initial=0) for the same
       container + AimShipperId. Returns {Status, Message, NewId (ShippingLabelId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "reprintLabel shippingLabelId=%s printReasonCode=%s appUserId=%s"
        % (shippingLabelId, printReasonCode, appUserId))
    params = {"shippingLabelId": shippingLabelId, "printReasonCode": printReasonCode,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/ShippingLabel_Reprint", params)
