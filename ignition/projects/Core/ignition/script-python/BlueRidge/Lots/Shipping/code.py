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


def listRecentByCell(cellLocationId, topN=10):
    """Recent shipping labels for containers at or under an Assembly OUT cell --
       one row per container (its newest non-void label), newest first. The pick
       list for Components/PlantFloor/ShippingLabelReprint. Returns list[dict]
       (empty when none / no cell). Columns: Id, ContainerId, AimShipperId, Serial,
       ItemId, PartNumber, ItemDescription, Quantity, Initial, PrintReasonCode,
       PrintStatus (Printed/Failed/Pending), CreatedAt, PrintedAt (both Eastern)."""
    cid = BlueRidge.Common.Util.extractQualifiedValues(cellLocationId)
    if cid is None:
        return []
    return BlueRidge.Common.Db.execList("lots/ShippingLabel_ListRecentByCell",
                                        {"cellLocationId": cid, "topN": topN})


def reprintAndDispatch(shippingLabelId, printReasonCode, appUserId, terminalLocationId=None):
    """Reprint a shipping label AND send it to the printer now.

       reprintLabel() only appends the Initial=0 row; nothing dispatches it, so on its
       own the label would sit until PrintFailureGateway.sweepTick next re-fires
       stranded rows (every ~5 min, rows older than ~60 s). This dispatches the new
       row immediately through ShippingDispatcher (gateway-async, 3 attempts; the
       outcome lands on the row + print-failure banner).

       appUserId is REQUIRED -- the elevated approver's id from AppUser.elevate(),
       not the session operator (the stateless elevation form never replaces the
       session user). Returns {Status, Message, NewId, Dispatched}: Status 0 if the
       reprint row was not written; otherwise Status 1, with Dispatched False when the
       print could not even start (no endpoint / no ZPL) -- the row is still there for
       the stranded sweep, which will flag it on the print-failure banner."""
    if appUserId is None:
        return {"Status": 0, "Message": "Reprint needs an approving user.", "NewId": None}
    res = reprintLabel(shippingLabelId, printReasonCode=printReasonCode,
                       appUserId=appUserId, terminalLocationId=terminalLocationId) or {}
    if not res.get("Status"):
        return {"Status": 0, "Message": res.get("Message") or "Reprint failed.", "NewId": None}
    newId = res.get("NewId")
    disp = BlueRidge.Lots.ShippingDispatcher.dispatch(
        shippingLabelId=newId, terminalLocationId=terminalLocationId) or {}
    if disp.get("Status"):
        return {"Status": 1, "Message": "Shipping label reprinted and sent to the printer.",
                "NewId": newId, "Dispatched": True}
    return {"Status": 1,
            "Message": "Reprint recorded, but it could not be sent to the printer: %s"
                       % (disp.get("Message") or "unknown error"),
            "NewId": newId, "Dispatched": False}


# Elevation action code for the reprint. Recorded on the ElevationGranted /
# ElevationDenied audit row today; it is also the key a future per-action role
# rule would match on (no role gate exists yet -- any active AD-mapped user may
# approve, same as every other protected action).
REPRINT_ACTION_CODE = "ShippingLabelReprint"


def reprintFromPopup(adAccount, password, shippingLabelId, printReasonCode, terminalLocationId=None):
    """Submit handler for Components/PlantFloor/ShippingLabelReprint.

       Stateless one-shot elevation (the Popups/CrtValidation form, NOT
       Common.Session.requireElevation): the approver's AD credential is checked
       for this one action and their AppUser id is attributed to the reprint. The
       session is never switched to the approver, so the operator stays signed in
       and nothing after the reprint is attributed to the supervisor.

       Order: selection + reason are checked first (no credential challenge for an
       incomplete form), then elevation, then reprint + immediate dispatch. Every
       outcome is toasted here. Returns True when the reprint row was written (the
       popup closes), False otherwise (the popup stays open to correct and retry)."""
    sid = BlueRidge.Common.Util.extractQualifiedValues(shippingLabelId)
    reason = ("%s" % (BlueRidge.Common.Util.extractQualifiedValues(printReasonCode) or "")).strip()
    if sid is None:
        BlueRidge.Common.Notify.toast("Reprint", "Select the shipping label to reprint.", "warning")
        return False
    if not reason:
        BlueRidge.Common.Notify.toast("Reprint", "Choose a reprint reason.", "warning")
        return False
    el = BlueRidge.Location.AppUser.elevate(adAccount, password, REPRINT_ACTION_CODE,
                                            terminalLocationId) or {}
    if not el.get("success"):
        BlueRidge.Common.Notify.toast("Elevation failed",
                                      el.get("message") or "Authentication failed.", "error")
        return False
    res = reprintAndDispatch(sid, reason, el.get("appUserId"), terminalLocationId)
    if not res.get("Status"):
        BlueRidge.Common.Notify.toast("Reprint failed", res.get("Message") or "", "error")
        return False
    if res.get("Dispatched"):
        BlueRidge.Common.Notify.toast("Label reprinted", res.get("Message") or "", "success")
    else:
        BlueRidge.Common.Notify.toast("Label not sent", res.get("Message") or "", "warning")
    return True


def ackBanner(shippingLabelId):
    """Acknowledge (dismiss) a print-failure banner (Brief D). Sets BannerAcknowledgedAt
       so the label stops re-broadcasting from PrintFailureGateway.broadcastTick.
       Returns {Status, Message}."""
    sid = BlueRidge.Common.Util.extractQualifiedValues(shippingLabelId)
    BlueRidge.Common.Util.log("ackBanner shippingLabelId=%s" % sid)
    return BlueRidge.Common.Db.execMutation("lots/ShippingLabel_AckBanner", {"shippingLabelId": sid})
