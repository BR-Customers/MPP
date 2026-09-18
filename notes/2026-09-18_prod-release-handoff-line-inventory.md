# Prod release handoff -- M&A Line Inventory panel (rev 1 + rev 2) and retirement of the tray projection

**Written:** 2026-09-18, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`, HEAD `17c06c0f` at the time of writing.
**Release shape (Jacques's decision):** everything from prod's last release to HEAD ships as **one combined release**. This note covers the line-inventory part of that bundle. The other features are covered by their own handoffs.
**Prod baseline:** SQL at release `192c77c1` (migration `0089`, `daa32e16` records it committed clean). Ignition last imported at release `aec53015` (2026-09-16). The 0089 release shipped no project resources, so the **Ignition `-Since` is `aec53015`**.
**Spec / plans:** `docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md` (revision 2), `docs/superpowers/plans/2026-09-17-line-inventory-sidebar.md`, `docs/superpowers/plans/2026-09-17-line-inventory-rev2.md`, mockup `mockup/line_inventory_rev2_mock.html`, build record `notes/2026-09-17_line-inventory-designer-handoff.md`.

**Deployable commits (38):**
- **SQL:** `cf001c27` (0091), `c35351d3`, `9b05e013`, `b5671df0`, `98df849e`, `aeb28943`, `5cfca15a`, `ceb8c34c`, `c590fcc1`, `bca73704` (0094), `c58f43da`, `1905f730`, `06415105` (0095).
- **Ignition:** `d977bfa0`, `ca1d7424`, `5146fa55`, `f89525fa`, `8a3d1699`, `9a9f2311`, `a9b4f7aa`, `a1168747`, `9e4125c5`, `3620bf12`, `86df125c`, `2cb476cc`, `b782fb6b`, `079ea185`, `0a473bcf`, `2d5079ac`, `c1121e35`, `83e58617`, `67947b9d`, `84449d2e`, `19d6e755`, `d5dfa7d8`, `ea4f05eb`, `7641bc89`, `f706a052`.

Found by `git log 192c77c1..HEAD` by message, then filtered to commits that touch `ignition/projects` or `sql/migrations`.

This note is scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. The five deliverables in `01_the_release_contract.md` are still owed.

---

## 0. Check these first

1. **Prod state.** `[3]` must say `89 applied, highest 0089`. If it doesn't, stop and reconcile. The 0089 runbook's outcome records 88 → 89.
2. **No 0092, and the preview won't mention it.** `[3]`'s only ordering gate is "pending **at or below** the applied high-water mark" (`Deploy-ProdRelease.ps1` line 211). It doesn't check for gaps. On a DB at 0089 the pending list is `0090 0091 0093 0094 0095`, all above 0089, so there's **no BLOCK and no WARN about 0092**. After this release the high-water mark is `0095`, so a `0092` written later would BLOCK. `PROJECT_STATUS.md` already says never to write it.
3. **Prod's `page-config` must still match `aec53015`.** `page-config` is one whole-project resource, and the import overwrites prod's copy entirely (see § 2.4). Before importing MPP, confirm nobody edited Page Configuration on the prod Gateway since the 2026-09-13 cutover-scan release (`515db6c6`, the last export that carried it). That copy is byte-identical to `aec53015`'s. If someone did, their edit would be silently lost.
4. **Ask Jacques:** does anyone need the Assembly OUT tray projection or the low-inventory toast between the SQL commit and the Ignition import? See Test 4. It's minutes, and it's visible on the live 6MA Assembly OUT screen.

---

## 1. What it does, in plant terms

The six Machining and Assembly screens get a **Line Inventory panel**, a 320 px column docked on the right. It opens on every visit. The six screens are:

- machining-in
- machining-out
- machining (both halves)
- assembly-in
- assembly-serialized
- assembly-nonserialized

**What the panel lists.** Each part the line **consumes** (a consumption-point eligibility row at the line or above it), listed even at zero, plus anything else with stock at the line. Finished goods are never listed.

**What each row shows.**
- The description and how many are **available**. Held and blocking LOTs don't count.
- A colour against the line's **Max** for that part: **orange at or below 30 %**, **red at or below 10 %**, and no colour when no Max is set.
- The most urgent rows sort to the top. Past 12 rows a footer says how many more there are and whether any of them are low.

**What each station sees by default.**
- **Machining** stations see castings (Component).
- **Assembly** stations see bought parts (Pass-Through).
- **Line-wide** shows every part.

**Checking in bought parts.**
- A Pass-Through part with a **Box Quantity** gets a one-tap button (`+5,000`), which creates one Received LOT of that size at the line.
- Without a Box Quantity the button reads `+ LOT` and asks for a count on a numpad.
- Castings get no button.

**Tolerances** (panel header) lists the line's consumption parts with their Max. **Anyone signed in** can set or clear a Max. Every change is audited (`Audit.ConfigLog`, entity `ItemLocation`). Max is also the **check-in cap** that `Lots.Lot_Create` enforces; see Test 1. A Max that lives on an ancestor Area is flagged "Shared: <code>", because editing it changes every line under that Area.

**Config Tool.** Item Master → Identity gains a **Box Quantity** field. It's enabled only for Pass-Through parts, and a blank field clears it.

**What goes away:**

**Assembly OUT (Non-Serialized)**
- The **tray projection sidebar** (on hand vs. what's still needed to finish the current container) is gone.
- The component list that sat under the projection is gone too.

**Assembly OUT (Serialized)**
- The one-line components label is gone.

**Every terminal on the line**
- The **low-inventory toast** used to fire after every tray close when anything was low.
- It's retired: the coloured rows replace it.

**Inventory popup** (the header "Inventory" button)
- It no longer shows finished goods.
- It lists parts by description, not part number.
- The **Receiving Dock** keeps part numbers and finished goods on purpose (they match the packing slip).

**A scope change operators will notice on Assembly OUT.**
- The old sidebar listed every component at the cell, including machined parts.
- The new panel defaults to **bought parts only** there, so machined sub-assemblies and castings appear only under **Line-wide**.
- That's per the spec (§ 3.1, rule 3), but it's worth one sentence to the Assembly OUT operators.

---

## 2. Scope

### 2.1 Versioned migrations

| Migration | DDL | Data | Notes |
|---|---|---|---|
| `0091_line_inventory_sidebar` | `ALTER TABLE Parts.Item ADD BoxQuantity INT NULL` + `CK_Item_BoxQuantity_Positive`. **Also** `ADD LowInventoryHorizon INT NULL` + `CK_Item_LowInventoryHorizon_Positive`. | None (no backfill) | Guarded by `COL_LENGTH`. Records its own `SchemaVersion` row. |
| `0094_retire_low_inventory_horizon` | `DROP CONSTRAINT CK_Item_LowInventoryHorizon_Positive`, `DROP COLUMN LowInventoryHorizon` | None | Guarded by `OBJECT_ID` / `COL_LENGTH`. `BoxQuantity` is kept. |
| `0095_retire_component_projection` | `DROP PROCEDURE Workorder.Assembly_GetComponentProjection` | None | Guarded by `OBJECT_ID`. Its repeatable file is deleted in the same commit. |

**The 0091/0094 pair nets out cleanly on a DB at 0089.** The deploy runs every pending migration in number order inside **one** transaction (`:r` per file, `SET XACT_ABORT ON`), so:

1. 0091 adds both columns and both CHECKs.
2. 0093 runs in between, touching a different table.
3. 0094 drops the horizon CHECK and then the column, and both of its guards find them present.

End state:
- `Parts.Item.BoxQuantity` + `CK_Item_BoxQuantity_Positive` present.
- `LowInventoryHorizon` and its CHECK absent.
- Both `SchemaVersion` rows recorded. 0091's description still mentions the horizon; that's history, not drift.

Adding a column and dropping it again in the same transaction is legal in SQL Server. The horizon never holds a value on prod.

**Idempotency:** all three files re-run as no-ops.

**Safe inside the release transaction:** yes. None contains `BEGIN TRAN` / `COMMIT` / `ROLLBACK` / `ALTER DATABASE`, so the `[3]` transaction-safety check passes.

**Evidence gap:** Dev applied these three **separately**, on different days, with 0093 between them. The single-transaction 0091→0094 sequence is first exercised by the ProdSim rehearsal (§ 4).

**Test 3 -- metadata-only?** Nearly.
- Every nullable `ADD` and every `DROP COLUMN` / `DROP CONSTRAINT` / `DROP PROCEDURE` is metadata-only.
- The one exception is `ADD ... CONSTRAINT CHECK`. It validates existing rows: a single scan of `Parts.Item`, which holds a few hundred rows and isn't partitioned.
- **The real cost is the lock.** From 0091 until COMMIT, `Parts.Item` holds a schema-modification lock, which blocks **every read of `Parts.Item`**. That covers every Part dropdown and every item join on every screen, for the whole transaction (seconds, as the rehearsal's lock window will show).
- The deploy already holds `TABLOCKX` on `Lots.Lot` for the same window, so the plant is paused either way. If a long read holds `Parts.Item`, the ALTER waits up to `LockTimeoutSeconds` and then aborts with nothing written.

### 2.2 Repeatables -- line inventory (vs `192c77c1`)

| Object | Expected `[4]` | Version | Effect |
|---|---|---|---|
| `Lots.Lot_GetLineInventorySummary` | **NEW** | 2.0 | The panel's single read (scope, level, add-lot mode, ordering). |
| `Parts.ItemLocation_ListConsumptionForLine` | **NEW** | 1.1 | Tolerances popup list; `RowLocationCode`/`LineLocationCode` for "Shared". |
| `Parts.ItemLocation_SetMaxQuantity` | **NEW** | 1.0 | Sets **only** `MaxQuantity`. Refuses a row that isn't a consumption point, a Max ≤ 0, or a Max below Min. Audited. |
| `Lots.Lot_GetLineInventoryByPart` | **CHANGED** | 1.3 | Adds `@ExcludeFinishedGoods BIT = 0`, which is opt-in, so existing callers are unaffected. **ORDER BY changed for every caller**: `PartNumber` → `ISNULL(Description, PartNumber), PartNumber` (see § 6). |
| `Parts.Item_Update` | **CHANGED** | 2.7 | Adds trailing `@BoxQuantity INT = NULL`: NULL leaves it alone, 0 clears it. Refuses a negative value, and refuses setting or changing it on a part that isn't Pass-Through. |
| `Parts.Item_Get` | **CHANGED** | 2.5 | Adds a trailing `BoxQuantity` column. |
| `R__Descriptions_ExtendedProperties.sql` (post-commit) | text changed | -- | `Item.BoxQuantity` description (guarded by `COL_LENGTH`) and a reworded `ItemLocation.MaxQuantity`. No horizon entry remains. Documentation only. |

**Dropped:** `Workorder.Assembly_GetComponentProjection`, by 0095. `R__Workorder_Assembly_GetComponentProjection.sql` is deleted from the repo. No SQL module on prod calls it; the only other callers were `sql/tests/0028/094`, also deleted.

**Whole-release `[4]` for reference.** 11 NEW / 14 CHANGED files vs `192c77c1` (ExtendedProperties excluded), which gives about **449 identical, 14 changed, 11 new** if prod matches `192c77c1` exactly. The line-inventory share is the 3 NEW + 3 CHANGED above. **The rehearsal is the authority on these numbers.**

**Two preview lines that look alarming and aren't:**
- **Dropped column.** `[4]` prints `Columns dropped by this release:` / `Parts.Item.LowInventoryHorizon (0094_retire_low_inventory_horizon)`. The column doesn't exist on prod; 0091 creates it earlier in the same run. The dropped-column gate scans the surviving modules and finds no hit: `Item_Update` and `Item_Get` mention it only in change-log comments, and the gate strips comments. **Expect no BLOCK.**
- **Orphan object.** `[4]` emits `WARN repeatables: object on the target with no file in this checkout: workorder.assembly_getcomponentprojection (left untouched)`. The orphan check compares prod's current modules against repo files and only exempts objects a migration **creates**. It doesn't know that 0095 **drops** this one. The WARN is expected; the proc is gone after the run. The last runbook (0089) printed no orphan WARNs, so this should be the only one from this feature.

### 2.3 Ignition resources -- line inventory (`-Since aec53015`)

| Project | Resource | State | Other features in the same resource |
|---|---|---|---|
| Core | `com.inductiveautomation.perspective/stylesheet` | MOD | none (+135 lines, `.psc-pf-inv-*`, purely additive) |
| Core | `named-query/lots/Lot_GetLineInventorySummary` | NEW | -- |
| Core | `named-query/lots/Lot_GetLineInventoryByPart` | MOD (`excludeFinishedGoods`) | -- |
| Core | `named-query/parts/Item_Update` | MOD (`boxQuantity`) | -- |
| Core | `named-query/parts/ItemLocation_ListConsumptionForLine` | NEW | -- |
| Core | `named-query/parts/ItemLocation_SetMaxQuantity` | NEW | -- |
| Core | `script-python/BlueRidge/Lots/Lot` | MOD | attribution `df99b8d5` |
| Core | `script-python/BlueRidge/Parts/Item` | MOD | cutover location-first `1da26dfb` `45c18b95`; attribution `df99b8d5` |
| Core | `script-python/BlueRidge/Parts/ItemLocation` | MOD | attribution `df99b8d5` |
| Core | `script-python/BlueRidge/Workorder/Assembly` | MOD (projection + `warnLowInventory` removed) | attribution `df99b8d5` |
| MPP | `page-config` | MOD | none (see § 2.4) |
| MPP | `views/BlueRidge/Components/PlantFloor/LineInventory` | NEW | -- |
| MPP | `.../PlantFloor/LineInventoryRow` | NEW | -- |
| MPP | `.../PlantFloor/LineTolerances` | NEW | -- |
| MPP | `.../PlantFloor/LineToleranceRow` | NEW | -- |
| MPP | `.../PlantFloor/LineToleranceEdit` | NEW | -- |
| MPP | `.../PlantFloor/AddLotQty` | NEW | -- |
| MPP | `.../PlantFloor/InventoryManager` | MOD (`getInventoryPopupCards`) | attribution `df99b8d5` |
| MPP | `views/BlueRidge/Views/ShopFloor/AppHeaderLarge` | MOD (toast handler removed) | OEE `412d0914` (header downtime indicator) |
| MPP | `views/.../ShopFloor/AssemblySerialized` | MOD (ComponentsPanel removed) | reprint footer `675e000e`; attribution `df99b8d5` |
| MPP | `views/.../ShopFloor/AssemblyNonSerialized` | MOD (InventorySidebar removed) | reprint footer `675e000e`; attribution `df99b8d5` |
| MPP_Config | `views/BlueRidge/Components/Parts/ItemMaster/Identity` | MOD (Box Quantity) | attribution `df99b8d5` |

Every view the new views embed is either in the NEW list or already on prod (`Numpad`, `InventoryManager`). The Receiving Dock view and the Scrap Entry popup are **not** modified. They call `Lots.Lot.getLineInventoryCards` / `getLineInventoryByPart`, which ship inside the modified `Lots/Lot` module with compatible signatures.

Per-file history (`git log --oneline aec53015..HEAD -- <path>`):

| File | Commits |
|---|---|
| `Core/.../Lots/Lot` | `df99b8d5` `67947b9d` `83e58617` `c1121e35` `079ea185` `2cb476cc` `9e4125c5` `f89525fa` `ca1d7424` `98df849e` |
| `Core/.../Parts/Item` | `df99b8d5` `f706a052` `bca73704` `9a9f2311` `ca1d7424` `45c18b95` `1da26dfb` |
| `Core/.../Parts/ItemLocation` | `df99b8d5` `67947b9d` `1905f730` `0a473bcf` `2cb476cc` |
| `Core/.../Workorder/Assembly` | `06415105` `df99b8d5` |
| `MPP/.../AssemblySerialized`, `AssemblyNonSerialized` | `ea4f05eb` `df99b8d5` `675e000e` |
| `MPP/.../InventoryManager` | `ea4f05eb` `df99b8d5` |
| `MPP/.../AppHeaderLarge` | `ea4f05eb` `412d0914` |
| `MPP/.../page-config` | `ea4f05eb` |
| `MPP_Config/.../ItemMaster/Identity` | `7641bc89` `df99b8d5` |
| `Core/.../stylesheet` | `3620bf12` `d977bfa0` |
| `Core/.../AssemblyIn` (MPP view) | `df99b8d5` only. The dock lives in page-config, not the view. |

In a combined release this entanglement is **fine**: each shared file ships once at HEAD with all its features. It matters only for rollback: rolling one of these files back rolls back every feature in its row.

### 2.4 `page-config` -- what rides along

`page-config/config.json` is one resource and the import replaces it whole. Between `aec53015` and HEAD **only `ea4f05eb` touched it**. The cutover routes (`0fbd6ce5`) and the mobile header (`4f3c7610`) are older than `aec53015`, and they shipped in the 2026-09-13 `cutover-scan` export (its `CONTENTS.txt` lists `page-config`). Prod's copy should therefore be identical to `aec53015`'s; see § 0.3.

`ea4f05eb`'s diff, in full:
- A right dock `lineInventory` on each of the six M&A routes, with these settings:
  - `BlueRidge/Components/PlantFloor/LineInventory`
  - size 320, `show: visible`, `content: push`, `handle: hide`, `autoBreakpoint: 480`
  - `viewParams: {terminalRole: ...}`
- **`sharedDocks.cornerPriority: "top-bottom"`** (new). This is shared, so it applies to **every** MPP page. It's probably Perspective's default, which would make it a no-op, and it keeps the top header spanning over the new right dock. It's still a whole-plant change, so the verification in § 5 includes one non-M&A page.
- `/shop-floor/assembly-nonserialized`'s own `docks` block also carries `cornerPriority: "top-bottom"`. None of the other five pages do. It's harmless, but it's an inconsistency.
- `/shop-floor/cutover-scan` loses an empty `"viewParams": {}`. The file loses its trailing newline. Both are harmless.

### 2.5 Deletions -- must be done by hand in the Designer

`Build-ChangeExport.ps1` builds from `git archive` and **cannot remove anything** (lines 89-92 print deletions in red; `CONTENTS.txt` gets a `DELETED in range` section).

| Project | Resource to delete | Why it's safe |
|---|---|---|
| **Core** | named query `workorder/Assembly_GetComponentProjection` | Its proc is dropped by 0095. After the Core import, nothing at HEAD references it. |
| **MPP** | view `BlueRidge/Components/PlantFloor/ComponentProjectionRow` | Only the old AssemblyNonSerialized sidebar embedded it. HEAD has no reference. |

**When:** after **both** the Core and MPP imports and the F5 reloads.
- Deleting earlier gains nothing, because the proc is already gone.
- Deleting the view before MPP is imported would make the old AssemblyNonSerialized sidebar show "View Not Found" on top of its binding error.
- If the deletions are skipped entirely, the orphaned NQ and view sit unused and harmless. But the next full-project export or diff will be confused by them, so do them.

**Builder quirk (observation for Jacques, not fixed).** The builder calls `git diff --name-only --diff-filter=D` **without `--no-renames`**. Git pairs each deleted `resource.json` with a new one:
- `Assembly_GetComponentProjection/resource.json` → `AppUser_GetActiveByAdAccount/resource.json`
- `ComponentProjectionRow/resource.json` → `DieCastShiftConfirm/resource.json`

So the red list shows only 2 of the 4 deleted files:

```
ignition/projects/Core/ignition/named-query/workorder/Assembly_GetComponentProjection/query.sql
ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/ComponentProjectionRow/view.json
```

Both resources are still identified, so the hand step above is correct. But if a future deleted resource had **every** file paired as a rename, the builder would print nothing for it. Adding `--no-renames` to line 89 would close that. Question for Jacques.

### 2.6 Ships nothing

- **SQL tests:**
  - `sql/tests/0008_Parts_Item/010` (mod) and `030`
  - `0009_Parts_Process/070`, `071`
  - `0027_PlantFloor_Machining/100` (mod)
  - `0028_PlantFloor_Assembly/099`
  - `0028/094` (deleted)
- `docs/superpowers/specs|plans/2026-09-17-line-inventory-*`, `mockup/line_inventory_rev2_mock.html`, `mockup/` layout options (`809c8b9e`)
- `notes/`, `PROJECT_STATUS.md`

---

## 3. Risk -- the four tests

### Test 1 -- does anything now refuse what it used to allow?

**`Lots.Lot_Create` v1.7 (added to this release 2026-09-18, Jacques's decision): held stock no longer counts against the cap.** The consumption-point cap itself (section 6b, since v1.1, 2026-08-20) is **already live on prod**. It applies to Received-origin LOTs and works like this:

1. Walk up from the LOT's destination.
2. Take the nearest active `IsConsumptionPoint = 1` row for the part.
3. **If that row's `MaxQuantity` is NULL, it's unrestricted.**
4. Otherwise refuse when `(usable PieceCount already at that exact location) + new pieces > Max`, where usable = not Closed and not a status that blocks production (Hold, Scrap). The message is `... (N usable on hand, held stock not counted; cap M).` Releasing a hold is not a check-in and is never capped, so a release can leave the line over Max; further check-ins are refused until usage brings it back under. This matches the sidebar's Available figure.

`Item.MaxParts` (section 6) is a second, older Received cap.

What this release changes is **who can move the cap, and how many doors lead to it**:
- **Anyone signed in** at an M&A terminal can now set a Max from Tolerances. Before, it was Config Tool only (Eligibility tab). That Max immediately caps **every** Received check-in at that point:
  - the Receiving Dock
  - the Inventory popup check-in
  - the **cutover scan's purchased-part path** (`Cutover.Scan`, Received origin, at the chosen destination)
  - the new one-tap and `+ LOT` buttons

  A Max typed during a cutover session can start refusing that session's box counts at a line.
- **The box rule.** A one-tap check-in fits only while `present + Box <= Max`. A Max set as a reorder point instead of "the most the line should hold" refuses the refill it was meant to prompt. Orange rows need `Max >= Box / 0.7`, and red rows need `Max >= Box / 0.9` (spec § 3.5).
- **Two counts disagree.** The panel's *Available* excludes held LOTs and sums the line and its descendants. Lot_Create's *present* counts **held** stock (non-Closed `PieceCount`) at the **exact** location. A line with held stock can show room on the panel and still refuse a check-in. That's pre-existing cap behaviour, not new, but the panel now puts the two numbers side by side. Question for Jacques: is that intended?
- **Other new refusals:**
  - `Item_Update` refuses a negative `BoxQuantity`, and refuses setting it on a part that isn't Pass-Through. The field is disabled for those parts anyway.
  - `ItemLocation_SetMaxQuantity` refuses a row that isn't a consumption point, a Max ≤ 0, and a Max below Min.
  - All are on new paths.

**Day one: probably no refusals, but only the pre-flight can say so.** I can't read prod. On Dev, 172 consumption rows (all Components at Work Center tier) carry **one** Max between them. Put these in the runbook as **informational** pre-flight and show the output to Jacques. They were checked for syntax against `MPP_MES_Dev`.

```sql
-- (a) Where a Max can exist at all: consumption rows by part type and tier. The Tolerances popup
--     lists ONLY these rows, so a type/tier with 0 rows cannot be coloured or capped from the floor.
SELECT it.Code AS ItemType, lt.Name AS Tier,
       COUNT(*) AS ConsumptionRows,
       SUM(CASE WHEN il.MaxQuantity IS NOT NULL THEN 1 ELSE 0 END) AS WithMax
FROM Parts.ItemLocation il
JOIN Parts.Item i                      ON i.Id = il.ItemId AND i.DeprecatedAt IS NULL
JOIN Parts.ItemType it                 ON it.Id = i.ItemTypeId
JOIN Location.Location l               ON l.Id = il.LocationId
JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
JOIN Location.LocationType lt          ON lt.Id = d.LocationTypeId
WHERE il.IsConsumptionPoint = 1 AND il.DeprecatedAt IS NULL
GROUP BY it.Code, lt.Name
ORDER BY it.Code, lt.Name;

-- (b) Every Max already set, and the headroom Lot_Create would see now at that row's own location.
--     Headroom <= 0 = a Received check-in there is refused today (already true before this release).
--     Caveat: for a row on an Area, the cap is applied per line (count at each line), not at the Area.
SELECT l.Code AS Location, i.PartNumber, it.Code AS ItemType,
       il.MinQuantity, il.MaxQuantity,
       ISNULL(p.Present, 0)                  AS PresentNow,
       il.MaxQuantity - ISNULL(p.Present, 0) AS Headroom
FROM Parts.ItemLocation il
JOIN Parts.Item i        ON i.Id = il.ItemId
JOIN Parts.ItemType it   ON it.Id = i.ItemTypeId
JOIN Location.Location l ON l.Id = il.LocationId
OUTER APPLY (SELECT SUM(x.PieceCount) AS Present
             FROM Lots.Lot x
             JOIN Lots.LotStatusCode s ON s.Id = x.LotStatusId
             WHERE x.CurrentLocationId = il.LocationId
               AND x.ItemId = il.ItemId
               AND s.Code <> N'Closed') p
WHERE il.IsConsumptionPoint = 1 AND il.DeprecatedAt IS NULL
  AND il.MaxQuantity IS NOT NULL
ORDER BY Headroom, l.Code, i.PartNumber;

-- (c) The other Received cap (Item.MaxParts), unchanged by this release but hit by the new buttons.
SELECT i.PartNumber, it.Code AS ItemType, i.MaxParts
FROM Parts.Item i JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
WHERE i.MaxParts IS NOT NULL AND i.DeprecatedAt IS NULL
ORDER BY i.PartNumber;

-- (d) How busy the Received path is (context for how often a cap could bite).
SELECT COUNT(*) AS ReceivedLotsLast7Days
FROM Lots.Lot l JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
WHERE o.Code = N'Received' AND l.CreatedAt >= DATEADD(DAY, -7, SYSUTCDATETIME());
```

Reading the results:
- If (b) is empty, **no check-in on prod can be refused by a Max on day one**. That stays true until someone sets one.
- If (a) shows **no PassThrough rows**, the Assembly panels can't be coloured, and Tolerances has nothing to edit for bought parts, until consumption rows exist (§ 7).
- If (c) is non-empty on a Pass-Through part, that part's box check-ins are already capped by `MaxParts` today.

### Test 2 -- is any of it shared code?

Yes, widely:
- `Lots.Lot` ships whole. It's used by die cast open/release/void, the cutover scan, the Receiving Dock, Scrap Entry, LOT detail and more.
- `Parts.Item` is used by Item Master, the die-cast Part dropdown and cutover.
- `Parts.ItemLocation` is used by the Config Tool Eligibility tab.
- `Workorder.Assembly` is used by every Assembly OUT tray close, **including the PLC-triggered ByWeight/ByVision path** (`plcCompleteTray`), which lost its `warnLowInventory` call.
- The **Core stylesheet** applies to every view (the change is additive).
- `AppHeaderLarge` is on every large shop-floor page.
- `page-config`'s shared docks apply to every MPP page.

Post-deploy must touch at least:
- a die-cast screen
- the Receiving Dock
- Scrap Entry at Assembly OUT (its LOT dropdown must still list finished-good LOTs)
- one tray close
- one non-M&A page

See § 5.

### Test 3 -- is the schema change metadata-only?

See § 2.1. Metadata-only except one small CHECK validation scan. The lock on `Parts.Item` covers the whole release transaction.

**Rollback after commit doesn't need the backup:**
- The dropped column never held data.
- The dropped proc can be recreated from git: `git show 192c77c1:sql/migrations/repeatable/R__Workorder_Assembly_GetComponentProjection.sql`.
- `BoxQuantity` can stay; old Ignition never reads it.

### Test 4 -- does the old Ignition keep working against the new SQL?

**Mostly, with one visible exception on a live screen.** Between the SQL COMMIT and the MPP import, old Ignition runs against the new SQL like this:

- **Assembly OUT (Non-Serialized) -- the live 6MA parallel-run screen.**
  - The old sidebar's `custom.componentProjection` binding calls `Workorder.Assembly.getComponentProjection` → `Common.Db.execList` (which raises) → the NQ → "Could not find stored procedure".
  - It runs whenever a finished good is selected or a container is open, which is the normal state, and again on every `refreshToken` bump.
  - The inventory sidebar goes to a binding error. **The rest of the screen works:** tray completion, container complete and the reprint are separate bindings.
  - After the **Core** import and before the **MPP** import, the same binding fails with a missing-function error instead: the new Core `Workorder.Assembly` no longer has `getComponentProjection`.
- **Every Assembly OUT tray close**, operator ByCount or PLC:
  - Old `warnLowInventory` runs **after** `completeTray` has committed.
  - It catches `(Exception, java.lang.Exception)` and logs `warnLowInventory failed: ...` at WARN.
  - **Tray closes, LOT mints and container completes are unaffected.** Expect one gateway-log warning per tray close in the gap.
- **Nothing else breaks:**
  - The old `Item_Update` NQ omits `@BoxQuantity` (defaults to NULL, which leaves it alone).
  - The old `Item_Get` readers ignore the trailing column.
  - The old `Lot_GetLineInventoryByPart` NQ omits `@ExcludeFinishedGoods` (defaults to 0).
  - The ByPart **sort order** changes at COMMIT: Receiving Dock, Inventory popup and the Scrap Entry dropdown switch to description order.

**New Ignition against old SQL is worse, so SQL must go first:**
- the dock errors on all six pages (proc missing);
- **every Item Master Identity save fails** for every item. The new NQ always passes `@BoxQuantity`, and the old proc has no such parameter ("too many arguments");
- Tolerances fails.

**Instruction for the runbook.** SQL, then import **Core then MPP back-to-back**, then F5 the M&A terminals.
- Do the SQL step when 6MA Assembly OUT is between trays, or warn its operator: "the inventory column on the right will show an error for a few minutes; closing trays is not affected".
- Then do the two Designer deletions.
- The import is not atomic with SQL from a data point of view: nothing refuses and nothing corrupts. It is from a *looks broken* point of view on one live screen.

**Rollback (Ignition side):**
- If the old AssemblyNonSerialized is re-imported, the proc must be recreated first (see Test 3). Re-import the deleted NQ and `ComponentProjectionRow` from an `aec53015` build too.
- Roll `Parts.Item_Update` back **together with** the Identity view, or Item Master saves fail (the new view always sends `BoxQuantity`).
- Because of § 2.3's entanglement, rolling back `Lots/Lot`, `Parts/Item`, `Workorder/Assembly` or the Assembly views also rolls back cutover / attribution / reprint work.

---

## 4. Rehearsal expectations

Rehearse locally at prod's exact SQL state (`05_local_rehearsal.md`):
1. Make a temp worktree at **`192c77c1`** (89 migrations, highest 0089). **Not** `aec53015`.
2. Run `Reset-DevDatabase.ps1` under a unique throwaway name. **Not** `MPP_MES_Test`, which other sessions reset.
3. Preview from HEAD.

Expected, for this feature:

- `[3]`:
  - `Database: 89 applied, highest 0089.`
  - `Pending (5):` `+ 0090_location_is_oee_enabled.sql`, `+ 0091_line_inventory_sidebar.sql`, `+ 0093_printreasoncode_ascii_name.sql`, `+ 0094_retire_low_inventory_horizon.sql`, `+ 0095_retire_component_projection.sql`.
  - No BLOCK, and nothing about 0092.
- `[4]`:
  - the 3 NEW + 3 CHANGED from § 2.2 among the release totals;
  - `Columns dropped by this release: Parts.Item.LowInventoryHorizon (0094_retire_low_inventory_horizon)` with no dropped-column BLOCK;
  - the orphan WARN for `workorder.assembly_getcomponentprojection`.
- `[5]`: no gate exists for 0090-0095, so nothing is printed for them.
- `[8]`: `5 migration(s), 25 repeatable(s) in one transaction` (whole release, if prod matches `192c77c1`).
- **Rehearsal PRINTs, in order:**
  - `Parts.Item.BoxQuantity: present`
  - `Parts.Item.LowInventoryHorizon: present`. It is supposed to say present here: 0091 adds it.
  - `Migration 0091 (line_inventory_sidebar) applied.`
  - `Parts.Item.LowInventoryHorizon: dropped`
  - `Migration 0094 ... applied.`
  - `Workorder.Assembly_GetComponentProjection: dropped`
  - `Migration 0095 ... applied.`
  - then `== checks passed` and `ROLLED BACK`.
- **After a local Execute on the throwaway:**
  - `Every repo migration is recorded.` (94 recorded, highest 0095)
  - `R__Descriptions_ExtendedProperties.sql applied.`
  - all applied repeatables match byte-for-byte.

**Local evidence to date (Dev, 2026-09-17/18):**
- Full SQL suite 3836/3836.
- Line-inventory tests: `0008/030`, `0009/070`, `0009/071`, `0027/100`, `0028/099`.
- The six views loaded in Designer after the file edits: `84449d2e` fixed a missing event `scope` that stopped the view loading, and `19d6e755` replaced `endsWith` with `indexOf`.

**Not yet proven on the floor** (`PROJECT_STATUS.md` "Owed" 1):
- scope and Line-wide on a real terminal;
- a Tolerances save recolouring a **second** terminal within 30 s;
- a check-in over Max refused;
- a one-tap check-in writing a LOT (the in-app browser can't commit inputs, so the UI→DB write is inferred).

**Dev also lacks 0088/0089**, so Dev has **no Pass-Through parts**. The one-tap / `+ LOT` path and the Assembly "Bought parts" scope have **never rendered with real data**. Prod will be their first run. Say so in the guide's verification section.

---

## 5. Post-deploy verification (prod)

Ordered by risk. **Do 3 first:** it's the path Dev couldn't show.

1. **SQL state:**
   ```sql
   SELECT CASE WHEN OBJECT_ID(N'Lots.Lot_GetLineInventorySummary') IS NULL THEN 0 ELSE 1 END          AS Summary,     -- 1
          CASE WHEN OBJECT_ID(N'Parts.ItemLocation_SetMaxQuantity') IS NULL THEN 0 ELSE 1 END         AS SetMax,      -- 1
          CASE WHEN OBJECT_ID(N'Parts.ItemLocation_ListConsumptionForLine') IS NULL THEN 0 ELSE 1 END AS ListCons,    -- 1
          CASE WHEN OBJECT_ID(N'Workorder.Assembly_GetComponentProjection') IS NULL THEN 0 ELSE 1 END AS Projection,  -- 0
          COL_LENGTH('Parts.Item','BoxQuantity')         AS BoxQty,   -- 4
          COL_LENGTH('Parts.Item','LowInventoryHorizon') AS Horizon;  -- NULL
   SELECT MigrationId FROM dbo.SchemaVersion
   WHERE MigrationId IN (N'0091_line_inventory_sidebar', N'0094_retire_low_inventory_horizon', N'0095_retire_component_projection');  -- 3 rows
   ```
2. **Designer:** the NQ `workorder/Assembly_GetComponentProjection` (Core) and the view `Components/PlantFloor/ComponentProjectionRow` (MPP) are gone.
3. **Assembly OUT (Non-Serialized), 6MA** (the live screen, and the only one Dev couldn't populate). F5.
   - The right dock shows "Bought parts at this line".
   - Pass-Through rows carry `+ LOT`, because no Box Quantity is set yet.
   - The old inventory column is gone, and the reprint footer is still there (shared file).
   - **Line-wide** lists the machined parts too.
   - **Complete one tray** (ByCount, or let the PLC close one). It completes normally, with no gateway-log line mentioning `warnLowInventory` or `Assembly_GetComponentProjection`.
4. **The other five M&A pages:**
   - Machining IN / OUT / combined show "Castings at this line".
   - Assembly IN and Assembly (Serialized) show "Bought parts at this line". On Serialized, the old one-line components label is gone.
   - An empty scope reads "None for this station - tap Line-wide", or "Nothing at this line" when the terminal doesn't resolve to a line.
   - No Component Error on any dock.
5. **Tolerances popup:**
   - Open it from the panel; it lists the line's consumption parts ("not set" where no Max exists).
   - Only if Jacques wants a live test: set a Max on one row, confirm the panel recolours (and on a second terminal within 30 s), then **Clear** it. Then check the audit:
     ```sql
     SELECT TOP 2 c.LoggedAt, c.UserId, c.Description, c.OldValue, c.NewValue
     FROM Audit.ConfigLog c JOIN Audit.LogEntityType e ON e.Id = c.LogEntityTypeId
     WHERE e.Code = N'ItemLocation' ORDER BY c.Id DESC;
     ```
     Expect two rows attributed to the signed-in operator, not AppUser 2.
6. **Item Master → Identity** (Config Tool):
   - A Pass-Through part has **Box Quantity** enabled; a Component has it disabled.
   - Saving an unchanged Component item succeeds with no error. The view sends `BoxQuantity` as blank → 0 → no change.
   - Setting a real Box Quantity is MPP's data entry (§ 7). Once one is set, the matching panel row shows `+<qty>`.
7. **Receiving Dock** (keeps `getLineInventoryCards`): "On hand at this station" still shows **part numbers** and still includes finished goods. The rows are now in **description order** (§ 6).
8. **Inventory popup** (header "Inventory" button on any M&A page): no finished goods, parts shown by description.
9. **Shared-code checks (Test 2):**
   - Open a die-cast terminal: header, cavity list and recent LOTs render.
   - At Assembly OUT, open **Scrap Entry**: its LOT dropdown still lists on-hand finished-good LOTs.
   - Open one **non-M&A** MPP page (e.g. Trim): the header and layout are unchanged by the new shared `cornerPriority`.

---

## 6. Caveats and questions for Jacques

**Sort order**
- **The ByPart sort changed for every caller**, not just the Inventory popup: `Lot_GetLineInventoryByPart` v1.3 orders by description.
- The Receiving Dock's list, which is **labelled** by part number, is now **ordered** by description.
- The Scrap Entry LOT dropdown's order changes too.
- `getLineInventoryCards`' docstring says the Receiving Dock "depends on this exact behaviour". The row shape is preserved, but the order isn't.
- Question: is that OK, or should the Receiving Dock keep part-number order?

**Load**
- **Three proc calls per terminal per 30 s.**
  - `LineInventory` binds instances, header and footer separately.
  - Each runs `Lot_GetLineInventorySummary` (two recursive walks plus a LOT aggregate).
  - The header runs it a fourth time when the scoped list is empty.
- Across all M&A terminals it's modest, but it's triple the necessary reads.
- Worth one line in the guide in case the Gateway's DB pool is watched. It's not a blocker.

**Who can change a Max**
- **Anyone signed in can move a check-in cap.** That's open by design (see `PROJECT_STATUS.md` TODO), and it's plant-wide in effect (Test 1).
- The guide should say who is expected to use Tolerances, and that a wrong Max shows up as refusals at the Receiving Dock and the cutover scan, not just as a colour.

**Two ways to open the same popup**
- Every M&A screen keeps its header **Inventory** button, and the panel has its own way into the same popup.
- The build record asks you to decide whether to keep both. That's still open.

**Stale docstring**
- `Lots.Lot.getInventoryPopupCards` still says the InventoryManager switch is "PENDING". `ea4f05eb` did it.
- Cosmetic, and it ships as-is.

**Deletions**
- **Builder rename-pairing:** see § 2.5. Suggest `--no-renames` on the deletion list.

**Working tree**
- **Checked 2026-09-18 by the release session:** every uncommitted file was compared with HEAD as PARSED JSON. All but the gateway session address (`session-props`), manifest `thumbnail.png` entries and signatures are byte-identical in content -- none is a real edit, and none ships (the export builds from git). The original observation follows.
- The shared Dev working tree currently holds **425 uncommitted files** under `ignition/`.
  - Most are Gateway-scan manifest churn: signatures, and `thumbnail.png` re-added to line-inventory manifests.
  - The rest are real edits: `MPP/session-props/props.json`, `MPP_Config/page-config`, `LotDetail/*`, `DieCastOverflow*`, `InspectionEntry`, `LotSearch`, and `ToolCavity_Create/query.sql`.
- The export builds from git, so none of it ships. But confirm none of it is meant to be part of this release before building. `session-props/props.json` is exactly the pickled-live-data trap from `02_scoping_a_release.md` § 3.

---

## 7. Data MPP must enter, and what the screens show until they do

| Data | Where | Until it's entered |
|---|---|---|
| **Consumption points** for the parts each line uses (`IsConsumptionPoint = 1`), especially **Pass-Through parts at the assembly lines** | Config Tool → Item Master → Eligibility (the only place that flag is set) | The panel still lists anything **with stock** at the line, uncoloured. A consumed part with zero stock does **not** appear. Tolerances can't list that part, so no Max can be set for it. Pre-flight (a) shows the starting position. |
| **Max per consumption part per line** | Tolerances on any M&A terminal, or Config Tool Eligibility | No colour, rows sorted by description, footer says "none low", **no check-in cap**. Set it to the most the line should hold, leaving room for a whole box (`Max >= Box / 0.7` for orange refills). |
| **Box Quantity per Pass-Through part** | Config Tool → Item Master → Identity | The row shows `+ LOT` (numpad count) instead of one-tap. Check-in still works. |

Castings get no check-in button in any case; they arrive through machining and moves, not receiving.
