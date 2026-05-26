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
5. **Optimistic locking via `RowVersion`.** Update and Deprecate procs accept `@RowVersion` and return `Status=0` with a "modified by another user" message on mismatch. Views load `RowVersion` with the row, keep it untouched during the edit session, and pass it through on save.
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
    ds = system.db.runNamedQuery(nq, params) if params else system.db.runNamedQuery(nq)
    if ds is None or ds.getRowCount() == 0:
        return []
    headers = list(ds.getColumnNames())
    rows = [dict(zip(headers, row)) for row in ds]
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
       the proc's SELECT aliases. Does NOT raise on Status=0 (business-rule
       failure)."""
    <integrator>.Common.Util.log("nq=%s params=%s" % (nq, params))
    ds = system.db.runNamedQuery(nq, params) if params else system.db.runNamedQuery(nq)
    headers = list(ds.getColumnNames())
    rows = [dict(zip(headers, row)) for row in ds]
    if not rows:
        return {"Status": 0, "Message": "No status returned from proc"}
    if len(rows) > 1:
        <integrator>.Common.Util.log("WARN multi-row from execMutation nq=%s" % nq)
    <integrator>.Common.Util.log("result=%s" % rows[0])
    return rows[0]
```

**Proc-side Status convention (project-specific, source of truth: the SPs themselves):**

The status row's `@Status` is **`BIT`** — `1` for success, `0` for business-rule failure. Procs declare:

```sql
DECLARE @Status  BIT           = 0;                  -- failure default
DECLARE @Message NVARCHAR(500) = N'Unknown error';
DECLARE @NewId   BIGINT        = NULL;               -- Create/Add procs only

-- On a validated failure path:
SET @Message = N'Duplicate part';
SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
RETURN;

-- On the success path:
SET @Status  = 1;
SET @Message = N'Part created';
SET @NewId   = SCOPE_IDENTITY();                     -- Create/Add only
SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
```

**Result shapes the caller sees:**

```python
# After an Add proc:       {"Status": 1, "Message": "Part created",   "NewId": 4172}
#                          {"Status": 0, "Message": "Duplicate part", "NewId": None}
# After an Update/Deprecate (no NewId in the SELECT):
#                          {"Status": 1, "Message": "Part updated"}
#                          {"Status": 0, "Message": "Modified by another user — reload"}
```

**Status check pattern:** callers use a truthy check — `if result.get("Status"):` — which is robust to JDBC mapping BIT as either Python `bool`, `int`, or Java `Boolean`. **Avoid `== "OK"` / `== 1` literal comparisons** for the same reason.

**Why BIT rather than NVARCHAR `"OK"`/`"ERROR"`:** matches SQL's native success-flag idiom and the existing project convention. Other projects following this pack MAY pick NVARCHAR `"OK"`/`"ERROR"` instead — whichever pattern your stored procs already use becomes the rule of law; the helper layer adapts.

**Why a plain dict (not a namedtuple or class) for mutation results:** the wire shape and the script-side shape are identical — no translation layer between SQL and Jython. Adding a new SELECT column (e.g., `@AffectedRows`) automatically appears in the result dict without touching the helper.

**Why `runNamedQuery` and never `execUpdate` for mutations:** mutation procs end with a `SELECT @Status, ...` row. `system.db.execUpdate` discards the result set, so the caller gets back an int and has no way to read `Status` / `Message` / `NewId`. Always use `system.db.runNamedQuery` (which returns a Dataset), even for INSERT / UPDATE / DELETE procs that go through an `UpdateQuery`-typed NQ.

**Why `runNamedQuery` and not `execQuery`:** `system.db.execQuery(sql, database)` is for raw SQL execution against a connection — it takes a SQL string and an optional database name. `system.db.runNamedQuery(path, params)` resolves the configured NQ resource and respects its `type` / `database` / `permissions` / `cache` settings. NQ paths go through `runNamedQuery`; raw SQL goes through `execQuery`. Don't confuse them.

### `<integrator>.Common.Ui` — notification helper

```python
# script-python/<integrator>/Common/Ui/code.py

def notifyResult(result, successTitle, successMsg=None, errorTitle=None):
    """Routes a mutation result to the toast layer.
       Status truthy → success toast with successTitle / successMsg.
       Status falsy  → error toast with (proc Message ?? generic fallback)."""
    status = result.get("Status") if result else 0
    if status:
        <integrator>.Common.Notify.toast(
            successTitle,
            successMsg or "",
            "success",
        )
        return
    message = (result.get("Message") if result else None) or "No additional detail."
    <integrator>.Common.Notify.toast(
        errorTitle or "Action failed",
        message,
        "error",
    )
```

### `<integrator>.Common.Notify` — toast surface

The notification primitive is a **popup-per-toast** stack rather than a single mounted banner view. Each fired toast opens its own Perspective popup positioned in the top-right corner; multiple toasts stack downward with explicit slot spacing.

```python
# script-python/<integrator>/Common/Notify/code.py

DEFAULT_TTL_SEC = 5         # auto-dismiss for non-error toasts
MAX_VISIBLE     = 5         # FIFO cap; older toasts evict
STACK_TOP_START = 10        # px from top of viewport for first toast
STACK_TOP_STEP  = 110       # px between stacked toasts
TOAST_VIEW_PATH = "<integrator>/Components/Popups/Toast"
MSG_HANDLER     = "<integrator>-toast"

def toast(title, message, level="info", ttl=None):
    """Fire a toast. Safe to call from any view event handler.

    level: 'success' | 'info' | 'warning' | 'error'
           Errors persist until user click; others auto-dismiss.
    ttl:   Override seconds. None = level default (DEFAULT_TTL_SEC for
           non-error, persistent for error)."""
    if level not in ("success", "info", "warning", "error"):
        level = "info"
    effective_ttl = ttl
    if effective_ttl is None and level != "error":
        effective_ttl = DEFAULT_TTL_SEC

    payload = {"title": title, "message": message, "level": level, "ttl": effective_ttl}
    system.perspective.sendMessage(MSG_HANDLER, payload, scope="session")
```

A host view (typically the project's Header or a session-overlay container) subscribes to the message handler and opens individual popups via `system.perspective.openPopup()`, tracking the stack in `session.custom.toastInstances` with FIFO eviction once `MAX_VISIBLE` is reached. The popup itself auto-dismisses by polling `now(500) > dismissAt` (where `dismissAt` is an expression-bound computed value).

**Toast payload contract:**

| Field | Type | Required | Meaning |
|---|---|---|---|
| `title` | string | yes | Toast headline. |
| `message` | string | yes | Body text. |
| `level` | string | yes | One of `success`, `info`, `warning`, `error`. |
| `ttl` | int or None | no | Auto-dismiss seconds. `None` for non-error means default ttl; `None` for error means persistent until user click. |

Behavior: top-right stacking, max 5 visible (FIFO eviction of oldest), level-coded color/icon, errors persist until manual dismiss, non-errors auto-dismiss after `ttl` seconds. Stale-instance defensive sweep every fire (drops entries older than 2 minutes).

**Why popup-per-toast rather than a single banner view:** each toast has independent dismissal timing, position computed at fire time, and can be styled or shaped per-level without coordinating with sibling toasts. The single-banner pattern (one mounted view stacking up to N toasts internally) is simpler to implement but couples toast lifecycles together and makes per-toast positioning awkward. Either pattern is defensible — the popup-per-toast approach in this pack reflects what one production project found cleaner; pick whichever fits your project.

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
<integrator>.Common.Ui.notifyResult(result, successTitle="Saved")
if result.get("Status"):
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
