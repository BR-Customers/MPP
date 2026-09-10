# Cavity Identifier — Numeric Ordinal → Per-Part Alphabetic Code

**Date:** 2026-09-10
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Die Cast configuration model. Config Tool (Arc 1) Tool Cavities editor changes with it.
**Origin:** Jacques, 2026-09-10 — *"scope out switching the cavity from numeric to alphabetic characters."*
**Builds on:** migration `0072` (`Tools.ToolCavity.ItemId`, the configured cavity-to-part map for family dies), 2026-09-09.
**Migration slot:** `0075_toolcavity_alpha_code.sql`

> ⚠️ **Prod is live.** `MPP_MES_Prod` went into production use 2026-09-09 and holds real die-cast LOTs stamped with `ToolCavityId`. This is a schema change against a running plant. Section 9 (Cutover) is not optional.

---

## 1. Motivation

### 1.1 What MPP actually calls a cavity

MPP runs **family dies** — one die casting several different part numbers at once. Migration `0072`'s own header, written from day-one floor feedback, names a cavity the way the plant does:

> *"6MA EX 1 cavity 'a' is out of service"*

A cavity is identified by a **letter, scoped to the part it cuts** — not by a die-wide ordinal. Jacques, 2026-09-10:

> *"a 12 cavity die might produce 4 unique parts, each part has cavities a-d… if a die has only a single cavity, it would just be a."*

### 1.2 What the system stores today

```sql
Tools.ToolCavity.CavityNumber INT NOT NULL
CREATE UNIQUE INDEX UQ_ToolCavity_ActiveToolCavity
    ON Tools.ToolCavity (ToolId, CavityNumber) WHERE DeprecatedAt IS NULL;
```

A **die-wide integer ordinal**, unique per tool. On a 12-cavity family die that forces `1..12` across four parts, which is not a number anybody on the floor uses.

### 1.3 The evidence that the model is already being worked around

`MPP_MES_Dev`'s live cavity configuration, 2026-09-10:

| Tool | Num | Part | Description |
|---|---|---|---|
| `6MA-B` | 1, 2, 3 | `12231-6MA -0000` | `Intake 1 Aa` / `Intake 1 Ab` / `Intake 1 Ac` |
| `6MA-B` | 4, 5, 6 | `12235-6MA -0000` | `Intake 5 Aa` / `Intake 5 Ab` / `Intake 5 Ac` |
| `6MA-B` | 7, 8, 9 | `12241-6MA -0000` | `Exhaust 1 Aa` / `Ab` / `Ac` *(Ac = Scrapped)* |
| `6MA-B` | 10, 11, 12 | `12245-6MA -0000` | `Exhaust 5 Aa` / `Ab` / `Ac` |
| `6MA-A` | 1, 2 | `12232-6MA -0000` | `Intake 2-A` / `Intake 2-B` |

The per-part letter is **already there** — hand-typed into the free-text `Description`, because the schema gave it nowhere else to live. It is entered inconsistently (`Aa/Ab/Ac` on one die, `-A/-B` on another), it is invisible to every query, and nothing enforces or dedupes it.

This spec moves that letter into the identifier where it belongs.

### 1.4 On sorting

Cavity order is **presentation only** — it appears in seven places and nothing computes from it:

| Proc | Drives |
|---|---|
| `Tools.ToolCavity_ListByTool` | Config Tool cavity grid |
| `Tools.ToolCavity_ListActiveByTool` | Cavity dropdown (Open a basket) |
| `Lots.Lot_GetOpenByTool` | Bulk-Open grid, one row per cavity |
| `Lots.Lot_GetShiftCavityTally` | Die-cast right-rail tally |
| `Workorder.DieCast_GetShiftOutputBreakdown` | Shift-output cavity rows |
| `Tools.Tool_Duplicate` | Cavity copy order |
| `Tools.ToolCavity_SaveAll` | Audit narrative order |

Single letters sort lexicographically in the order a human expects, so the letter change is neutral in itself. The **family-die scoping** is what forces a change: `ORDER BY CavityCode` alone would interleave `a, a, a, a, b, b, b, b…` across four parts. See §5.

---

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Identity is **`(Tool, Item, CavityCode)`** | Matches how MPP names cavities. Four cavities called `a` on one die, one per part. |
| D2 | Column renamed `CavityNumber` → **`CavityCode`** | `CavityNumber` holding `'a'` is a permanent misnomer; `Code` is the repo's convention for a short identifier. |
| D3 | **`CavityCode` immutable** once saved; **`ItemId` editable**, collision-checked | Preserves the existing immutability rule. `0072` shipped 2026-09-09, so `ItemId` values are freshly entered and will need correcting without deprecating rows. |
| D4 | **`Description` unchanged** — still the display name per the 2026-08-19 decision, existing values untouched | Jacques, 2026-09-10: *"keep it as is. no need for a change there."* No parsing of free text, no backfill from it, no change to `cavityDisplayName()`. |
| D5 | Rename carried **all the way through to the Perspective views** | Chosen over stopping at the Python boundary. One name at every layer; cost is 15 Designer view edits (§7.4). |
| D6 | `Lots.Lot.CavityNumber` → **`CavityNote`** | The legacy free-text D2 column, already fed by `@CavityNote`. Leaving a second `CavityNumber` behind would defeat the audit in §8. |
| D7 | `Tools.Tool_Duplicate`'s missing `ItemId` copy **fixed in scope** | Pre-existing defect in the exact statement being edited; per-part identity makes it materially worse. See §6. |
| D8 | Codes stored **lowercase**, 1–4 letters | Matches `0072`'s *"cavity 'a'"*. Collation is `SQL_Latin1_General_CP1_CI_AS`, so `'A'`/`'a'` collide in the unique index regardless — case is a display choice, not a correctness one. |

### 2.1 Explicitly out of scope

- Any change to `ToolCavity.Description` semantics or content (D4).
- Any change to elevation, LOT genealogy, or `Lot.ToolCavityId` itself — the FK still points at exactly one physical cavity row, so traceability is untouched.
- Making `ToolCavity.ItemId` `NOT NULL`. It stays nullable; see §3.2.
- Renaming Perspective **component** names (`CavityOrdinal`, `KpiCavity`, …). Cosmetic, no functional effect.
- The five pre-existing stale-fixture test failures (§7.3).

---

## 3. Schema

### 3.1 Migration `0075_toolcavity_alpha_code.sql`

Forward-only, additive-then-cutover, idempotent-guarded per repo convention. **No versioned migration is edited** — `0010` (which created `CavityNumber INT`) and `0020` (which created `Lot.CavityNumber`) are history and stay as written; a full `Reset-DevDatabase` replays them and then applies `0075`.

```
1. ALTER TABLE Tools.ToolCavity ADD CavityCode NVARCHAR(4) NULL;

2. -- Guard BEFORE writing anything: abort if any (Tool, Item) group exceeds 26.
   IF EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL
              GROUP BY ToolId, ISNULL(ItemId, -1) HAVING COUNT(*) > 26)
       RAISERROR(...)  -- a group that large means the model is wrong, not the letters

3. -- Backfill: letters assigned per part group, in existing ordinal order.
   UPDATE tc SET CavityCode = CHAR(96 + rn)
   FROM (SELECT Id, ROW_NUMBER() OVER (
                    PARTITION BY ToolId, ISNULL(ItemId, -1)
                    ORDER BY CavityNumber) AS rn
         FROM Tools.ToolCavity) x ...
   -- Deprecated rows included: the unique index is filtered, but the column is NOT NULL.

4. ALTER TABLE Tools.ToolCavity ALTER COLUMN CavityCode NVARCHAR(4) NOT NULL;

5. DROP INDEX UQ_ToolCavity_ActiveToolCavity ON Tools.ToolCavity;
   CREATE UNIQUE INDEX UQ_ToolCavity_ActiveToolItemCode
       ON Tools.ToolCavity (ToolId, ItemId, CavityCode) WHERE DeprecatedAt IS NULL;

6. ALTER TABLE Tools.ToolCavity DROP COLUMN CavityNumber;

7. EXEC sp_rename 'Lots.Lot.CavityNumber', 'CavityNote', 'COLUMN';   -- D6
```

**Why the backfill is safe on Dev, and must be reviewed on Prod.** The letter is derived from the *ordinal*, not from the paper sheet. On Dev it reproduces exactly what operators typed into `Description`: `6MA-B` part `12231` nums 1,2,3 → `a,b,c` against descriptions `Aa/Ab/Ac`; `6MA-A` part `12232` nums 1,2 → `a,b` against `-A/-B`. **On Prod this correspondence is an assumption, not a fact** — see §9.1.

Largest `(Tool, Item)` group in Dev today is **3**. 35 cavity rows across 14 tools.

### 3.2 Why `ItemId` stays nullable

SQL Server treats `NULL`s as equal for uniqueness purposes, so a non-family die whose cavities all leave `ItemId` unset forms a single group `(ToolId, NULL, code)` and still gets distinct letters `a, b, c`. That is the correct behaviour: a one-part die's cavities *are* mutually exclusive. Making `ItemId` mandatory would force every non-family die to be reconfigured for no gain.

Edge case, accepted: a die with *some* cavities mapped and some not puts the unmapped ones in the `NULL` group. That is already how `0072` behaves and is not made worse here.

---

## 4. Rules

Replacing the current `CavityNumber < 1` check:

| Rule | Enforced in | Behaviour |
|---|---|---|
| Format | `ToolCavity_Create`, `ToolCavity_SaveAll` | 1–4 characters, letters only (`a`–`z`), normalized to lowercase. Reject empty/NULL. |
| Uniqueness | `UQ_ToolCavity_ActiveToolItemCode` + pre-check in both procs | One `CavityCode` per `(Tool, Item)` among non-deprecated rows. Pre-check so the operator gets a message, not a constraint violation. |
| Code immutability | `ToolCavity_SaveAll` | Unchanged rule, retargeted: `CavityCode` may not change on a saved row. Message: *"Cavity code is immutable on existing cavities."* |
| **ItemId collision** *(new)* | `ToolCavity_SaveAll` | An `ItemId` edit that would produce a duplicate `(Tool, newItemId, CavityCode)` is rejected before mutation. This rejection does not exist today and is the direct consequence of D1 + D3. |
| Scrapped transition | `ToolCavity_SaveAll` | Unchanged. |

All rejections run **before `BEGIN TRANSACTION`** per the `INSERT-EXEC` co-requirement in `CLAUDE.md`.

---

## 5. Ordering

Seven sites move from `ORDER BY tc.CavityNumber` to `ORDER BY i.PartNumber, tc.CavityCode` (NULL `PartNumber` first — a non-family die has one group and is unaffected):

`ToolCavity_ListByTool` · `ToolCavity_ListActiveByTool` · `Lot_GetOpenByTool` · `Lot_GetShiftCavityTally` · `DieCast_GetShiftOutputBreakdown` · `Tool_Duplicate` · `ToolCavity_SaveAll` (audit narrative)

Without this, a 12-cavity/4-part die renders `a, a, a, a, b, b, b, b, c, c, c, c` on the Bulk-Open grid, the shift-output rows and the right-rail tally — four unrelated parts interleaved. With it, the screens group by part, which is how the paper production sheets read.

`DieCast_GetShiftOutputBreakdown` keeps its existing secondary keys: `ORDER BY i.PartNumber, tc.CavityCode, ISNULL(lo.IsOpen,0) DESC, lo.LotId`.

---

## 6. `Tool_Duplicate` — pre-existing defect, fixed here

```sql
-- R__Tools_Tool_Duplicate.sql:325
INSERT INTO Tools.ToolCavity
    (ToolId, CavityNumber, StatusCodeId, Description, CreatedAt, CreatedByUserId)
SELECT @NewId, c.CavityNumber, c.StatusCodeId, c.Description, ...
```

`ItemId` is absent. Migration `0072` added the column on 2026-09-09 and this proc was never updated, so **duplicating a family die silently discards the entire cavity-to-part map**. The duplicate's cavities all come back unmapped, and the shift-output screen cannot name them — precisely the failure `0072` was written to fix.

Under per-part identity it also becomes a *correctness* problem: every copied cavity lands in the single `NULL`-item group, so a 12-cavity family die needs 12 distinct letters instead of 3, and the backfill/insert can collide.

`ItemId` is added to both the copy `SELECT` and the JSON preview at lines 289 and 369. A regression test is added (§7.2).

---

## 7. Blast radius

Verified against the working tree on 2026-09-10. The re-runnable audit that produced these numbers is `tools/verify_cavity_rename.py` (§8).

### 7.1 By layer

**67 files, 366 occurrences.**

| Layer | Files | Occurrences | Change class |
|---|---|---|---|
| `sql/migrations/versioned` | **0** | — | **Untouched** — history. One *new* file, `0075`. |
| `sql/migrations/repeatable` | 18 | 111 | Rename; 6 procs change behaviour (§7.2) |
| `sql/tests` | 26 | 157 | Rename + 7 new cases |
| Named queries | 2 | 4 | Rename + `sqlType` change |
| `script-python` | 3 | 36 | Rename; delete 2 `int()` coercions |
| Perspective views | 15 | 30 | **Designer edits** |
| Perspective views (pickled) | 1 | 16 | **Not a rename** — strip stale data (§7.5) |
| Docs | 2 | 12 | Prose + extended properties |

### 7.1.1 Two identifiers, not one

The audit distinguishes them because they rename in different places:

- **`CavityNumber`** — the column itself → `CavityCode`
- **`ToolCavityNumber`** — `Lots.Lot_Get`'s result-set *alias* (`tc.CavityNumber AS ToolCavityNumber`) → **`ToolCavityCode`**. Consumed by four plant-floor views (`ShopFloor/LotDetail`, `LotDetail/CountPanel`, `LotDetail/ScrapPanel`, `ShopFloor/InspectionEntry`), by `Lots/Lot/code.py`'s `_EMPTY` shape, and by `MPP_MES_DATA_MODEL.md`.

A rename of the column that misses the alias leaves four screens rendering a blank cell with **no error at all** — the failure mode this audit exists to catch.

### 7.2 Behaviour changes (not mechanical renames)

| File | Change |
|---|---|
| `R__Tools_ToolCavity_SaveAll.sql` (30 refs) | `@Incoming.CavityCode NVARCHAR(4)`; `TRY_CAST(… AS INT)` → `JSON_VALUE` string; `< 1` → format check; **new ItemId-collision rejection**; uniqueness pre-check re-scoped to `(Tool, Item, Code)`; audit `+#1` → `+#a`; ordering |
| `R__Tools_ToolCavity_Create.sql` (11 refs) | `@CavityNumber INT` → `@CavityCode NVARCHAR(4)`; `< 1` → format check; uniqueness re-scoped |
| `R__Tools_Tool_Duplicate.sql` (8 refs) | Rename + **`ItemId` added to the copy** (§6) |
| `R__Lots_Lot_Get.sql` (2 refs) | Result alias `tc.CavityNumber AS ToolCavityNumber` → `ToolCavityCode` — consumed by 4 views and `Lot/code.py`'s `_EMPTY` shape (§7.1.1) |
| `R__Lots_Lot_GetTerminalRecentCreations.sql` (4 refs) | Reads both `tc.CavityCode` and the renamed `l.CavityNote`; drops `CAST(… AS NVARCHAR(20))` |
| `R__Lots_Lot_Create.sql` (7 refs) | `@CavityNum` now naturally a string; `@CavityNumberToStore` → `@CavityNoteToStore`; audit prose unchanged |

Remaining procs are pure renames: `DieCastLot_Open`, `Lot_GetLatestForToolCavity`, `Lot_GetOpenByTool`, `Lot_GetShiftCavityTally`, `Lot_SearchAdvanced`, `ToolCavity_ListActiveByTool`, `ToolCavity_ListByTool`, `Assembly_CompleteTray`, `DieCast_GetReleasePreview`, `DieCast_GetShiftOutputBreakdown`, `MachiningOut_Mint`.

### 7.3 Tests

26 files, 157 occurrences. Heaviest: `0015_Tools_Cavity/030_ToolCavity_ItemId.sql` (17), `0022_PlantFloor_DieCast/040_CavityParallel_peers.sql` (17), `080_ShotReadingChain.sql` (15), `100_CounterAnchor.sql` (11), `050_Lot_GetShiftCavityTally.sql` (10).

**New cases:**

1. Two cavities coded `a` on **different parts** of one tool → **allowed**
2. Two cavities coded `a` on the **same part** → **rejected**
3. `'A'` vs `'a'` on the same part → **rejected** (case-insensitive collation)
4. Non-letter / empty / 5-char code → **rejected**
5. `CavityCode` edit on a saved row → **rejected**
6. `ItemId` edit producing a duplicate `(Tool, Item, Code)` → **rejected**
7. `Tool_Duplicate` carries `ItemId` (§6 regression)

Plus a migration-level assertion that the `> 26` guard fires.

> **Pre-existing failures, not regressions.** `0022/030`, `0022/040`, `0022/050`, `0022/070` and `0020/040` already error on the stale `ToolAssignment.CellLocationId` fixture (the 2026-07-06 eligibility-tier decision). They make the runner exit 1 while assertion counts stay green. Do not read them as caused by this change.

### 7.4 Perspective views — 15 Designer edits

**MPP_Config (2) — the only views that treat cavity as a number:**

| View | Change |
|---|---|
| `Components/Parts/Tools/_Tools/CavityRow` | `ia.input.numeric-entry-field` → `ia.input.text-field`; 2 bindings `view.params.row.cavityNumber` → `.cavityCode`; param default `null` → `""` |
| `Components/Parts/Tools/Cavities` | 3 inline-Python dict keys; **delete `int(newNumber)`**; `updateCavityNumber` method + its param |

**MPP plant floor (13):**

| View | Token | Change |
|---|---|---|
| `DieCastEntry/BulkOpenRow` | `param` | param + `propConfig.paramDirection` |
| `DieCastEntry/CavityLotRow` | `param` | param + `propConfig.paramDirection` |
| `DieCastEntry/OpenBasketRow` | `param` | param + `propConfig.paramDirection` |
| `DieCastEntry/RejectPanel` | `col` | expression binding `toStr({view.custom.targetLot.CavityNumber})` |
| `Popups/DieCastOverflow` | `param` | inline-Python row build |
| `Popups/DieCastOverflowRow` | `param` | param + `propConfig` + **expression binding** |
| `Popups/DieCastRelease` | `param` | custom prop |
| `ShopFloor/DieCastBody` | `col`, `param` | inline Python reading `r.get("CavityNumber")` — the SQL column, so it changes regardless of param naming |
| `ShopFloor/LotSearch` | `col` | table column definition `"field": "CavityNumber"` (from `Lot_SearchAdvanced`) |
| `ShopFloor/LotDetail` | `colalias` ×3 | `ToolCavityNumber` → `ToolCavityCode` |
| `ShopFloor/InspectionEntry` | `colalias` | `ToolCavityNumber` → `ToolCavityCode` |
| `LotDetail/CountPanel` | `colalias` | `ToolCavityNumber` → `ToolCavityCode` |
| `LotDetail/ScrapPanel` | `colalias` | `ToolCavityNumber` → `ToolCavityCode` |

> The last six were **missed by a manual grep** and found by the audit. A hand search for the lowercase param form `cavityNumber` sees none of them: four use the `ToolCavityNumber` alias, and two use the capitalised column inside an expression binding and a table-column definition. That gap — six of fifteen views — is the case for running §8 rather than trusting a reviewer's eye.

**Matched "cavity" but need nothing** (`toolCavityId` / `cavityName` only): none remaining once the audit's token set is used. The earlier "needs nothing" list was an artefact of the incomplete search.

### 7.5 `Views/Audit/AuditLog` — pickled data, not a rename

`AuditLog/view.json` is 44 KB and carries **19 `"$ts"` QualifiedValue timestamps** — live audit rows fetched in the Designer and saved into a component's *default* property value, committed in `c1938eab`. Sixteen `CavityNumber` hits sit inside those stale `OldValue` / `NewValue` payloads.

**These are not rename targets.** Rewriting a column name inside a pickled audit payload preserves the defect and makes it look deliberate. The fix is to strip the pickled rows so the property defaults to empty and binds at runtime.

Pre-existing, unrelated to this change, and tracked separately — but it must be handled, because `--mode verify` cannot reach zero while it stands. Textbook `feedback_designer_pickles_live_data`.

**Traps, from project memory:**

- Existing views are **Designer-only** — file edits are unreliable (`feedback_ignition_view_edit_boundary`).
- `DieCastOverflowRow`'s expression is `"Cavity " + toStr({view.params.cavityNumber}) + " · " + …` — expression string literals reject `\u` escapes, so the `·` must survive as a literal character (`feedback_ignition_expr_no_unicode_escape`).
- Designer writes `=` `'` `<` `>` as 6-char unicode escapes; anchor edits on escape-free text (`feedback_ignition_designer_unicode_escapes`).
- `CavityLotRow` **already lost a `paramDirection` to a Designer save** in the 2026-08-19 merge. Diff `propConfig` key sets and `paramDirection` values, not just visible props.
- Check `git diff --stat` before committing — Designer pickles live data into defaults (`feedback_designer_pickles_live_data`).
- `.\scan.ps1` after the NQ and script-python edits.

### 7.6 Named queries

| NQ | Change |
|---|---|
| `parts/ToolCavity_Create` | param `cavityNumber` → `cavityCode`; **`sqlType: 2` → `sqlType: 7`** (String) |
| `lots/Lot_Create` | `@CavityNote = :cavityNote` unchanged; verify against the renamed `Lot.CavityNote` |

`ToolCavity_SaveAll` passes rows as a JSON string (`sqlType: 7`) — no signature change, but the JSON **key** inside becomes `CavityCode`.

### 7.7 Docs

`MPP_MES_DATA_MODEL.md` (10 `CavityNumber` + 1 `ToolCavityNumber`) · `MPP_MES_SUMMARY.md` (1) · `R__Descriptions_ExtendedProperties.sql` (8, incl. the `Lot.CavityNumber` "legacy" note which now describes `CavityNote`) · FDS-05-034 wording · regenerate `MPP_MES_ERD.html` via SchemaGen · regenerate affected `.docx`.

Historical documents that **keep** the old name and are allowlisted by the audit: `MPP_MES_FDS_CHANGELOG.md`, `docs/superpowers/specs/**`, `docs/superpowers/plans/**`, `notes/**`, `Meeting_Notes/**`, `sql/migrations/versioned/**`.

---

## 8. The audit — `tools/verify_cavity_rename.py`

A re-runnable blast-radius test, in the style of `tools/verify_project_tree.py`. Three modes:

| Mode | Purpose |
|---|---|
| `--mode inventory` | Prints the classified table in §7 from the live tree. The source of every number in this spec. |
| `--mode baseline` | Writes `tools/cavity_rename_baseline.json` — the pre-change fingerprint. |
| `--mode verify` | **Exit 1 if any legacy token survives** outside the allowlist. The completion gate. |

It scans for the full token set, not just the column name: `CavityNumber` / `cavityNumber`, `@CavityNumber`, `int(cavityNumber)`, `int(newNumber)`, `TRY_CAST(… CavityNumber … AS INT)`, `CavityNumber < 1`, `ORDER BY … CavityNumber`, `numeric-entry-field` inside `CavityRow`, and `"sqlType": 2` inside `ToolCavity_Create`. Unicode-escaped forms inside `view.json` are matched too, since Designer rewrites them.

`--mode verify` returning 0 is the definition of done for the rename. It does **not** assert behaviour — that is the SQL test suite (§7.3).

---

## 9. Cutover

### 9.1 Pre-flight on Prod — blocking

Prod is live. Before `0075` runs:

```sql
-- 1. How much is there, and is 0072's map even populated?
SELECT COUNT(*) AS Cavities,
       SUM(CASE WHEN ItemId IS NULL THEN 1 ELSE 0 END) AS Unmapped
FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL;

-- 2. Would the guard fire?
SELECT ToolId, ISNULL(ItemId,-1) AS ItemGrp, COUNT(*) n
FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL
GROUP BY ToolId, ISNULL(ItemId,-1) HAVING COUNT(*) > 26;

-- 3. THE ONE THAT MATTERS: dry-run the derived letters next to the
--    Description operators typed, and put it in front of MPP.
SELECT t.Code AS Tool, i.PartNumber, tc.CavityNumber, tc.Description,
       CHAR(96 + ROW_NUMBER() OVER (PARTITION BY tc.ToolId, ISNULL(tc.ItemId,-1)
                                    ORDER BY tc.CavityNumber)) AS DerivedCode
FROM Tools.ToolCavity tc
JOIN Tools.Tool t ON t.Id = tc.ToolId
LEFT JOIN Parts.Item i ON i.Id = tc.ItemId
WHERE tc.DeprecatedAt IS NULL
ORDER BY t.Code, i.PartNumber, tc.CavityNumber;
```

**Query 3 is a gate, not a check.** The letters come from the ordinal, not from the die. On Dev they happen to reproduce what operators typed; on Prod that is an assumption. If `0072`'s `ItemId` map is still unpopulated on Prod, every cavity falls into the `NULL` group and the derived letters will be *die-wide* `a..l` — wrong, and exactly the thing this change exists to stop. **If `Unmapped > 0` on a family die, configure `ItemId` first and re-run query 3.**

`CavityCode` is immutable after save (D3), so a wrong letter means deprecating and re-creating the row — with live LOTs already pointing at it. Get this right before, not after.

### 9.2 Order of operations

1. **Backup** `MPP_MES_Prod` + `RESTORE VERIFYONLY`, as with `0066` and the FAT purge.
2. `0075` and the repeatable procs deploy **together** — `Update-Prod.ps1` runs migrations then repeatables, which is the correct order. A repeatable referencing `CavityCode` applied before `0075` is a hard failure.
3. Rebuild the Ignition project exports **after** the view edits, and import in step with the DB. Prod's Ignition server still has no projects imported (`PROJECT_STATUS.md`), so there is a window here — but if the 09-09 zips are imported before this ships, they must be re-exported.
4. Dev first: full `Reset-DevDatabase`, then the full SQL test suite, then `.\scan.ps1`, then live smoke on the Die Cast screen with a family die (`6MA-B`).

### 9.3 Rollback

Not reversible by a down-migration — `CavityNumber` is dropped in step 6 and the ordinal is not recoverable from the letter once cavities are added or deprecated. **Rollback is restore-from-backup.** This is the strongest argument for completing §9.1 before touching Prod.

---

## 10. Open questions

| # | Question | Owner | Blocking? |
|---|---|---|---|
| Q1 | Lowercase (`a`) or uppercase (`A`)? Spec assumes lowercase per `0072`. Dev's descriptions are mixed. | MPP / Jacques | No — one-line change, uniqueness unaffected |
| Q2 | Is `ItemId` populated on Prod's family dies yet? `0072` shipped 2026-09-09. | Jacques | **Yes** — gates §9.1 query 3 |
| Q3 | Do MPP's paper production sheets letter cavities in the same order as the current `CavityNumber` ordinal? | MPP | **Yes** — gates the backfill |
| Q4 | Should `Lots.Lot.CavityNote` be dropped outright rather than renamed? It is marked *"legacy as of v1.9, scheduled for removal"*. | Jacques | No — rename now, drop separately |

---

## 11. Revision History

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 2026-09-10 | Blue Ridge (with Claude) | Initial design. Decisions D1–D8 taken in session with Jacques. |
