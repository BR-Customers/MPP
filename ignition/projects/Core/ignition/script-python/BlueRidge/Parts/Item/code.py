# =============================================================================
# Project Library:  BlueRidge.Parts.Item
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.6
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
#   listForCutoverLocation(locationId) -> list[dict]
#   getForCutoverLocationDropdown(locationId) -> list[{label, value}]
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
#   2026-08-20 - 1.3 - Part-scoped CRT (Task 8): CrtEnabled added to
#                      _ITEM_SHAPE_KEYS and always sent (1/0) by update().
#   2026-09-17 - 1.4 - Cutover scan: listForCutoverLocation /
#                      getForCutoverLocationDropdown (Components only; the
#                      warehouse lists every active Component). Option
#                      shaping shared via _partOptions.
#   2026-09-17 - 1.5 - Line inventory sidebar (Task 5): boxQuantity /
#                      lowInventoryHorizon added to _ITEM_SHAPE_KEYS and
#                      forwarded by update() (NULL-preserving, same rule as
#                      crtEnabled).
#   2026-09-17 - 1.6 - Final review fix: update() maps an emptied editor field
#                      ("") to 0 (clear) for boxQuantity / lowInventoryHorizon
#                      via new _blankToClear() -- previously "" forwarded as SQL
#                      NULL, which the proc reads as "leave alone", so clearing
#                      the field silently kept the old value. None (omitted key)
#                      is unaffected.
# =============================================================================

import java.lang


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
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e), level="warn")
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
        BlueRidge.Common.Util.log("getOne failed: %s" % str(e), level="warn")
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
    "CrtEnabled", "BoxQuantity", "LowInventoryHorizon",
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


def getEligibleForLocationDropdown(locationId, operationTypeCode=None, _refreshToken=None):
    """Items eligible at a Location, shaped for ia.input.dropdown:
        [{label: '<PartNumber> - <Description>', value: Id}].
    Always a list (never None). Empty if locationId is None or nothing is eligible.
    Wraps Parts.Item_ListEligibleForLocation. Used by the die-cast entry screen's
    eligibility-constrained Item dropdown.

    operationTypeCode (optional, 2026-07-07): route-role filter. When supplied
    (e.g. 'DieCast'), only items whose route carries a step of that OperationType
    role are listed - the same predicate as the no-template Create gate, so the
    dropdown never offers a part the gate would block.
    _refreshToken is ignored - runScript bindings pass a bumped token to force
    a re-read (runScript caches on args)."""
    locationId = _u(locationId)
    operationTypeCode = _u(operationTypeCode)
    BlueRidge.Common.Util.log(
        "getEligibleForLocationDropdown locationId=%s operationTypeCode=%s"
        % (locationId, operationTypeCode))
    if locationId is None:
        return []
    try:
        if operationTypeCode:
            rows = BlueRidge.Common.Db.execList(
                "parts/Item_ListEligibleForLocationByRole",
                {"locationId": locationId, "operationTypeCode": operationTypeCode})
        else:
            rows = BlueRidge.Common.Db.execList(
                "parts/Item_ListEligibleForLocation", {"locationId": locationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getEligibleForLocationDropdown failed: %s" % str(e), level="warn")
        return []
    return _partOptions(rows)


def _partOptions(rows):
    """Item rows -> [{label: '<PartNumber> - <Description>', value: Id}]."""
    out = []
    for r in (rows or []):
        pn = r.get("PartNumber") or ""
        desc = r.get("Description") or ""
        label = ("%s - %s" % (pn, desc)) if desc else pn
        out.append({"label": label, "value": r.get("Id")})
    return out


def listForCutoverLocation(locationId):
    """Raw rows of parts/Item_ListForCutoverLocation: the Components eligible
       at a line or trim store, or EVERY active Component for the warehouse (a
       cutover destination with no eligibility configured -- the proc decides).
       Always a list."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Item_ListForCutoverLocation", {"locationId": locationId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("listForCutoverLocation failed: %s" % str(e), level="warn")
        return []


def getForCutoverLocationDropdown(locationId, _refreshToken=None):
    """listForCutoverLocation shaped for ia.input.dropdown."""
    return _partOptions(listForCutoverLocation(locationId))


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


def _blankToClear(v):
    """Transport-mapping helper for boxQuantity / lowInventoryHorizon ONLY.

    The Item Master editor turns an emptied number field into "" (not None),
    but Parts.Item_Update's NULL-preserving contract treats None as 'omitted --
    leave alone' and 0 as 'clear'. Forwarding "" unchanged sends SQL NULL, which
    the proc reads as 'leave alone' -- so emptying the field would report success
    and the old value would come back on reload. Map a blank string (or one that
    is empty after strip) to 0 so it hits the proc's clear path instead. None
    (the key genuinely omitted from the payload) passes through unchanged and
    still means 'leave alone'. This is transport mapping only -- not a business
    rule -- so it does not touch how any other key is handled."""
    if v is None:
        return None
    if isinstance(v, basestring) and v.strip() == "":
        return 0
    return v


def update(meta):
    """Update an existing Item in place. PartNumber + ItemTypeId are
    immutable per the proc; do not pass them. meta keys (camelCase OR
    PascalCase tolerated):
        Id, description, macolaPartNumber, defaultSubLotQty,
        maxLotSize, uomId, unitWeight, weightUomId,
        countryOfOrigin, maxParts, crtEnabled,
        boxQuantity, lowInventoryHorizon (NULL-preserving; 0 clears -- same rule as
        crtEnabled, enforced in the proc)

    Returns {Status, Message}.

    crtEnabled (part-scoped CRT, Task 8) is NULL-PRESERVING, unlike every other
    key here: an explicit True/False is coerced to 1/0, but an OMITTED key sends
    None -> SQL NULL, and Parts.Item_Update resolves NULL to the row's CURRENT
    value. A partial payload therefore leaves the flag ALONE instead of silently
    untagging a CRT part (which would ship suspect material unmarked). Pass an
    explicit falsy crtEnabled to clear it -- which is what the Item Master
    Identity checkbox does on every save.

    boxQuantity / lowInventoryHorizon share crtEnabled's NULL-preserving rule, but
    the Item Master editor emits "" (not None) for an emptied number field. "" is
    mapped to 0 (clear) here via _blankToClear so an operator clearing the field
    actually clears it instead of the omitted-key "leave alone" path silently
    keeping the old value. An omitted key (None) is unaffected -- still "leave
    alone".
    """
    m = _u(meta) or {}
    BlueRidge.Common.Util.log("meta=%s" % m)
    def _pick(camel, pascal):
        v = m.get(camel)
        if v is None:
            v = m.get(pascal)
        return v
    # _pick returns None when NEITHER spelling of the key is present, which is
    # exactly the "omitted" case -- forward it as None so the proc preserves the
    # stored flag. Only an explicitly supplied value is coerced to 1/0.
    _crt = _pick("crtEnabled", "CrtEnabled")
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
            "crtEnabled":       None if _crt is None else (1 if _crt else 0),
            "boxQuantity":         _blankToClear(_pick("boxQuantity",         "BoxQuantity")),
            "lowInventoryHorizon": _blankToClear(_pick("lowInventoryHorizon", "LowInventoryHorizon")),
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


def getPlcId(itemId):
    """The item's PLC/vision recipe integer. Returns {ItemId, PlcId} or None.
       PlcId is NULL for parts without a PLC recipe (spec Sec 4.3)."""
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    return BlueRidge.Common.Db.execOne("parts/Item_GetPlcId", {"itemId": itemId})


def setPlcId(itemId, plcId, appUserId=None):
    """Set the item's PLC/vision recipe integer. Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log("itemId=%s plcId=%s" % (itemId, plcId))
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_SetPlcId",
        {"itemId": itemId, "plcId": plcId, "appUserId": appUserId})
