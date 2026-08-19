# Backlog — CRT + shop-floor items (captured 2026-08-19)

Raw backlog handed over by Hunter on 2026-08-19, recorded verbatim in intent so
work can be picked up later without re-deriving it. Branch at capture time:
`hunter/explore` @ `3f9f9fa0`.

Status legend: **OPEN** (not started) · **WIP** · **DONE** · **BLOCKED** (needs a
decision from MPP or Hunter).

---

## 1. CRT — needs a design conversation before any code

**BLOCKED — do not implement from this note alone.** The existing CRT work on this
branch (`Container_ValidateCrt`, the assembly-out validation button, the
changeover-popup CRT switch) is *container*-scoped. The requirement below is
*part*-scoped and materially larger.

Requirement as stated:

- CRT is normally **part based**. A "CRT enabled" flag on the part; **any LOT of
  that part created while the bit is on is stamped `CRTActive`**.
- On LOT creation → **popup** telling the operator the LOT is marked CRT.
- On any later attempt to use that LOT **at a different terminal** → **popup that
  blocks use** until cleared.
- **Only a Quality person can clear it** (elevated / role-gated action).
- A **machined** part marked CRT: when a LOT is created from it, the **new label
  must carry the CRT mark**.
- **CRT at assembly out** behaves the same, and its **label must also include CRT**.

Open questions to resolve with Hunter/MPP first:
- Where does the part-level flag live — `Parts.Item`, `ContainerConfig`, or a new
  `Parts.ItemCrt` with effective dating? Needs history: "which LOTs were minted
  while the bit was on" must stay answerable after the bit is turned off.
- Does `CRTActive` propagate through genealogy (casting → SubAssembly → FG), or is
  it re-evaluated from the part flag at each mint?
- "Different terminal" — does the *originating* terminal stay unblocked
  deliberately, or is that incidental?
- Clearing: per-LOT, per-container, or bulk-by-part? Audit shape?
- Label change: ZPL template variant vs. a conditional field on the existing
  template. Affects `Lots.LotLabel` + the Zebra templates.
- Interaction with the existing container-scoped CRT already built — replace,
  or coexist?

## 2. Die Cast — Record Shift Output screen

| # | Item | Status |
|---|---|---|
| 2.1 | Pre-populate the reporting shift with the **current** shift | OPEN |
| 2.2 | Cavity name must show the **actual cavity name**, not "Cavity 1" | OPEN |
| 2.3 | Remove the **limit on scrap reasons** per cavity | OPEN |
| 2.4 | Operators should **not see released lots** on record shift output | OPEN |
| 2.5 | Good-pc entry field → **display only** (no longer operator-editable) | OPEN |
| 2.6 | Better use of space for cavities (layout explore) | OPEN |
| 2.7 | Remove the extra comments/instruction text on the die cast screen | OPEN |

## 3. Die Cast — behaviour / back end

| # | Item | Status |
|---|---|---|
| 3.1 | Defect codes offered at die cast must be **die-cast codes only** | OPEN |
| 3.2 | **Die total shots does not increment** when Register Shot Loss is used | OPEN |
| 3.3 | Multiple terminals on the **same die cast machine** must see each other's entries | OPEN |
| 3.4 | **Bulk open of baskets**: a row per cavity on the mounted tool, auto-assign a part per row from the cavity name, operator scans each basket's LTT | OPEN |
| 3.5 | Die cast **supervisor dashboard** — registered production total, current + previous shift (explore) | OPEN |

## 4. Auth / permissions

| # | Item | Status |
|---|---|---|
| 4.1 | Only a **supervisor** may edit or void a downtime event | OPEN |
| 4.2 | **Sort cage** needs an elevated-access requirement | OPEN |
| 4.3 | Elevated access must authenticate against the **Active Directory** user source, not the MPP internal source | OPEN |

> 4.3 relates to `AppUser.elevate` / `_validateAdCredentials`. Note the interim
> `system.security.validateUser(..., _DEV_USER_SOURCE)` path added in `ebc70495`
> — that is the thing being replaced.

## 5. LOT / Lot Detail

| # | Item | Status |
|---|---|---|
| 5.1 | **8-digit LTT** at machining and die cast — the current 9-digit check is wrong there | OPEN |
| 5.2 | **Scrap tab on Lot Detail** — attribute scrap to a LOT against its *current location* (die cast → die cast, warehouse → warehouse, …). All defect reasons available, not a filtered subset | OPEN |
| 5.3 | **Rectify LOT counts** in Lot Detail when entered wrong, with a mandatory reason | OPEN |

## 6. OEE / shifts

| # | Item | Status |
|---|---|---|
| 6.1 | **Shift override screen** — let an operator extend a shift on a given day for a *specific piece of equipment*. Affects OEE. Resolution order: for a given day, if the equipment has an override use it, else fall back to the global shift | OPEN |
| 6.2 | **Validate the shift hours** used by the downtime report | OPEN |

## 7. Styling

| # | Item | Status |
|---|---|---|
| 7.1 | Checkbox component **label text is dark grey**; should match the rest of the app | OPEN |
| 7.2 | **Trim IN** — left-side flex container to 50% width, to make room for the scrap reason rows | OPEN |

---

## Context worth carrying forward

- **Audit merges from Designer-edited branches.** Four defects on 2026-08-19 traced
  to one merge (`56af3f84`), all from Designer saves silently dropping structure:
  a `script-python` module in MPP shadowing Core, four dropped `custom.*` bindings
  on AssemblyNonSerialized, a missing `paramDirection` on `CavityLotRow`, and six
  missing `ScrapQty` blur handlers. Diff *structure* (propConfig key sets, param
  directions, `events` blocks) against `main` — and check sub-views, not just the
  screen being reported.
- **AD elevation wants a re-test.** The AppUser shadow's `elevate` ran stale code
  and failed silently. Fixed in `54fffbcd`, not re-verified.
- **Known-open, pre-existing:** `sql/tests/0022_PlantFloor_DieCast/070_Lot_GetLatestForToolCavity.sql`
  errors out (stale fixture, 2026-07-06 eligibility-tier decision);
  `ia.display.inline-frame` not registered on the gateway; `var(--mpp-accent)`
  referenced by 11 MPP_Config views but never defined; `sql_best_practices_mes.md`
  omits `JSON_QUERY` in its resolved-FK example that 82 procs use;
  `MachiningEntry/ScrapLineRow` still the pre-refactor twin of the Trim row.
