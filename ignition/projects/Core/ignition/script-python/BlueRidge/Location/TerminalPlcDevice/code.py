"""BlueRidge.Location.TerminalPlcDevice - terminal -> PLC-device mapping access.

   Thin wrappers over the Plan 2 Core NQs (no business logic). The mapping row is
   a pointer: which UDT instance(s) a terminal drives. OPC addressing lives on the
   UDT instance parameters, not here (spec Sec 4.2). Routes through
   BlueRidge.Common.Db.*; appUserId defaults to the current operator when None.
"""

import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Location.Terminal
import system.tag

# Tag provider + folder holding the PlcDevices UDT instances (Plan 2). Change here
# if the provider is not 'MPP' at commissioning (mirror BlueRidge.Sim.PROVIDER).
_INSTANCE_ROOT = "[MPP]PlcDevices"


def getTerminalsForDropdown(searchText=None):
    """[{label, value}] of terminals for the mapping editor's terminal picker."""
    rows = BlueRidge.Location.Terminal.listForSelector(searchText) or []
    out = []
    for r in rows:
        r = r or {}
        tid = r.get("TerminalLocationId") or r.get("Id")
        label = ("%s - %s" % (r.get("TerminalCode") or "", r.get("TerminalName") or "")).strip(" -")
        out.append({"label": label or ("%s" % tid), "value": tid})
    return out


def getDeviceTypesForDropdown():
    """[{label, value}] of the 4 PLC UDT device types."""
    rows = BlueRidge.Common.Db.execList("location/PlcDeviceType_List") or []
    return [{"label": r.get("Name") or r.get("Code"), "value": r.get("Id")} for r in rows]


def getInstancePathOptions():
    """[{label, value}] of the imported PlcDevices/* UDT instances (browse the tag
       provider). value = the full instance path stored in UdtInstancePath. Empty
       list if the tags are not imported yet."""
    try:
        results = system.tag.browse(_INSTANCE_ROOT)
        out = []
        for r in results.getResults():
            name = "%s" % r["name"]
            path = "%s" % r["fullPath"]
            out.append({"label": name, "value": path})
        return sorted(out, key=lambda d: d["label"])
    except Exception as e:
        BlueRidge.Common.Util.log("getInstancePathOptions browse failed: %s" % e, level="warn")
        return []


def getByTerminal(terminalLocationId):
    """Active mapping rows for a terminal, ordered by SortOrder. Returns
       list[dict] of {Id, TerminalLocationId, PlcDeviceTypeId, PlcDeviceTypeCode,
       DeviceCode, UdtInstancePath, SortOrder} (per the proc's SELECT)."""
    BlueRidge.Common.Util.log("terminalLocationId=%s" % terminalLocationId)
    return BlueRidge.Common.Db.execList(
        "location/TerminalPlcDevice_GetByTerminal",
        {"terminalLocationId": terminalLocationId})


def getMappingsForTerminal(terminalLocationId):
    """The terminal's mappings shaped for the editor's flex-repeater (adds a
       0-based index each row). Empty list when no terminal / no rows."""
    if not terminalLocationId:
        return []
    rows = getByTerminal(terminalLocationId) or []
    out = []
    for i, r in enumerate(rows):
        out.append({
            "index": i,
            "id": r.get("Id"),
            "deviceCode": r.get("DeviceCode"),
            "deviceTypeName": r.get("DeviceTypeName"),
            "plcDeviceTypeId": r.get("PlcDeviceTypeId"),
            "udtInstancePath": r.get("UdtInstancePath"),
            "sortOrder": r.get("SortOrder"),
        })
    return out


def getByInstancePath(udtInstancePath):
    """Reverse lookup: the active mapping row(s) for a UDT instance path. The
       watcher derives the instance path from a fired trigger member and calls
       this to resolve the driving terminal + device type. list[dict]."""
    BlueRidge.Common.Util.log("udtInstancePath=%s" % udtInstancePath)
    return BlueRidge.Common.Db.execList(
        "location/TerminalPlcDevice_GetByInstancePath",
        {"udtInstancePath": udtInstancePath})


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
