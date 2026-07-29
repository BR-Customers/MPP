# Working Notes

**Date:** 2026-07-10
**Author:** Jacques Potgieter (working session)

---

## Item Master — item selection list

1. **Item selection is not sorted.** Sort the item list by ItemType in this exact order:
   1. Raw Material
   2. Component
   3. Sub-Assembly
   4. Finished Good
   5. Pass-Through

   (Not alphabetical, not by PartNumber — group/order by ItemType in the sequence above.)

2. **Need a way to reset the filter.** Add a filter reset control to the item list.

### Implementation pointers (for whoever picks this up)
- Screen: `/items` → `BlueRidge/Views/Parts/ItemMaster` (item list is the `ItemRow`
  flex-repeater; source is `BlueRidge.Parts.Item.getAllForList` → NQ `parts/Item_List`
  → `Parts.Item_List`).
- Ordering is domain logic, so drive it in SQL, not Python (per `feedback_no_business_logic_in_python`):
  order `Parts.Item_List` by an ItemType ordinal. `Parts.ItemType` has no explicit sort
  column today — either add a `SortOrder`/ordinal to `Parts.ItemType` (seed the 5 codes in
  the order above) or `ORDER BY CASE it.Code WHEN 'RawMaterial' THEN 1 ... END, PartNumber`.
  Confirm the exact ItemType `Code` values against the seed before wiring the CASE.
- Filter reset: mirror the Config-Tool pattern already used elsewhere (e.g. Downtime Codes /
  Audit browser have an explicit Reset that clears `view.custom.filter` back to its empty
  shape and re-applies). The dropdown's built-in clear `×` (`noSelectionText`) is the
  one-click option if the filter is a single dropdown; a dedicated Reset button clears all
  filter fields at once.

---

## Routes config — layout

- **Scroll bar on routes config is not needed — build to fit.** Remove the inner scroll on
  the Routes config surface; size the layout to fit its content instead of introducing a
  scrollbar.
  - Likely culprit: a fixed height / `overflow: auto` on the route-steps container (Item
    Master Routes tab `BlueRidge/.../ItemMaster/Routes`, or the MPP_Config Routes editor).
    Let the steps list grow to fit (`basis: auto`, `grow`) rather than clipping with a
    scroll region.

---

## Route-legality validation — consume/creation event semantics need refinement

The consume-mint route rule is **partly** right but needs work. The event semantics differ
by ItemType and the current check doesn't capture that:

- **A Sub-Assembly** has its **first/creation event where it is created** (it is minted at a
  Machining OUT). It does **NOT** need an event at *its own consumption* (when the SA is later
  consumed into the FG at Assembly OUT).
- **A Finished Good MUST have an event at its creation** — Assembly OUT.

**Observed:** when testing a route with **both Machining OUT and Assembly OUT** consume steps,
publish rejected with:

> "A route may contain at most one consumption step and it must be the final step."

That is **partly correct but not the whole story** — we need to work on this.

### Context / where to work
- Validation lives in `Parts.RouteTemplate_Publish` (route-legality checks). Per CLAUDE.md
  (Terminal-mint section) + spec `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md`,
  the current checks are **structural only** ("non-FinishedGood routes must end at a
  ConsumeMint; at most one ConsumeMint, which must be last; OriginMint first"), and the
  **full `ItemType` × `OperationRoleKind` matrix was explicitly deferred**. This note is that
  deferred matrix surfacing.
- Model reminder (Model Y): the consume-mint is the **final step of the *consumed* part**.
  Casting route `…→MachiningIn→MachiningOut` (MachiningOut mints the SubAssembly). The
  SubAssembly's route picks up *after* birth (`AssemblyOut` mints the FG). FGs are unrouted.
  So a single route carrying **both** MachiningOut and AssemblyOut consume steps conflates two
  parts' identities — need to define exactly what's legal per ItemType (Raw Material /
  Component / Sub-Assembly / Finished Good / Pass-Through) and per role
  (Advance / OriginMint / ConsumeMint), and reconcile the error message + the check with the
  "SA creation-event, no SA-consumption-event; FG creation-event at Assembly OUT" rule above.

---

## Container config — needs to be 1-to-many (per customer)

- **Need to accommodate a 1-many container config.** Some lines have **multiple closure
  methods**, and which one applies **depends on which customer they are producing for**.
- Today `Parts.ContainerConfig` is effectively **1:1 with the Item** (single `ClosureMethod`
  = ByCount / ByWeight / ByVision, plus `TargetWeight` / `MaxParts`; migration `0005`). That
  can't represent "same part/line, different closure method per customer."

### Direction to work out
- Model container config as **1-to-many** keyed by **customer** (and possibly line): one Item
  can carry several ContainerConfig rows, each with its own ClosureMethod / target, selected
  by the customer being produced for.
- Open questions to settle before building:
  - What is the "customer" entity here — is there a Customers table (legacy MES has
    `reference/legacy_mes_extract/customers.csv`), or is it derived from the order/Honda?
  - Selection key: customer only, or (customer × line/location)?
  - How does the plant-floor closure flow pick the right config at run time (which customer is
    the LOT being produced for)?
  - Migration impact: new child table (e.g. `Parts.ContainerConfig` gains a CustomerId +
    relaxed uniqueness, or a new `Parts.ContainerConfigVariant`) + Item Master Container
    Config tab becomes a list/editor instead of a single form.

---

## Trim OUT — destination dropdown broken

- **The destination dropdown on Trim OUT is broken.** We tried to filter it by the part's
  eligibility and that appears to have broken it.
- **Want:** default the dropdown to the **first option**. Most of the time there will only be
  one option anyway.

### Where to look
- Trim OUT view: `BlueRidge/Views/ShopFloor/TrimBody` (OUT tab destination dropdown).
- The eligibility-filter attempt is almost certainly the new
  `Location_ListMachiningDestinationsForItem` NQ (`ignition/.../named-query/location/
  Location_ListMachiningDestinationsForItem`) + proc `Location_ListMachiningDestinations`
  (both came in via Hunter's branch, now on `main`). Check the binding is passing a valid
  `itemId` and that the proc returns rows for the LOT's part — a broken/empty result is the
  likely cause of the "broken" dropdown.
- Fix: on load, set `props.value` to the first option's value when options are non-empty
  (guard for 0 options). Confirm the dropdown options binding actually resolves before
  defaulting.

