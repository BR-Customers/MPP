# Item Master Phase 3 — Design Spec

**Date:** 2026-05-20
**Status:** Draft — pending Jacques's review
**Scope:** Phase 3 of the 8-phase Item Master Configuration Tool — wire Item meta CRUD (Create / Update / Deprecate) end-to-end on the `/items` surface. Replaces the toast placeholders on the parent `BtnSave` / `BtnDeprecate` and on the AddItem modal `BtnCreate`. Adds MaxParts + CountryOfOrigin to the editable Identity row.

Phase 4 (ContainerConfig save), Phases 5/6 (versioned Routes/BOMs), Phase 7 (Quality Specs cross-link), Phase 8 (Eligibility editor) remain out of scope.

---

## 1. Goals

End-state for Phase 3:

- Clicking **+Add Item** opens the AddItem modal, which now sources ItemType + UOM dropdown options from live NQs (no more hardcoded lists).
- Filling out the modal and clicking **Create Item** writes a new `Parts.Item` row via `Parts.Item_Create`, surfaces success/failure via the standard `notifyResult` toast, closes the popup on success, and refreshes the items list on the parent (the new item appears in the left panel; **no auto-selection** — operator clicks to load).
- Selecting an existing item, editing fields in the Identity row, and clicking **Save** writes the changes via `Parts.Item_Update`, toasts the result, rebaselines `selected` from `editDraft` on success, and re-runs the items list binding so the row's display reflects any Description / type changes.
- Clicking **Deprecate** on a selected item calls `Parts.Item_Deprecate` (which has FK-guards against active Bom / RouteTemplate / ItemLocation / ContainerConfig). On success: clear `selected` / `editDraft`, set `mode = "view"`, refresh items list. On failure (active dependents exist): toast surfaces the proc's specific message verbatim.
- The Identity row now surfaces `MaxParts` and `CountryOfOrigin` inputs (both optional fields — UI does not validate them as required). Mockup placeholder `PartsPerBasket` field renamed to its real backing column `MaxLotSize` and the underlying state key corrected to match.
- Dirty indicator (already present from Phase 1/2) continues to work — `editDraft != selected` lights up "● Unsaved changes" in the title bar.

---

## 2. Architecture Decision

**Approach A — Per-action procs, no popup unification.** AddItem stays Add-only; existing inline **Save** / **Deprecate** buttons on the parent ItemMaster handle Update / Deprecate. Two surfaces, two purposes.

| Action | Entry point | Proc |
|---|---|---|
| Create | AddItem popup `BtnCreate` | `Parts.Item_Create` |
| Update | Parent `BtnSave` (inline) | `Parts.Item_Update` |
| Deprecate | Parent `BtnDeprecate` (inline) | `Parts.Item_Deprecate` |

Rationale:
- Matches the existing mockup (`mockup/index.html` lines 308–860 + the Add Item modal lines 2629–2715) which positions Create as a discrete modal action and Save/Deprecate inline on the parent.
- The Downtime Codes precedent (`mpp-confirm-unsaved-popup-pattern` reference impl) uses a unified popup with mode discriminator because *Downtime Codes has no parent-inline editor* — it's a list with row Edit buttons. Items has a parent-inline editor (the Identity row in the page header), so a unified popup would either (a) double the editor surface, or (b) move all editing into the popup and abandon the inline editor — both larger changes than this phase warrants.
- Mode discriminator is not needed: AddItem only ever serves Create.

### Three-layer rule (unchanged from Phase 2)

```
View bindings        -> view.custom.* (parent) + view.params.* (popup) + editDraft form fields
view.scripts         -> BlueRidge.Parts.Item.{add,update,deprecate} + BlueRidge.Parts.ItemType + BlueRidge.Parts.Uom
BlueRidge.Parts.*    -> BlueRidge.Common.Db.execMutation / execList / execOne
BlueRidge.Common.Db  -> the only layer that calls system.db.runNamedQuery
Named Queries        -> EXEC Parts.Item_{Create,Update,Deprecate}, Parts.ItemType_List, Parts.Uom_List
Stored Procs         -> already exist; NO SQL changes in Phase 3
```

---

## 3. SQL — no changes

All required procs exist with the current Status-row BIT contract. Phase 3 wires them through NQs + entity scripts + view event handlers. Test count stays at the current baseline (currently 937/937 per PROJECT_STATUS).

| Proc | Used by | Returns |
|---|---|---|
| `Parts.Item_Create` | AddItem popup `BtnCreate` | `{Status, Message, NewId}` |
| `Parts.Item_Update` | Parent `BtnSave` | `{Status, Message}` |
| `Parts.Item_Deprecate` | Parent `BtnDeprecate` | `{Status, Message}` — fails with specific message on active FK dependents |
| `Parts.ItemType_List` | ItemType dropdown options (AddItem modal + parent Identity row) | rowset of `{Id, Name, Description, DeprecatedAt}` |
| `Parts.Uom_List` | UOM + Weight UOM dropdowns (AddItem + parent) | rowset of `{Id, Code, Name, DeprecatedAt}` |

**Immutability rules** (enforced by `Parts.Item_Update`):
- `PartNumber` and `ItemTypeId` are immutable post-create. The UI marks these inputs as **read-only when `mode == "update"`**, only editable on Create.
- All other fields are mutable: Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts.

**Optimistic locking:** not in scope. Project has no `RowVersion` column anywhere (verified via `Grep RowVersion sql/migrations`); existing Downtime Codes / DefectCodes patterns also rely on last-write-wins. Phase 3 follows precedent.

---

## 4. Named Queries — new (5 total)

| NQ path | Backing proc | Type |
|---|---|---|
| `parts/Item_Create` | `Parts.Item_Create` | UpdateQuery (status-row result) |
| `parts/Item_Update` | `Parts.Item_Update` | UpdateQuery |
| `parts/Item_Deprecate` | `Parts.Item_Deprecate` | UpdateQuery |
| `parts/ItemType_List` | `Parts.ItemType_List` | Query |
| `parts/Uom_List` | `Parts.Uom_List` | Query |

All NQs follow project conventions (v2 schema, Designer-canonical sqlType enum, camelCase param identifiers, `cacheEnabled: false` by default).

### 4.1 — `parts/Item_Create`

```sql
EXEC Parts.Item_Create
    @PartNumber       = :partNumber,
    @ItemTypeId       = :itemTypeId,
    @Description      = :description,
    @MacolaPartNumber = :macolaPartNumber,
    @DefaultSubLotQty = :defaultSubLotQty,
    @MaxLotSize       = :maxLotSize,
    @UomId            = :uomId,
    @UnitWeight       = :unitWeight,
    @WeightUomId      = :weightUomId,
    @CountryOfOrigin  = :countryOfOrigin,
    @MaxParts         = :maxParts,
    @AppUserId        = :appUserId
```

Parameters:
- `partNumber` (sqlType 7, NVARCHAR) — required, unique
- `itemTypeId` (sqlType 3, BIGINT) — required, FK to ItemType
- `description` (7, NVARCHAR) — nullable
- `macolaPartNumber` (7) — nullable
- `defaultSubLotQty` (2, INT) — nullable
- `maxLotSize` (2, INT) — nullable
- `uomId` (3) — required, FK to Uom
- `unitWeight` (5, FLOAT) — nullable; requires weightUomId when supplied (proc enforces)
- `weightUomId` (3) — nullable
- `countryOfOrigin` (7, NVARCHAR(2)) — nullable, ISO 3166-1 alpha-2
- `maxParts` (2, INT) — nullable, must be > 0 when supplied (proc enforces)
- `appUserId` (3) — required

Note: `unitWeight` is `DECIMAL(10,4)` in the proc; Ignition NQ sqlType `5` (Float8/FLOAT) is the closest match in the Designer enum. SQL Server coerces FLOAT → DECIMAL implicitly. Verified pattern from `parts/ContainerConfig_GetByItem` (which projects DECIMAL columns similarly).

### 4.2 — `parts/Item_Update`

```sql
EXEC Parts.Item_Update
    @Id               = :id,
    @Description      = :description,
    @MacolaPartNumber = :macolaPartNumber,
    @DefaultSubLotQty = :defaultSubLotQty,
    @MaxLotSize       = :maxLotSize,
    @UomId            = :uomId,
    @UnitWeight       = :unitWeight,
    @WeightUomId      = :weightUomId,
    @CountryOfOrigin  = :countryOfOrigin,
    @MaxParts         = :maxParts,
    @AppUserId        = :appUserId
```

Same param types as Create except no `partNumber` or `itemTypeId` (immutable). `id` (3, BIGINT) required.

### 4.3 — `parts/Item_Deprecate`

```sql
EXEC Parts.Item_Deprecate @Id = :id, @AppUserId = :appUserId
```

Parameters: `id` (3), `appUserId` (3).

### 4.4 — `parts/ItemType_List`

```sql
EXEC Parts.ItemType_List
    @IncludeDeprecated = :includeDeprecated
```

Or — if the existing `Parts.ItemType_List` proc has a different signature, the NQ adapts. Pre-verify the proc signature when writing the NQ.

Param: `includeDeprecated` (sqlType 6, BIT) — default 0.

### 4.5 — `parts/Uom_List`

```sql
EXEC Parts.Uom_List @IncludeDeprecated = :includeDeprecated
```

Same shape as ItemType_List. Pre-verify the proc signature.

Both reference-list NQs **MAY enable caching** (`cacheEnabled: true, cacheAmount: 5, cacheUnit: "MIN"`) since ItemType and UOM are slow-changing lookup tables — but Phase 3 ships with caching OFF by default (matches existing project conventions). Revisit if measured RPS warrants it.

---

## 5. Entity scripts — one extended + two new

### 5.1 — `BlueRidge.Parts.Item` (extended)

Phase 2 landed `getAll`, `getOne`, `mapItemRowsForList`, `typeBadgeFor`, `getAllForList`. Phase 3 adds the four mutation/factory functions:

```python
def add(meta):
    """Create. meta = {partNumber, itemTypeId, description, macolaPartNumber,
       defaultSubLotQty, maxLotSize, uomId, unitWeight, weightUomId,
       countryOfOrigin, maxParts}. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "partNumber":       m.get("partNumber") or m.get("PartNumber"),
        "itemTypeId":       m.get("itemTypeId") or m.get("ItemTypeId"),
        "description":      m.get("description") or m.get("Description"),
        "macolaPartNumber": m.get("macolaPartNumber") or m.get("MacolaPartNumber"),
        "defaultSubLotQty": m.get("defaultSubLotQty") or m.get("DefaultSubLotQty"),
        "maxLotSize":       m.get("maxLotSize") or m.get("MaxLotSize"),
        "uomId":            m.get("uomId") or m.get("UomId"),
        "unitWeight":       m.get("unitWeight") or m.get("UnitWeight"),
        "weightUomId":      m.get("weightUomId") or m.get("WeightUomId"),
        "countryOfOrigin":  m.get("countryOfOrigin") or m.get("CountryOfOrigin"),
        "maxParts":         m.get("maxParts") or m.get("MaxParts"),
        "appUserId":        BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("parts/Item_Create", params)

def update(meta):
    """Update. meta = {id, description, macolaPartNumber, defaultSubLotQty,
       maxLotSize, uomId, unitWeight, weightUomId, countryOfOrigin, maxParts}.
       PartNumber + ItemTypeId immutable; proc rejects changes.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "id":               m.get("Id") or m.get("id"),
        "description":      m.get("Description") or m.get("description"),
        "macolaPartNumber": m.get("MacolaPartNumber") or m.get("macolaPartNumber"),
        "defaultSubLotQty": m.get("DefaultSubLotQty") or m.get("defaultSubLotQty"),
        "maxLotSize":       m.get("MaxLotSize") or m.get("maxLotSize"),
        "uomId":            m.get("UomId") or m.get("uomId"),
        "unitWeight":       m.get("UnitWeight") or m.get("unitWeight"),
        "weightUomId":      m.get("WeightUomId") or m.get("weightUomId"),
        "countryOfOrigin":  m.get("CountryOfOrigin") or m.get("countryOfOrigin"),
        "maxParts":         m.get("MaxParts") or m.get("maxParts"),
        "appUserId":        BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("parts/Item_Update", params)

def deprecate(id):
    """Soft-delete by Id. Returns {Status, Message}.
       Proc enforces FK guards (active Bom / RouteTemplate / ItemLocation /
       ContainerConfig dependents block deprecation with a specific message)."""
    BlueRidge.Common.Util.log("id=%s" % id)
    params = {
        "id":        _u(id),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("parts/Item_Deprecate", params)

def emptyMeta():
    """Blank meta dict for the AddItem popup's initial state.
       Keys match what the view's form fields bidi-bind to."""
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
```

**Key/case-tolerance pattern**: `m.get("partNumber") or m.get("PartNumber")` lets the same module accept both camelCase (from popup `view.custom.draft.*`) and PascalCase (from parent `view.custom.editDraft.meta.*`, which is hydrated from `Item_Get` whose SELECT aliases are PascalCase). Avoids forcing callers to normalize. Matches DowntimeReasonCode's lenient `_u()`-then-`.get()` style.

### 5.2 — `BlueRidge.Parts.ItemType` (new)

```python
def getAll(includeDeprecated=False):
    """List item types. Returns list[dict] of {Id, Name, Description}."""
    BlueRidge.Common.Util.log("includeDeprecated=%s" % includeDeprecated)
    try:
        return BlueRidge.Common.Db.execList(
            "parts/ItemType_List",
            {"includeDeprecated": 1 if includeDeprecated else 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load item types", str(e), "error")
        return []

def getForDropdown(includeSelectPrompt=True):
    """[{label, value}] shape. Optional 'Select…' prompt as first entry
       when includeSelectPrompt=True."""
    rows = getAll()
    options = [{"label": r.get("Name", ""), "value": r.get("Id")} for r in rows]
    if includeSelectPrompt:
        options.insert(0, {"label": "Select…", "value": None})
    return options
```

### 5.3 — `BlueRidge.Parts.Uom` (new)

```python
def getAll(includeDeprecated=False):
    """List UOMs. Returns list[dict] of {Id, Code, Name}."""
    BlueRidge.Common.Util.log("includeDeprecated=%s" % includeDeprecated)
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Uom_List",
            {"includeDeprecated": 1 if includeDeprecated else 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load UOMs", str(e), "error")
        return []

def getForDropdown(includeBlank=False, blankLabel=u"—"):
    """[{label, value}] for UOM dropdowns. blankLabel param drives the
       'no UOM' entry for the Weight UOM dropdown (—)."""
    rows = getAll()
    options = [{"label": r.get("Code", ""), "value": r.get("Id")} for r in rows]
    if includeBlank:
        options.insert(0, {"label": blankLabel, "value": None})
    return options
```

Two flavors:
- `getForDropdown()` — for counting UOM (required field; no blank entry)
- `getForDropdown(includeBlank=True)` — for Weight UOM (optional field; blank entry = None)

### 5.4 — Common helper changes — none

`Common.Db.execMutation`, `Common.Ui.notifyResult`, `Common.Util._u`, `Common.Util._currentAppUserId`, `Common.Notify.toast` all already exist. Phase 3 uses them as-is.

---

## 6. View changes — three views touched

### 6.1 — AddItem popup (`Components/Popups/AddItem/view.json`)

**Current Phase 1 state:** form fields bidi-bind to `view.custom.draft.*` (PartNumber, ItemTypeName, UomCode, Description, UnitWeight, WeightUomCode, DefaultSubLotQty, **PartsPerBasket**, MacolaPartNumber). Hardcoded ItemType + UOM dropdown options. BtnCancel + BtnCreate fire close + toast-placeholder respectively. CloseIcon uses `scope: "C"`.

**Phase 3 edits:**

1. **Replace `view.custom.draft` shape** with camelCase keys matching the entity script's `add(meta)` expected input. Initialize **both** `draft` AND `selected` to the same empty-meta shape on view open so the dirty indicator (`draft != selected`) is correctly clear at open and trips the moment the user types anything:
   ```yaml
   draft:
     partNumber:       ""
     itemTypeId:       null      # was ItemTypeName (Name → Id binding)
     description:      ""
     macolaPartNumber: ""
     defaultSubLotQty: null
     maxLotSize:       null      # was PartsPerBasket (renamed to real backing column)
     uomId:            null      # was UomCode (Code → Id binding)
     unitWeight:       null
     weightUomId:      null      # was WeightUomCode (Code → Id binding)
     countryOfOrigin:  ""        # NEW field
     maxParts:         null      # NEW field
   selected:                     # baseline = identical-shape empty-meta, used for the dirty indicator
     partNumber:       ""
     itemTypeId:       null
     description:      ""
     macolaPartNumber: ""
     defaultSubLotQty: null
     maxLotSize:       null
     uomId:            null
     unitWeight:       null
     weightUomId:      null
     countryOfOrigin:  ""
     maxParts:         null
   ```
   **Note for the Designer step:** the current AddItem view binds form fields to *PascalCase + Name/Code* keys (`PartNumber`, `ItemTypeName`, `UomCode`, …). Phase 3 repoints every form-field bidi binding to the new camelCase + Id-bound keys above. ItemType dropdown's value is now an `Id` (BIGINT), not a name string. Similarly UOM dropdowns. Plan task will enumerate each binding change.

2. **ItemType dropdown** — replace hardcoded options with a property binding:
   ```json
   "props.options": {
     "binding": {
       "type": "expr",
       "config": { "expression": "runScript(\"BlueRidge.Parts.ItemType.getForDropdown\", 0)" }
     }
   }
   ```
   Bind `props.value` bidi to `view.custom.draft.itemTypeId`.

3. **UOM dropdown** (counting UOM, required) — same pattern:
   ```json
   "props.options": {
     "binding": {
       "type": "expr",
       "config": { "expression": "runScript(\"BlueRidge.Parts.Uom.getForDropdown\", 0)" }
     }
   }
   ```
   Bind `props.value` bidi to `view.custom.draft.uomId`.

4. **Weight UOM dropdown** (optional) — same pattern but include blank:
   ```json
   "expression": "runScript(\"BlueRidge.Parts.Uom.getForDropdown\", 0, true)"
   ```
   Bind `props.value` bidi to `view.custom.draft.weightUomId`.

5. **Rename `PartsPerBasket` field UI label** to `Max LOT Size` and rebind to `view.custom.draft.maxLotSize`. (Or keep the user-facing label "Parts Per Basket" per the data-model-v1.9 repurposing note in Phase 1 § R2, but bind to `maxLotSize`. Decision: **keep the existing user-facing label "Parts Per Basket"** since that matches the mockup wording; only the bidi binding path and `view.custom.draft.*` key change. Visible diff to user: zero.) Same path change applied to `view.custom.draft` initial state.

6. **Add `CountryOfOrigin` field** to the "Identity" section (per FDS-03-001). Text input, optional, 2-char ISO code (no client-side validation in Phase 3 — proc accepts any 2-char NVARCHAR). Placeholder: `"US, JP, MX, …"`.

7. **Add `MaxParts` field** to the "LOT Configuration" section (per OI-12). Numeric text input, optional, integer > 0 when supplied. Placeholder: `"Optional — max pieces per container"`.

8. **BtnCreate** — replace toast placeholder with the actual mutation call. Inline script (≤3 lines per pack convention; longer goes into a handler script):
   ```python
   result = BlueRidge.Parts.Item.add(self.view.custom.draft)
   BlueRidge.Common.Ui.notifyResult(result, "Item created")
   if result and result.get("Status"):
       system.perspective.sendMessage("itemsRefresh", scope="page")
       system.perspective.closePopup(id="mpp-add-item")
   ```
   Note: 4 logical lines but the last is a conditional block — still acceptable. If reviewer flags, factor into `BlueRidge.Parts.Item.handleCreateFromPopup(draft, popupId)`.

9. **BtnCancel + CloseIcon** — wire ConfirmUnsaved guard. Pattern (matches DowntimeCodeEditor's header X):
   ```python
   if self.view.custom.draft == self.view.custom.selected:
       system.perspective.closePopup(id="mpp-add-item")
   else:
       system.perspective.openPopup(
           id="mpp-confirm-unsaved",
           view="BlueRidge/Components/Popups/ConfirmUnsaved",
           modal=True, showCloseIcon=False,
           params={
               "title": "Discard New Item?",
               "message": "You have started filling out this form. Discard before closing?"
           }
       )
   ```
   `scope: "G"` required because the script calls `openPopup` (per `feedback-ignition-popup-open-scope` memory).

10. **ConfirmUnsavedResult message handler** at root view (pageScope): routes `save` / `discard` / `cancel` actions. For AddItem:
    - `save` → call `Item.add(...)`, notify, close popup on success
    - `discard` → close popup
    - `cancel` → no-op

11. **DirtyIndicator label** in the modal header — bind to `draft != selected` per project convention. **DESIGN DECISION:** put it next to the "Add Item" header title, matching the DowntimeCodeEditor's header-bar dirty indicator.

### 6.2 — Parent ItemMaster (`Views/Parts/ItemMaster/view.json`)

**Current Phase 2 state:**
- Items list loaded via `runScript("BlueRidge.Parts.Item.getAllForList", 0, search, typeFilter)`
- `itemRowClicked` handler loads `{meta: dict(itemMeta)}` into both `selected` and `editDraft`
- BtnSave + BtnDeprecate fire toast placeholders
- BtnAddItem uses native `popup`-type event with `scope: "C"`

**Phase 3 edits:**

1. **BtnSave handler** — replace toast with the actual update call:
   ```python
   draft = self.view.custom.editDraft.get("meta") if self.view.custom.editDraft else None
   if not draft or not draft.get("Id"):
       BlueRidge.Common.Notify.toast("Nothing to save", "Select an item first.", "info", 5)
       return
   result = BlueRidge.Parts.Item.update(draft)
   BlueRidge.Common.Ui.notifyResult(result, "Item updated")
   if result and result.get("Status"):
       self.view.custom.selected = {"meta": dict(draft)}
       system.perspective.sendMessage("itemsRefresh", scope="page")
   ```
   `scope: "G"` (matches DowntimeCodeEditor SaveButton precedent).

2. **BtnDeprecate handler** — replace toast with the actual deprecate call. **No client-side confirmation popup** — the proc's FK-guards are the safety net and surface specific messages on failure. (Could add ConfirmDestructive guard later if engineering reports accidental deprecates; deferred for Phase 3.)
   ```python
   draft = self.view.custom.editDraft.get("meta") if self.view.custom.editDraft else None
   if not draft or not draft.get("Id"):
       return
   result = BlueRidge.Parts.Item.deprecate(draft.get("Id"))
   BlueRidge.Common.Ui.notifyResult(result, "Item deprecated")
   if result and result.get("Status"):
       self.view.custom.selected  = {"meta": {}}
       self.view.custom.editDraft = {"meta": {}}
       self.view.custom.mode      = "view"
       system.perspective.sendMessage("itemsRefresh", scope="page")
   ```
   `scope: "G"`.

3. **New page-scoped message handler `itemsRefresh`** at the root view:
   ```python
   system.perspective.refreshBinding("view.custom.items")
   ```
   Configuration: `pageScope: true, viewScope: false, sessionScope: false`. (Matches the page-scoped pattern from `downtimeCodesRefresh` handler in the existing project.)

4. **BtnAddItem** — currently uses native `popup`-type event with `scope: "C"`. The project memory `feedback-ignition-popup-open-scope` specifically targets *script-type* events that call `system.perspective.openPopup`. The `popup`-type event is a different mechanism and **MAY** work with `scope: "C"`. **Phase 3 leaves the scope as-is and verifies in smoke**; if the button doesn't open the popup, flip to `scope: "G"` (this is the same fix that resolved DowntimeCodes' and DefectCodes' instances of the script-event version).

5. **Identity row — add `CountryOfOrigin` + `MaxParts` inputs**. Mockup doesn't show them; we're adding for FDS-03-001 + OI-12 compliance. Layout: extend the existing `FieldRow 3` (UnitWeight / WeightUOM / DefaultSubLotQty / PartsPerBasket / MaxLotSize) with two more fields, or add a `FieldRow 4`. Decision: **add a new FieldRow 4** to keep visual hierarchy clean — Row 4: `CountryOfOrigin (2-char text)` + `MaxParts (numeric)` + spacer.

6. **Identity row — Country/MaxParts inputs** bidi-bind to `view.custom.editDraft.meta.CountryOfOrigin` / `view.custom.editDraft.meta.MaxParts`. `Item_Get` already returns these columns (per Phase 2 § 3.3 + the actual `Parts.Item_Get` proc; verify Phase 2's data shape exposes them — they should appear in `selected.meta` / `editDraft.meta` automatically since `Item_Get` does `SELECT *`-style projection of the joined columns).

7. **Identity row — `PartNumber` input** — make read-only. The parent inline editor never serves "create" mode (Create lives in the AddItem popup); per `Item_Update` immutability, PartNumber cannot change post-create either. So the parent's PartNumber input is **always read-only** in Phase 3. Implementation: set `props.enabled = false` as a static value (no expr binding needed — there's no forward case where the parent enters create mode). If a future phase ever moves Create into the parent inline editor, this becomes an expr binding to `view.custom.mode == "create"` at that time.

8. **Identity row — `ItemType` badge / select** — the badge currently *displays* `ItemTypeName`. Per Item_Update immutability, ItemType cannot change post-create either. The Identity row's ItemType element stays a **read-only badge** (current state). No edit affordance. If MPP later requests "change item type", the user can deprecate + create-new (per FDS-03-001 / proc convention).

9. **PartsPerBasket input on parent** — Phase 2 deferred cleanup (the field exists in the Identity row labeled as "Parts Per Basket" but bound to `editDraft.meta.PartsPerBasket` which doesn't exist on the row). Phase 3 fix: relabel binding path to `editDraft.meta.MaxLotSize`. User-facing label stays "Parts Per Basket" per the data-model-v1.9 repurposing. If `editDraft.meta.MaxLotSize` is null, input shows empty. If user types, bidi writes to `MaxLotSize` and the Save flow picks it up.

### 6.3 — `Components/Parts/ItemMaster/ItemRow/view.json` — no changes

The flex-repeater row sub-view continues to display `instance.item.partNumber` etc. as in Phase 2.

---

## 7. Mockup-vs-FDS reconciliation

| Mockup field | Stored as | Phase 3 decision |
|---|---|---|
| "Part Number" | `Parts.Item.PartNumber` (immutable) | Editable in Create; read-only in Update |
| "Item Type" | `Parts.Item.ItemTypeId` (FK, immutable) | Editable in Create (dropdown); read-only badge in Update |
| "Description" | `Parts.Item.Description` (nullable) | Editable; required in UI per FDS-03-001 ("every item shall have") |
| "UOM" | `Parts.Item.UomId` (FK, required) | Editable, dropdown |
| "Unit Weight" + "Weight UOM" | `UnitWeight` + `WeightUomId` (paired) | Editable; if Weight set, Weight UOM required (proc enforces) |
| "Default Sub-LOT Qty" | `DefaultSubLotQty` (nullable) | Editable, numeric |
| "Parts Per Basket" (mockup) | `MaxLotSize` (nullable) | Editable, numeric. **Label "Parts Per Basket" preserved, binding repointed.** |
| "Macola Part #" | `MacolaPartNumber` (nullable, FUTURE per FDS-03-001) | Editable, free text |
| — (NEW, not in mockup) | `CountryOfOrigin` NVARCHAR(2) | Editable, 2-char text, FDS-03-001 |
| — (NEW, not in mockup) | `MaxParts` INT (> 0 if supplied) | Editable, numeric, OI-12 |

The decision to surface CountryOfOrigin + MaxParts now (rather than defer): the procs accept them, the FDS specs them, the proc-side validation is in place. Adding the fields is one Designer-touch per view and keeps the data model fully reachable from the UI. No client-side validation beyond "if you type something invalid the proc will reject it" — that's adequate for a Configuration Tool (not a plant-floor operator surface).

---

## 8. State machine — modes on the parent

| `view.custom.mode` | When | UI state |
|---|---|---|
| `"view"` (initial, after Deprecate) | No item selected | Identity row shows empty placeholders; Save/Deprecate hidden (or disabled) |
| `"update"` | An item is selected (set by `itemRowClicked` handler — already wired in Phase 2) | Identity row shows item data; PartNumber + ItemType read-only; other fields editable; Save + Deprecate visible/enabled |
| `"create"` | (not used on parent; reserved for AddItem popup) | n/a on parent |

**Save / Deprecate button visibility:** bind via expression to `view.custom.mode == "update"`. Hidden in `view` mode (no row selected = nothing to save/deprecate).

**Dirty indicator:** bind to `editDraft != selected`. Lights up when in `update` mode and any field has been edited. Stays clear in `view` mode (both are empty `{meta: {}}`).

---

## 9. List refresh mechanics

Project convention (from pack file 04 + 02 + DowntimeCodes precedent): use a page-scoped message + binding refresh.

```
Action                              Message fired                  Receiver
-----------------------------------  -----------------------------  -------------------------------
AddItem.BtnCreate succeeds          sendMessage("itemsRefresh")    ItemMaster root handler →
                                    scope=page                     refreshBinding("view.custom.items")
ItemMaster.BtnSave succeeds         sendMessage("itemsRefresh")    same
                                    scope=page
ItemMaster.BtnDeprecate succeeds    sendMessage("itemsRefresh")    same
                                    scope=page
```

The items list binding is a `runScript` expression that re-evaluates on `refreshBinding` (or when `view.custom.search` / `view.custom.typeFilter` change). The new row appears in alphabetical order based on the proc's ORDER BY (PartNumber ascending per `Parts.Item_List`).

**No auto-select after Create** — per the answered design question. Operator clicks the new row to land on it. Matches "no nav guard / no auto-actions" convention.

---

## 10. Error handling

| Failure | Surface |
|---|---|
| `Item_Create` → duplicate PartNumber | Toast `error`: "An Item with this PartNumber already exists." (proc Message verbatim via `notifyResult`) |
| `Item_Create` → missing required | Toast `error`: "Required parameter missing." (proc Message verbatim) |
| `Item_Create` → invalid ItemTypeId | Toast `error`: "Invalid or deprecated ItemTypeId." (proc Message verbatim) |
| `Item_Update` → not found / deprecated | Toast `error`: "Item not found or deprecated." (proc Message verbatim) |
| `Item_Update` → invalid Uom | Toast `error`: "Invalid or deprecated UomId." |
| `Item_Update` → weight without UOM | Toast `error`: "WeightUomId is required when UnitWeight is provided." |
| `Item_Update` → MaxParts ≤ 0 | Toast `error`: "MaxParts must be greater than zero when supplied." |
| `Item_Deprecate` → active Bom dependent | Toast `error`: "Cannot deprecate: active BOMs reference this Item as parent." |
| `Item_Deprecate` → active BomLine dependent | Toast `error`: "Cannot deprecate: BOM lines reference this Item as a child component." |
| `Item_Deprecate` → active RouteTemplate | Toast `error`: "Cannot deprecate: active RouteTemplates reference this Item." |
| `Item_Deprecate` → active ItemLocation | Toast `error`: "Cannot deprecate: active ItemLocation eligibility entries reference this Item." |
| `Item_Deprecate` → active ContainerConfig | Toast `error`: "Cannot deprecate: an active ContainerConfig references this Item." |
| NQ exception (DB unavailable, malformed, etc.) | Toast `error`: "Action failed — <ERROR_MESSAGE>" (caught by `notifyResult`'s falsy branch) |

All proc Messages flow through `Common.Ui.notifyResult` unchanged. No client-side message mapping or rewording.

---

## 11. Smoke checklist (post-deploy)

After the merge to main and gateway scan:

1. **Cold open Item Master view** — list populates; no auto-selection; Save + Deprecate hidden (mode=view).
2. **Click an Item row** — Identity row populates (PartNumber, ItemType badge, Description, UOM, Unit Weight + Weight UOM, Default Sub-LOT Qty, Parts Per Basket, CountryOfOrigin, MaxParts, Macola). Mode → "update". Save + Deprecate visible. Dirty indicator empty.
3. **Edit Description** — dirty indicator → "● Unsaved changes". Click **Save** → toast "Item updated" → dirty clears → items list refreshes (Description change visible in left panel).
4. **Edit UnitWeight without WeightUOM** — proc rejects, toast surfaces "WeightUomId is required when UnitWeight is provided."
5. **Edit MaxParts to 0** — proc rejects, toast surfaces "MaxParts must be greater than zero when supplied."
6. **Click +Add Item** — popup opens. (If the button doesn't open, flip `scope: "C"` → `"G"` per § 6.2.4.)
7. **Type Part Number "TEST-001", pick Item Type "Component", UOM "EA", Description "Phase 3 smoke test"** → click **Create Item** → toast "Item created" → popup closes → new row appears in left panel (no auto-select).
8. **Click the new row** → Identity row populates. Mode = "update".
9. **Click Deprecate** → toast "Item deprecated" → row disappears (default Include Deprecated = false on Phase 2's `Item_List` call). Identity row clears. Mode → "view".
10. **Click another existing Item that has an active RouteTemplate** (e.g., 5G0) → click Deprecate → expect toast `error` surfacing "Cannot deprecate: active RouteTemplates reference this Item." Item stays selected and visible.
11. **Open AddItem modal, type any character into PartNumber, click ✕** → ConfirmUnsaved popup opens with Save / Discard / Cancel. Click Discard → popup closes. Click +Add Item again → form is empty again.
12. **Audit log inspection** (existing Audit page) — `Audit.ConfigLog` shows new rows: `Item Created`, `Item Updated`, `Item Deprecated` with full OldValue / NewValue / AppUserId.

---

## 12. Risks + open questions

| # | Risk / question | Mitigation / status |
|---|---|---|
| R1 | The bidi `params.value` for ContainerConfig (Phase 1 R1 risk) is still untested. Phase 2 spec called for the `itemRowClicked` handler to also load `containerConfig`, but the landed handler only loads `meta`. So the ContainerConfig tab won't show data when an item is selected — but Phase 3 doesn't depend on ContainerConfig wire; it works entirely on `editDraft.meta`. Phase 3 is independent of the R1 smoke outcome. | Carry-over; Phase 4 (ContainerConfig save) will need to revisit. Phase 3 ships unaffected. |
| R2 | `BtnAddItem` uses native `popup`-type event with `scope: "C"`. Memory targets script events; native popup-type may or may not be subject to the same silent-no-op rule. | Test in smoke. Flip to `"G"` if needed. |
| R3 | Mockup labels say "Parts Per Basket" but the backing column is `MaxLotSize`. Phase 3 keeps the label, rebinds the path. | Documented in § 7. |
| R4 | `CountryOfOrigin` and `MaxParts` are not in the mockup. Phase 3 adds them on the parent Identity row and in the AddItem modal. | Per user confirmation: surface, both optional, no required-field validation. |
| R5 | No client-side validation for `CountryOfOrigin` (e.g., is it a valid ISO code?). The proc accepts any 2-char NVARCHAR. | Acceptable — Configuration Tool users are engineers; proc-side validation is the floor. ISO check could be added later if quality issues arise. |
| R6 | Item dropdowns sourced from live NQs — what if a deprecated ItemType remains the FK on an existing Item? Hides from dropdown options → looks like a data error in the UI. | Item.getOne includes `ItemTypeName` regardless of deprecation; the badge displays the (deprecated) name. The dropdown (Add modal only) shows active only. Update path doesn't need the ItemType dropdown (immutable). So no actual issue. |
| R7 | No optimistic locking. Two users editing the same item concurrently → last write wins. | Matches established project pattern (Downtime Codes, DefectCodes). Acceptable. Engineering surface, low concurrency. |
| R8 | No client-side confirmation on Deprecate. The FK-guards are the safety net. | Documented in § 6.2.2 as an explicit defer. If accidental-deprecate becomes a real concern, add a `ConfirmDestructive` popup in a future polish phase. |
| R9 | Save handler tolerates both camelCase and PascalCase keys (`m.get("partNumber") or m.get("PartNumber")`) to bridge view-side state from two sources (popup uses camelCase draft keys, parent uses PascalCase Item_Get column aliases). Slightly verbose. | Acceptable defensive idiom; matches lenient `_u()`-then-`.get()` style elsewhere. If it becomes confusing, normalize the parent's `editDraft.meta` to camelCase too (out of scope for Phase 3 — would touch the Phase 2 read handler). |
| R10 | The `Audit.ConfigLog` captures proc-level OldValue/NewValue payloads. The Configuration Tool's existing Audit Log browser already surfaces them. No new audit work needed. | Documented for completeness; no design action. |
| R11 | Item Master parent's `view.custom.itemTypes` and `view.custom.uoms` arrays — should these be hydrated once on view open (faster, but stale if MPP adds a type mid-session) or per-render via `runScript`? Phase 1 used hardcoded arrays. Phase 3 needs live data. | **Decision: per-render via `runScript("BlueRidge.Parts.ItemType.getForDropdown", 0)`** — same pattern as `view.custom.items`. NQ-level caching is off; gateway call per binding eval. Cost is trivial (small lookup tables, ~5 rows each). Revisit if measured. |

---

## 13. File deltas

**New:**

- `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Create/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Update/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Deprecate/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/ItemType_List/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/Uom_List/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ItemType/{code.py, resource.json}`
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Uom/{code.py, resource.json}`

**Modified:**

- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Item/code.py` — add `add`, `update`, `deprecate`, `emptyMeta` functions (+ keep all Phase 2 functions intact)
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/view.json` — rebuild draft state, swap hardcoded dropdowns for NQ-bound, add CountryOfOrigin + MaxParts, wire ConfirmUnsaved, wire BtnCreate
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` — wire BtnSave / BtnDeprecate, add itemsRefresh handler, add CountryOfOrigin + MaxParts inputs to Identity row, fix PartsPerBasket → MaxLotSize binding

**Not modified:**

- All SQL (tests stay at 937/937)
- `Components/Parts/ItemMaster/ItemRow/view.json`
- `Components/Parts/ItemMaster/{ContainerConfig,Routes,Boms,QualitySpecs,Eligibility}/view.json`
- `Common/*`
- `Components/Popups/ConfirmUnsaved/view.json` (reused as-is)

**File-edit boundary** (per `feedback_ignition_view_edit_boundary.md`):
- **NEW view files** (none in this phase — AddItem and ItemMaster already exist): file-write safe.
- **Existing view edits** (AddItem.view.json, ItemMaster.view.json): per memory, **Designer is the safe path**. Plan will mark these explicitly as **[DESIGNER]** vs **[FILE]** steps.

---

## 14. References

- `MPP_MES_DATA_MODEL.md` — § Parts schema (Item, ItemType, Uom, ContainerConfig)
- `MPP_MES_FDS.md` — FDS-03-001 (Item required fields incl. CountryOfOrigin), FDS-03-002 (5 ItemType seeds), FDS-03-003 (soft-delete only)
- `mockup/index.html` — lines 308–860 (Item Master screen), lines 2629–2715 (Add Item modal)
- `sql/migrations/repeatable/R__Parts_Item_Create.sql`, `_Update.sql`, `_Deprecate.sql`, `_List.sql`, `_Get.sql`, `R__Parts_ItemType_List.sql`, `R__Parts_Uom_List.sql`
- `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md` (Phase 1)
- `docs/superpowers/specs/2026-05-20-item-master-phase2-design.md` (Phase 2 — extends from here)
- `docs/superpowers/specs/2026-05-19-downtime-codes-wiring-design.md` (closest pattern reference)
- `ignition/.../script-python/BlueRidge/Oee/DowntimeReasonCode/code.py` (entity-script reference impl)
- `ignition/.../views/BlueRidge/Components/Popups/DowntimeCodeEditor/view.json` (popup editor reference impl)
- `ignition-context-pack/03_script_python.md`, `04_named_queries.md`, `07_conventions_and_antipatterns.md`
- Memory: `mpp-confirm-unsaved-popup-pattern`, `feedback-ignition-popup-open-scope`, `feedback-ignition-message-scope-view-vs-page`, `feedback_ignition_view_edit_boundary`, `feedback_ignition_nq_resource_schema`, `project-mpp-item-master-pattern`

---

## 15. Out of scope (deferred to future phases)

| Item | Phase |
|---|---|
| ContainerConfig save (`ContainerConfig.update` / `_Create`) | 4 |
| Routes tab live data + versioning workflow | 5 (already landed: design + plan; impl pending) |
| BOMs tab live data + versioning workflow | 6 (already landed: design + plan; impl pending) |
| Quality Specs cross-link (read-only join) | 7 |
| Eligibility editor (`ItemLocation`) | 8 |
| ConfirmDestructive popup on Deprecate (if accidental-deprecate becomes a concern) | Polish |
| Optimistic locking via RowVersion | Project-wide adoption pass; not Phase 3 |
| Client-side ISO 3166 validation on CountryOfOrigin | Polish |
| ItemType dropdown caching strategy (5-min gateway cache) | Performance tuning |
| Sourcing AddItem modal's dropdown options via view params from parent (instead of per-render runScript) | Refactor if perf surfaces |

---

**Approval:** Self-approved under auto mode. Subject to Jacques's review of the spec post-write.
