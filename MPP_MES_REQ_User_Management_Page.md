# Requirements — Config Tool "User Management" Page (Operators)

**Project:** MPP MES Replacement (Ignition Perspective + SQL Server 2022)
**Surface:** Configuration Tool app (`MPP_Config` Perspective project), new `/users` page
**Audience:** Front-end intern (no AI assistant)
**Author:** Blue Ridge Automation
**Date:** 2026-06-16
**Status:** Ready for build

---

## 1. Revision History

| Date | Version | Author | Change |
|---|---|---|---|
| 2026-06-16 | 1.0 | Blue Ridge Automation | Initial requirements for the operator User Management page. |

---

## 2. Goal (read this first)

Build a **User Management** page in the Configuration Tool that lets an administrator
**create, view, edit, and deprecate (deactivate) "Operator" users**.

An *Operator* is a shop-floor worker who is identified only by their **initials** — they
do **not** log in with a password and have **no** security role. Every production and
audit event in the plant is stamped with an operator's `AppUser.Id`, so keeping this list
accurate is important.

You are building the whole feature stack for this page: a thin database glue layer
(Named Queries + one Python script module) **and** the Perspective views. The SQL stored
procedures already exist — you will **not** write any SQL stored procedures or migrations.

> **What "operator" means here:** in the `Location.AppUser` table an operator row has
> `AdAccount = NULL` and `IgnitionRole = NULL`. Users that *do* have an AD account / role
> (Supervisors, Quality, Engineering, Admin — "interactive users") are **out of scope** and
> must **never** appear in or be edited by this page. See §8 (Safety Rule) — this matters.

---

## 3. Scope

### In scope
- A list of operator users with a search box and an "include deprecated" toggle.
- Create a new operator (Initials + Display Name).
- Edit an existing operator (Initials + Display Name).
- Deprecate (deactivate) an operator.
- The 4 Named Queries and 1 Python script module that the page calls.
- Registering the page route and nav entry.

### Out of scope (do **not** build)
- Managing interactive users (Admin / Engineering / Supervisor / Quality). No AD account field,
  no role field anywhere on this page.
- Passwords / PIN / authentication of any kind. Operators have none.
- Any SQL stored procedure or database migration (they already exist — see §5).
- Hard-deleting users. We only "deprecate" (soft-delete via a timestamp).

---

## 4. Architecture you must follow (the 3-layer rule)

Every database call in this project flows through exactly three layers. **Do not skip a layer.**
Views never touch the database directly.

```
Perspective View  ──►  Python entity script        ──►  Common.Db helper      ──►  Named Query   ──►  SQL stored proc
(view.json)            BlueRidge.Location.AppUser        BlueRidge.Common.Db        (resource.json     Location.AppUser_*
                       (you write this)                  (already exists)            + query.sql)       (already exists)
```

- **Views** call the entity script via a `runScript("BlueRidge.Location.AppUser.<fn>", 0, ...)` binding
  or from an event/message-handler script.
- **The entity script** (`BlueRidge.Location.AppUser`) is the only place that knows Named Query names.
  It calls `BlueRidge.Common.Db.execList / execOne / execMutation`.
- **`Common.Db`** is the only code allowed to call `system.db.*`. You do not modify it.
- **Named Queries** are thin `EXEC` wrappers around the stored procedures.

---

## 5. What already exists vs. what YOU build

### 5.1 The database table (exists — reference only)

`Location.AppUser` — columns relevant to this page:

| Column | Type | Notes for operators |
|---|---|---|
| `Id` | BIGINT (PK) | Surrogate key. |
| `Initials` | NVARCHAR(10), **NOT NULL, UNIQUE** | The operator's stamp. Required. Must be globally unique. |
| `DisplayName` | NVARCHAR(200), **NOT NULL** | Full name for display. Required. |
| `AdAccount` | NVARCHAR(100), NULL | **Operators: always NULL.** (Interactive-user field — not on this page.) |
| `IgnitionRole` | NVARCHAR(100), NULL | **Operators: always NULL.** (Interactive-user field — not on this page.) |
| `CreatedAt` | DATETIME2(3) | Set by the DB on insert. Display only. |
| `DeprecatedAt` | DATETIME2(3), NULL | NULL = active. Non-NULL = deprecated/inactive. |

### 5.2 Stored procedures (exist — you call them, do not edit them)

All in schema `Location`. Mutation procs return a single status row:
`Status` (1 = success, 0 = business-rule failure), `Message` (text), and `NewId` (Create only).

| Proc | Parameters | Returns | Notes |
|---|---|---|---|
| `AppUser_List` | `@IncludeDeprecated BIT = 0` | rows: `Id, Initials, DisplayName, AdAccount, IgnitionRole, CreatedAt, DeprecatedAt` (ordered by DisplayName) | Returns **all** classes — you filter to operators in the script (§8). |
| `AppUser_Get` | `@Id BIGINT` | 0 or 1 row (same columns) | Empty result = not found (not an error). |
| `AppUser_Create` | `@Initials, @DisplayName, @AdAccount=NULL, @IgnitionRole=NULL, @AppUserId` | `Status, Message, NewId` | Initials required + globally unique. |
| `AppUser_Update` | `@Id, @Initials, @DisplayName, @AdAccount=NULL, @IgnitionRole=NULL, @AppUserId` | `Status, Message` | Initials unique (excluding self). Row must exist and not be deprecated. |
| `AppUser_Deprecate` | `@Id, @AppUserId` | `Status, Message` | **Cannot** deprecate the bootstrap user (`Id = 1`) or **your own** account. |

For operators you always pass `@AdAccount = NULL` and `@IgnitionRole = NULL`.

### 5.3 Glue layer — **YOU BUILD THIS** (it does not exist yet)

| Item | Status | You do |
|---|---|---|
| Named Query `location/AppUser_Create` | ✅ exists | nothing |
| Named Query `location/AppUser_List` | ❌ missing | **create** (Task A) |
| Named Query `location/AppUser_Get` | ❌ missing | **create** (Task A) |
| Named Query `location/AppUser_Update` | ❌ missing | **create** (Task A) |
| Named Query `location/AppUser_Deprecate` | ❌ missing | **create** (Task A) |
| Script module `BlueRidge.Location.AppUser` | ❌ missing | **create** (Task B) |
| `/users` page view, row component, editor popup | ❌ missing | **create** (Tasks C–E) |
| Route + nav registration | ❌ missing | **create** (Task F) |

---

## 6. Task breakdown

Build in this order. Each task lists exactly where files go and what they contain.

### Task A — Create the 4 missing Named Queries

Named Queries live in the **Core** project (project convention — all NQs are in Core, child
projects inherit them). Each NQ is a folder containing `resource.json` (metadata) and
`query.sql` (the EXEC body).

Create these four folders under:
`ignition/projects/Core/ignition/named-query/location/`

`sqlType` codes you'll use: **`3` = BIGINT/Long**, **`6` = BIT (boolean)**, **`7` = VARCHAR/string**.

> ⚠️ **Critical:** all four `resource.json` files must set `"type": "Query"` (already shown below).
> Mutation procs that return a status row, if mis-typed as `UpdateQuery`, throw *"A result set was
> generated for update"* and the UI silently does nothing. Use `"Query"` for **all** of these.

#### `AppUser_List/query.sql`
```sql
EXEC Location.AppUser_List
    @IncludeDeprecated = :includeDeprecated
```
#### `AppUser_List/resource.json`
```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": ["query.sql"],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "intern", "timestamp": "2026-06-16T00:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "includeDeprecated", "sqlType": 6 }
    ]
  }
}
```

#### `AppUser_Get/query.sql`
```sql
EXEC Location.AppUser_Get
    @Id = :id
```
#### `AppUser_Get/resource.json`
Same boilerplate as above, with this `parameters` array:
```json
"parameters": [
  { "type": "Parameter", "identifier": "id", "sqlType": 3 }
]
```

#### `AppUser_Update/query.sql`
```sql
EXEC Location.AppUser_Update
    @Id           = :id,
    @Initials     = :initials,
    @DisplayName  = :displayName,
    @AdAccount    = :adAccount,
    @IgnitionRole = :ignitionRole,
    @AppUserId    = :appUserId
```
#### `AppUser_Update/resource.json`
Same boilerplate, with:
```json
"parameters": [
  { "type": "Parameter", "identifier": "id",           "sqlType": 3 },
  { "type": "Parameter", "identifier": "initials",     "sqlType": 7 },
  { "type": "Parameter", "identifier": "displayName",  "sqlType": 7 },
  { "type": "Parameter", "identifier": "adAccount",    "sqlType": 7 },
  { "type": "Parameter", "identifier": "ignitionRole", "sqlType": 7 },
  { "type": "Parameter", "identifier": "appUserId",    "sqlType": 3 }
]
```

#### `AppUser_Deprecate/query.sql`
```sql
EXEC Location.AppUser_Deprecate
    @Id        = :id,
    @AppUserId = :appUserId
```
#### `AppUser_Deprecate/resource.json`
Same boilerplate, with:
```json
"parameters": [
  { "type": "Parameter", "identifier": "id",        "sqlType": 3 },
  { "type": "Parameter", "identifier": "appUserId", "sqlType": 3 }
]
```

> ✅ A perfect reference for the file shape is the existing
> `ignition/projects/Core/ignition/named-query/location/AppUser_Create/` folder — copy its
> `resource.json` and edit the `parameters` array + `query.sql`.

> 🔁 **After creating Named Queries you must RESTART the Ignition gateway** — not just run a
> scan. Inherited Named Queries (created in Core, used from `MPP_Config`) are only picked up on
> gateway restart. If you skip this, the page will fail with *"Named query not found ..."* in the
> gateway log. (A scan is enough for views/scripts; NQ inheritance needs the restart.)

---

### Task B — Create the entity script `BlueRidge.Location.AppUser`

**Path:** `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/AppUser/code.py`
(plus the standard `resource.json` next to it — copy one from a sibling script folder such as
`BlueRidge/Quality/DefectCode/`).

This is **Jython 2.x** (Python 2 syntax). Use the template below as-is; it mirrors the existing
`BlueRidge.Quality.DefectCode` module, adapted for operators.

```python
# =============================================================================
# Project Library:  BlueRidge.Location.AppUser
#
# Description:
#   Read + mutation surface for the Operator User Management screen.
#   OPERATORS ONLY: rows where AdAccount IS NULL and IgnitionRole IS NULL.
#   Interactive (AD-backed) users are filtered out and must never be
#   created or edited through this module.
#
#   Routes every DB call through BlueRidge.Common.Db.* helpers.
#
# Public surface:
#   search(filter)   -> list[dict]            (list-view feed)
#   getOne(id)       -> dict | None
#   add(data)        -> {Status, Message, NewId}
#   update(data)     -> {Status, Message}
#   deprecate(id)    -> {Status, Message}
# =============================================================================


def _u(value):
    """Deep-unwrap QualifiedValue / Java Map containers handed in from views."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filter=None):
    """One-shot list-view feed. Loads operators, applies the client-side
    search-text filter, maps each row to the shape the UserRow component
    expects.

    filter keys (all optional):
        includeDeprecated  bool, default False  (server-side via proc)
        searchText         string or None       (client-side filter here)
    """
    f = _u(filter) or {}
    rows = getAll(bool(f.get("includeDeprecated", False)))
    needle = (f.get("searchText") or "").strip().lower()
    out = []
    for r in rows:
        # OPERATORS ONLY: skip any interactive (AD-backed) user. See requirements §8.
        if r.get("AdAccount"):
            continue
        initials    = r.get("Initials") or ""
        displayName = r.get("DisplayName") or ""
        if needle and needle not in initials.lower() and needle not in displayName.lower():
            continue
        out.append({
            "id":          r.get("Id"),
            "initials":    initials,
            "displayName": displayName,
            "createdAt":   r.get("CreatedAt"),
            "deprecated":  r.get("DeprecatedAt") is not None,
            "selected":    False,
        })
    return out


def getAll(includeDeprecated=False):
    """List users from the proc (all classes; search() filters to operators)."""
    try:
        return BlueRidge.Common.Db.execList(
            "location/AppUser_List",
            {"includeDeprecated": 1 if includeDeprecated else 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("AppUser.getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load users", str(e), "error")
        return []


def getOne(appUserId):
    """Single-row lookup for the editor load. Returns dict or None."""
    appUserId = _u(appUserId)
    if appUserId is None:
        return None
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_Get",
        {"id": appUserId},
    )


def add(data):
    """Create an operator. data: {Initials, DisplayName}.
    adAccount / ignitionRole are forced to None (operators have neither)."""
    data = _u(data) or {}
    return BlueRidge.Common.Db.execMutation(
        "location/AppUser_Create",
        {
            "initials":     (data.get("Initials") or "").strip(),
            "displayName":  (data.get("DisplayName") or "").strip(),
            "adAccount":    None,
            "ignitionRole": None,
            "appUserId":    BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update an operator. data: {Id, Initials, DisplayName}.
    adAccount / ignitionRole are forced to None — never set them here."""
    data = _u(data) or {}
    return BlueRidge.Common.Db.execMutation(
        "location/AppUser_Update",
        {
            "id":           data.get("Id"),
            "initials":     (data.get("Initials") or "").strip(),
            "displayName":  (data.get("DisplayName") or "").strip(),
            "adAccount":    None,
            "ignitionRole": None,
            "appUserId":    BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(appUserId):
    """Soft-delete (deactivate). Returns {Status, Message}."""
    appUserId = _u(appUserId)
    return BlueRidge.Common.Db.execMutation(
        "location/AppUser_Deprecate",
        {
            "id":        appUserId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )
```

Notes:
- `BlueRidge.Common.Util._currentAppUserId()` returns the logged-in admin's `AppUser.Id` for
  audit attribution — already exists, just call it.
- `add()`/`update()` **hard-code `adAccount=None`, `ignitionRole=None`**. Do not parameterize these.
- The mutation result is always a dict `{"Status": 1|0, "Message": "..."}`. `Status` truthy = success.
  Never compare to `"OK"`.

---

### Task C — Build the list page view `/users`

**Use `BlueRidge/Views/Quality/DefectCodes/view.json` as your template** — copy it and adapt.
It is the cleanest CRUD list page in the project.

**Path:** `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/Users/view.json`

Layout (mirror DefectCodes):
- **Title row:** breadcrumb + title "User Management" + an **"+ Add Operator"** button.
- **Filter bar:** a search text input (bound to `view.custom.filter.searchText`) and an
  **"Include deprecated"** checkbox (bound to `view.custom.filter.includeDeprecated`).
- **Table header row** with columns: Initials · Display Name · Created · Status · (Edit).
- **Flex-repeater** (`ia.display.flex-repeater`, `direction: "column"`) whose `props.instances`
  is bound to `view.custom.rows`, rendering the `UserRow` component (Task D).

Required `custom` block (pre-declare every bound prop with a fully-shaped default — see Gotcha G6):
```json
"custom": {
  "filter": { "searchText": "", "includeDeprecated": false },
  "rows": []
}
```

Bind the rows (expression binding on `custom.rows`):
```
runScript("BlueRidge.Location.AppUser.search", 0, {view.custom.filter})
```

Add a **page-scoped message handler** named `userRefresh` that reloads the list (used after
save/deprecate). The handler script body (remember the leading tab — Gotcha G4):
```python
	self.view.custom.rows = BlueRidge.Location.AppUser.search(self.view.custom.filter)
```

The **"+ Add Operator"** button opens the editor popup in create mode (note `scope: "G"` — Gotcha G3):
```python
	system.perspective.openPopup(
		"mpp-user-editor",
		"BlueRidge/Components/Popups/UserEditor",
		params={"mode": "create", "appUserId": None},
		modal=True)
```

---

### Task D — Build the `UserRow` component

**Path:** `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/UserRow/view.json`

Reference: `BlueRidge/Components/DefectCodeRow/view.json`.

- **Params (input):** `id`, `initials`, `displayName`, `createdAt`, `deprecated`, `selected`.
- Display the fields in aligned columns. Within a tabular row, using `meta.visible` to hide a
  cell is acceptable (it preserves column alignment — Gotcha G7).
- Reduce row opacity when `deprecated = true` (expression binding on style).
- An **"Edit"** button opens the editor in update mode (`scope: "G"`):
```python
	system.perspective.openPopup(
		"mpp-user-editor",
		"BlueRidge/Components/Popups/UserEditor",
		params={"mode": "update", "appUserId": self.view.params.id},
		modal=True)
```

---

### Task E — Build the `UserEditor` popup

**Use `BlueRidge/Components/Popups/DefectCodeEditor/view.json` as your template.**

**Path:** `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/UserEditor/view.json`

**Params:** `mode` ("create" | "update"), `appUserId` (BIGINT or None).

**`custom` block** — keep both an original (`selected`) and a working copy (`editDraft`), and
**pre-shape `editDraft.meta` with every key the form binds** (Gotcha G5/G6):
```json
"custom": {
  "mode": "create",
  "selected": { "meta": { "Id": null, "Initials": "", "DisplayName": "" } },
  "editDraft": { "meta": { "Id": null, "Initials": "", "DisplayName": "" } }
}
```

**Form fields (only two):**
| Field | Component | Bind (bidirectional) | Rules |
|---|---|---|---|
| Initials | `ia.input.text-field` | `view.custom.editDraft.meta.Initials` | Required, ≤ 10 chars. |
| Display Name | `ia.input.text-field` | `view.custom.editDraft.meta.DisplayName` | Required, ≤ 200 chars. |

There is **no** AD Account field and **no** Role field on this page.

**On open, in update mode**, load the record (see DefectCodeEditor's load pattern — a lifecycle/
onStartup hook in `events.system`, Gotcha G8):
```python
	if self.view.params.mode == "update" and self.view.params.appUserId is not None:
		row = BlueRidge.Location.AppUser.getOne(self.view.params.appUserId)
		if row:
			meta = {"Id": row["Id"], "Initials": row["Initials"], "DisplayName": row["DisplayName"]}
			# ONE atomic write of the whole state object (Gotcha G5):
			self.view.custom.editDraft = {"meta": dict(meta)}
			self.view.custom.selected = {"meta": dict(meta)}
```

**Save button** custom method:
```python
	mode = self.view.custom.mode
	meta = (self.view.custom.editDraft or {}).get("meta") or {}
	initials = (meta.get("Initials") or "").strip()
	displayName = (meta.get("DisplayName") or "").strip()

	# Client-side guard rails (the proc is the real authority):
	if not initials:
		BlueRidge.Common.Notify.toast("Initials required", "Enter the operator's initials.", "warning")
		return
	if not displayName:
		BlueRidge.Common.Notify.toast("Display name required", "Enter the operator's name.", "warning")
		return

	if mode == "create":
		result = BlueRidge.Location.AppUser.add(meta)
		successTitle = "Operator created"
	else:
		result = BlueRidge.Location.AppUser.update(meta)
		successTitle = "Operator updated"

	# Route the proc result (Status/Message) to a toast:
	BlueRidge.Common.Ui.notifyResult(result, successTitle)

	if result and result.get("Status"):
		system.perspective.sendMessage("userRefresh", scope="page")
		system.perspective.closePopup("mpp-user-editor")
```

**Deprecate button** (visible in update mode only) — confirm, then call deprecate:
```python
	result = BlueRidge.Location.AppUser.deprecate(self.view.params.appUserId)
	BlueRidge.Common.Ui.notifyResult(result, "Operator deprecated")
	if result and result.get("Status"):
		system.perspective.sendMessage("userRefresh", scope="page")
		system.perspective.closePopup("mpp-user-editor")
```
> The proc itself blocks deprecating the bootstrap user (`Id 1`) and self-deprecation, returning
> `Status = 0` with an explanatory `Message` — `notifyResult` will surface that to the admin, so you
> do not need to re-implement those checks in the UI.

**Cancel / X** buttons close the popup. (Optional polish: wire them through the existing
`BlueRidge/Components/Popups/ConfirmUnsaved` popup if the draft is dirty — see DefectCodeEditor /
LocationTypeEditor for the established pattern. Not required for a first pass.)

---

### Task F — Register the route and nav entry

1. **Route** — add to
   `ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json`:
   ```json
   "/users": {
     "title": "User Management",
     "viewPath": "BlueRidge/Views/Location/Users"
   }
   ```
   (Match the exact JSON shape of the existing entries in that file.)

2. **Nav highlight** — add `/users` to the category mapping in
   `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Common/Nav/code.py`
   (find `categoryForPath` and map `/users` to the same category the other admin/config screens use).
   Then add a nav rail item following the existing pattern so the page is reachable.

---

### Task G — Scan, restart, and test

1. **Restart the Ignition gateway** (required for the new Named Queries — see Task A note).
2. Run **`.\scan.ps1`** at the project root after writing any new view / script / NQ resource so the
   gateway re-reads the files.
3. Walk the acceptance checklist in §9 in a browser session (you must be logged in so
   `_currentAppUserId()` resolves).

---

## 7. Form & validation summary

| Field | Required | Max len | Unique | Where enforced |
|---|---|---|---|---|
| Initials | Yes | 10 | Yes (all users) | Proc (authoritative) + UI pre-check |
| Display Name | Yes | 200 | No | Proc + UI pre-check |

The stored procedures are the **source of truth** for validation. The UI checks above are just for
a snappier experience — always show the proc's returned `Message` on `Status = 0`.

---

## 8. ⚠️ Safety Rule — operators only (do not skip)

`AppUser_List` returns **every** user, including interactive (AD-backed) users such as Supervisors
and Admins. This page must show and edit **only operators** (`AdAccount IS NULL`).

**Two reasons this is mandatory:**
1. **Clarity** — admins managing shop-floor initials should not see login accounts mixed in.
2. **It prevents data corruption.** This page's edit form does not expose the `AdAccount` or
   `IgnitionRole` fields, and the entity script's `update()` always sends them as `NULL`. If an
   *interactive* user were ever edited here, saving would **wipe their AD account and role**,
   silently demoting a Supervisor/Admin into a no-login operator.

**How it's enforced:** the `search()` function in the entity script skips any row where
`AdAccount` is set (`if r.get("AdAccount"): continue`). Because the list only ever contains
operators, the edit/deprecate paths can only ever touch operators. **Do not remove that filter.**

---

## 9. Acceptance criteria

- [ ] `/users` appears in the nav and loads without component errors.
- [ ] The list shows only operators (no AD-backed users), sorted by Display Name.
- [ ] The search box filters by initials or display name (case-insensitive).
- [ ] "Include deprecated" off → only active users; on → deprecated users also appear (visually marked).
- [ ] "+ Add Operator" opens a blank editor; saving a valid operator shows a success toast and the new
      row appears in the list.
- [ ] Creating with a duplicate Initials value shows the proc's failure message (no crash, popup stays open).
- [ ] Editing an operator's Initials/Display Name persists and the list updates.
- [ ] Deprecate shows a success toast, the row becomes marked deprecated / drops out of the active list.
- [ ] Attempting to deprecate user `Id 1` (bootstrap) or your own account shows the proc's blocking
      message via a toast (no crash).
- [ ] No `system.db.*` calls anywhere in your views or the entity script (all DB access via `Common.Db`).
- [ ] `git diff --stat` on each `view.json` shows a small, structural change — not thousands of lines
      (see Gotcha G9).

---

## 10. Reference files to copy from

| You're building | Copy / study this |
|---|---|
| List page view | `views/BlueRidge/Views/Quality/DefectCodes/view.json` |
| Row component | `views/BlueRidge/Components/DefectCodeRow/view.json` |
| Editor popup | `views/BlueRidge/Components/Popups/DefectCodeEditor/view.json` |
| Entity script | `script-python/BlueRidge/Quality/DefectCode/code.py` |
| Named Query files | `Core/.../named-query/location/AppUser_Create/` (resource.json + query.sql) |
| `Common.Db` API | `script-python/BlueRidge/Common/Db/code.py` (read only — do not edit) |
| Toasts | `BlueRidge.Common.Notify.toast(title, message, level)` and `BlueRidge.Common.Ui.notifyResult(result, title)` |

---

## 11. Ignition gotchas (these will waste your day if you don't know them)

These are hard-won project conventions. Every one of them has bitten someone before.

- **G1 — Scan after file writes.** After creating/editing any view, script, or NQ on disk, run
  `.\scan.ps1` so the gateway re-reads the files. Nothing updates until you do.
- **G2 — New Named Queries need a gateway *restart*, not just a scan.** NQs created in Core and used
  from `MPP_Config` are only registered on restart. Symptom if skipped: *"Named query not found"* in the
  gateway log and the page fails to load data.
- **G3 — `system.perspective.*` from a DOM-event script needs `"scope": "G"`.** Popup opens and
  messages silently no-op under `scope: "C"`. Always declare `scope: "G"` on button-click handlers
  that open popups or send messages.
- **G4 — Event/handler script bodies must start with a tab.** Designer wraps your script in
  `def runAction(self, event):`, so the body must be indented. A column-0 first line = `IndentationError`
  and the handler silently does nothing. Begin each handler body with `\t`, nested blocks with more tabs.
- **G5 — Reseed editor state in ONE atomic write.** When loading a record, assign the whole
  `editDraft` / `selected` object in a single property write (as shown in Task E). Two sequential
  writes make the "dirty" detection fire spuriously.
- **G6 — Pre-declare every custom prop a binding reads, with a fully-shaped default.** A binding that
  traverses `{view.custom.X.field}` or measures `len({view.custom.X})` errors out (red component) if
  `X` doesn't exist yet. Declare `custom.rows: []`, `custom.filter: {...}`, `editDraft.meta: {...all keys...}`
  up front. A `runScript`-bound prop's *initial* value must also be the correct shape (`[]`, not `{}`/null).
- **G7 — `meta.visible` is OK inside table/row layouts.** The usual rule is "use `position.display`",
  but in a tabular row where column alignment matters, `meta.visible` is the correct choice (it preserves
  the slot).
- **G8 — `onStartup` lives in `events.system`, not `events.component`.** A startup script placed under
  `events.component.onStartup` never fires (no error shown). Put view startup logic in the `events.system` channel.
- **G9 — Don't commit pickled live data.** Saving a view in Designer can embed runtime table data
  (thousands of rows) into `view.json` as a prop default. Always `git diff --stat` before committing; a
  small structural change should be tens of lines, not thousands. Revert the pickle if you see it.
- **G10 — ASCII only in any text that reaches SQL/labels.** Avoid em-dashes / smart quotes / middle-dots
  in seed strings; they get stored as mojibake. (Not a big risk on this page, but a project rule.)
- **G11 — Table row clicks are `onSelectionChange`, not `onRowClick`** (if you use a `ia.display.table`
  anywhere). The flex-repeater pattern in this doc avoids that, but keep it in mind.
- **G12 — Editing an *existing* view? Do it in Designer, not by editing the file.** File edits are safe
  for the **new** views you create here, but editing an already-existing `view.json` on disk fights
  Designer's cache and its serialization escapes. The files in this task are all new — file editing is fine.

---

## 12. Glossary

| Term | Meaning |
|---|---|
| **Operator** | Shop-floor worker identified by initials; no login, no role. `AdAccount`/`IgnitionRole` NULL. |
| **Interactive user** | A user who logs in via Active Directory and carries an Ignition role. **Out of scope here.** |
| **Deprecate** | Soft-delete: set `DeprecatedAt` to now. The row stays for history; it's just inactive. |
| **Entity script** | Project Python module (`BlueRidge.<Area>.<Entity>`) that wraps DB access for one entity. |
| **Named Query (NQ)** | An Ignition resource that runs a parameterized SQL statement (here, an `EXEC`). |
| **`Common.Db`** | The shared helper (`execList`/`execOne`/`execMutation`) — the only code that calls `system.db.*`. |
| **Status row** | The `{Status, Message, NewId?}` result every mutation proc returns. `Status` 1 = success, 0 = failure. |
| **Scan / `scan.ps1`** | Tells the gateway to re-read project files from disk after you change them. |
