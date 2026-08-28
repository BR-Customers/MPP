"""BlueRidge.Lots.SerializedPart - thin access to the Phase 6 serialized-part
   mint proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (Assembly / Container). Entry
   logs at default INFO. Routes through BlueRidge.Common.Db.execMutation;
   appUserId defaults to the current operator when None."""


def mint(itemId, producingLotId, appUserId=None, terminalLocationId=None,
         serialNumber=None):
    """Mint a new serialized part for an item, attributed to its producing LOT.
       serialNumber: PLC/etch-supplied serial; None/empty => auto-generate from
       the identifier sequence (FDS-06-012 NoRead bypass). Returns
       {Status, Message, NewId (SerializedPartId), SerialNumber}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "mint itemId=%s producingLotId=%s serialNumber=%s appUserId=%s"
        % (itemId, producingLotId, serialNumber, appUserId))
    params = {"itemId": itemId, "producingLotId": producingLotId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId,
              "serialNumber": serialNumber}
    return BlueRidge.Common.Db.execMutation("lots/SerializedPart_Mint", params)


def getBySerial(serialNumber):
    """Look up a serialized part by its serial number (uniqueness/dedup check
       for the MIP watcher). Returns dict or None."""
    BlueRidge.Common.Util.log("serialNumber=%s" % serialNumber)
    return BlueRidge.Common.Db.execOne(
        "lots/SerializedPart_GetBySerial", {"serialNumber": serialNumber})


# ---------------------------------------------------------------------------
# FDS-12-002 Serialized Item Search -- Global Trace detail panel
# ---------------------------------------------------------------------------

_EMPTY_TRACE_DETAIL = {
    "SerialNumber": None, "ItemId": None, "ItemPartNumber": None,
    "ProducingLotId": None, "ProducingLotName": None, "EtchedAt": None,
    "ProducedAt": None, "OperatorName": None, "MachineName": None,
    "ContainerId": None, "ContainerStatusCode": None, "AimShipperId": None,
    "CompletedAt": None,
}


def getTraceDetail(serialNumber):
    """FDS-12-002 payload for one serial: item, producing LOT, production
       date/time, operator, machine, container, AIM shipper id. Returns dict, or
       None when the serial is unknown.

       CompletedAt is container CLOSE time -- the schema has no ship timestamp
       (design spec 2.5). The view labels it "Completed", never "Ship date".

       Distinct from getBySerial above, which has a narrower contract and
       existing callers."""
    BlueRidge.Common.Util.log("getTraceDetail serialNumber=%s" % serialNumber)
    return BlueRidge.Common.Db.execOne(
        "lots/SerializedPart_GetTraceDetail", {"serialNumber": serialNumber})


def getTraceDetailOrEmpty(serialNumber):
    """Binding-safe variant: ALWAYS the fully-shaped dict. A None return would
       replace the view's shaped default and make every nested read error."""
    return getTraceDetail(serialNumber) or dict(_EMPTY_TRACE_DETAIL)
