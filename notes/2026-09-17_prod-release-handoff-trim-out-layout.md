# Prod release handoff -- Trim OUT compact layout

**Written:** 2026-09-17, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`. **Feature commits:** `272dafc7` (layout), `1d678f36` (container renames), `1fd6ffe8` (ScrapLineRow manifest signature), plus this note.
**Proposed `-Since`:** `c76f939a`. If this ships bundled with other pending handoffs, use the earliest `-Since` of the bundle.
**Builds on:** nothing that isn't already in prod. This release has no SQL and depends on no unreleased proc or column.

This note is the scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. The five deliverables in `01_the_release_contract.md` are still owed. The release is small, but the contract still applies.

---

## 0. Check these first

1. **The `c76f939a..HEAD` range contains commits that are not this feature.**
   - `fb61f627` changes `R__Workorder_DieCast_GetShiftOutputBreakdown.sql` (die cast: a released basket proposes 0 good). `Deploy-ProdRelease.ps1` will list it under `[4]` as CHANGED.
   - `02079cbf` is docs only.
   - Anything else committed later from other sessions will also be in the range.

   **Ask Jacques whether `fb61f627` ships with this release.** It belongs to the die-cast work, not to Trim. If it stays out, the release commit has to exclude it.
2. **`InventoryRow` is shared, and it changed shape. Get Jacques's call before release.** Besides Trim, `Components/PlantFloor/Trim/InventoryRow` is used by:
   - `Components/PlantFloor/InventoryManager` (`OnHandRepeater`)
   - `Views/ShopFloor/ReceivingDock` (`OnHandRepeater`)

   This release changes the row in two ways:
   - Its default height goes from 92 to 64 px, with tighter padding.
   - The **`Position` label ("Position 1 - oldest") is removed**.

   Both of those screens still give each row a **92 px** slot (`elementPosition.basis`) and still pass `position` from `BlueRidge.Lots.Lot.getLineInventoryCards`. After release they will show a shorter card in a taller slot and **no FIFO position text**. Jacques signed off the Trim screen but was not asked about these two screens. Either:
   - confirm the loss of the position label is acceptable there, or
   - hold `InventoryRow` out of the release and restore the label (for example, make it conditional on a param).

   Check both screens on Dev before deciding.

---

## 1. What it does, in plant terms

On the Trim Station **Trim OUT** tab (`/shop-floor/trim` and `/shop-floor/trim/dedicated`, both of which embed `TrimBody`):

- **Scrap tiles:** the reason tiles now **wrap** into a grid that fits the column, instead of running off the right edge behind a scrollbar. When the list is long, the grid scrolls inside its own box and **More reasons / Show Trim reasons only** stays visible below it.
- **Scrap lines:** the list takes the remaining width, so its +, − and ✕ buttons are no longer clipped at the right edge. With many lines the list scrolls and the **Trim OUT** button stays visible.
- **Scrap tile and line row:** both are tighter to suit the denser layout.
- **Inventory cards:** shorter, with no "Position N" label (see § 0.2). On Check IN, the space where the hidden Select button sits is blank.

There are no functional changes. The scripts, bindings, named queries and procs are untouched.

---

## 2. Scope

### Versioned migrations
**None.**

### Repeatables
**None from this feature.** Anything `[4]` lists comes from other commits in the range (§ 0.1).

### Ignition resources (built 2026-09-17 with `-Since c76f939a`)
| Project | Resource | State |
|---|---|---|
| MPP | `views/BlueRidge/Views/ShopFloor/TrimBody` | MOD (layout + renames) |
| MPP | `views/BlueRidge/Components/PlantFloor/TrimEntry/ScrapCodeTile` | MOD |
| MPP | `views/BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow` | MOD |
| MPP | `views/BlueRidge/Components/PlantFloor/Trim/InventoryRow` | MOD (shared; see § 0.2) |

Expected builder output:

```
Core         no changed resources -- skipped
MPP            4 resource(s),   9 entries
MPP_Config   no changed resources -- skipped
4 manifest(s) rewritten to drop an excluded file (thumbnail.png).
```

**No deletions. No Core resources.** Rebuild at the actual release commit.

**Renames inside TrimBody (`1d678f36`):**
- `OutScanField/FlexContainer` → `ScanCol`
- `CountsRow/FlexContainer` → `ScrapTileCol`
- `CountsRow/FlexContainer_0` → `ScrapLinesCol`
- The duplicate, unbound `ShotField/ActiveLotLabel` → `ShotSpacer`

No script addresses any of these by name (checked for `getChild` / `getSibling` / name references).

**TrimBody custom defaults:** Designer had saved the live scrap-tile catalog (38 rows), `scrapMoreCount: 13` and `trimState: "out"` into the view, and had dropped the `defectCodeTiles: []` default. These were reset to the committed shaped-empty values before `272dafc7`. Confirm this in the built archive: `custom.scrapTiles` should be `[]` and `custom.trimState` should be `"in"`.

### Ships nothing
`notes/`, `PROJECT_STATUS.md`.

---

## 3. Risk -- the four tests

**Test 1: does anything now refuse what it used to allow?** No. The changes are layout only. **No gate needed.**

**Test 2: is any of it shared code?**
- `TrimBody` is used by both Trim pages. Verify both.
- `ScrapCodeTile` and `ScrapLineRow` under `TrimEntry/` are used only by `TrimBody`. (Die cast has its own `DieCastEntry/ScrapLineRow`, which is untouched.)
- **`InventoryRow` is shared.** See § 0.2; post-deploy verification must open the Inventory Manager and the Receiving Dock screen.

**Test 3: is the schema change metadata-only?** There's no schema change.

**Test 4: does old Ignition work against new SQL, and new against old?** Yes in both directions. Nothing on the SQL side changed for this feature, so there's no ordering constraint of its own.

**Rollback:** re-import the four resources as they were at `c76f939a`. There's no data to unwind.

---

## 4. Rehearsal expectations

Rehearse at prod's exact state (`05_local_rehearsal.md`). For this feature alone:
- `[3]` 0 pending.
- `[4]` nothing, apart from whatever other commits in the range contribute (§ 0.1).
- `[5]` nothing new.

**Local evidence (Dev, 2026-09-17), in-app browser.** Terminal `TRIM1-T1` was picked on `/shop-floor/terminal-selector`; operator was Dev User.
- **Check IN:** lists the four Trim Shop 1 LOTs with their status badges.
- **Trim OUT, picking a LOT:** the HOLD LOT can't be selected. Selecting 000000021 fills the lot count (998) and shows the tiles.
- **Scrap tiles:** tapping one adds a line and a +N badge.
- **Scrap line buttons:** +, − and ✕ keep the lot count and the "pcs scrap" total correct.
- **More reasons toggle:** works, and the grid scrolls to the extended reasons.
- **Stress (10 lines):** the lines list scrolls, the Trim OUT button stays visible, and rows fit edge to edge (lot count 988).
- **1366x768:** the tiles drop to 2 columns, both buttons stay visible, and descriptions end in "…".
- **Console:** no errors.
- **Jacques then ran his own checks, including the submit path, and signed off.**
- **Not checked:** Inventory Manager and Receiving Dock (§ 0.2).

---

## 5. Post-deploy verification (prod)

1. **Trim OUT layout:**
   - Open a Trim terminal and go to the Trim OUT tab.
   - Select a LOT: the tiles wrap within the column, and **More reasons** is visible under the grid.
   - Tap three or four reasons: the lines appear with the ✕ fully visible, and the lot count drops by the scrap total.
   - Clear the lines, **or** record a Trim OUT if Jacques wants a live test.
2. **Dedicated page:** `/shop-floor/trim/dedicated` renders the same body.
3. **Shared `InventoryRow`:**
   - Open the Receiving Dock screen and an M&A Inventory Manager.
   - The on-hand cards render, with no Component Error. The position label is absent, as agreed in § 0.2.

---

## 6. Known caveats to tell Jacques

- **"LOT # selected" with nothing selected.** With no LOT picked, the helper under the scan box reads "LOT # selected". This predates the release: `custom.activeLotId` defaults to `""`, not null, so the "No LOT selected" branch never fires. A follow-up can make the expression test for empty as well as null.
- **Blank gap on Check IN cards.** There's an empty space at the left of each card, where the Select button is hidden.
- **`ScrapHeaderRow` placement.** The "SCRAP REASONS - TAP A REASON TO ADD 1" header sits at the bottom of the form column, below the tiles. This was kept as Jacques laid it out.
