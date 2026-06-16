# Terminal-Mode View-Policy Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the derived `TerminalMode` (parent-tier rule) per spec `docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md` — terminal behavior becomes a property of the assigned view (`DefaultScreen`); simplify the resolver procs, add the context-cells picker proc + `HasPrinter` flag, update the Ignition session layer, and amend the FDS to v1.4.

**Architecture:** SQL-first: two repeatable-proc revisions + one new proc + tests, then the thin Ignition layer (NQ, entity script, session bootstrap, HomeRouter, CellContextSelector), then FDS/doc updates. No schema migration, no seed change.

**Tech Stack:** SQL Server 2022 (`MPP_MES_Dev` on `localhost`, sqlcmd flags `-b -I -C`), Ignition 8.3 file-based projects (Core + MPP via junctions, register with `.\scan.ps1` from repo root), test framework `test.Assert_*` via `sql\tests\Run-Tests.ps1`.

---

## Execution prerequisites (read first)

1. **Uncommitted user edits exist** in `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/{props.json,resource.json}` and `.../views/BlueRidge/Views/ShopFloor/TerminalSelector/{view.json,resource.json}` (Jacques's in-flight Designer work). Tasks 5 and 6 touch these files: **Read the current on-disk content immediately before editing, make minimal Edits, never Write-replace these files wholesale.** Do not stage/commit Jacques's unrelated hunks — stage whole files only after confirming the diff contains only this plan's changes plus his already-present edits, and call that out in the commit message if mixed (or ask him to commit his edits first).
2. **All Ignition view files in this plan are file-authored and have never been Designer-saved** — they contain plain `=`/`==` (no `=` escapes). Plain-text Edit needles work. Close the affected views in Designer before file-editing; after every Ignition file change run `.\scan.ps1` from the repo root.
3. SQL deploy loop for a repeatable proc: `sqlcmd.exe -S localhost -d MPP_MES_Dev -i <file> -b -I -C`. Test loop: from `sql\tests\`, `.\Run-Tests.ps1 -Filter "<file fragment>"` (note: the runner resets the dev DB when run without filter; filtered runs execute matching files only).
4. Per `feedback_runtests_exit1_zero_failures`: Run-Tests exits 1 if any file's sqlcmd errors even with 0 assertion failures — read the red output, don't re-run blindly.

---

### Task 1: `Terminal_GetByIpAddress` v1.1 — drop derived TerminalMode

**Files:**
- Modify: `sql/migrations/repeatable/R__Location_Terminal_GetByIpAddress.sql`
- Modify: `sql/tests/0020_PlantFloor_Foundation/010_Terminal_GetByIpAddress.sql`

- [ ] **Step 1: Update the test file first (it defines the new contract)**

Apply these edits to `010_Terminal_GetByIpAddress.sql`:

1. Header description block: replace the two mode bullets:
   - `*  Known IP (Cell-parented Terminal) -> correct Terminal +` / `Zone + DefaultScreen + TerminalMode='Dedicated'.` becomes `*  Known IP (Cell-parented Terminal) -> correct Terminal + Zone + DefaultScreen.`
   - `*  Known IP (Area-parented Terminal) -> TerminalMode='Shared'` / `and (this fixture has no DefaultScreen) NULL DefaultScreen.` becomes `*  Known IP (Area-parented Terminal) -> resolves; NULL DefaultScreen when unset.`
2. ALL FOUR temp tables (`#C`, `#A`, `#U`, `#D`) — remove the `TerminalMode NVARCHAR(20),` column from the CREATE TABLE shape. New shape for each:

```sql
CREATE TABLE #C (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                 ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                 DefaultScreen NVARCHAR(255), IsFallback BIT);
```

3. Test 1: remove `@Mode NVARCHAR(20),` from the DECLARE, remove `@Mode = TerminalMode,` from the SELECT, and DELETE this whole assertion:

```sql
EXEC test.Assert_IsEqual
    @TestName = N'[TermCell] TerminalMode derived Dedicated (Cell parent)',
    @Expected = N'Dedicated', @Actual = @Mode;
```

4. Test 2: remove `@Mode NVARCHAR(20),` from the DECLARE, remove `@Mode = TerminalMode,` from the SELECT, and DELETE this whole assertion:

```sql
EXEC test.Assert_IsEqual
    @TestName = N'[TermArea] TerminalMode derived Shared (Area parent)',
    @Expected = N'Shared', @Actual = @Mode;
```

(Tests 3 and 4 declare no `@Mode` — only their temp-table shapes change.)

- [ ] **Step 2: Run the file to verify it FAILS against the deployed v1.0 proc**

Run from `sql\tests\`: `.\Run-Tests.ps1 -Filter "010_Terminal_GetByIpAddress"`
Expected: FAIL — `Msg 213` (column-count mismatch on INSERT-EXEC: proc still emits 9 columns into an 8-column temp table). This proves the test now pins the new contract.

- [ ] **Step 3: Revise the proc**

In `R__Location_Terminal_GetByIpAddress.sql`:

1. Header: `Version: 1.1`; in Description replace the sentence block `and a DERIVED TerminalMode: ... (and for any other / NULL parent tier).` with:

```
--   attribute value (NULL when unset). TerminalMode was REMOVED in v1.1:
--   terminal behavior (dedicated vs shared) is a property of the assigned
--   view per FDS-02-010 (view-policy model) and the spec
--   docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md.
```

2. Result-set comment: `DefaultScreen, TerminalMode, IsFallback` → `DefaultScreen, IsFallback`.
3. Change Log: add `--   2026-06-10 - 1.1 - Drop derived TerminalMode (view-policy model).`
4. In the §2b empty-shape SELECT, delete the line `CAST(NULL AS NVARCHAR(20))  AS TerminalMode,`.
5. In the §3 final SELECT, delete the two lines:

```sql
        CAST(CASE WHEN plt.Code = N'Cell' THEN N'Dedicated'
                  ELSE N'Shared' END AS NVARCHAR(20))       AS TerminalMode,
```

6. Delete the now-unused tier joins (the `p` join stays — Zone columns still need it):

```sql
    LEFT JOIN Location.LocationTypeDefinition pltd
        ON pltd.Id = p.LocationTypeDefinitionId
    LEFT JOIN Location.LocationType plt
        ON plt.Id = pltd.LocationTypeId
```

7. Update the §3 comment line `-- 3. Project the Terminal + parent ("Zone") + DefaultScreen + derived mode.` → `-- 3. Project the Terminal + parent ("Zone") + DefaultScreen.`

- [ ] **Step 4: Deploy the proc and re-run the test file**

```powershell
sqlcmd.exe -S localhost -d MPP_MES_Dev -i "sql\migrations\repeatable\R__Location_Terminal_GetByIpAddress.sql" -b -I -C
cd sql\tests; .\Run-Tests.ps1 -Filter "010_Terminal_GetByIpAddress"
```
Expected: PASS, 11 assertions (was 13; two mode assertions removed).

- [ ] **Step 5: Commit**

```powershell
git add "sql/migrations/repeatable/R__Location_Terminal_GetByIpAddress.sql" "sql/tests/0020_PlantFloor_Foundation/010_Terminal_GetByIpAddress.sql"
git commit -m "feat(sql): Terminal_GetByIpAddress v1.1 - drop derived TerminalMode (view-policy model)"
```

---

### Task 2: `Terminal_List` v1.1 — drop TerminalMode, add `HasPrinter`

**Files:**
- Modify: `sql/migrations/repeatable/R__Location_Terminal_List.sql`

(Automated assertions for this proc land in Task 3's new test file; this task verifies via ad-hoc query.)

- [ ] **Step 1: Revise the proc**

In `R__Location_Terminal_List.sql`:

1. Header: `Version: 1.1`; Description — replace `and the same DERIVED TerminalMode as Terminal_GetByIpAddress ('Dedicated' for a Cell-tier parent, 'Shared' otherwise). Backs the terminal-registry admin surface.` with:

```
--   and a HasPrinter validation flag (1 when the Terminal has at least one
--   active child Printer Location - every Terminal must carry >= 1 printer).
--   TerminalMode was REMOVED in v1.1 (view-policy model; FDS-02-010 v1.4).
--   Backs the terminal-registry admin surface.
```

2. Result-set comment: `IpAddress, DefaultScreen, TerminalMode, IsFallback` → `IpAddress, DefaultScreen, IsFallback, HasPrinter`.
3. Change Log: add `--   2026-06-10 - 1.1 - Drop derived TerminalMode; add HasPrinter flag.`
4. In the SELECT, replace:

```sql
        CAST(CASE WHEN plt.Code = N'Cell' THEN N'Dedicated'
                  ELSE N'Shared' END AS NVARCHAR(20))       AS TerminalMode,
        CAST(CASE WHEN t.Code = N'FALLBACK-TERMINAL' THEN 1
                  ELSE 0 END AS BIT)                        AS IsFallback
```

with:

```sql
        CAST(CASE WHEN t.Code = N'FALLBACK-TERMINAL' THEN 1
                  ELSE 0 END AS BIT)                        AS IsFallback,
        CAST(CASE WHEN EXISTS (
            SELECT 1
            FROM Location.Location pr
            INNER JOIN Location.LocationTypeDefinition prd
                ON prd.Id = pr.LocationTypeDefinitionId
               AND prd.Code = N'Printer'
            WHERE pr.ParentLocationId = t.Id
              AND pr.DeprecatedAt IS NULL
        ) THEN 1 ELSE 0 END AS BIT)                         AS HasPrinter
```

5. Delete the now-unused tier joins (the `p` join stays):

```sql
    LEFT JOIN Location.LocationTypeDefinition pltd
        ON pltd.Id = p.LocationTypeDefinitionId
    LEFT JOIN Location.LocationType plt
        ON plt.Id = pltd.LocationTypeId
```

- [ ] **Step 2: Deploy and spot-check**

```powershell
sqlcmd.exe -S localhost -d MPP_MES_Dev -i "sql\migrations\repeatable\R__Location_Terminal_List.sql" -b -I -C
sqlcmd.exe -S localhost -d MPP_MES_Dev -Q "SET NOCOUNT ON; CREATE TABLE #T (TerminalId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200), ZoneId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200), IpAddress NVARCHAR(45), DefaultScreen NVARCHAR(255), IsFallback BIT, HasPrinter BIT); INSERT INTO #T EXEC Location.Terminal_List; SELECT COUNT(*) AS Terminals, SUM(CAST(HasPrinter AS INT)) AS WithPrinter FROM #T;" -b -I -C
```
Expected: no Msg 213 (shape matches), `Terminals` = 63, `WithPrinter` > 0 (seed parents printers under terminals).

- [ ] **Step 3: Commit**

```powershell
git add "sql/migrations/repeatable/R__Location_Terminal_List.sql"
git commit -m "feat(sql): Terminal_List v1.1 - drop TerminalMode, add HasPrinter validation flag"
```

---

### Task 3: NEW `Terminal_ListContextCells` proc + test file 015

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Terminal_ListContextCells.sql`
- Create: `sql/tests/0020_PlantFloor_Foundation/015_Terminal_ContextCells_List.sql`

- [ ] **Step 1: Write the test file (full content)**

```sql
-- =============================================
-- File:         0020_PlantFloor_Foundation/015_Terminal_ContextCells_List.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-10
-- Description:  Tests for Location.Terminal_ListContextCells (view-policy
--               model spec 2026-06-10) + Terminal_List v1.1 shape/HasPrinter.
--               Asserts:
--                 * Area-parented terminal -> exactly the active equipment
--                   cells under the parent (Terminal/Printer kinds and
--                   deprecated cells excluded).
--                 * Line-parented terminal whose parent has only
--                   terminals/printers beneath -> empty set.
--                 * Unknown / deprecated terminal id -> empty set.
--                 * Terminal_List: HasPrinter=1 with an active child Printer,
--                   0 without; result-set shape pins (no TerminalMode).
--
--               Self-contained fixture subtree under the Site (MPP-MAD):
--                 TEST-CTX-AREA (Area, DefId 3)
--                   +- TEST-CTX-M1 (DieCastMachine, DefId 8)
--                   +- TEST-CTX-M2 (DieCastMachine, DefId 8)
--                   +- TEST-CTX-MDEP (DieCastMachine, DefId 8, deprecated)
--                   +- TEST-CTX-TERM (Terminal, DefId 7)
--                        +- TEST-CTX-PRN (Printer, DefId 16)
--                   +- TEST-CTX-TERM2 (Terminal, DefId 7, NO printer)
--                 TEST-CTX-LINE (Line, DefId 5)
--                   +- TEST-CTX-LTERM (Terminal, DefId 7)
--                        +- TEST-CTX-LPRN (Printer, DefId 16)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/015_Terminal_ContextCells_List.sql';
GO

-- ---- teardown any prior fixtures (children before parents) ----
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-PRN', N'TEST-CTX-LPRN');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-M1', N'TEST-CTX-M2', N'TEST-CTX-MDEP', N'TEST-CTX-TERM', N'TEST-CTX-TERM2', N'TEST-CTX-LTERM');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-AREA', N'TEST-CTX-LINE');
GO

-- ---- build the fixture subtree ----
DECLARE @SiteId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (3, @SiteId, N'Test Ctx Area', N'TEST-CTX-AREA', N'ContextCells test area', 950),
       (5, @SiteId, N'Test Ctx Line', N'TEST-CTX-LINE', N'ContextCells test line', 951);

DECLARE @AreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-AREA');
DECLARE @LineId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-LINE');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (8, @AreaId, N'Ctx Machine 1', N'TEST-CTX-M1',    N'Equipment cell', 1),
       (8, @AreaId, N'Ctx Machine 2', N'TEST-CTX-M2',    N'Equipment cell', 2),
       (7, @AreaId, N'Ctx Terminal',  N'TEST-CTX-TERM',  N'Area terminal', 3),
       (7, @AreaId, N'Ctx Terminal 2',N'TEST-CTX-TERM2', N'Area terminal no printer', 4),
       (7, @LineId, N'Ctx Line Term', N'TEST-CTX-LTERM', N'Line terminal', 1);

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, DeprecatedAt)
VALUES (8, @AreaId, N'Ctx Machine Depr', N'TEST-CTX-MDEP', N'Deprecated equipment cell', 5, SYSUTCDATETIME());

DECLARE @TermId  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-TERM');
DECLARE @LTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-LTERM');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @TermId,  N'Ctx Printer',      N'TEST-CTX-PRN',  N'Printer under terminal', 1),
       (16, @LTermId, N'Ctx Line Printer', N'TEST-CTX-LPRN', N'Printer under line terminal', 1);
GO

-- =============================================
-- Test 1: Area terminal -> exactly the two active equipment cells
-- =============================================
DECLARE @TermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-TERM');
DECLARE @Rows INT, @Codes NVARCHAR(200);
CREATE TABLE #CC (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(100));
INSERT INTO #CC EXEC Location.Terminal_ListContextCells @TerminalId = @TermId;
SELECT @Rows = COUNT(*) FROM #CC;
SELECT @Codes = STRING_AGG(Code, N',') WITHIN GROUP (ORDER BY Code) FROM #CC;
DROP TABLE #CC;
EXEC test.Assert_RowCount
    @TestName = N'[CtxCells] Area terminal sees exactly the 2 active equipment cells',
    @ExpectedCount = 2, @ActualCount = @Rows;
EXEC test.Assert_IsEqual
    @TestName = N'[CtxCells] Cells are M1+M2 (terminal/printer/deprecated excluded)',
    @Expected = N'TEST-CTX-M1,TEST-CTX-M2', @Actual = @Codes;
GO

-- =============================================
-- Test 2: Line terminal (parent has only terminals/printers) -> empty
-- =============================================
DECLARE @LTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-LTERM');
DECLARE @Rows INT;
CREATE TABLE #CL (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(100));
INSERT INTO #CL EXEC Location.Terminal_ListContextCells @TerminalId = @LTermId;
SELECT @Rows = COUNT(*) FROM #CL;
DROP TABLE #CL;
EXEC test.Assert_RowCount
    @TestName = N'[CtxCells] Line terminal with no equipment cells -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- =============================================
-- Test 3: Unknown terminal id -> empty set (never errors)
-- =============================================
DECLARE @Rows INT;
CREATE TABLE #CU (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(100));
INSERT INTO #CU EXEC Location.Terminal_ListContextCells @TerminalId = -1;
SELECT @Rows = COUNT(*) FROM #CU;
DROP TABLE #CU;
EXEC test.Assert_RowCount
    @TestName = N'[CtxCells] Unknown terminal id -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- =============================================
-- Test 4: Terminal_List v1.1 shape + HasPrinter flags
-- =============================================
DECLARE @HasPrn BIT, @NoPrn BIT, @HasStr NVARCHAR(1), @NoStr NVARCHAR(1);
CREATE TABLE #TL (TerminalId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  IpAddress NVARCHAR(45), DefaultScreen NVARCHAR(255), IsFallback BIT, HasPrinter BIT);
INSERT INTO #TL EXEC Location.Terminal_List;
SELECT @HasPrn = HasPrinter FROM #TL WHERE TerminalCode = N'TEST-CTX-TERM';
SELECT @NoPrn  = HasPrinter FROM #TL WHERE TerminalCode = N'TEST-CTX-TERM2';
DROP TABLE #TL;
SET @HasStr = CAST(@HasPrn AS NVARCHAR(1));
SET @NoStr  = CAST(@NoPrn  AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[TermList] HasPrinter=1 with an active child Printer',
    @Expected = N'1', @Actual = @HasStr;
EXEC test.Assert_IsEqual
    @TestName = N'[TermList] HasPrinter=0 without a child Printer',
    @Expected = N'0', @Actual = @NoStr;
GO

-- ---- cleanup (children before parents) ----
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-PRN', N'TEST-CTX-LPRN');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-M1', N'TEST-CTX-M2', N'TEST-CTX-MDEP', N'TEST-CTX-TERM', N'TEST-CTX-TERM2', N'TEST-CTX-LTERM');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-AREA', N'TEST-CTX-LINE');
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it to verify it fails (proc doesn't exist yet)**

Run from `sql\tests\`: `.\Run-Tests.ps1 -Filter "015_Terminal_ContextCells"`
Expected: FAIL — `Could not find stored procedure 'Location.Terminal_ListContextCells'`.

- [ ] **Step 3: Write the proc (full file content)**

`sql/migrations/repeatable/R__Location_Terminal_ListContextCells.sql`:

```sql
-- =============================================
-- Procedure:   Location.Terminal_ListContextCells
-- Author:      Blue Ridge Automation
-- Created:     2026-06-10
-- Version:     1.0
--
-- Description:
--   The eligible location-context options for a shared-flavor operator view
--   at the given Terminal (view-policy model; FDS-02-009 v1.4 + spec
--   docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md):
--   the ACTIVE descendant EQUIPMENT cells of the Terminal's parent Location -
--   Cell-tier Locations excluding the Terminal and Printer infrastructure
--   kinds (terminals/printers are themselves Cell-tier but are never a
--   production context). Recursive: equipment cells any depth below the
--   parent qualify.
--
--   Empty result set when: the Terminal id is unknown / deprecated / has no
--   parent, or the parent has no active equipment cells beneath it (e.g., a
--   machining line tracked at line resolution - dedicated-flavor views bind
--   the parent itself and never call this proc). Never raises.
--
--   No OUTPUT params (Ignition JDBC). One result set.
--
-- Parameters:
--   @TerminalId BIGINT - Location.Id of the Terminal (DefId resolves kind
--                        Terminal; not validated - unknown id -> empty set).
--
-- Result set (zero or more rows, ordered by Code):
--   LocationId, Code, Name, Kind
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition,
--           Location.LocationType
--
-- Change Log:
--   2026-06-10 - 1.0 - Initial version (view-policy model).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_ListContextCells
    @TerminalId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ParentId BIGINT = (
        SELECT ParentLocationId
        FROM Location.Location
        WHERE Id = @TerminalId
          AND DeprecatedAt IS NULL
    );

    IF @ParentId IS NULL
    BEGIN
        SELECT
            CAST(NULL AS BIGINT)        AS LocationId,
            CAST(NULL AS NVARCHAR(50))  AS Code,
            CAST(NULL AS NVARCHAR(200)) AS Name,
            CAST(NULL AS NVARCHAR(100)) AS Kind
        WHERE 1 = 0;
        RETURN;
    END

    ;WITH Descendants AS (
        SELECT l.Id, l.Code, l.Name, l.LocationTypeDefinitionId
        FROM Location.Location l
        WHERE l.ParentLocationId = @ParentId
          AND l.DeprecatedAt IS NULL
        UNION ALL
        SELECT c.Id, c.Code, c.Name, c.LocationTypeDefinitionId
        FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        WHERE c.DeprecatedAt IS NULL
    )
    SELECT
        d.Id        AS LocationId,
        d.Code      AS Code,
        d.Name      AS Name,
        ltd.Name    AS Kind
    FROM Descendants d
    INNER JOIN Location.LocationTypeDefinition ltd
        ON ltd.Id = d.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt
        ON lt.Id = ltd.LocationTypeId
    WHERE lt.Code = N'Cell'
      AND ltd.Code NOT IN (N'Terminal', N'Printer')
    ORDER BY d.Code
    OPTION (MAXRECURSION 32);
END;
GO
```

- [ ] **Step 4: Deploy and run the test file**

```powershell
sqlcmd.exe -S localhost -d MPP_MES_Dev -i "sql\migrations\repeatable\R__Location_Terminal_ListContextCells.sql" -b -I -C
cd sql\tests; .\Run-Tests.ps1 -Filter "015_Terminal_ContextCells"
```
Expected: PASS, 6 assertions.

- [ ] **Step 5: Run the full 0020 suite to catch collateral damage**

`.\Run-Tests.ps1 -Filter "0020_PlantFloor"`
Expected: all PASS.

- [ ] **Step 6: Commit**

```powershell
git add "sql/migrations/repeatable/R__Location_Terminal_ListContextCells.sql" "sql/tests/0020_PlantFloor_Foundation/015_Terminal_ContextCells_List.sql"
git commit -m "feat(sql): Terminal_ListContextCells - shared-view context picker (equipment cells only)"
```

---

### Task 4: NQ + `BlueRidge.Location.Terminal` entity additions (Core)

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/location/Terminal_ListContextCells/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/Terminal_ListContextCells/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py`

- [ ] **Step 1: Write the NQ**

`query.sql`:

```sql
EXEC Location.Terminal_ListContextCells
    @TerminalId = :terminalId
```

`resource.json` (clone of the sibling `Terminal_GetByIpAddress` shape; only the parameter differs):

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
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
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-06-10T12:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "terminalId",
        "sqlType": 3
      }
    ]
  }
}
```

- [ ] **Step 2: Add the entity functions**

Append to `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py` (after `findByCode`):

```python
def listContextCells(terminalLocationId):
    """Eligible location-context rows for a shared-flavor view at the given
       terminal: active descendant EQUIPMENT cells of the terminal's parent
       (Terminal/Printer kinds excluded by the proc). Returns list[dict]
       (LocationId, Code, Name, Kind); always a list, empty when the
       terminal is unknown or its parent has no equipment cells."""
    BlueRidge.Common.Util.log("terminalLocationId=%s" % terminalLocationId)
    if terminalLocationId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "location/Terminal_ListContextCells",
        {"terminalId": terminalLocationId},
    )


def getContextCellsForDropdown(terminalLocationId):
    """listContextCells shaped for ia.input.dropdown + scan matching:
       [{label: '<Code> - <Name>', value: LocationId, code, name}].
       Always returns a list (never None) so the runScript-bound
       view.custom.cells default ([]) is never overwritten with null."""
    rows = listContextCells(terminalLocationId) or []
    out = []
    for r in rows:
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        out.append({
            "label": ("%s - %s" % (code, name)).strip(" -"),
            "value": r.get("LocationId"),
            "code":  code,
            "name":  name,
        })
    return out
```

- [ ] **Step 3: Scan and verify in Designer Script Console (Designer opened on MPP)**

Run `.\scan.ps1` from repo root, then in Script Console:

```python
print BlueRidge.Location.Terminal.getContextCellsForDropdown(15L)   # DC1-T1 -> 11 die-cast machines
print BlueRidge.Location.Terminal.getContextCellsForDropdown(76L)   # MA1-5GOF-MIN (line terminal) -> []
```
Expected: first prints 11 option dicts (DC1-M01..M11, no terminals/printers); second prints `[]`.

- [ ] **Step 4: Commit**

```powershell
git add "ignition/projects/Core/ignition/named-query/location/Terminal_ListContextCells" "ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py"
git commit -m "feat(ignition): Terminal_ListContextCells NQ + Terminal.listContextCells/getContextCellsForDropdown"
```

---

### Task 5: Session layer — onStartup, session-props, HomeRouter

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/startup/onStartup.py`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json` *(HAS UNCOMMITTED USER EDITS — Read fresh, minimal Edits only)*
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/HomeRouter/view.json`

- [ ] **Step 1: onStartup — drop `terminalMode` from the session terminal shape**

In `onStartup.py`, delete these two lines (one in the defensive-None block, one in the main block):

```python
			"terminalMode":       "",
```
```python
		"terminalMode":       term.get("TerminalMode"),
```

- [ ] **Step 2: session-props — drop `terminalMode`, add `presence`**

Read the CURRENT `props.json` first (user edits in flight). Then two minimal Edits inside the `"custom"` block:

1. Delete the line `"terminalMode": "",` inside `"terminal": { ... }`.
2. Add a `presence` sibling key (alphabetical placement after `"cell"`):

```json
    "presence": {
      "policy": "strict"
    },
```

(`strict` is the safe pre-view default per the spec; dedicated-flavor views set `confirm` on load in later phases.)

- [ ] **Step 3: HomeRouter — remove the mode gate from `route()`**

In `HomeRouter/view.json`, the `route` customMethod script is currently:

```
\tt = self.session.custom.terminal\n\tif (not t.terminalLocationId) or t.isFallback:\n\t\tsystem.perspective.navigate(\"/shop-floor/terminal-selector\")\n\t\treturn\n\tif t.terminalMode == \"Dedicated\" and self.session.custom.user.appUserId is None:\n\t\tsystem.perspective.navigate(\"/shop-floor/initials\")\n\t\treturn\n\tif t.defaultScreen:\n\t\tsystem.perspective.navigate(t.defaultScreen)\n\t\treturn
```

Replace with (the Dedicated-initials gate is removed — the view flavor + presence policy own it per the spec):

```
\tt = self.session.custom.terminal\n\tif (not t.terminalLocationId) or t.isFallback:\n\t\tsystem.perspective.navigate(\"/shop-floor/terminal-selector\")\n\t\treturn\n\tif t.defaultScreen:\n\t\tsystem.perspective.navigate(t.defaultScreen)\n\t\treturn
```

- [ ] **Step 4: Scan + smoke**

`.\scan.ps1`, then launch `http://localhost:8088/data/perspective/client/MPP`:
Expected: session starts with no errors in wrapper.log; unknown-IP fallback still routes to the Terminal Selector; `session.custom.terminal` no longer has a `terminalMode` key; `session.custom.presence.policy` = `strict`.

- [ ] **Step 5: Commit (verify the staged diff contains only this plan's hunks + Jacques's known in-flight session-props edits; coordinate if mixed)**

```powershell
git add "ignition/projects/MPP/com.inductiveautomation.perspective/startup/onStartup.py" "ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/HomeRouter/view.json"
git commit -m "feat(mpp): retire terminalMode from session shape + HomeRouter; add presence.policy"
```

---

### Task 6: CellContextSelector re-point + TerminalSelector mode-column check

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/CellContextSelector/view.json`
- Inspect/Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TerminalSelector/view.json` *(HAS UNCOMMITTED USER EDITS)*

- [ ] **Step 1: Re-point the cells binding**

In `CellContextSelector/view.json`, `propConfig.custom.cells.binding.config.expression` is currently:

```
runScript(\"BlueRidge.Location.Location.getCellsForDropdown\", 0)
```

Replace with:

```
runScript(\"BlueRidge.Location.Terminal.getContextCellsForDropdown\", 0, {session.custom.terminal.terminalLocationId})
```

(`findCellById` / `findCellByCode` calls in the customMethods stay — they are generic list resolvers and the option shape is unchanged.)

- [ ] **Step 2: Deprecate the now-unconsumed generic dropdown helper**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py`, `getCellsForDropdown()` loses its only consumer. Do NOT delete it (other callers may appear); update its docstring first line to:

```python
    """Cell-tier Locations shaped for ia.input.dropdown + scan matching.

       SUPERSEDED for the Cell Context Selector by
       BlueRidge.Location.Terminal.getContextCellsForDropdown (view-policy
       model, 2026-06-10) which scopes to the terminal parent's descendant
       equipment cells. This generic all-Cells variant remains for ad-hoc
       dropdowns but note it includes Terminal/Printer kind cells.
```

(Keep the rest of the docstring and the implementation as-is.)

- [ ] **Step 3: TerminalSelector — remove the TerminalMode column if present**

Read the CURRENT `TerminalSelector/view.json` (user edits in flight). Search for `TerminalMode` / `terminalMode`. If the table's `props.columns` contains a column with `"field": "TerminalMode"`, delete that whole column object (it must be the FULL ~25-key schema object per project convention — remove the entire object, not just the field key). If the user's in-flight edits make file-editing risky, flag to Jacques to remove the column in Designer instead. Also check any row-click handler reads of `TerminalMode` (none expected — selection persists terminal identity fields only).

- [ ] **Step 4: Scan + smoke**

`.\scan.ps1`, then in the running session: Terminal Selector renders without a Component Error; selecting `DC1-T1` then opening any surface embedding CellContextSelector shows exactly the 11 DC1 die-cast machines in the dropdown (no terminals, no printers).

- [ ] **Step 5: Commit**

```powershell
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/CellContextSelector/view.json" "ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TerminalSelector/view.json"
git commit -m "feat(mpp): CellContextSelector scoped to terminal-parent equipment cells; drop mode column"
```

---

### Task 7: FDS v1.4 amendments

**Files:**
- Modify: `MPP_MES_FDS.md`

The FDS contains UTF-8 em-dashes — use the Read tool to capture exact needles before each Edit (PowerShell `Get-Content` displays them as mojibake; the Edit tool sees true bytes). Section anchors below locate each edit; replacement text is normative.

- [ ] **Step 1: §2.5 narrative (under heading `### 2.5 Terminals`)**

Replace the first paragraph (begins `Terminals are a mix of **dedicated** and **shared**.`) with:

> Terminals are a mix of **dedicated** and **shared** — determined by the operator view each terminal is assigned via its `DefaultScreen` attribute, not by its position in the hierarchy (FDS-02-010). `Terminal` is a `LocationTypeDefinition` under the `Cell` type, and a Terminal `Location` MAY be parented at any tier — Cell, WorkCenter, or Area. Dedicated-flavor views carry a fixed location context: the Terminal's parent Location, at whatever tier it sits (a press Cell, a machining/assembly Line tracked at line resolution, or an Area such as a Trim Shop tracked at area resolution). Shared-flavor views open with a select-location step that lets the operator pick the context — by **scan or dropdown** — constrained to descendant *equipment* Cells of the parent Location (excluding the `Terminal` / `Printer` infrastructure kinds). Part ↔ Cell eligibility is enforced via `Parts.ItemLocation` plus BOM-derived component eligibility (§3.5 + FDS-02-012). Honda plans to place RFID tags on container labels in the future; the MES SHALL stay RFID-agnostic (FUTURE).

- [ ] **Step 2: FDS-02-008 (heading `#### FDS-02-008 — Terminal as Cell Kind`)**

Replace the final sentence `Terminal mode (Dedicated vs Shared) is derived from the parent tier per FDS-02-010 — not stored as an attribute.` with:

> Terminal behavior (dedicated vs shared) follows the operator view assigned via the Terminal's `DefaultScreen` attribute per FDS-02-010 — it is neither derived from the parent tier nor stored as a mode attribute. Every Terminal SHALL carry at least one active child `Printer` Location (multiple supported); the terminal registry surfaces a `HasPrinter` validation flag.

- [ ] **Step 3: FDS-02-009 (heading `#### FDS-02-009 — Cell Context Selection`)**

Keep the two-reference bullet list (TerminalLocationId + LocationId) but replace the sentence in the `LocationId` bullet `(a Cell — DieCastMachine, CNCMachine, TrimPress, AssemblyStation, InspectionStation, etc.)` with `(an equipment Cell — DieCastMachine, CNCMachine, TrimPress, AssemblyStation, InspectionStation, etc. — or, for terminals running a dedicated-flavor view whose parent is a Line or Area, that parent Location itself)`.

Replace the paragraph `On **Dedicated** terminals (FDS-02-010) the Cell context SHALL be the Terminal Location's parent Cell — fixed, with no selector exposed in the UI.` with:

> On terminals running a **dedicated-flavor** view (FDS-02-010) the location context SHALL be the Terminal Location's parent — fixed, with no selector exposed in the UI. The parent MAY be any tier: a Cell (e.g., a die-cast machine), a WorkCenter/Line (machining + assembly lines tracked at line resolution per MPP's traceability requirement), or an Area (e.g., a Trim Shop tracked at area resolution).

Replace the lead-in `On **Shared** terminals the Cell context SHALL be selected by the operator at session start using either of two equivalent mechanisms:` with:

> On terminals running a **shared-flavor** view the location context SHALL be selected by the operator at session start using either of two equivalent mechanisms:

In the numbered Dropdown mechanism, replace `(the descendant Cells of the terminal's parent Location)` with `(the descendant **equipment** Cells of the terminal's parent Location — Cell-tier Locations excluding the `Terminal` and `Printer` infrastructure kinds; proc `Location.Terminal_ListContextCells`)`.

- [ ] **Step 4: FDS-02-010 — full rewrite**

Replace the ENTIRE section from `#### FDS-02-010 — Terminal Mode Determined by Location Assignment — \`MVP\`` down to (excluding) `#### FDS-02-011` with:

> #### FDS-02-010 — Terminal Behavior Determined by Assigned View — `MVP`
>
> A Terminal's dedicated-vs-shared behavior is a property of the **operator view it is assigned** via its `DefaultScreen` attribute. There is no `TerminalMode` — neither derived from the hierarchy nor stored as an attribute. Operator views are authored in one of two flavors:
>
> | | **Shared-flavor view** | **Dedicated-flavor view** |
> |---|---|---|
> | Opening step | Select-location menu (or persistent location dropdown) | None |
> | Location context | Operator-selected from the terminal-parent's descendant equipment Cells (FDS-02-009) | Bound automatically to the Terminal's parent Location (any tier) |
> | Context change | Re-select via the same selector | Not changeable in the UI |
> | Presence policy | `strict` — idle ⇒ initials re-entry; context change ⇒ re-prompt (FDS-04-003) | `confirm` — idle ⇒ "Operate as [XY]? [Yes]" continue (FDS-04-006); initials persist through the shift |
>
> The view sets `session.custom.presence.policy` on load; a single always-present idle watcher branches on it (FDS-04-006 applies to BOTH flavors). **Examples:** the Die Cast cabin terminals (`DC1-T1`..`DC4-T1`) run a shared-flavor view and the operator picks the press; the machining/assembly line terminals (`MA1-*`, `MA2-*`) and Trim Shop terminals run dedicated-flavor views whose context is the line / trim shop itself.
>
> The Gateway terminal resolver returns the terminal identity, parent ("zone"), and `DefaultScreen`; it carries no mode. Configuration Tool Location admin screens let Engineering attach a Terminal under any Cell, WorkCenter, or Area and assign its `DefaultScreen` from the MPP-supplied per-workstation list (Phase 0 Track A item 4) — the behavior follows the assigned view.
>
> **Design history:** v1.0–v1.3a derived the mode from the Terminal's parent tier ("the mode IS the assignment"). That rule was retired 2026-06-10: MPP's machining/assembly lines and trim shops are tracked at line/area resolution with NO equipment cells beneath them, and terminals carry mandatory child Printer locations — the tree cannot reliably encode behavior. See `docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md`.
>
> FUTURE: an `AutoReleaseOnIdle` attribute may be added to tune the re-confirmation interval per terminal — out of MVP.

- [ ] **Step 5: FDS-02-011 (heading `#### FDS-02-011 — Cell Context Change Rules`)**

Replace `- On **Dedicated** terminals the active Cell context SHALL NOT be changeable via the UI. The terminal's parent Cell IS the context for the session; no scan, dropdown, or search is offered.` with:

> - On terminals running a **dedicated-flavor** view the active location context SHALL NOT be changeable via the UI. The terminal's parent Location IS the context for the session; no scan, dropdown, or search is offered.

Replace `- On **Shared** terminals the active Cell context SHALL be changeable only via the FDS-02-009 selectors (scan or dropdown), constrained to descendant Cells of the terminal's parent Location.` with:

> - On terminals running a **shared-flavor** view the active location context SHALL be changeable only via the FDS-02-009 selectors (scan or dropdown), constrained to descendant equipment Cells of the terminal's parent Location.

- [ ] **Step 6: FDS-04-003 (heading `#### FDS-04-003 — Terminal Mode: Dedicated vs Shared — \`MVP\``)**

Replace the ENTIRE section (heading + body, down to but excluding `#### FDS-04-004`) with:

> #### FDS-04-003 — Presence Policy: Dedicated vs Shared Views — `MVP`
> Presence behavior follows the **view flavor** assigned to the terminal (FDS-02-010), surfaced at runtime as `session.custom.presence.policy`:
>
> - **Dedicated-flavor views** (`policy = confirm`): the location context is fixed, so presence context persists across idle gaps subject only to the 30-minute re-confirmation prompt (FDS-04-006). Initials do not clear unless explicitly changed.
> - **Shared-flavor views** (`policy = strict`; e.g., a Die Cast cabin where one terminal serves multiple presses): the presence context SHALL be requested on first action after any idle period longer than the presence-timeout, and SHALL also be re-prompted when the operator changes location context — by scan or dropdown — per FDS-02-009.

- [ ] **Step 7: Header version + Revision History**

1. Find the document-header version line near the top of the file (it stale-reads v1.1 per `PROJECT_STATUS.md`) and set it to `1.4` with date `2026-06-10`.
2. Insert a new first row in the `## Revision History` table:

```markdown
| 1.4 | 2026-06-10 | Blue Ridge Automation | **Terminal mode model replaced (view-policy).** FDS-02-010 rewritten — dedicated-vs-shared behavior is a property of the operator view assigned via the Terminal's `DefaultScreen` attribute; the parent-tier derivation is retired (MPP's machining/assembly lines + trim shops are tracked at line/area resolution with no equipment cells beneath their terminals, so the hierarchy cannot encode behavior; smoke-discovered 2026-06-10). Dedicated context = the Terminal's parent Location at any tier; shared context picker = descendant **equipment** Cells (new `Location.Terminal_ListContextCells`, excluding Terminal/Printer kinds). FDS-02-008 (no mode attribute; ≥1 child Printer required, `HasPrinter` registry flag), FDS-02-009/011 (context rules re-anchored to view flavor), FDS-04-003 (presence policy via `session.custom.presence.policy`) amended; **FDS-04-006 explicitly unchanged** — both flavors keep the 30-minute re-confirmation. Design record: `docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md`. |
```

- [ ] **Step 8: Regenerate the Word version**

```powershell
pandoc MPP_MES_FDS.md -o MPP_MES_FDS.docx --reference-doc=reference.docx; node style_docx_tables.js MPP_MES_FDS.docx
```
Expected: both commands exit 0.

- [ ] **Step 9: Commit**

```powershell
git add "MPP_MES_FDS.md" "MPP_MES_FDS.docx"
git commit -m "docs(fds): v1.4 - terminal behavior by assigned view; retire parent-tier mode derivation"
```

---

### Task 8: Status doc + full verification

**Files:**
- Modify: `PROJECT_STATUS.md`

- [ ] **Step 1: Full SQL suite**

From `sql\tests\`: `.\Run-Tests.ps1`
Expected: all files PASS (suite was 1196 + 6 new − 2 removed ⇒ expect ~1200; record the exact number).

- [ ] **Step 2: Final scan + session smoke**

`.\scan.ps1`; relaunch the MPP session: fallback routing, Terminal Selector populates, no wrapper.log stack traces from `Terminal_GetByIpAddress` / `Shift` ticks.

- [ ] **Step 3: PROJECT_STATUS.md**

Update the Current Document Versions table row for FDS to `v1.4 | 2026-06-10` (summary: terminal view-policy model; header-version stale note resolved). Add a Recently-closed entry titled "Terminal-mode view-policy model (2026-06-10)" summarizing: derived TerminalMode retired (spec + FDS v1.4), resolver procs v1.1, `Terminal_ListContextCells` + `HasPrinter`, session/HomeRouter/CellContextSelector updates, suite count.

- [ ] **Step 4: Commit**

```powershell
git add "PROJECT_STATUS.md"
git commit -m "docs(status): terminal view-policy model landed; FDS v1.4"
```

---

## Out of scope (per spec §5)

- Authoring the actual shared-/dedicated-flavor work views (Arc 2 Phases 2+).
- MPP's per-workstation DefaultScreen seed values (Phase 0 Track A item 4).
- `IsInfrastructure` flag on `LocationTypeDefinition` (FUTURE).
- Terminal-registry admin UI (flags are in `Terminal_List` now; screen later).
- PresenceIdleWatcher branching on `presence.policy` (wired when the first work views are built; the session prop + convention land here).
