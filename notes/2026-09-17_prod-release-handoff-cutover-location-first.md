# Prod release handoff -- cutover scan: location-first setup

**Written:** 2026-09-17, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`. **Feature commits:** `a0d32be7` (SQL + tests) and `1da26dfb` (Ignition), plus this note.
**Proposed `-Since` for this feature alone:** `485fa593`. Jacques wants this released **together with other pending work** (at least `notes/2026-09-17_prod-release-handoff-tool-shot-count.md`). For the combined release, use the earliest `-Since` of the bundled handoffs; for these two that is `8ba40203`.
**Builds on:** the cutover destination release (`095bb8c3`, runbook `notes/2026-09-14_prod-release-runbook-cutover-destination.md`), which **is** in prod. That release put migration `0083` (`Location.IsCutoverDestination`) and `Location_ListCutoverDestinationsForLine` v1.0 in prod.

This note is the scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. The five deliverables in `01_the_release_contract.md` are still owed.

---

## 0. Check these first

1. **0089 is out.** Commit `daa32e16` records it committed to prod cleanly, which answers the shot-count handoff's § 0. Still confirm `[3]` shows prod at `0089` with nothing pending.
2. **Prod trim-store names.** On 2026-09-17 Jacques **renamed the trim-store locations in prod**. Both procs in this release label `TRIM1-STORE` / `TRIM2-STORE` by **Code**, as `Tumble Trim Storage` / `Blast Trim Storage`, so **the label wins over whatever Name prod now holds**. Read prod's names (gate query in § 3) and show them to Jacques. If they differ from those two strings, he decides whether the CASE should change before release. On Friday 2026-09-18 he is pulling a prod backup to sync config into Dev. Once Dev's names match prod, the CASE can be dropped so Names drive the label. That is a **follow-up, not part of this release**.

---

## 1. What it does, in plant terms

The inventory cutover scan (`/shop-floor/cutover-scan`) now starts by asking **where the stock is**, not which line it belongs to:

- **Location** (previously "Line") lists Warehouse, Blast Trim Storage (Trim Shop 2), Tumble Trim Storage (Trim Shop 1), then every production line. It **opens on Warehouse**.
- **A store picked:** Entry Step and Destination are hidden, and the store is the destination. The entry step is Machining IN behind the scenes; finished goods and purchased parts have no such route step and get no entry sequence, exactly as before. **Warehouse lists every active part**; a trim store lists the parts eligible at its shop.
- **A line picked:** Entry Step and Destination appear. After a part is chosen, Destination **defaults to the trim store where that part is eligible** (Tumble wins if both, the line if neither). Stock goes to the line only if the operator changes it.
- The latched header says "Location" and hides the entry-step pill for a store.
- **Cast date** is Ignition's popup date picker, with the ‹ › day arrows kept. A future date is still refused by `Lot_Create`.
- **After Add basket** the LTT field keeps all but its last 4 characters (it used to clear). Piece count clears; cavity and date stay set, as before.
- Everything is shorter and tighter so the setup and entry panels fit without scrolling.

---

## 2. Scope

### Versioned migrations
**None.**

### Repeatables
| Object | State on prod (expected) | Effect |
|---|---|---|
| `Location.Location_ListCutoverSources` (`R__Location_Location_ListCutoverSources.sql`) | **NEW** | The Location dropdown. |
| `Parts.Item_ListForCutoverLocation` (`R__Parts_Item_ListForCutoverLocation.sql`) | **NEW** | The Part dropdown (the warehouse gets every part). |
| `Location.Location_ListCutoverDestinationsForLine` | **CHANGED** v1.0 -> v2.0 | Optional `@ItemId`; `IsDefault` follows the part's trim shop; a store is its own default; Tumble/Blast labels. |

`[4]` should list exactly these three for this feature. Anything else is either from the other bundled handoffs or unexplained; read its diff.

### Ignition resources (built 2026-09-17 with `-Since 485fa593`)
| Project | Resource | State |
|---|---|---|
| Core | `named-query/location/CutoverDestination_ListForLine` | MOD (adds `itemId`) |
| Core | `named-query/location/CutoverSource_List` | NEW |
| Core | `named-query/parts/Item_ListForCutoverLocation` | NEW |
| Core | `script-python/BlueRidge/Cutover/Scan` | MOD |
| Core | `script-python/BlueRidge/Location/Location` | MOD |
| Core | `script-python/BlueRidge/Parts/Item` | MOD |
| MPP | `views/BlueRidge/Views/ShopFloor/_CutoverScan/Desktop`, `/Phone`, `/Tablet` | MOD |
| MPP | `views/BlueRidge/Components/PlantFloor/Cutover/CavityToggle` | MOD (tile 64 -> 48 px) |

Expected: `Core 6 resource(s), 13 entries` and `MPP 4 resource(s), 9 entries`; MPP_Config skipped. The builder drops `thumbnail.png` from two manifests; that's expected. **No deletions.** Rebuild at the real release commit together with the other bundled features. Import **Core first**, then MPP.

The three view JSONs were **rewritten by a JSON round-trip** and are fully reindented, so a text diff is huge. A structural diff against `095bb8c3` shows only the listed changes.

### Ships nothing
`sql/tests/0070_Cutover_EntryRoute/080_*.sql` (updated) and `090_*.sql` (new), `PROJECT_STATUS.md`, `notes/`.

---

## 3. Risk -- the four tests

**Test 1: does anything now refuse what it used to allow?**
- `loadSession` now returns "Pick where the stock is counted in." when the destination list is empty (only possible for a deprecated or unknown location). It used to fall back to the line. That isn't reachable from the dropdowns.
- The Part list at a **line** is unchanged (eligibility). At a **store** it is new behaviour, not a refusal.
- No SQL proc gained a rejection. **No blocking gate.** Add this **informational pre-flight** to the runbook and show the output to Jacques:
  ```sql
  -- (a) the three stores the Location dropdown leads with; expect WHSE, TRIM1-STORE, TRIM2-STORE
  SELECT l.Code, l.Name, p.Name AS Parent
  FROM Location.Location l LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
  WHERE l.IsCutoverDestination = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Code;
  -- (b) parts eligible up each store's chain. WHSE must be 0 for "every part" to apply;
  --     trim stores at 0 mean no part will ever default to a trim store.
  SELECT l.Code, COUNT(DISTINCT e.ItemId) AS EligibleParts
  FROM Location.Location l
  OUTER APPLY (SELECT eil.ItemId FROM Parts.v_EffectiveItemLocation eil
               JOIN Location.ufn_AncestorLocationIds(l.Id) a ON a.LocationId = eil.LocationId) e
  WHERE l.IsCutoverDestination = 1 AND l.DeprecatedAt IS NULL GROUP BY l.Code;
  ```
  If (a) doesn't return all three codes, stop. The sources proc keys the default on `WHSE`, and the labels key on the two store codes.

**Test 2: is any of it shared code?** Yes. All three script modules ship whole.
- `BlueRidge.Location.Location` is used across the Config Tool (plant hierarchy editor) and every terminal. Only the cutover functions changed or were added, and the old `getCutoverDestinationDropdown(lineId)` call shape still works.
- `BlueRidge.Parts.Item`: `getEligibleForLocationDropdown` was refactored to share `_partOptions`, with identical output, and the module gained `import java.lang`. Its other callers are the **die-cast entry Part dropdown** and the Config Tool **Item Master**. Post-deploy verification must touch one of them (§ 5).
- `BlueRidge.Cutover.Scan` is only used by the cutover screen and `Common.Barcode` (camera routing; `applyScan` is unchanged).

**Test 3: is the schema change metadata-only?** There's no schema change.

**Test 4: does old Ignition work against new SQL?** **Yes.** The old NQ passes only `@LineLocationId`; `@ItemId` defaults to NULL, so the line stays the default, as before. The two new procs have no old callers. **New Ignition against old SQL:** the Location and Part dropdowns come up empty (missing procs) and Destination fails ("too many arguments"). **Deploy SQL first**; after that, the two steps don't need to happen together.

**Rollback:** re-import the previous versions of the 6 Core and 4 MPP resources from `095bb8c3`, re-apply `R__Location_Location_ListCutoverDestinationsForLine.sql` from `095bb8c3`, and optionally drop the two new procs. There's no data to unwind; LOTs counted in the meantime are real.

---

## 4. Rehearsal expectations

Rehearse at prod's exact state (`05_local_rehearsal.md`). Expected for this feature:
- `[3]` 0 pending (see § 0.1).
- `[4]` 2 NEW + 1 CHANGED as in § 2.
- `[5]` nothing new.

**Local evidence (Dev / `MPP_MES_Test`, 2026-09-17):**
- `0070_Cutover_EntryRoute` 97/97 (15 in 080, 12 in 090).
- The procs return this on Dev: sources `WHSE` (default), `TRIM2-STORE` "Blast Trim Storage", `TRIM1-STORE` "Tumble Trim Storage", then lines.
- Browser run on Dev, with no LOTs created:
  - Opens on Warehouse with Entry Step and Destination hidden.
  - MA1-5GOF shows both.
  - Part `5G0-c` defaults the destination to Blast Trim Storage.
  - Start Session works; ‹ moves the date; the picker sets a date and ‹ works after it.
  - Switching to Tumble Trim Storage hides both fields and clears `5G0-c` (not eligible at Trim Shop 1).
  - No gateway log errors.
- **Not exercised live:** Add basket (it would create a Dev LOT). The LTT trim and date coercion were checked with a stubbed-DB harness only.

Don't rehearse on `MPP_MES_Test`; other sessions reset it. Use a unique throwaway name.

---

## 5. Post-deploy verification (prod)

1. **SQL present:** `OBJECT_ID(N'Location.Location_ListCutoverSources')` and `OBJECT_ID(N'Parts.Item_ListForCutoverLocation')` are both non-NULL.
2. **Cutover screen, store path:**
   - Open `/shop-floor/cutover-scan`. Location shows **Warehouse**, and there's no Entry Step or Destination.
   - The Part list is long (every part).
   - Pick Tumble Trim Storage; the Part list becomes the Trim Shop 1 parts.
3. **Cutover screen, line path:**
   - Pick a line: Entry Step and Destination appear.
   - Pick a cast part Jacques names: Destination shows its trim store.
   - Start Session: the header shows the location, the step pill, and the destination.
4. **Basket (only if Jacques wants a live test):**
   - Scan or type an LTT, pick a cavity, count, Add basket.
   - The LTT field keeps all but its last 4 characters.
   - The LOT lands at the chosen destination: `SELECT TOP 1 LotName, CurrentLocationId, CastDate FROM Lots.Lot ORDER BY Id DESC`.
   - Void the test LOT from the session list afterwards, as the 09-14 release did.
5. **Shared-module check (Test 2):**
   - Open a die-cast terminal: its Part dropdown still lists parts (`getEligibleForLocationDropdown`).
   - Open Config Tool -> Items: the list loads.

---

## 6. Known caveats to tell Jacques

- **Keyboard-wedge scanners and the kept LTT prefix.** A camera scan replaces the field; a wedge scanner *types into* it, which would append a full barcode after the kept prefix. It's fine if operators key only the tail or use the camera. Otherwise it needs a follow-up.
- The date picker still shows a small hour/minute spinner despite `pickerMode: date`. It's cosmetic; `Lot_Create` stores a `DATE`.
- Changing Location or Part recalculates Destination, replacing a manual destination pick.
