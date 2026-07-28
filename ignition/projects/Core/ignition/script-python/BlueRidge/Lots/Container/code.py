"""BlueRidge.Lots.Container - thin access to the Phase 6 Container procs.

   Wrappers only; no business logic. Arc 2 Phase 6 (Assembly / Container). Each
   entry logs at default INFO (meaningful shop-floor events, not debug noise).
   Mutations route through BlueRidge.Common.Db.execMutation (status-row procs);
   the read routes through execList. appUserId defaults to the current operator
   via BlueRidge.Common.Util._currentAppUserId() when None."""

import BlueRidge.Common.Db
import BlueRidge.Common.Notify
import BlueRidge.Common.Util
import BlueRidge.Lots.ShippingDispatcher


def open(itemId, containerConfigId, cellLocationId, appUserId=None, terminalLocationId=None):
    """Open a new container at a Cell against an item + container config.
       Returns {Status, Message, NewId (ContainerId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "open itemId=%s containerConfigId=%s cellLocationId=%s appUserId=%s"
        % (itemId, containerConfigId, cellLocationId, appUserId))
    params = {"itemId": itemId, "containerConfigId": containerConfigId,
              "cellLocationId": cellLocationId, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/Container_Open", params)


def trayClose(containerId, trayPosition, partsCount, closureMethod=None, appUserId=None, terminalLocationId=None):
    """Close a tray within a container, recording its parts count + closure method.
       Returns {Status, Message, NewId (ContainerTrayId), ContainerAccumulatedParts}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "trayClose containerId=%s trayPosition=%s partsCount=%s closureMethod=%s appUserId=%s"
        % (containerId, trayPosition, partsCount, closureMethod, appUserId))
    params = {"containerId": containerId, "trayPosition": trayPosition,
              "partsCount": partsCount, "closureMethod": closureMethod,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/ContainerTray_Close", params)


def serialAdd(containerId, serializedPartId, containerTrayId=None, trayPosition=None,
              hardwareInterlockBypassed=False, appUserId=None, terminalLocationId=None):
    """Add a serialized part to a container (optionally pinned to a tray /
       tray position). hardwareInterlockBypassed flags a manual override of the
       PLC interlock. Returns {Status, Message, NewId (ContainerSerialId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "serialAdd containerId=%s serializedPartId=%s containerTrayId=%s trayPosition=%s bypass=%s appUserId=%s"
        % (containerId, serializedPartId, containerTrayId, trayPosition, hardwareInterlockBypassed, appUserId))
    params = {"containerId": containerId, "containerTrayId": containerTrayId,
              "trayPosition": trayPosition, "serializedPartId": serializedPartId,
              "hardwareInterlockBypassed": hardwareInterlockBypassed,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/ContainerSerial_Add", params)


def complete(containerId, operatorConfirmed=False, plcCompletionConfirmed=False,
             appUserId=None, terminalLocationId=None):
    """Complete (close out) a full container -- claims an AIM shipper ID + prints
       the shipping label when configured. Returns
       {Status, Message, ShippingLabelId, AimShipperId, LabelPrint (dispatch outcome,
       present only when a ShippingLabelId was claimed)}."""
    from java.lang import Throwable
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "complete containerId=%s operatorConfirmed=%s plcCompletionConfirmed=%s appUserId=%s"
        % (containerId, operatorConfirmed, plcCompletionConfirmed, appUserId))
    params = {"containerId": containerId, "plcCompletionConfirmed": plcCompletionConfirmed,
              "operatorConfirmed": operatorConfirmed, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    result = BlueRidge.Common.Db.execMutation("lots/Container_Complete", params)
    # Print the container's shipping label. Mirrors Workorder.Machining.mint: check the
    # RETURNED Status (dispatchContainer does not raise for the common shop-floor cases)
    # AND catch genuine exceptions -- either way NEVER lose the completed container.
    # Complete and print are separate steps (FDS-07-005/006a).
    if result and result.get("Status") and result.get("ShippingLabelId") is not None:
        try:
            printRes = BlueRidge.Lots.ShippingDispatcher.dispatchContainer(
                containerId, terminalLocationId, result.get("ShippingLabelId"))
        except Throwable as t:
            printRes = {"Status": 0, "Message": "print raised: %s" % (t.getMessage() or t)}
        except Exception as e:
            printRes = {"Status": 0, "Message": "print raised: %s" % e}
        result["LabelPrint"] = printRes
        if not (printRes and printRes.get("Status")):
            BlueRidge.Common.Util.log(
                "Container shipping label print failed: %s" % (printRes or {}).get("Message"))
            try:
                BlueRidge.Common.Notify.toast(
                    "Label not printed",
                    "The container was completed but its shipping label did not print. "
                    "Reprint from the Shipping Dock.",
                    "warning")
            except:
                # Gateway scope (PLC auto-complete) has no session to toast into.
                # The container is already committed; never let a toast failure escape.
                pass
    return result


def getOpenByCell(cellLocationId, _refreshToken=None):
    """Read the OPEN container(s) at a Cell with fill progress (TargetParts /
       AccumulatedParts / ClosedTrays). Returns list[dict] (empty list = none
       open)."""
    BlueRidge.Common.Util.log("getOpenByCell cellLocationId=%s" % cellLocationId)
    params = {"cellLocationId": cellLocationId}
    return BlueRidge.Common.Db.execList("lots/Container_GetOpenByCell", params)
