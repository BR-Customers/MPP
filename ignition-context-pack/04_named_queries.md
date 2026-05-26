# Named queries

How named queries are structured under `ignition/named-query/`, the conventions for keeping them as thin DB-side dispatch, parameter `sqlType` codes, and consumption patterns.

## Layout

`ignition/named-query/<group>/<name>/{query.sql, resource.json}`. The folder name becomes the call key:

```
named-query/items/getAllItems/         →  system.db.execQuery("items/getAllItems")
named-query/items/addItem/             →  system.db.execQuery("items/addItem", params)
```

A common convention is to align groups with database schemas so locating the SQL behind a script call is obvious — group for table/proc lookups, schema name for the actual SQL.

## query.sql — keep it thin

The named query should be a near-empty wrapper around a stored procedure or single SELECT. Business logic stays in SQL — the named query is dispatch:

**Read:**

```sql
EXEC items.GetAllItems
```

**Mutation with params:**

```sql
-- @itemId       BIGINT
-- @partNumber   NVARCHAR(50)
-- @description  NVARCHAR(500)
-- @userId       BIGINT
EXEC items.UpdateItem
    @itemId      = :itemId,
    @partNumber  = :partNumber,
    @description = :description,
    @userId      = :userId
```

`:paramName` is the Ignition NQ binding placeholder; the `@name` is the SQL Server proc parameter. Names match by convention, not by requirement.

## resource.json — for an UpdateQuery

```json
{
  "scope": "DG",
  "version": 2,
  "files": ["query.sql"],
  "attributes": {
    "type": "UpdateQuery",
    "enabled": true,
    "database": "",
    "useMaxReturnSize": false,
    "maxReturnSize": 100,
    "autoBatchEnabled": false,
    "cacheEnabled": false,
    "cacheAmount": 1,
    "cacheUnit": "SEC",
    "fallbackEnabled": false,
    "fallbackValue": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "...", "timestamp": "..." },
    "parameters": [
      { "type": "Parameter", "identifier": "itemId",      "sqlType": -5 },
      { "type": "Parameter", "identifier": "partNumber",  "sqlType": -9 },
      { "type": "Parameter", "identifier": "description", "sqlType": -9 },
      { "type": "Parameter", "identifier": "userId",      "sqlType": -5 }
    ]
  }
}
```

**Key fields:**

| Field | Meaning |
|---|---|
| `attributes.type` | `"Query"` returns a Dataset (consume with `system.db.execQuery`); `"UpdateQuery"` returns affected-row count (consume with `system.db.execUpdate`). Use `execQuery` even on `UpdateQuery` if your proc still SELECTs an output row. |
| `attributes.database` | Empty string = use the project's default database connection. |
| `attributes.cacheEnabled` + `cacheAmount` + `cacheUnit` | Gateway-side memoization for slow-changing read NQs (e.g., reference / lookup tables). Off by default. |
| `attributes.parameters[]` | Each `{type, identifier, sqlType}`. Read NQs typically have no `parameters[]`. |

## sqlType integer codes — Designer's own enum

**Designer's `sqlType` is its own internal type enum, NOT `java.sql.Types`.** This is non-obvious and trips up anyone copying values from the JDBC reference.

Empirically verified by saving an NQ in Designer 8.3 with one parameter of every available type and reading the resulting `resource.json`:

| sqlType | Designer name | DB type |
|---|---|---|
| `0` | Int1 | `TINYINT` |
| `1` | Int2 | `SMALLINT` |
| `2` | Int4 | `INTEGER` (32-bit) |
| `3` | Int8 | `BIGINT` (64-bit) |
| `4` | Float4 | `REAL` |
| `5` | Float8 | `FLOAT` / `DOUBLE` |
| `6` | Boolean | `BIT` / `BOOLEAN` |
| `7` | String | `NVARCHAR` / `VARCHAR` |
| `8` | DateTime | `DATETIME` |
| `20` | ByteArray | `VARBINARY` |

**For SQL Server with our `BIGINT IDENTITY` PK / FK convention, `sqlType: 3` is the right code for every Id parameter.** For text columns (`NVARCHAR(...)`), `sqlType: 7`.

**Why this trips people up:** `java.sql.Types` defines `2` as `NUMERIC` and `-5` as `BIGINT`. Several existing online examples (including some pack drafts) carry the JDBC `-5 = BIGINT` claim. It is irrelevant — Designer reads / writes its own enum and ignores the JDBC codes entirely. Hand-authoring `-5` or `-9` produces a value Designer does not recognize, which works only because JDBC's runtime type coercion is forgiving; on next Designer save the value is rewritten to whatever Designer's enum says for the param's true type.

**Practical rule:** standardize on Designer's enum. When in doubt, set the parameter in the Designer NQ editor with the type matching the SQL column / SP parameter, save, and copy the resulting integer into any hand-authored sibling files.

### NQ resource.json schema — version 2

Designer 8.3.5 emits `version: 2` on NQ resources and **NPEs when opening a `version: 1` NQ resource**. Any hand-authored NQ resource files must use the v2 shape; field ordering inside `attributes` matters (Designer rewrites to its canonical order on save). Clone the shape from any Designer-saved NQ before hand-authoring a new one.

## Calling pattern from script-python

Entity scripts go through the `<integrator>.Common.Db.*` helpers (see `03_script_python.md`) — they don't call `system.db.execQuery` directly. The helpers own the `dict(zip(headers, row))` idiom so every entity script reads cleanly:

```python
# Reads
def getAll():
    return <integrator>.Common.Db.execList("items/getAllItems")

def getOne(itemId):
    return <integrator>.Common.Db.execOne("items/getItem", {"ItemId": itemId})

# Mutation — returns the proc's status dict {Status, Message, NewId}
def add(data):
    params = {
        "PartNumber":  data.get("PartNumber"),
        "Description": data.get("Description"),
        "AppUserId":   <integrator>.Common.Util._currentAppUserId(),
    }
    return <integrator>.Common.Db.execMutation("items/addItem", params)
```

Why not inline the `dict(zip(...))` here: a project that pulls many lists ends up with that idiom in 50+ places, and it's the only place where cross-cutting concerns (logging the call, auditing the user, wrapping transient retries) can be added. Centralize it once in `Common.Db`.

## Mutation result pattern — single-row status SELECT

**Default pattern.** Every mutation proc (Add / Update / Deprecate / SaveAll) declares local `@Status`, `@Message`, `@NewId` variables and ends each exit path with a single-row SELECT:

```sql
DECLARE @Status  BIT           = 0;                  -- failure default
DECLARE @Message NVARCHAR(500) = N'Unknown error';
DECLARE @NewId   BIGINT        = NULL;               -- Create/Add procs only

-- Validation / business-rule failure path:
SET @Message = N'Duplicate part';
SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
RETURN;

-- Success path:
SET @Status  = 1;
SET @Message = N'Part created';
SET @NewId   = SCOPE_IDENTITY();
SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
```

`@Status` is **`BIT`** — `1` for success, `0` for business-rule failure. `@NewId` is included only on Insert procs that allocate identity; Update / Deprecate procs SELECT `@Status` + `@Message` only.

**Caller consumption** — through `Common.Db.execMutation`:

```python
result = <integrator>.Common.Db.execMutation("items/addItem", params)
# result is a plain dict (BIT comes back as 1/0 — or as bool depending on the
# JDBC driver; the truthy check below works for either):
#   {"Status": 1, "Message": "Item created",   "NewId": 4172}
#   {"Status": 0, "Message": "Duplicate part", "NewId": None}

if result.get("Status"):
    # success path — NewId is available if the proc returned it
    ...
else:
    # business-rule failure — surface result["Message"] to the UI
    ...
```

Use a **truthy check** rather than `== 1` literal equality — JDBC drivers map BIT to Boolean / Integer / Long depending on version, so `result.get("Status")` is robust where `result["Status"] == 1` may not be.

This pattern separates expected failure from exceptional failure cleanly:

- **Validation / business-rule failure** → proc sets `@Status = 0` (the declared default), populates `@Message`, falls through to the final SELECT, returns normally. Caller surfaces `Message` to the UI via `Common.Ui.notifyResult`. Not an exception.
- **System error / programming bug** → proc `RAISERROR` propagates as a `system.db` exception. Caller may wrap in try/except for logging, but typically doesn't need to.

The plain-dict result shape (keys match the proc's SELECT aliases) means adding a new column to the proc — e.g., `@AffectedRows` for batch operations — automatically appears in the caller's result without changing any helper code.

**Project variation:** the pack reflects what this project's stored procs return verbatim — BIT 1/0 with NVARCHAR(500) Message. Other projects using this pack MAY use NVARCHAR `"OK"`/`"ERROR"` for `@Status` if their procs already do; the helper layer (`execMutation`) is shape-agnostic and the truthy/comparison call site adapts. **The stored procs are the rule of law.** Whatever they emit, the helpers and callers match — never the other way around.

### Why not exceptions for all failures

The naive alternative is to `RAISERROR` on every failure (validation, FK violation, anything) and let the script catch. Two problems:

- Every "expected" failure becomes an exception in the script and in the gateway logs, which conflates business outcomes with system errors.
- The proc has no clean way to return a structured message for the UI — the exception text is what the caller gets, and exception text isn't designed for end-user display.

Use exceptions for things the operator can't fix (programming bugs, DB unavailable). Use the status row for things they can (duplicate part number, missing required field, stale RowVersion).

### Why not JDBC OUTPUT params

**Avoid OUTPUT params in Ignition.** The Ignition JDBC driver reads OUTPUT params as the first result set and ignores subsequent SELECTs. A proc that does:

```sql
SELECT ...data rows...
SELECT @NewId AS OutputId  -- this is what you want to read
```

…will hand the caller the *data rows* (or, with OUTPUT params declared, the OUTPUT row) and silently drop everything else. The status-row pattern above sidesteps this entirely by returning exactly one result set per proc.

## Bundled mutations — `SaveAll` for parent + dependent children

The default mutation shape is one proc per action: `Add<Entity>`, `Update<Entity>`, `Deprecate<Entity>`. That works cleanly when an entity stands alone or when its child rows can be edited independently.

For entities whose children are not independently editable — where the parent and its children form a single editing unit, saved together or not at all — use a **`SaveAll` proc** that takes the parent fields plus a JSON array of children, and reconciles them in one transaction.

### When to use

| The case | Pattern |
|---|---|
| Entity has no children, or children are independently CRUD'd elsewhere | Separate `Add<Entity>` / `Update<Entity>` / `Deprecate<Entity>` |
| Children are a tightly coupled part of the parent — created together, edited together on one screen, never edited in isolation | One `Save<Entity>All` proc + a single Save button |

Reach for `SaveAll` only when the children genuinely cannot live without the parent's editing context — definition rows for a type, line items on a document, attribute schemas. Don't use it just to save a script round-trip.

### Shape

`SaveAll` takes:

- **Parent identity:** `@Id BIGINT = NULL` (NULL = create, non-NULL = update). On update, immutable parent keys (e.g., `Code`, `<ParentType>Id`) must match the existing row; the proc rejects mismatches with `Status=0`.
- **Parent fields:** the same fields a separate Update proc would take.
- **`@AppUserId BIGINT`** for audit.
- **`@<Children>Json NVARCHAR(MAX) = N'[]'`** — desired-state JSON array of child rows. Each element has `{Id: long|null, ...child fields}`. Children with no `Id` are new; matching `Id` is an update; active children whose `Id` is missing from the incoming array are deprecated. `SortOrder` is derived from the array index (1-based).

Returns the same status row shape as any mutation proc: `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;` (`@NewId` is the parent's `Id` — newly assigned on create, echoed back on update).

### Reconciliation rules

In update mode, the proc walks the incoming JSON array against currently active children and performs three set operations:

| Set | Action |
|---|---|
| Active child whose `Id` is **not** in incoming | DEPRECATE |
| Incoming row whose `Id` matches an active child | UPDATE |
| Incoming row with `Id = NULL` | INSERT |

All three sets execute inside the same transaction. Any failure rolls back the parent and every child change together. A filtered `UNIQUE` index on the natural child key (e.g., `(<ParentId>, <ChildName>) WHERE DeprecatedAt IS NULL`) is the safety net against racing saves.

### Script-side shape

```python
def handleSaveAll(meta, children, userId=None):
    if userId is None:
        userId = <integrator>.Common.Util._currentAppUserId()
    params = {
        "Id":            meta.get("Id"),
        # ...parent fields...
        "AppUserId":     userId,
        "ChildrenJson":  system.util.jsonEncode(children or []),
    }
    return <integrator>.Common.Db.execMutation("<group>/save<Entity>All", params)
```

Caller routes the result through `Common.Ui.notifyResult` like any other mutation. After a successful save, the caller typically re-runs the relevant `execList` calls to refresh both the parent's display row and the children's table.

### Why not separate procs with view-side transactional bracketing

Ignition does not expose multi-NQ transactional bracketing as a first-class primitive. Splitting `SaveAll` into separate `Add/Update<Parent>` + per-child `Add/Update/Deprecate<Child>` calls means either:

- **No transaction across calls** — partial-failure leaves the parent updated but children in a half-applied state. Operator sees a confusing toast about "row 3 failed" and no obvious recovery path.
- **Optimistic patch logic** in the view (try parent, then each child, roll back the parent on any child failure) — fragile, untestable, easy to get wrong, leaks DB-shape concerns into UI code.

`SaveAll` lives in one proc precisely because the rollback path is already SQL's strong suit. The cost is a slightly larger proc; the win is correctness under partial failure.

## Cache config for read-heavy lookup tables

For NQs that hit slow-changing reference data (defect codes, downtime reasons, location types), enable gateway-side caching:

```json
"cacheEnabled": true,
"cacheAmount": 5,
"cacheUnit": "MIN"
```

Result: the NQ result is held in memory for 5 minutes per parameter combination. Subsequent calls with the same params return the cached dataset without hitting the DB.

Leave caching off until the data is stable enough that staleness isn't a concern.

## Anti-patterns to flag

1. **One proc / NQ does both INSERT and UPDATE.** Common in older code: the same `add<Entity>` is called by both `add()` and `update()` script functions, with a NULL-vs-not-NULL ID determining the branch. Hides intent and complicates the proc. Prefer separate `Add<Entity>` and `Update<Entity>` procs / NQs.
2. **Multiple result sets from one proc.** Ignition JDBC reads the first one and discards the rest. If you find a proc returning two SELECTs, drop one and use a sibling NQ for the second.
3. **Inline SQL in NQ files.** A query.sql with a hand-written multi-line SELECT instead of `EXEC schema.proc`. Acceptable for a one-off ad-hoc report; not for anything in a CRUD path. Migration / version control / testing are all better when the SQL lives in stored procs.
