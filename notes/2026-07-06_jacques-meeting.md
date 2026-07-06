# Meeting Notes — Jacques

**Date:** 2026-07-06
**Note-taker:** Hunter (live capture)

---

## Die Cast terminal — refresh button for mounted tool
Add a **refresh button** on the Die Cast terminal page that re-fetches / refreshes the **currently mounted tool**, so the displayed mounted tool updates without reloading the whole screen.

## Die Cast — cavity dropdown scales weirdly on selection
When the operator **selects a cavity**, the cavity **dropdown scales/resizes oddly** (visual glitch). Die Cast entry screen.

## Die Cast entry — prepopulate default part count (and weight) from the part
On Die Cast entry, **part count** should prepopulate with a **default = the part's parts-per-basket**. Same for **weight** — prepopulate its default from the part **if it exists**.

## Create LOT popup — button spacing off
On the **Create LOT** popup, the spacing of the **Create LOT buttons** is off (needs a spacing fix).

## Die Cast — "Cavity this shift" dropdown showing more than expected
The **"Cavity this shift"** dropdown on Die Cast needs to be checked — it's **showing more entries than expected**.

## Die Cast — "Shots this shift" is null
The **"Shots this shift"** value is showing **null** (should show a count).

## Die Cast — "Shots this shift" should also reflect scrap
"Shots this shift" should **also reflect scrap** (include/account for scrap, not just good shots).

## Die Cast — verify reject entry is scoped to the selected cavity
Check whether **reject entry** is recorded **in the context of the selected cavity** (should be cavity-scoped).

## Die Cast — consolidate the three right-side cards into one
The **three cards on the right** should be replaced with **one card** instead.

## Die Cast — able to run a part with no operation template 🐞
Was able to **run a part in Die Cast even when there was no operation template** for it. Should be gated — running a part without an operation template should not be allowed.

## Operation template selection dropdown — not scoped by area
The **operation template selection dropdown** is **not scoped by area** — it should filter to templates for the current area. (Note: post OperationType restructure, ops are area-agnostic / role-classified — dropdown scoping needs to reflect the new model.)

## Routes — Data Collection column empty on create screen (populates on published)
On the **Route create/edit screen**, the **Data Collection column does not populate**, but it **does populate on the published (view) screen**. Inconsistency between the draft/create view and the published view.

## Eligibility — printers should not appear in the location dropdown
**Printers should not be listed** in the **eligibility location dropdown** (filter out Printer-kind locations).

## Trim IN — confirm available cells are terminals, not printers
On **Trim IN**, confirm the **available cells** are **terminals** and **not printers** (verify the cell/location list excludes Printer-kind).

## Terminal selection table — default to 100 rows + add search bar
On the **terminal selection** table: **default to 100 rows** and **add a search bar**.

## Remove FDS commentary from all Perspective views
**No FDS commentary should be visible on any Perspective view** — strip any FDS references / spec commentary text from operator-facing screens.

## Eligibility — should target Area + Production Line, not terminals/printers
Eligibility should be configurable at the **Area** and **Production Line** tiers, **not** at **terminals** or **printers**. The eligibility location list should offer Area / WorkCenter (line) tiers and exclude Cell-tier terminals & printers. (Ties in with the hierarchy-cascade eligibility work + the line-resident direction.)

## Trim IN — "null" under the Eligible label
On **Trim IN**, there's a **"null"** displayed **underneath the Eligible label** (should show a value or be hidden).

## Trim IN — show an inventory of what's currently in Trim
**Trim IN** should **display an inventory of what is currently in Trim** (on-hand LOTs at the trim area/line).

## Trim OUT — show the Trim inventory + selectable LOT list (or scan)
On **Trim OUT**, also show the **same Trim inventory**, and provide a **selectable list of LOTs** to pick from — while **still supporting scan** as an alternative. (Pick from the queue or scan the LTT.)

## Trim OUT — destination should be the production line, not machining-in terminals
The **Trim OUT destination** dropdown is currently filtered to **Machining-IN terminals** — it should instead list the **production line** (WorkCenter). (Matches the line-resident / operator-picks-a-line direction.)

## Trim OUT — should not navigate to LOT summary on submit
On **Trim OUT submission**, it currently **navigates to the LOT summary page** — it **should not** do that (stay on the Trim OUT screen / return to the queue).

## Trim shop — able to check out the same LOT twice 🐞
Was able to **check out the same LOT twice** from the Trim shop. Should be blocked (once checked out, it can't be checked out again).

## Trim OUT — shot count allowed to exceed the LOT's actual count 🐞
Was able to enter a **shot count much higher than the LOT actually contained**. Needs validation against the LOT's piece count.

## Trim OUT — scrap count allowed to exceed the LOT 🐞
Similarly, the **scrap count was allowed to be much higher** than the LOT contained. Needs validation/cap.

## LOT Detail — need more than just terminal/machine name
On the **LOT Detail** page, we need **more detail than just the terminal or machine name** (richer location/context info per event).

## LOT Detail — show scrap per movement + total scrap card
In **LOT Detail**: show **scrap recorded in each movement** where applicable, and add a **Total Scrap card at the top**.

## LOT Detail — round the date in history
In the **LOT Detail history**, the **date should be rounded** (over-precise timestamp — round it).

## Trim checkout — move the LOT to the production line, not the terminal
When **checking out a LOT from Trim**, it should **move the LOT to the production line** (WorkCenter), **not to the terminal**. (Line-resident: `CurrentLocationId` = the production line.)

## Routes tab — restructure "Area" to Operation Type
On the **Routes tab**, the **"Area"** concept/column needs to be **restructured to Operation Type** (route steps classified by operation type/role, per the OperationType restructure — not by Area). *(Overlaps the already-in-progress routes op-template dropdown task — see tasks file.)*

## Routes — "New Version" doesn't switch to the route editor
On the Routes tab, hitting **New Version** does **not switch to the route editor** (should open/enter the editor for the new draft version).
