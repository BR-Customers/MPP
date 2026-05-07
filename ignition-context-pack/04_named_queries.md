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

```python
def getAllItems():
    results = system.db.execQuery("items/getAllItems")
    headers = list(results.getColumnNames())
    return [dict(zip(headers, row)) for row in results]

def addItem(data):
    if isinstance(data, str):
        data = system.util.jsonDecode(data)
    params = {
        'partNumber':   data.get('partNumber'),
        'description':  data.get('description'),
        'userId':       data.get('userId'),
    }
    return system.db.execQuery("items/addItem", params)
```

The `dict(zip(headers, row))` idiom converts an Ignition Dataset → `list[dict]` in two lines. Wrap it in a `Common.Db.execList(nq, params)` helper if your project pulls many lists; otherwise inline is fine.

## Mutation result patterns

Stored procedures that need to communicate success / failure / new-id back to the caller have a few options:

### Option A — exception on failure, no return shape

The proc raises (`RAISERROR` in SQL Server) on any failure. The NQ call throws to script-python and the caller wraps in try/except. Success cases need no return shape.

Simple, but every "expected" failure (validation rejections, FK violations) becomes an exception, which conflates business outcomes with system errors.

### Option B — single-row status SELECT at the end

Every mutation proc declares local `@Status`, `@Message`, `@NewId` variables and ends each exit path with:

```sql
SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
```

(`@NewId` only on Insert procs that allocate identity; Update / Deprecate procs return `Status` + `Message` only.)

Script-side consumption:

```python
def addItem(data):
    params = { ... }
    results = system.db.execQuery("items/addItem", params)
    headers = list(results.getColumnNames())
    rows = [dict(zip(headers, row)) for row in results]
    return rows[0] if rows else {"Status": "ERROR", "Message": "no rows returned"}
```

The caller then checks `result["Status"] == "OK"` and surfaces `result["Message"]` to the UI on error.

This pattern handles expected-failure (validation) and exceptional-failure (SQL error → `RAISERROR`) cleanly:

- Validation / business-rule failure → proc returns a row with `Status='ERROR'`, never raises. Caller surfaces `Message` to the UI.
- System error / programming bug → proc `RAISERROR` propagates as a `system.db` exception. Caller may wrap in try/except for logging.

### Option C — JDBC OUTPUT params

**Avoid in Ignition.** The Ignition JDBC driver reads OUTPUT params as the first result set and ignores subsequent SELECTs. If your proc wants to return both data rows and an output ID, use option B (status SELECT at end) instead. OUTPUT params are silent failure waiting to happen.

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
