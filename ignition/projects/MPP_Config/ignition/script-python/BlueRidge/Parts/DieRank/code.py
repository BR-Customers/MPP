# =============================================================================
# Project Library:  BlueRidge.Parts.DieRank
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          0.3 (scaffold)
#
# Description:
#   Read + mutation surface for the Die Ranks modal. SCAFFOLD ONLY --
#   returns hardcoded ranks and compatibility matrix data so the modal
#   renders. Populate pass will swap to Tools.DieRank_List /
#   Tools.DieRankCompatibility_List proc calls via
#   BlueRidge.Common.Db.execList.
#
# Encoding:
#   Source is pure ASCII. Em-dashes come from \\u2014 escapes inside
#   u"" literals, not literal characters, so Jython 2 source decoding
#   can't mangle them. The JSON pipe to Perspective sees real Unicode
#   at runtime.
#
# Layer:
#   View -> BlueRidge.Parts.DieRank (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#   Views never call system.db.* directly.
# =============================================================================


def _u(value):
	"""Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
	return BlueRidge.Common.Util.extractQualifiedValues(value)


_DUMMY_RANKS = [
	{"Id": 1, "Code": "A", "Name": "Premium",  "SortOrder": 1},
	{"Id": 2, "Code": "B", "Name": "Standard", "SortOrder": 2},
	{"Id": 3, "Code": "C", "Name": "Marginal", "SortOrder": 3},
]

# Pairs of (fromCode, toCode) that ARE compatible. Anything not listed
# is blocked. Mirrors are computed at render time so we only store the
# upper triangle.
_DUMMY_COMPATIBLE_PAIRS = {
	("A", "A"), ("A", "B"),
	            ("B", "B"),
	                        ("C", "C"),
}


def getAllForList():
	"""Returns rank rows in the shape the DieRanks modal expects."""
	BlueRidge.Common.Util.log("call")
	return [dict(r) for r in _DUMMY_RANKS]


def getForDropdown():
	"""Returns [{label:'A - Premium', value:'A'}, ...] for the Die Rank
	dropdown on Add Die / Tool detail header. Em-dash via \\u2014 escape
	so the source stays pure ASCII regardless of Jython's source-decoding
	defaults."""
	return [
		{"label": u"%s - %s" % (r["Code"], r["Name"]), "value": r["Code"]}
		for r in _DUMMY_RANKS
	]


def getInstancesForFlexRepeater():
	"""Composes the flex-repeater instances payload for the rank list.
	Each instance is {'rank': <row>}. Mirrors the Tool.getInstancesForFlexRepeater pattern."""
	ranks = sorted(_DUMMY_RANKS, key=lambda r: r["SortOrder"])
	return [{"rank": dict(r)} for r in ranks]


def getMatrixHeaderInstances():
	"""Flex-repeater instances for the matrix column headers.
	Each instance is {'header': {code, label}}."""
	ranks = sorted(_DUMMY_RANKS, key=lambda r: r["SortOrder"])
	return [
		{"header": {"code": r["Code"], "label": u"%s - %s" % (r["Code"], r["Name"])}}
		for r in ranks
	]


def getMatrixRowInstances():
	"""Flex-repeater instances for the matrix body rows.
	Each instance is {'row': {fromCode, label, cells: [...]}} where the
	inner cells list is already wrapped for the per-row CellRepeater:
	[{cell: {fromCode, toCode, compatible, mirror}}, ...]."""
	ranks = sorted(_DUMMY_RANKS, key=lambda r: r["SortOrder"])
	rankCodes = [r["Code"] for r in ranks]
	matrix = getCompatibilityMatrix()
	rowInstances = []
	for r in ranks:
		cellInstances = []
		for toCode in rankCodes:
			isMirror = rankCodes.index(r["Code"]) > rankCodes.index(toCode)
			compatible = bool(matrix.get(r["Code"], {}).get(toCode, False))
			cellInstances.append({
				"cell": {
					"fromCode":   r["Code"],
					"toCode":     toCode,
					"compatible": compatible,
					"mirror":     isMirror,
				}
			})
		rowInstances.append({
			"row": {
				"fromCode": r["Code"],
				"label":    u"%s - %s" % (r["Code"], r["Name"]),
				"cells":    cellInstances,
			}
		})
	return rowInstances


def getCompatibilityMatrix():
	"""Returns a nested dict {fromCode: {toCode: bool}} representing the
	full pairwise compatibility matrix. Symmetric -- matrix[a][b] always
	equals matrix[b][a]. Cell bindings in the view use dotted paths like
	{view.custom.matrix.A.B} to look up state."""
	ranks = [r["Code"] for r in _DUMMY_RANKS]
	matrix = {}
	for fromCode in ranks:
		matrix[fromCode] = {}
		for toCode in ranks:
			pair = (fromCode, toCode)
			mirror_pair = (toCode, fromCode)
			matrix[fromCode][toCode] = (pair in _DUMMY_COMPATIBLE_PAIRS) or (mirror_pair in _DUMMY_COMPATIBLE_PAIRS)
	return matrix


def getOne(dieRankId):
	"""Single-row lookup. Returns dict or None. Stub backed by _DUMMY_RANKS."""
	dieRankId = _u(dieRankId)
	BlueRidge.Common.Util.log("dieRankId=%s" % dieRankId)
	if dieRankId is None:
		return None
	for r in _DUMMY_RANKS:
		if r["Id"] == dieRankId:
			return dict(r)
	return None


def add(data):
	"""Append a new die rank to _DUMMY_RANKS. Returns {Status, Message, NewId}.
	Populate pass swaps for Tools.DieRank_Create via execMutation."""
	data = _u(data) or {}
	BlueRidge.Common.Util.log("data=%s" % data)
	code = (data.get("Code") or "").strip()
	name = (data.get("Name") or "").strip()
	if not code:
		return {"Status": "ERROR", "Message": "Code is required", "NewId": None}
	if not name:
		return {"Status": "ERROR", "Message": "Name is required", "NewId": None}
	# Disallow duplicate code (case-insensitive).
	for r in _DUMMY_RANKS:
		if r["Code"].upper() == code.upper():
			return {"Status": "ERROR", "Message": "Code '%s' already exists" % code, "NewId": None}
	newId = max([r["Id"] for r in _DUMMY_RANKS] + [0]) + 1
	newSortOrder = max([r["SortOrder"] for r in _DUMMY_RANKS] + [0]) + 1
	_DUMMY_RANKS.append({
		"Id":        newId,
		"Code":      code,
		"Name":      name,
		"SortOrder": newSortOrder,
	})
	return {"Status": "OK", "Message": "Die rank created", "NewId": newId}


def update(data):
	"""Update an existing die rank by Id. Returns {Status, Message}."""
	data = _u(data) or {}
	BlueRidge.Common.Util.log("data=%s" % data)
	dieRankId = data.get("Id")
	code = (data.get("Code") or "").strip()
	name = (data.get("Name") or "").strip()
	if dieRankId is None:
		return {"Status": "ERROR", "Message": "Id is required for update"}
	if not code:
		return {"Status": "ERROR", "Message": "Code is required"}
	if not name:
		return {"Status": "ERROR", "Message": "Name is required"}
	# Disallow Code collision with other ranks.
	for r in _DUMMY_RANKS:
		if r["Id"] != dieRankId and r["Code"].upper() == code.upper():
			return {"Status": "ERROR", "Message": "Code '%s' already in use" % code}
	for r in _DUMMY_RANKS:
		if r["Id"] == dieRankId:
			r["Code"] = code
			r["Name"] = name
			return {"Status": "OK", "Message": "Die rank updated"}
	return {"Status": "ERROR", "Message": "Die rank id %s not found" % dieRankId}


def deprecate(dieRankId):
	"""Remove a die rank from _DUMMY_RANKS. Returns {Status, Message}."""
	dieRankId = _u(dieRankId)
	BlueRidge.Common.Util.log("dieRankId=%s" % dieRankId)
	if dieRankId is None:
		return {"Status": "ERROR", "Message": "Id is required"}
	for i, r in enumerate(_DUMMY_RANKS):
		if r["Id"] == dieRankId:
			_DUMMY_RANKS.pop(i)
			return {"Status": "OK", "Message": "Die rank removed"}
	return {"Status": "ERROR", "Message": "Die rank id %s not found" % dieRankId}


def setCompatibility(fromCode, toCode, compatible):
	"""Stub. Toggle a single matrix cell. Returns {Status, Message}."""
	BlueRidge.Common.Util.log("fromCode=%s toCode=%s compatible=%s"
	                          % (fromCode, toCode, compatible))
	return {"Status": "OK", "Message": "Compatibility updated (stub)"}
