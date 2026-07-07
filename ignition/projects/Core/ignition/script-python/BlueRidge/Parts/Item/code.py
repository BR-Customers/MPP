# =============================================================================
# Project Library:  BlueRidge.Parts.Item
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.2
#
# Description:
#   Read + mutation surface for the Item Master Configuration Tool
#   screen. Routes every DB call through BlueRidge.Common.Db.* helpers.
#
# Public surface:
#   getAll(searchText=None, itemTypeId=None, includeDeprecated=False)
#                          -> list[dict]
#   getOne(itemId)         -> dict | None
#   getOneOrEmpty(itemId)  -> dict (full key-shape, null values when no row)
#   mapItemRowsForList(rows, typeFilter='All Types') -> list[dict]
#   typeBadgeFor(itemTypeName) -> str
#   getAllForList(searchText='', typeFilter='All Types') -> list[dict]
#   getInstancesForFlexRepeater(...) -> list[dict]
#   itemMasterTabLabels(sectionDirty) -> list[str]
#   itemMasterTabObjects(sectionDirty, activeTab) -> list[dict]
#   add(meta)              -> {Status, Message, NewId}
#   update(meta)           -> {Status, Message}
#   deprecate(itemId)      -> {Status, Message}
#   emptyMeta()            -> dict (blank shape for AddItem popup)
#
# Layer:
#   View -> BlueRidge.Parts.Item (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (read paths only).
#   2026-05-26 - 1.1 - Phase 4: getOneOrEmpty + itemMasterTabLabels +
#                      itemMasterTabObjects helpers.
#   2026-05-26 - 1.2 - Phase 3: add() + update() + deprecate() +
#                      emptyMeta() mutation surface. Key-tolerant
#                      (camelCase OR PascalCase) so the AddItem popup
#                      (camelCase draft) and the Identity embed
#                      (PascalCase editDraft from Item_Get) both work.
# =============================================================================


_TYPE_BADGE = {
    "Finished Good": "FG",
    "Component":     "COMP",
    "Sub-Assembly":  "SA",
    "Raw Material":  "RAW",
    "Pass-Through":  "PT",
}


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def typeBadgeFor(itemTypeName):
    """Returns short-form badge text (FG / COMP / SA / RAW / PT) for the
    given item-type name. Unknown names -> '' (no exception)."""
    return _TYPE_BADGE.get(itemTypeName or "", "")


def getAll(searchText=None, itemTypeId=None, includeDeprecated=False):
    """List items with optional server-side SearchText (PartNumber +
    Description LIKE) and ItemTypeId filter. Includes ItemType.Name and
    Uom.Code joins."""
    BlueRidge.Common.Util.log(
        "searchText=%s itemTypeId=%s includeDeprecated=%s"
        % (searchText, itemTypeId, includeDeprecated))
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Item_List",
            {
                "itemTypeId":        itemTypeId,
                "searchText":        searchText,
                "includeDeprecated": 1 if includeDeprecated else 0,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load items", str(e), "error")
        return []


def getOne(itemId):
    """Single-row Item lookup with ItemType + UOM joins. Returns dict or
    None."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if itemId is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne(
            "parts/Item_Get",
            {"id": itemId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getOne failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load item", str(e), "error")
        return None


_ITEM_SHAPE_KEYS = (
    "Id", "PartNumber", "Description",
    "ItemTypeId", "ItemTypeName",
    "UomId", "UomCode",
    "WeightUomId", "WeightUomCode",
    "MacolaPartNumber", "CountryOfOrigin",
    "UnitWeight", "DefaultSubLotQty", "PartsPerBasket",
    "MaxLotSize", "MaxParts",
    "CreatedAt", "CreatedByUserId",
    "UpdatedAt", "UpdatedByUserId",
    "DeprecatedAt",
)


def getOneOrEmpty(itemId):
    """Like getOne but returns the full Item key-shape with null values
    instead of None when itemId is null/missing. Designed for use as a
    runScript binding source for view.custom.selectedItem where bindings
    traverse the dict on every render — None breaks Quality, empty-shape
    {Id: None, PartNumber: None, ...} renders cleanly."""
    row = getOne(itemId)
    if row:
        return row
    return dict((k, None) for k in _ITEM_SHAPE_KEYS)


def getEligibleForLocationDropdown(locationId):
    """Items eligible at a Location, shaped for ia.input.dropdown:
        [{label: '<PartNumber> - <Description>', value: Id}].
    Always a list (never None). Empty if locationId is None or nothing is eligible.
    Wraps Parts.Item_ListEligibleForLocation. Used by the die-cast entry screen's
    eligibility-constrained Item dropdown."""
    locationId = _u(locationId)
    BlueRidge.Common.Util.log("getEligibleForLocationDropdown locationId=%s" % locationId)
    if locationId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/Item_ListEligibleForLocation", {"locationId": locationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getEligibleForLocationDropdown failed: %s" % str(e))
        return []
    out = []
    for r in (rows or []):
        pn = r.get("PartNumber") or ""
        desc = r.get("Description") or ""
        label = ("%s - %s" % (pn, desc)) if desc else pn
        out.append({"label": label, "value": r.get("Id")})
    return out


def mapItemRowsForList(rows, typeFilter="All Types"):
    """Flex-repeater instances transform.

    - Filters by ItemTypeName when typeFilter != 'All Types'.
    - Maps DB columns to the ItemRow view-param shape.

    Defensive against Dataset input (Ignition custom-prop layer can coerce
    stored lists back to Dataset when read via expression). Returns
    list[dict] ready for Repeater.props.instances composition."""
    rows = _u(rows)
    if rows is None:
        return []
    if hasattr(rows, "getColumnNames") and hasattr(rows, "getRowCount"):
        headers = list(rows.getColumnNames())
        rows = [dict(zip(headers, row)) for row in rows]
    typeFilter = _u(typeFilter)
    keepAll = (not typeFilter) or typeFilter == "All Types"
    out = []
    for r in rows:
        itemTypeName = r.get("ItemTypeName") or ""
        if (not keepAll) and itemTypeName != typeFilter:
            continue
        out.append({
            "id":           r.get("Id"),
            "partNumber":   r.get("PartNumber") or "",
            "description": r.get("Description") or "",
            "itemTypeId":   r.get("ItemTypeId"),
            "itemTypeName": itemTypeName,
            "typeBadge":    typeBadgeFor(itemTypeName),
            "isDraft":      False,
        })
    return out


def getAllForList(searchText="", typeFilter="All Types"):
    """One-shot getAll + map composed for the expression binding on
    view.custom.items. Server-side filter on SearchText; client-side
    filter on type name."""
    searchText = _u(searchText) or ""
    typeFilter = _u(typeFilter) or "All Types"
    rows = getAll(
        searchText=searchText if searchText.strip() else None,
        itemTypeId=None,
        includeDeprecated=False,
    )
    return mapItemRowsForList(rows, typeFilter)


def getInstancesForFlexRepeater(searchText="", typeFilter="All Types", selectedId=0):
    """LEGACY -- composes the flex-repeater instances payload by calling
    getAllForList and wrapping. Kept for any binding that still uses it,
    but the convention is now: view.custom.items binds to getAllForList,
    and components bind to view.custom.items via attachSelectedId
    (pure transform, no DB call from a component-level binding)."""
    selectedId = _u(selectedId) or 0
    rows = getAllForList(searchText, typeFilter)
    return [{"item": r, "selectedId": selectedId} for r in rows]


def attachSelectedId(items, selectedId):
    """Pure transform: takes the items list (already loaded from DB into
    view.custom.items via getAllForList) and the currently-selected
    item id, returns the flex-repeater instances payload:
    [{'item': <row>, 'selectedId': <int>}, ...]

    No DB call -- this is purely a shape transform safe to call from a
    component binding. View layer:
      view.custom.items binds to runScript(getAllForList, search, typeFilter)
      ItemList.props.instances binds to runScript(attachSelectedId,
                                                  view.custom.items,
                                                  view.custom.selectedItemId)
    """
    items = _u(items) or []
    selectedId = _u(selectedId) or 0
    return [{"item": r, "selectedId": selectedId} for r in items]


_TAB_LABELS = [
    ("containerConfig", "Container Config"),
    ("routes",          "Routes"),
    ("boms",            "Boms"),
    ("qualitySpecs",    "Quality Specs"),
    ("eligibility",     "Eligibility"),
]


def itemMasterTabLabels(sectionDirty):
    """Returns the 5 tab labels for the ItemMaster TabContainer with a
    leading dot prefix on any tab whose section is currently dirty.

    sectionDirty: dict { section_key: bool }, comes from
    view.custom.sectionDirty. Defensive against null / Java Map wrappers
    via Common.Util.extractQualifiedValues."""
    d = _u(sectionDirty) or {}
    out = []
    for key, label in _TAB_LABELS:
        if d.get(key, False):
            out.append(u"● " + label)
        else:
            out.append(label)
    return out


def itemMasterTabObjects(sectionDirty, activeTab):
    """Returns the 5 tab objects for ia.container.tab. Each tab is a
    dict with text / runWhileHidden / disabled per the 8.3 tab-object
    schema.

    - text: label with leading ● when its section is dirty
    - runWhileHidden: True (keep embed state across tab switches —
      avoids the unmount-remount cycle that loses local editDraft)
    - disabled: True when any section is dirty AND this isn't the
      active tab (locks navigation until user saves or discards;
      replaces the bidi-onChange popup intercept which doesn't work
      cleanly with ia.container.tab)

    sectionDirty: dict { section_key: bool } from view.custom.sectionDirty
    activeTab:    string section-key from view.custom.activeTab
    """
    d = _u(sectionDirty) or {}
    activeTab = _u(activeTab)
    anyDirty = any(d.get(k, False) for k, _ in _TAB_LABELS)
    out = []
    for key, label in _TAB_LABELS:
        out.append({
            "text":           (u"● " + label) if d.get(key, False) else label,
            "runWhileHidden": True,
            "disabled":       bool(anyDirty and key != activeTab),
        })
    return out


def add(meta):
    """Create a new Item. meta keys (camelCase OR PascalCase tolerated):
        partNumber, itemTypeId, description, macolaPartNumber,
        defaultSubLotQty, maxLotSize, uomId, unitWeight, weightUomId,
        countryOfOrigin, maxParts

    PartNumber, ItemTypeId, and UomId are required (proc rejects nulls).
    Returns {Status, Message, NewId}.

    The proc enforces:
      - PartNumber uniqueness
      - ItemTypeId / UomId / WeightUomId FK + not-deprecated
      - WeightUomId required when UnitWeight supplied
      - MaxParts > 0 when supplied
      - CountryOfOrigin <= 2 chars
    """
    m = _u(meta) or {}
    BlueRidge.Common.Util.log("meta=%s" % m)
    def _pick(camel, pascal):
        v = m.get(camel)
        if v is None:
            v = m.get(pascal)
        return v
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_Create",
        {
            "partNumber":       _pick("partNumber",       "PartNumber"),
            "itemTypeId":       _pick("itemTypeId",       "ItemTypeId"),
            "description":      _pick("description",      "Description"),
            "macolaPartNumber": _pick("macolaPartNumber", "MacolaPartNumber"),
            "defaultSubLotQty": _pick("defaultSubLotQty", "DefaultSubLotQty"),
            "maxLotSize":       _pick("maxLotSize",       "MaxLotSize"),
            "uomId":            _pick("uomId",            "UomId"),
            "unitWeight":       _pick("unitWeight",       "UnitWeight"),
            "weightUomId":      _pick("weightUomId",      "WeightUomId"),
            "countryOfOrigin":  _pick("countryOfOrigin",  "CountryOfOrigin"),
            "maxParts":         _pick("maxParts",         "MaxParts"),
            "appUserId":        BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(meta):
    """Update an existing Item in place. PartNumber + ItemTypeId are
    immutable per the proc; do not pass them. meta keys (camelCase OR
    PascalCase tolerated):
        Id, description, macolaPartNumber, defaultSubLotQty,
        maxLotSize, uomId, unitWeight, weightUomId,
        countryOfOrigin, maxParts

    Returns {Status, Message}.
    """
    m = _u(meta) or {}
    BlueRidge.Common.Util.log("meta=%s" % m)
    def _pick(camel, pascal):
        v = m.get(camel)
        if v is None:
            v = m.get(pascal)
        return v
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_Update",
        {
            "id":               _pick("id",               "Id"),
            "description":      _pick("description",      "Description"),
            "macolaPartNumber": _pick("macolaPartNumber", "MacolaPartNumber"),
            "defaultSubLotQty": _pick("defaultSubLotQty", "DefaultSubLotQty"),
            "maxLotSize":       _pick("maxLotSize",       "MaxLotSize"),
            "uomId":            _pick("uomId",            "UomId"),
            "unitWeight":       _pick("unitWeight",       "UnitWeight"),
            "weightUomId":      _pick("weightUomId",      "WeightUomId"),
            "countryOfOrigin":  _pick("countryOfOrigin",  "CountryOfOrigin"),
            "maxParts":         _pick("maxParts",         "MaxParts"),
            "appUserId":        BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(itemId):
    """Soft-delete the Item by Id. Returns {Status, Message}. The proc
    (v3.0, 2026-07-07) CASCADE-deprecates the part's owned config artifacts
    (RouteTemplate / Bom-as-parent / ItemLocation / ContainerConfig) and
    rejects ONLY when a live (non-terminal) LOT of the part still exists; the
    Message field surfaces that hard stop. A part used as a BomLine child in
    another part's BOM is neither blocked nor cascaded."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_Deprecate",
        {
            "id":        itemId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def emptyMeta():
    """Blank meta dict for the AddItem popup's initial state. Keys match
    what the popup's form fields bidi-bind to (camelCase)."""
    return {
        "partNumber":       "",
        "itemTypeId":       None,
        "description":      "",
        "macolaPartNumber": "",
        "defaultSubLotQty": None,
        "maxLotSize":       None,
        "uomId":            None,
        "unitWeight":       None,
        "weightUomId":      None,
        "countryOfOrigin":  "",
        "maxParts":         None,
    }


def getMaxParts(itemId):
    """Arc 2 Phase 4. Thin read of the OI-12 per-Item lineside cap.
       Returns {MaxParts} (MaxParts None = uncapped) or None. The cap is
       enforced server-side in Lots.Lot_MoveToValidated; this drives the
       Movement Scan capacity hint only."""
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    return BlueRidge.Common.Db.execOne("parts/Item_GetMaxParts", {"itemId": itemId})


def getForDropdown():
    """[{label: PartNumber, value: Id}] for the Receiving PartNumber dropdown
       (allowCustomOptions). Built off getAll()."""
    return [{"label": r.get("PartNumber"), "value": r.get("Id")} for r in (getAll() or [])]


def getByPartNumber(partNumber):
    """Resolve an active Item by exact PartNumber (case-insensitive). Returns a
       dict or None. Used by the Receiving Dock scan-or-pick field to turn a
       scanned/typed part number into an itemId. Scans getAll() (modest list)
       rather than a dedicated NQ."""
    BlueRidge.Common.Util.log("partNumber=%s" % partNumber)
    target = (BlueRidge.Common.Util.extractQualifiedValues(partNumber) or "")
    target = ("%s" % target).strip().upper()
    if not target:
        return None
    for r in (getAll() or []):
        if ("%s" % (r.get("PartNumber") or "")).strip().upper() == target:
            return r
    return None
