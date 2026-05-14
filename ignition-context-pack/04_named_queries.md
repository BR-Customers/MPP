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

## sqlType integer codes (java.sql.Types)

Common ones:

| sqlType | Type |
|---|---|
| `-5` | `BIGINT` |
| `-9` | `NVARCHAR` |
| `4` | `INTEGER` |
| `6` | `FLOAT` |
| `7` | `REAL` (or used for `NVARCHAR` / `uniqueidentifier` in older code) |
| `8` | `DOUBLE` (or `DATETIME` in older code) |
| `12` | `VARCHAR` |
| `16` | `BOOLEAN` (or `BIT`) |
| `91` | `DATE` |
| `93` | `TIMESTAMP` |

Full reference: `java.sql.Types`. Older NQs frequently use sqlType `7` for any string-shaped value (varchar, nvarchar, uuid) — fine for SQL Server which is loose about column-vs-parameter typing.

When in doubt, set the parameter in the Designer NQ editor and copy the resulting integer into source.

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

**Default pattern.** Every mutation proc (Add / Update / Deprecate) declares local `@Status`, `@Message`, `@NewId` variables and ends each exit path with a single-row SELECT:

```sql
SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
```

(`@NewId` is included only on Insert procs that allocate identity; Update / Deprecate procs SELECT `@Status` + `@Message` only.)

**Caller consumption** — through `Common.Db.execMutation`:

```python
result = <integrator>.Common.Db.execMutation("items/addItem", params)
# result is a plain dict:
#   {"Status": "OK",    "Message": "Item created",   "NewId": 4172}
#   {"Status": "ERROR", "Message": "Duplicate part", "NewId": None}

if result["Status"] == "OK":
    # success path — NewId is available if the proc returned it
    ...
else:
    # business-rule failure — surface result["Message"] to the UI
    ...
```

This pattern separates expected failure from exceptional failure cleanly:

- **Validation / business-rule failure** → proc sets `@Status='ERROR'`, populates `@Message`, falls through to the final SELECT, returns normally. Caller surfaces `Message` to the UI via `Common.Ui.notifyResult`. Not an exception.
- **System error / programming bug** → proc `RAISERROR` propagates as a `system.db` exception. Caller may wrap in try/except for logging, but typically doesn't need to.

The plain-dict result shape (keys match the proc's SELECT aliases) means adding a new column to the proc — e.g., `@AffectedRows` for batch operations — automatically appears in the caller's result without changing any helper code.

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
