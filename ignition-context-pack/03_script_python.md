# Script-python module conventions

How Jython script modules are organized under `ignition/script-python/`, the standard CRUD module shape per entity, the logging idiom, and reusable Util helpers.

## Layout

`ignition/script-python/<package>/<sub>/<entity>/code.py` — the folder path becomes the dotted Python package. So:

```
ignition/script-python/<integrator>/<Domain>/<Entity>/code.py
                       └── package path ────────────┘
```

…is callable from any binding / event / script as `<integrator>.<Domain>.<Entity>.getAll()`.

A typical layout splits scripts by domain (often matching DB schema or application area):

```
script-python/<integrator>/
├─ Common/                   # cross-cutting helpers used by every domain
│  ├─ Db/                    # DB-access helpers
│  ├─ Ui/                    # UI helpers (notifications, etc.)
│  └─ Util/                  # logging, type-coercion, dropdown formatters
├─ <DomainA>/                # one folder per domain
│  ├─ <EntityA1>/code.py
│  ├─ <EntityA2>/code.py
│  └─ Util/code.py           # domain-specific helpers (optional)
└─ <DomainB>/
   └─ <EntityB1>/code.py
```

## Per-module resource.json

```json
{
  "scope": "A",
  "version": 1,
  "files": ["code.py"],
  "attributes": {
    "hintScope": 2,
    "lastModification": { "actor": "...", "timestamp": "..." }
  }
}
```

`scope: "A"` (All) makes the module available to gateway, Designer autocomplete, and client-side scripts. `hintScope: 2` controls Designer autocomplete inclusion (2 = both designer & runtime).

## Standard entity module shape

A predictable surface across every entity module makes views and scripts easier to reason about. Entity scripts go through `<integrator>.Common.Db.*` for all database access — they never call `system.db.*` directly. (See "Common helper implementations" below for what those helpers look like.)

```python
def getAll(filter=None):
    """List shape: returns rows as list[dict] for tables / dropdowns."""
    <integrator>.Common.Util.log("running")
    return <integrator>.Common.Db.execList("<group>/getAllEntities")

def getOne(entityId):
    """Single-row lookup. Returns dict, or None if not found."""
    <integrator>.Common.Util.log("entityId=%s" % entityId)
    return <integrator>.Common.Db.execOne("<group>/getEntity", {"EntityId": entityId})

def add(data):
    """Insert. Returns the proc's status dict: {Status, Message, NewId}."""
    <integrator>.Common.Util.log("data=%s" % data)
    params = {
        "Name":        data.get("Name"),
        "Description": data.get("Description"),
        "AppUserId":   <integrator>.Common.Util._currentAppUserId(),
    }
    return <integrator>.Common.Db.execMutation("<group>/addEntity", params)

def update(data):
    """Update existing row. Pass RowVersion for optimistic locking.
       Returns {Status, Message}."""
    <integrator>.Common.Util.log("data=%s" % data)
    params = {
        "Id":          data.get("Id"),
        "Name":        data.get("Name"),
        "Description": data.get("Description"),
        "RowVersion":  data.get("RowVersion"),
        "AppUserId":   <integrator>.Common.Util._currentAppUserId(),
    }
    return <integrator>.Common.Db.execMutation("<group>/updateEntity", params)

def deprecate(entityId, rowVersion):
    """Soft delete. Returns {Status, Message}."""
    <integrator>.Common.Util.log("entityId=%s" % entityId)
    params = {
        "Id":         entityId,
        "RowVersion": rowVersion,
        "AppUserId":  <integrator>.Common.Util._currentAppUserId(),
    }
    return <integrator>.Common.Db.execMutation("<group>/deprecateEntity", params)

def getEntitiesForDropdown():
    """[{label, value}] shape for ia.input.dropdown."""
    return [{"label": r["Name"], "value": r["Id"]} for r in getAll()]
```

### Conventions worth enforcing across every module

1. **Log entry and exit of every public function.** Direct call to `<integrator>.Common.Util.log(msg)` — no per-module `log()` wrapper. The shared logger auto-fills the calling module and function name via `inspect.currentframe().f_back`.
2. **Docstrings carry purpose / args / returns.** Use the same shape across modules so generated docs are uniform.
3. **Callers pass a dict, never a JSON string.** Older patterns dual-mode the first arg with `if isinstance(data, str): data = system.util.jsonDecode(data)`. Drop that: the type guards exist because the calling convention is ambiguous. If a view truly has a JSON string (rare), decode at the boundary, not in every entity function.
4. **AppUserId from the session, not the caller.** Mutations call `<integrator>.Common.Util._currentAppUserId()` and pass `@AppUserId` to the proc. The proc stamps audit columns (`CreatedAt`, `LastEditedAt`, etc.) — script-side stamping is wrong because the proc's `getdate()` is the canonical write time and the client clock isn't trustworthy.
5. **Optimistic locking via `RowVersion`.** Update and Deprecate procs accept `@RowVersion` and return `Status='ERROR'` with a "modified by another user" message on mismatch. Views load `RowVersion` with the row, keep it untouched during the edit session, and pass it through on save.
6. **Deprecate, not hard-delete.** The proc soft-deletes by setting `DeprecatedAt` (or similar). Hard `DELETE` only when the row is truly transient (in-progress draft being abandoned) — and even then, prefer a dedicated `Discard<Entity>` proc over generic DELETE.

## Standard UI return shapes

Two common shapes for UI-bound queries:

**List shape** (for tables, flex repeaters):

```python
[
  {"Id": 1, "Name": "Foo", "Description": "...", ...},
  {"Id": 2, "Name": "Bar", "Description": "...", ...}
]
```

Plain list of dicts with column names matching the proc's `SELECT` aliases. Tables and repeaters consume this directly.

**Dropdown shape** (for `ia.input.dropdown`):

```python
[
  {"label": "Foo", "value": 1},
  {"label": "Bar", "value": 2}
]
```

The dropdown component looks for `label` and `value` keys specifically — provide these via a separate `<entity>/getForDropdown()` function rather than transforming on the view side.

## Common helper implementations

These three modules (`<integrator>/Common/Db/`, `<integrator>/Common/Ui/`, `<integrator>/Common/Util/`) are the only place that calls `system.db.*` and `system.perspective.*`. Every entity script and every view binding goes through them.

### `<integrator>.Common.Db` — database access

Three sibling functions, paired to the three shapes a proc result takes (many rows, zero-or-one row, status row).

```python
# script-python/<integrator>/Common/Db/code.py

def execList(nq, params=None):
    """Read procs that return 0..N rows. Returns list[dict] keyed by the proc's
       SELECT aliases. Empty list = no match (never None, never an exception)."""
    <integrator>.Common.Util.log("nq=%s params=%s" % (nq, params))
    results = system.db.execQuery(nq, params) if params else system.db.execQuery(nq)
    headers = list(results.getColumnNames())
    rows = [dict(zip(headers, row)) for row in results]
    <integrator>.Common.Util.log("rows=%d" % len(rows))
    return rows

def execOne(nq, params=None):
    """Read procs that return 0 or 1 row. Returns dict or None.
       If proc returns >1, logs a warning and returns the first."""
    rows = execList(nq, params)
    if not rows:
        return None
    if len(rows) > 1:
        <integrator>.Common.Util.log("WARN multi-row from execOne nq=%s" % nq)
    return rows[0]

def execMutation(nq, params=None):
    """Add/Update/Deprecate procs that follow the status-row convention
       (SELECT @Status, @Message, @NewId). Returns the raw dict — keys match
       the proc's SELECT aliases. Does NOT raise on Status='ERROR'."""
    <integrator>.Common.Util.log("nq=%s params=%s" % (nq, params))
    results = system.db.execQuery(nq, params) if params else system.db.execQuery(nq)
    headers = list(results.getColumnNames())
    rows = [dict(zip(headers, row)) for row in results]
    if not rows:
        return {"Status": "ERROR", "Message": "No status returned from proc"}
    if len(rows) > 1:
        <integrator>.Common.Util.log("WARN multi-row from execMutation nq=%s" % nq)
    <integrator>.Common.Util.log("result=%s" % rows[0])
    return rows[0]
```

**Result shapes the caller sees:**

```python
# After an Add proc:       {"Status": "OK",    "Message": "Part created",   "NewId": 4172}
#                          {"Status": "ERROR", "Message": "Duplicate part", "NewId": None}
# After an Update/Deprecate (no NewId in the SELECT):
#                          {"Status": "OK",    "Message": "Part updated"}
#                          {"Status": "ERROR", "Message": "Modified by another user — reload"}
```

**Why a plain dict (not a namedtuple or class) for mutation results:** the wire shape and the script-side shape are identical — no translation layer between SQL and Jython. Adding a new SELECT column (e.g., `@AffectedRows`) automatically appears in the result dict without touching the helper.

**Why `execQuery` and never `execUpdate` for mutations:** mutation procs end with a `SELECT @Status, ...` row. `execUpdate` discards the result set, so the caller gets back an int and has no way to read `Status` / `Message` / `NewId`. Always `execQuery`, even for INSERT / UPDATE / DELETE procs.

### `<integrator>.Common.Ui` — notification helper

```python
# script-python/<integrator>/Common/Ui/code.py

def notifyResult(result, successText, errorText=None):
    """Routes a mutation result to the shared NotificationBanner.
       Success → green toast with successText.
       Failure → red toast with (proc Message ?? caller errorText ?? generic fallback)."""
    if result.get("Status") == "OK":
        payload = {"type": "success", "text": successText}
    else:
        text = result.get("Message") or errorText or "Save failed"
        payload = {"type": "error", "text": text}
    system.perspective.sendMessage("notify", payload=payload)
```

Subscribed to by a `<integrator>/Components/NotificationBanner` view mounted once in the project's top dock or session-overlay container.

**NotificationBanner payload contract:**

| Field | Type | Required | Meaning |
|---|---|---|---|
| `type` | string | yes | One of `success`, `error`, `warning`, `info`. |
| `text` | string | yes | Banner copy. |
| `durationMs` | int | no | Auto-dismiss timeout. Default 4000 (success/info), 8000 (warning/error). |

Behavior: stacks if multiple messages arrive (max 3 visible), auto-dismisses by type, manual close via X button, color/icon coded by `type`.

### `<integrator>.Common.Util` — shared utilities

```python
# script-python/<integrator>/Common/Util/code.py
import inspect
from com.inductiveautomation.ignition.common import TypeUtilities
from com.inductiveautomation.ignition.common.model.values import QualifiedValue

def log(msg):
    """Function-trace logger. Auto-fills calling module + function name so
       call sites don't need a per-module wrapper. Result line:
       <full.module.path>: <funcName>() <msg>"""
    frame  = inspect.currentframe().f_back
    module = frame.f_globals.get("__name__", "unknown")
    func   = frame.f_code.co_name
    system.util.getLogger(module).info("%s() %s" % (func, msg))

def _currentAppUserId():
    """Resolves the calling session's appUserId from session.custom.appUserId
       (set at login). Mutations pass this to procs as @AppUserId for audit
       attribution. Underscore-prefixed because callers should not be passing
       around appUserId values — the helper is the only sanctioned source."""
    return system.perspective.getSessionInfo()["custom"].get("appUserId")

def extractQualifiedValues(data):
    """Recursively unwrap QualifiedValue (from tag/property bindings) through
       lists / tuples / dicts. Use whenever a binding hands script-side code
       a value that might be wrapped — bidirectional-bound props especially."""
    if isinstance(data, QualifiedValue):
        return data.getValue()
    if isinstance(data, list):
        return [extractQualifiedValues(x) for x in data]
    if isinstance(data, tuple):
        return tuple(extractQualifiedValues(x) for x in data)
    if isinstance(data, dict):
        return {k: extractQualifiedValues(v) for k, v in data.items()}
    return data

def convertWrapperObjectToJson(obj):
    """TypeUtilities.pyToGson — converts Jython PyDictionary / PyList wrappers
       into Gson-safe JSON before passing as named-query params. Required when
       a view hands a self.custom.* dict to a script that forwards it to a NQ."""
    return TypeUtilities.pyToGson(obj)
```

`extractQualifiedValues` and `convertWrapperObjectToJson` solve a class of "value comes back wrapped and SQL parameter binding fails" problems you'll otherwise hit repeatedly.

The previous-generation pattern (seen in older Ignition projects) had a `log(msg)` wrapper in every entity module that delegated to a per-domain `Util.logging(...)`. Modern practice: one shared `Common.Util.log` and direct calls — fewer wrappers, single source of truth.

### View → entity → Common helper, end-to-end

A Save button's `onActionPerformed` is a one-liner that delegates to the entity script and routes the result through `notifyResult`:

```python
result = <integrator>.Items.Item.update(self.view.custom.editDraft)
<integrator>.Common.Ui.notifyResult(result, successText="Saved")
if result["Status"] == "OK":
    self.view.custom.selected = dict(self.view.custom.editDraft)
    system.perspective.sendMessage("refreshTrigger")
```

Three lines is the inline-script cap. If the handler grows past that, factor into `<integrator>.Items.Item.handleSave(draft)` and call as a one-liner from the event.

## Do NOT call `system.db.*` from views directly

Three-layer rule for clean separation:

| Layer | Path | Allowed to call |
|---|---|---|
| **View** | `views/<integrator>/Views/<Domain>/<Page>/view.json` | Entity scripts only |
| **Entity script** | `script-python/<integrator>/<Domain>/<Entity>/code.py` | `<integrator>.Common.*` and other entity scripts |
| **Common helpers** | `script-python/<integrator>/Common/<Module>/code.py` | `system.db.*`, `system.perspective.*`, low-level Ignition APIs |

A view's event handler calls into an entity script (`<integrator>.Items.Item.add(self.view.custom.editDraft)`); the entity script does its data shaping and calls into `Common.Db.execMutation(...)`; only Common knows about `system.db.execQuery`.

This isolates: SQL named-query names stay out of views; UI-shape vs DB-shape conversion has one home; business logic doesn't leak into bindings; and the same entity script can serve UI events, gateway timers, and (later) REST endpoints.

## Long event scripts → factor into a project script

A view's `events.dom.onClick` config takes a script string. Anything past 1–3 logical lines should move into a project script and be called as a one-liner:

```json
"events": {
  "component": {
    "onActionPerformed": {
      "type": "script", "scope": "C",
      "config": { "script": "<integrator>.Items.Item.handleSave(self.view.custom.editDraft)" }
    }
  }
}
```

Inline scripts are interpreted at action time — slower than expression bindings (preloaded) and slower than project-script calls (also preloaded). They also don't show up in any IDE search for "where is this logic?", which slows refactoring.

## Project-script call from a binding

Inside a binding transform or expression:

```
runScript('<integrator>.MyDomain.MyEntity.computeSomething', 0, {value})
```

The `0` is the cache TTL in seconds (`0` = no cache). Use a positive number for read-side scripts that hit the DB infrequently and benefit from gateway-side memoization. The function should be idempotent and side-effect-free.
