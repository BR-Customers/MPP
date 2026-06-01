# =============================================================================
# Project Library:  BlueRidge.Parts.Tool
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          0.3 (scaffold)
#
# Description:
#   Read + mutation surface for the Tools Configuration Tool screen.
#   SCAFFOLD ONLY -- getAllForList currently returns hardcoded dummy
#   rows so the flex-repeater renders visible content while the screen
#   is being refined. Populate pass will swap to a real
#   Tools.Tool_List proc call via BlueRidge.Common.Db.execList.
#
# Encoding:
#   Source is pure ASCII. Em-dashes come from \\u2014 escapes inside
#   u"" literals, not literal characters, so Jython 2 source decoding
#   can't mangle them. The JSON pipe to Perspective sees real Unicode
#   at runtime.
#
# Layer:
#   View -> BlueRidge.Parts.Tool (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#   Views never call system.db.* directly.
# =============================================================================


def _u(value):
	"""Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
	return BlueRidge.Common.Util.extractQualifiedValues(value)


# Full meta records (one per tool) -- keys mirror what the view's
# DetailHeader bindings expect: Code, Name, Description, ToolTypeName,
# DieRankCode, DieRankName, StatusCode, plus Id and deprecated.
_DUMMY_TOOLS = [
	{
		"Id":            1,
		"Code":          "DC-042",
		"Name":          "Front Cover Die",
		"Description":   "2-cavity die for 5G0 Front Cover Assy",
		"ToolTypeName":  "Die",
		"DieRankCode":   "A",
		"DieRankName":   u"A - Premium",
		"StatusCode":    "Active",
		"deprecated":    False,
	},
	{
		"Id":            2,
		"Code":          "DC-018",
		"Name":          "Oil Pan Die",
		"Description":   "Single-cavity oil pan die",
		"ToolTypeName":  "Die",
		"DieRankCode":   "B",
		"DieRankName":   u"B - Standard",
		"StatusCode":    "Active",
		"deprecated":    False,
	},
	{
		"Id":            3,
		"Code":          "DC-031",
		"Name":          "Cam Holder Die",
		"Description":   u"Cam holder die - currently in repair",
		"ToolTypeName":  "Die",
		"DieRankCode":   "B",
		"DieRankName":   u"B - Standard",
		"StatusCode":    "UnderRepair",
		"deprecated":    False,
	},
	{
		"Id":            4,
		"Code":          "DC-007",
		"Name":          "Fuel Pump Die",
		"Description":   u"Retired 2025-11 - porosity issues",
		"ToolTypeName":  "Die",
		"DieRankCode":   "C",
		"DieRankName":   u"C - Marginal",
		"StatusCode":    "Retired",
		"deprecated":    True,
	},
]


def _toListRow(meta):
	"""Convert a full meta record to the slimmer dict ToolRow consumes."""
	return {
		"id":         meta["Id"],
		"code":       meta["Code"],
		"name":       meta["Name"],
		"rank":       meta["DieRankCode"],
		"deprecated": meta["deprecated"],
	}


def getAllForList(searchText="", statusCode="All"):
	"""Returns ToolRow-shaped rows (id/code/name/rank/deprecated),
	filtered by status + search text. Stub backed by _DUMMY_TOOLS;
	populate pass swaps to a Tools.Tool_List proc call."""
	BlueRidge.Common.Util.log("searchText=%s statusCode=%s" % (searchText, statusCode))
	needle = (searchText or "").strip().lower()
	rows = []
	for t in _DUMMY_TOOLS:
		if statusCode and statusCode != "All" and t["StatusCode"] != statusCode:
			continue
		if needle and needle not in t["Code"].lower() and needle not in t["Name"].lower():
			continue
		rows.append(_toListRow(t))
	return rows


def getInstancesForFlexRepeater(searchText="", statusCode="All", selectedId=0):
	"""Composes the flex-repeater instances payload for the tools list.
	Each instance is {'tool': <row>, 'selectedId': <int>}. Matches the
	BlueRidge.Parts.Item.getInstancesForFlexRepeater pattern."""
	searchText = _u(searchText) or ""
	statusCode = _u(statusCode) or "All"
	selectedId = _u(selectedId) or 0
	rows = getAllForList(searchText, statusCode)
	return [{"tool": r, "selectedId": selectedId} for r in rows]


def getOne(toolId):
	"""Returns the full meta record for a single tool, or None.
	Stub backed by _DUMMY_TOOLS."""
	toolId = _u(toolId)
	BlueRidge.Common.Util.log("toolId=%s" % toolId)
	if toolId is None:
		return None
	for t in _DUMMY_TOOLS:
		if t["Id"] == toolId:
			return dict(t)
	return None


def add(data):
	"""Stub. Insert a new tool. Returns {Status, Message, NewId}.
	Populate pass will replace with a Tools.Tool_Create proc call via
	BlueRidge.Common.Db.execMutation."""
	data = _u(data) or {}
	BlueRidge.Common.Util.log("data=%s" % data)
	if not data.get("Code"):
		return {"Status": "ERROR", "Message": "Code is required", "NewId": None}
	if not data.get("Name"):
		return {"Status": "ERROR", "Message": "Name is required", "NewId": None}
	# Append to the in-memory dummy list so the new row shows up in the list.
	newId = max([t["Id"] for t in _DUMMY_TOOLS] + [0]) + 1
	_DUMMY_TOOLS.append({
		"Id":            newId,
		"Code":          data.get("Code"),
		"Name":          data.get("Name"),
		"Description":   data.get("Description") or "",
		"ToolTypeName":  "Die",
		"DieRankCode":   data.get("DieRankCode") or "B",
		"DieRankName":   _rankNameForCode(data.get("DieRankCode") or "B"),
		"StatusCode":    "Active",
		"deprecated":    False,
	})
	return {"Status": "OK", "Message": "Tool created", "NewId": newId}


def _rankNameForCode(code):
	"""Local helper -- maps rank code A/B/C to display name (stub).
	Real impl will look this up via BlueRidge.Parts.DieRank.getOne."""
	return {
		"A": u"A - Premium",
		"B": u"B - Standard",
		"C": u"C - Marginal",
	}.get(code, code)


# =============================================================================
# Per-tab dummy data for Attributes / Cavities / Assignments.
# Keyed by toolId. Tools without an entry get an empty list.
# =============================================================================


def _toInt(v):
	try:
		return int(v)
	except (TypeError, ValueError):
		return None


_DUMMY_ATTRIBUTES = {
	1: [
		{"Id": 101, "AttrName": "Maintenance Interval (shots)", "Value": "25000",      "DataType": "number"},
		{"Id": 102, "AttrName": "Last Maintained",              "Value": "2026-04-01", "DataType": "date"},
		{"Id": 103, "AttrName": "Tonnage",                      "Value": "800",        "DataType": "number"},
	],
	2: [
		{"Id": 111, "AttrName": "Maintenance Interval (shots)", "Value": "30000",      "DataType": "number"},
		{"Id": 112, "AttrName": "Tonnage",                      "Value": "650",        "DataType": "number"},
	],
	3: [
		{"Id": 121, "AttrName": "Maintenance Interval (shots)", "Value": "20000",      "DataType": "number"},
		{"Id": 122, "AttrName": "Last Maintained",              "Value": "2026-03-15", "DataType": "date"},
	],
	4: [
		{"Id": 131, "AttrName": "Tonnage",                      "Value": "400",        "DataType": "number"},
	],
}

_DUMMY_CAVITIES = {
	1: [
		{"Id": 201, "Number": 1, "StatusCode": "Active", "Description": ""},
		{"Id": 202, "Number": 2, "StatusCode": "Active", "Description": ""},
		{"Id": 203, "Number": 3, "StatusCode": "Closed", "Description": "Shut off 2026-03-14 - porosity defects"},
	],
	2: [
		{"Id": 211, "Number": 1, "StatusCode": "Active", "Description": ""},
	],
	3: [
		{"Id": 221, "Number": 1, "StatusCode": "Active",  "Description": ""},
		{"Id": 222, "Number": 2, "StatusCode": "Scrapped","Description": "Cracked during heat-treat"},
	],
	4: [
		{"Id": 231, "Number": 1, "StatusCode": "Closed", "Description": "Retired with the die"},
	],
}

_DUMMY_ASSIGNMENTS = {
	1: [
		{"Id": 301, "CellName": "DC Machine #7", "AssignedAt": "2026-04-29 06:02", "ReleasedAt": None,                 "AssignedByInitials": "CM", "ReleasedByInitials": None, "Notes": "",               "IsActive": True},
		{"Id": 302, "CellName": "DC Machine #7", "AssignedAt": "2026-04-21 05:58", "ReleasedAt": "2026-04-29 05:55",   "AssignedByInitials": "JR", "ReleasedByInitials": "CM", "Notes": "",               "IsActive": False},
		{"Id": 303, "CellName": "DC Machine #3", "AssignedAt": "2026-04-10 06:10", "ReleasedAt": "2026-04-21 05:45",   "AssignedByInitials": "CM", "ReleasedByInitials": "JR", "Notes": "Loan from line 7", "IsActive": False},
		{"Id": 304, "CellName": "DC Machine #7", "AssignedAt": "2026-03-02 06:05", "ReleasedAt": "2026-04-10 06:08",   "AssignedByInitials": "JR", "ReleasedByInitials": "JR", "Notes": "",               "IsActive": False},
	],
	2: [
		{"Id": 311, "CellName": "DC Machine #4", "AssignedAt": "2026-05-12 06:00", "ReleasedAt": None,                 "AssignedByInitials": "CM", "ReleasedByInitials": None, "Notes": "",               "IsActive": True},
	],
	3: [],
	4: [
		{"Id": 331, "CellName": "DC Machine #2", "AssignedAt": "2025-09-01 06:00", "ReleasedAt": "2025-11-15 17:30",   "AssignedByInitials": "JR", "ReleasedByInitials": "CM", "Notes": "Retired post-run", "IsActive": False},
	],
}


def getAttributeInstancesForTool(toolId):
	"""Flex-repeater instances for the Attributes tab.
	Each instance is {'attr': <row>}. Returns [] for unknown tool ids."""
	toolId = _toInt(_u(toolId))
	rows = _DUMMY_ATTRIBUTES.get(toolId, [])
	return [{"attr": dict(r)} for r in rows]


def getCavityInstancesForTool(toolId):
	"""Flex-repeater instances for the Cavities tab.
	Each instance is {'cavity': <row>}. Returns [] for unknown tool ids."""
	toolId = _toInt(_u(toolId))
	rows = _DUMMY_CAVITIES.get(toolId, [])
	return [{"cavity": dict(r)} for r in rows]


def getAssignmentInstancesForTool(toolId):
	"""Flex-repeater instances for the Assignments tab history table.
	Each instance is {'assignment': <row>}. Returns [] for unknown tool ids."""
	toolId = _toInt(_u(toolId))
	rows = _DUMMY_ASSIGNMENTS.get(toolId, [])
	return [{"assignment": dict(r)} for r in rows]


def getActiveAssignmentForTool(toolId):
	"""Returns the currently-active assignment dict for the tool, or None.
	Used to populate the 'Currently mounted on...' banner."""
	toolId = _toInt(_u(toolId))
	rows = _DUMMY_ASSIGNMENTS.get(toolId, [])
	for r in rows:
		if r.get("IsActive"):
			return dict(r)
	return None
