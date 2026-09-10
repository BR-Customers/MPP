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
| D6 | `Lots.Lot.CavityNumber` **dropped**, and the D2 manual-cavity fallback retired with it | Jacques, 2026-09-10 (Q4): drop it, *"so long as that's not the description"* — it is not; it is the free-text cavity note on the LOT. Dev has **0** LOTs using it and **0** die-cast LOTs without a proper `ToolCavityId`. See §6.2. |
| D7 | `Tools.Tool_Duplicate`'s missing `ItemId` copy — **NOT in scope; owned by the punch list** | Independently found and specified the same day in `docs/superpowers/specs/2026-09-10-tools-screen-punch-list-design.md` §1, more thoroughly than here (deprecated-part guard, audit JSON, `@Message` reporting, two test assertions). This spec **depends on** it, it does not re-specify it. See §6.1. |
| D8 | Codes stored **lowercase**, 1–4 letters — **confirmed by Jacques 2026-09-10 (Q1)** | Matches `0072`'s *"cavity 'a'"* and prod's own descriptions (`In 1 Da` / `Db` / `Dc` — the `D` is part of the *die* identifier, the trailing lowercase letter is the cavity). Collation is `SQL_Latin1_General_CP1_CI_AS`, so `'A'`/`'a'` collide in the unique index regardless. |
| D9 | A Scrapped cavity's `ItemId` must be mappable — **NOT in scope; owned by the punch list** | Found here on prod answering Q2 and, the same day, specified in `2026-09-10-tools-screen-punch-list-design.md` §2 with a broader fix (both locks removed, SQL *and* UI). What this spec contributes is the **consequence**: until that lands, the `0075` backfill mis-letters peer cavities. See §6.2. |

### 2.1 Explicitly out of scope

- Any change to `ToolCavity.Description` semantics or content (D4).
- Any change to elevation, LOT genealogy, or `Lot.ToolCavityId` itself — the FK still points at exactly one physical cavity row, so traceability is untouched.
- Making `ToolCavity.ItemId` `NOT NULL`. It stays nullable; see §3.2.
- Renaming Perspective **component** names (`CavityOrdinal`, `KpiCavity`, …). Cosmetic, no functional effect.
- The five pre-existing stale-fixture test failures (§7.3).
- `Tool_Duplicate`'s missing `ItemId` copy and the Scrapped-cavity lock — both owned by the Tools punch list (§6.0). Dependencies, not scope.

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

3b. -- CROSS-CHECK, not a source. Operators already typed the letter as the last
    -- character of Description ('In 1 Da', 'Ex 1 Db', 'Exhaust 1 Aa'). Where the
    -- Description ends in a lowercase letter, it must equal the derived code;
    -- RAISERROR listing every mismatch. Descriptions with no trailing letter
    -- (single-cavity dies -- '6MA oil Pan') are skipped, not failed.
    -- D4 stands: Description is never PARSED INTO the column, only compared to it.

4. ALTER TABLE Tools.ToolCavity ALTER COLUMN CavityCode NVARCHAR(4) NOT NULL;

5. DROP INDEX UQ_ToolCavity_ActiveToolCavity ON Tools.ToolCavity;
   CREATE UNIQUE INDEX UQ_ToolCavity_ActiveToolItemCode
       ON Tools.ToolCavity (ToolId, ItemId, CavityCode) WHERE DeprecatedAt IS NULL;

6. ALTER TABLE Tools.ToolCavity DROP COLUMN CavityNumber;

7. ALTER TABLE Lots.Lot DROP COLUMN CavityNumber;   -- D6, see 6.2 (verify 0 rows first)
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
| ~~Scrapped transition~~ | — | **Removed** by punch-list §2, which deletes the `-- No transition OUT of Scrapped` block and frees status in both directions. This spec must not re-assert it (§6.0). |

All rejections run **before `BEGIN TRANSACTION`** per the `INSERT-EXEC` co-requirement in `CLAUDE.md`.

---

## 5. Ordering

Seven sites move from `ORDER BY tc.CavityNumber` to `ORDER BY i.PartNumber, tc.CavityCode` (NULL `PartNumber` first — a non-family die has one group and is unaffected):

`ToolCavity_ListByTool` · `ToolCavity_ListActiveByTool` · `Lot_GetOpenByTool` · `Lot_GetShiftCavityTally` · `DieCast_GetShiftOutputBreakdown` · `Tool_Duplicate` · `ToolCavity_SaveAll` (audit narrative)

Without this, a 12-cavity/4-part die renders `a, a, a, a, b, b, b, b, c, c, c, c` on the Bulk-Open grid, the shift-output rows and the right-rail tally — four unrelated parts interleaved. With it, the screens group by part, which is how the paper production sheets read.

`DieCast_GetShiftOutputBreakdown` keeps its existing secondary keys: `ORDER BY i.PartNumber, tc.CavityCode, ISNULL(lo.IsOpen,0) DESC, lo.LotId`.

---

## 6. Dependencies and adjacent changes

### 6.0 This spec sits on top of the Tools punch list

`2026-09-10-tools-screen-punch-list-design.md` was committed to `jacques/working` the same day (`7ddf1f83`), from the post-go-live plant-floor testing session. It independently found **both** of the adjacent defects this spec had picked up, and specifies them better. They are **removed from this scope** and become a **merge-order dependency** instead.

| Defect | Punch list | This spec |
|---|---|---|
| `Tool_Duplicate` drops `ItemId` | §1 — owns the fix, incl. deprecated-part guard, resolved-FK audit JSON, `@Message` count, 2 new assertions, `DuplicateDie` popup text | §6.1 — records only *why `0075` needs it* |
| Scrapped cavity is unmappable | §2 — owns the fix, and goes further: **both** locks removed (the SQL `-- No transition OUT of Scrapped` block **and** all three `CavityRow` `props.enabled` bindings), no gate replacing them | §6.2 — records only the **backfill consequence**, which the punch list does not cover |

**Order: punch list first, then `0075`.** They edit the same four files — `R__Tools_ToolCavity_SaveAll.sql`, `R__Tools_Tool_Duplicate.sql`, `_Tools/CavityRow/view.json`, `Tools/Cavities/view.json`. Landing the rename first would force the punch list to re-derive its edits against renamed columns and a swapped input component, for no gain. Re-run `--mode baseline` (§8) after the punch list lands so the rename measures against the corrected tree.

One rule in §4 changes as a result: **"no transition out of Scrapped" is deleted by the punch list**, so this spec must not re-assert it.

### 6.1 Why `0075` needs punch-list §1

`Tool_Duplicate`'s cavity `INSERT` omits `ItemId`. Under **die-wide** identity that loses the part map — bad, but recoverable by re-entering it. Under **per-part** identity (D1) it is worse than data loss: every copied cavity lands in the single `NULL`-`ItemId` group, so a 12-cavity family die needs 12 distinct letters instead of 3 per part, and the insert can collide against `UQ_ToolCavity_ActiveToolItemCode`. A duplicated die would fail to save rather than merely come back unmapped.

### 6.2 Why `0075` needs punch-list §2 — the backfill consequence

Answering Q2, Jacques found `DMO124` (`6MA IN 1&5 EX 1&5 - D`, 12 cavities, 4 parts, mounted on Machine 11) has one cavity that cannot be mapped:

> *"all except one cavity that was marked scrapped prior to the part maping. NOW i cannot update it."*

Cavity 7 (`Exhaust 1 Aa`) was set Scrapped before `0072` shipped. `CavityRow` binds Description, **Part** and Status to one expression — `!{view.params.row.isScrappedSaved} && !{view.params.row.isDeprecated}` — so the whole row greys out. Worth noting for the punch list: **the proc was never the blocker.** `ToolCavity_SaveAll`'s `UPDATE` leg already sets `ItemId`, and its Scrapped guard only fires on a status *change* (`sc.Code = 'Scrapped' AND i.StatusCode <> 'Scrapped'`). A row submitted still-Scrapped with a new `ItemId` would have been accepted. Punch-list §2 removes both locks regardless, which resolves it either way.

**The part this spec adds:** that stuck row is not just an annoyance, it silently corrupts the backfill.

#### 6.2.1 One unmapped cavity mis-letters two others

The backfill partitions by `(ToolId, ISNULL(ItemId, -1))`. With cavity 7 unmapped it falls into the `NULL` group **alone**, and part `12241-6MA`'s group shrinks to cavities 8 and 9:

| Cavity | Description | `ItemId` | Group | Derived | Correct |
|---|---|---|---|---|---|
| 1, 2, 3 | `In 1 Da/Db/Dc` | `12231-6MA` | 12231 | `a, b, c` | ✅ |
| 4, 5, 6 | `In 5 Da/Db/Dc` | `12235-6MA` | 12235 | `a, b, c` | ✅ |
| **7** | `Exhaust 1 Aa` | **NULL** | NULL | `a` | ⚠️ should be `a` **of 12241** |
| **8** | `Ex 1 Db` | `12241-6MA` | 12241 | **`a`** | ❌ should be **`b`** |
| **9** | `Ex 1 Dc` | `12241-6MA` | 12241 | **`b`** | ❌ should be **`c`** |
| 10, 11, 12 | `Ex 5 D…` | `12245-6MA` | 12245 | `a, b, c` | ✅ |

`CavityCode` is immutable once saved (D3), so a wrong letter means deprecating and re-creating a row that live LOTs already point at. **Map cavity 7 before `0075` runs** — which is what the punch list unblocks. Backfill step 3b (§3.1) then catches any remaining case automatically by comparing the derived code against the trailing letter already in `Description`.

### 6.3 Dropping `Lots.Lot.CavityNumber` (D6)

The column is the D2 *manual-cavity* fallback: when a die-cast-origin `Lot_Create` gets no `@ToolCavityId`, it demands a free-text `@CavityNote` and stores it here. Dropping the column therefore **retires that fallback** — `@ToolCavityId` becomes unconditionally required for a die-cast-origin LOT. That is a behaviour change, not a schema tidy, and is called out so it is chosen rather than absorbed.

It is the right change now: cavities are properly configured with parts on prod, and a die-cast LOT whose cavity is untyped free text cannot be rolled up per part, which is the whole point of `0072`.

Dev evidence: **0** LOTs with a non-empty `CavityNumber`, **0** die-cast LOTs with `ToolId` set but `ToolCavityId` NULL. The same two counts must be run on prod before the drop (§9.1).

**Blast radius — 6 files, no views:** `R__Lots_Lot_Create.sql` (drop `@CavityNote`, drop the D2 branch, require `@ToolCavityId`), `R__Lots_Lot_GetTerminalRecentCreations.sql` (drop the `COALESCE` fallback), `lots/Lot_Create` NQ (`query.sql` + `resource.json`, drop the `cavityNote` param), `Lots/Lot/code.py` (drop the `cavityNote` argument), and `sql/tests/0023_.../030_Lot_Create_LotName_and_Cavity.sql` (Tests 5 and 6 are the D2 accept/reject pair — Test 5 is deleted, Test 6 becomes *"die-cast origin without `@ToolCavityId` is rejected"*).

**Splittable.** If this is more change than wanted in one migration, `0075` can rename the column to `CavityNote` instead and a later migration can drop it. The audit in §8 passes either way.

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
| `R__Tools_ToolCavity_SaveAll.sql` (30 refs) | `@Incoming.CavityCode NVARCHAR(4)`; `TRY_CAST(… AS INT)` → `JSON_VALUE` string; `< 1` → format check; **new ItemId-collision rejection**; uniqueness pre-check re-scoped to `(Tool, Item, Code)`; audit `+#1` → `+#a`; ordering. Rebase onto punch-list §2, which deletes the Scrapped guard from this same proc |
| `R__Tools_ToolCavity_Create.sql` (11 refs) | `@CavityNumber INT` → `@CavityCode NVARCHAR(4)`; `< 1` → format check; uniqueness re-scoped |
| `R__Tools_Tool_Duplicate.sql` (8 refs) | Rename **only** — the `ItemId` copy is punch-list §1's (§6.0). Rebase onto it. |
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

```sql
-- 4. D6 only: the drop must not destroy data or strand a LOT.
SELECT COUNT(*) FROM Lots.Lot WHERE NULLIF(LTRIM(RTRIM(CavityNumber)), '') IS NOT NULL;
SELECT COUNT(*) FROM Lots.Lot WHERE ToolId IS NOT NULL AND ToolCavityId IS NULL;
-- Both must be 0 (they are on Dev). Non-zero -> do not drop; rename per §6.3.
```

**Query 3 is a gate, not a check — and it has already failed once.** Answering Q2 on 2026-09-10, `DMO124` cavity 7 was found unmapped (Scrapped before `0072` shipped, and unmappable through the UI — D9). That single unmapped row mis-letters cavities 8 and 9 of part `12241-6MA`; the full working is in §6.2.1.

So the rule is concrete: **`Unmapped` must be 0 on every family die before `0075` runs.** Fix D9 first, map the stragglers, re-run query 3, and diff `DerivedCode` against the trailing letter in `Description` — step 3b automates exactly that comparison inside the migration, so a miss aborts rather than corrupts.

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

All four opened with this spec were **answered by Jacques on 2026-09-10** against live prod data.

| # | Question | Resolution |
|---|---|---|
| Q1 | Lowercase `a` or uppercase `A`? | **Lowercase.** Prod's own descriptions confirm it: `In 1 Da` / `Db` / `Dc` — the `D` belongs to the *die* identifier (`DMO124`, `… - D`), the **trailing lowercase letter is the cavity**. Folded into D8. |
| Q2 | Is `ItemId` populated on prod's family dies? | **Yes, except one** — `DMO124` cavity 7, Scrapped before `0072` shipped and unmappable through the UI. Promoted to defect **D9** (§6.2) and to a blocking pre-flight rule (§9.1). |
| Q3 | Do the paper sheets letter cavities in the current ordinal order? | **Yes, and better than asked.** *"they group production by part, where each row represents a cavity"* — which independently confirms the §5 ordering change (`ORDER BY PartNumber, CavityCode`). Prod's descriptions run `Da, Db, Dc` in ordinal order on every mapped group, so the ordinal→letter derivation is sound; step 3b now asserts it per row rather than trusting it. |
| Q4 | Drop `Lots.Lot.CavityNumber` rather than rename it? | **Drop.** *"so long as that's not the description"* — it is not; it is the free-text cavity note on the LOT. Folded into D6, scoped in §6.3, gated by pre-flight query 4. |

### 10.1 Still open

| # | Item | Owner | Blocking? |
|---|---|---|---|
| ~~O1~~ | Resolved by punch-list §2 — Description, Part **and** Status all become editable on a Scrapped row; the `isScrappedSaved` term comes out of all three bindings. | — | Closed |
| O2 | `Views/Audit/AuditLog/view.json` carries 19 pickled QualifiedValue rows (§7.5). Pre-existing and unrelated, but `--mode verify` cannot reach zero until they are stripped. | Jacques | Only for the audit's exit code |
| O3 | Single-cavity dies (`DMO126 — 6MA Oil Pan E`) get code `a` and a Description with no letter to cross-check. Confirmed intended (*"these cavities would just be a"*); noted so step 3b's skip is not read as a gap. | — | No |

---

## 11. Revision History

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 2026-09-10 | Blue Ridge (with Claude) | Initial design. Decisions D1–D8 taken in session with Jacques. Blast radius measured by `tools/verify_cavity_rename.py`: 67 files, 366 occurrences. |
| 0.3 | 2026-09-10 | Blue Ridge (with Claude) | **Reconciled with `2026-09-10-tools-screen-punch-list-design.md`** (`7ddf1f83`, committed the same day from the post-go-live testing session), which independently specifies both adjacent defects and goes further on the Scrapped lock. D7 and D9 **removed from scope** and restated as merge-order dependencies (§6.0): punch list first, then `0075`, because they edit the same four files. §4's "no transition out of Scrapped" rule struck — the punch list deletes it. §6 retitled *Dependencies and adjacent changes*; §6.2.1 (the backfill mis-lettering) retained as this spec's own contribution, which the punch list does not cover. O1 closed. |
| 0.2 | 2026-09-10 | Blue Ridge (with Claude) | Q1–Q4 answered against live prod (§10). **D9 added** — a Scrapped cavity's `ItemId` is unmappable through `CavityRow`, found on `DMO124` cavity 7, and it mis-letters two peer cavities in the backfill (§6.2). **D6 hardened** from rename to drop, retiring the D2 manual-cavity fallback (§6.3). Backfill gains step 3b, a per-row cross-check of the derived code against the trailing letter already in `Description` (validate, never source — D4 stands). Pre-flight gains query 4 and a concrete blocking rule. §6 restructured into three adjacent in-scope changes. |
