"""BlueRidge.Location.TerminalPlcDevice - terminal -> PLC-device mapping access.

   Thin wrappers over the Plan 2 Core NQs (no business logic). The mapping row is
   a pointer: which UDT instance(s) a terminal drives. OPC addressing lives on the
   UDT instance parameters, not here (spec Sec 4.2). Routes through
   BlueRidge.Common.Db.*; appUserId defaults to the current operator when None.
"""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getByTerminal(terminalLocationId):
    """Active mapping rows for a terminal, ordered by SortOrder. Returns
       list[dict] of {Id, TerminalLocationId, PlcDeviceTypeId, PlcDeviceTypeCode,
       DeviceCode, UdtInstancePath, SortOrder} (per the proc's SELECT)."""
    BlueRidge.Common.Util.log("terminalLocationId=%s" % terminalLocationId)
    return BlueRidge.Common.Db.execList(
        "location/TerminalPlcDevice_GetByTerminal",
        {"terminalLocationId": terminalLocationId})


def save(data, appUserId=None):
    """Insert (Id None) or update a mapping row. Returns {Status, Message, NewId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "id": data.get("id"),
        "terminalLocationId": data.get("terminalLocationId"),
        "plcDeviceTypeId": data.get("plcDeviceTypeId"),
        "deviceCode": data.get("deviceCode"),
        "udtInstancePath": data.get("udtInstancePath"),
        "sortOrder": data.get("sortOrder"),
        "appUserId": appUserId,
    }
    BlueRidge.Common.Util.log("save params=%s" % params)
    return BlueRidge.Common.Db.execMutation("location/TerminalPlcDevice_Save", params)


def deprecate(id, appUserId=None):
    """Soft-delete a mapping row. Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log("id=%s" % id)
    return BlueRidge.Common.Db.execMutation(
        "location/TerminalPlcDevice_Deprecate",
        {"id": id, "appUserId": appUserId})
