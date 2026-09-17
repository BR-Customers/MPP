"""BlueRidge.Lots.Shipping - thin access to the Phase 7 shipping procs.

   Wrappers only; no business logic. Arc 2 Phase 7 (Shipping Dock / Sort Cage
   re-pack). All three route through BlueRidge.Common.Db.execMutation (status-row
   procs). appUserId defaults to the current operator via
   BlueRidge.Common.Util._currentAppUserId() when None. Each entry logs at default
   INFO."""


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


def getLastForTerminal(terminalLocationId):
    """Most recent non-void shipping label printed at this terminal, or None.
       Powers a plant-floor "Reprint" button that acts on the last label without
       the operator knowing a ShippingLabelId (e.g. a dropped/damaged label)."""
    rows = BlueRidge.Common.Db.execList(
        "lots/ShippingLabel_GetLastForTerminal", {"terminalLocationId": terminalLocationId})
    return rows[0] if rows else None


def reprintLastForTerminal(terminalLocationId, appUserId=None):
    """Reprint the most recent shipping label printed at this terminal -- for an
       operator who dropped or damaged the label they already got, at the
       terminal itself rather than through the Shipping Dock. {Status, Message}
       shaped for notifyResult; no label yet at this terminal is a business-rule
       miss, not an exception."""
    last = getLastForTerminal(terminalLocationId)
    if last is None:
        return {"Status": False, "Message": "No shipping label has printed at this terminal yet."}
    return reprintLabel(last.get("Id"), appUserId=appUserId, terminalLocationId=terminalLocationId)


def ackBanner(shippingLabelId):
    """Acknowledge (dismiss) a print-failure banner (Brief D). Sets BannerAcknowledgedAt
       so the label stops re-broadcasting from PrintFailureGateway.broadcastTick.
       Returns {Status, Message}."""
    sid = BlueRidge.Common.Util.extractQualifiedValues(shippingLabelId)
    BlueRidge.Common.Util.log("ackBanner shippingLabelId=%s" % sid)
    return BlueRidge.Common.Db.execMutation("lots/ShippingLabel_AckBanner", {"shippingLabelId": sid})
