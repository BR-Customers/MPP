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

A predictable surface across every entity module makes views and scripts easier to reason about. The common shape:

```python
import inspect

def log(msg):
    """Function-trace logging via inspect.currentframe().f_back."""
    <integrator>.Common.Util.log(msg)

def getAll(filter=None):
    """List shape: returns rows as list[dict] for tables / dropdowns."""
    log('running')
    results = system.db.execQuery('<group>/getAllEntities')
    headers = list(results.getColumnNames())
    rows = [dict(zip(headers, row)) for row in results]
    log('rows=%d' % len(rows))
    return rows

def getOne(entityId):
    """Single-row lookup. Returns dict, or None if not found."""
    log('entityId=%s' % entityId)
    results = system.db.execQuery('<group>/getEntity', {'EntityId': entityId})
    headers = list(results.getColumnNames())
    rows = [dict(zip(headers, row)) for row in results]
    return rows[0] if rows else None

def add(data):
    """Insert. Accepts dict OR JSON string."""
    log('data=%s' % data)
    if isinstance(data, str):
        data = system.util.jsonDecode(data)
    params = {
        'Name':         data.get('Name'),
        'Description':  data.get('Description'),
        'CreatedAt':    system.date.now(),
        'CreatedById':  data.get('UserId'),
        # ...
    }
    return system.db.execQuery('<group>/addEntity', params)

def update(data):
    """Update existing row. Same data shape as add plus an Id."""
    log('data=%s' % data)
    if isinstance(data, str):
        data = system.util.jsonDecode(data)
    params = {
        'Id':           data.get('Id'),
        'Name':         data.get('Name'),
        'LastEditedAt': system.date.now(),
        'LastEditedById': data.get('UserId'),
    }
    return system.db.execQuery('<group>/updateEntity', params)

def archive(data):
    """Soft delete. Cascades to children before removing the parent."""
    log('data=%s' % data)
    if isinstance(data, str):
        data = system.util.jsonDecode(data)
    entityId = data if not isinstance(data, dict) else data.get('Id')

    # archive children first
    for child in <integrator>.OtherDomain.Child.getByParent(entityId):
        <integrator>.OtherDomain.Child.archive(child.get('Id'))

    return system.db.execQuery('<group>/archiveEntity', {'Id': entityId})

def getEntitiesForDropdown():
    """[{label, value}] shape for ia.input.dropdown."""
    return [{'label': r['Name'], 'value': r['Id']} for r in getAll()]
```

### Conventions worth enforcing across every module

1. **Log start + result of every public function.** `log('data=%s' % data)` first line, `log('resp=%s' % resp)` (or similar) before `return`. Searchable in the gateway log when something goes wrong.
2. **Docstrings carry purpose / args / returns.** Use the same shape across modules so generated docs are uniform.
3. **Accept dict OR JSON string** for `data`. First line of mutation funcs: `if isinstance(data, str): data = system.util.jsonDecode(data)`. Lets event scripts pass a string-formatted JSON dict directly without having to decode at the call site.
4. **Stamp last-edited fields** on every write — `system.date.now()` and the user's id from session context. The view passes the user via `self.session.props.auth.user.userName` or a resolved app-user id from session custom props.
5. **Archive cascades** — archive child rows before the parent so the FK chain stays intact.

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

## Logging idiom

Centralize the logger entry-point in `<integrator>/Common/Util/code.py`:

```python
# In <integrator>/Common/Util/code.py
import inspect

def log(msg):
    """Logs to gateway with auto-detected calling module + function name."""
    frame  = inspect.currentframe().f_back
    module = frame.f_globals.get('__name__', 'unknown')
    func   = frame.f_code.co_name
    system.util.getLogger(module).info("%s() %s" % (func, msg))
```

Then any entity-script function calls `<integrator>.Common.Util.log("running")` directly — no per-module `log()` wrapper needed. Result: every log line is `<full.module.path>: <funcName>() <msg>`, searchable via the gateway's log viewer.

The previous-generation pattern (seen in older Ignition projects) had a `log(msg)` wrapper in every entity module that called into a per-domain `Util.logging(...)`. Modern practice: one shared `Common.Util.log` and direct calls — fewer wrappers, single source of truth.

## Util helpers worth having

```python
from com.inductiveautomation.ignition.common import TypeUtilities
from com.inductiveautomation.ignition.common.model.values import QualifiedValue

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

These two helpers solve a class of "value comes back wrapped and SQL parameter binding fails" problems you'll otherwise hit repeatedly.

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
