# Prod release runbook — cutover destination picker

**Release commit:** `095bb8c3` on `jacques/working` — the commit the two archives were
built and verified from.
**Previous release:** `9d700f3a`, deployed to prod 2026-09-14 11:56 (migration `0082`,
three procs, nine Ignition resources).
**Rehearsed against:** `MPP_MES_ProdSim2`, built at `9d700f3a` — prod's exact state
(82 migrations, highest `0082`).

**Nothing may be committed between the preview you read and the Execute.** The plan
fingerprint covers HEAD; Execute refuses if anything moved.

HEAD will be this runbook, or a later docs-only commit — expected. What matters is that
no deployable moved after the archives were built:

```bash
git diff --stat 095bb8c3..HEAD -- ignition/ sql/
```

Expect **no output**. If anything is listed the archives are stale — rebuild with
`.\tools\Build-ChangeExport.ps1 -Since 9d700f3a -Label cutover-destination` and re-run
the preview.

---

## 1. What this ships

The cutover operator can now choose **where scanned stock is counted in**. Until now every
LOT landed at the selected line, because `Location_GetStockDestination` resolves
`ISNULL(DefaultStockLocationId, l.Id)` and **no line has a default set** — all 21 fell back
to themselves.

Migration `0081` already established that stock legitimately rests in four places —
the warehouse, the trim shop floor, the trim stores, and the M&A lines — but the screen
could only ever deposit at the line. This closes that gap.

The dropdown offers the **line (pre-selected)**, **Warehouse**, **Trim Shop 1 - Trim
Storage** and **Trim Shop 2 - Trim Storage**. The choice is latched per session beside
Line / Part / Machine, changed through the **Change** button, and shown in the latched
header — depositing 2,000 pieces into the wrong store is an expensive silent error.

### Two details worth knowing

**The flag is per-row, not per-type.** `0083` adds `Location.Location.IsCutoverDestination`.
`0081`'s `IsStockLocation` sits on `LocationTypeDefinition`, and that cannot work here:
`WHSE` and `Shipping IN` are **both `SupportArea`**, so the type does not discriminate.
Seven locations are `IsStockLocation = 1`; only three are cutover destinations. The
migration header says this in capitals so nobody "tidies" the flag onto the definition
table and silently re-admits shipping.

**Colliding names are qualified dynamically.** Both trim stores are named `Trim Storage`.
The proc prefixes a name with its parent **only when that name repeats in the result**, so
the operator sees `Trim Shop 1 - Trim Storage` and `Trim Shop 2 - Trim Storage`, but plain
`Warehouse` rather than `Madison Facility - Warehouse`. Deprecate one trim store and the
other un-qualifies on its own.

---

## 2. Database change

| | |
|---|---|
| Migrations | **1** — `0083_location_is_cutover_destination` |
| Repeatables | **1 new**, 0 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | **0.3s** |

```
NEW  R__Location_Location_ListCutoverDestinationsForLine.sql
```

`0083` adds a `BIT NOT NULL DEFAULT 0` column to `Location.Location` and flags three rows.
`Lots.Lot_Create` is **not touched** — it already takes `@CurrentLocationId`, and `0081`
already makes it skip the eligibility gate at stock locations. All three destinations are
`IsStockLocation = 1`, so they pass today.

> **A seed file ships in the repo but is NOT deployed, and that is correct.**
> `sql/seeds/033_seed_cutover_destinations.sql` exists because on a **rebuilt** database
> `Reset-DevDatabase.ps1` runs migrations at `[4/6]` and seeds at `[6/7]` — and the
> warehouse and trim stores are created by a *seed*, so `0083`'s `UPDATE` would match zero
> rows there. Prod is not in that situation: its locations already exist, so the
> migration's `UPDATE` does the work. **Verified** — applying `0083` to a seeded database
> printed `Cutover destinations: TRIM1-STORE, TRIM2-STORE, WHSE` and flagged exactly those
> three rows. `Deploy-ProdRelease.ps1` deploys no seeds, by design.

---

## 3. Deploy

Connection details confirmed from your 2026-09-14 11:56 execute log.

### Step 1 — Preview (read-only)

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect:

```
[3] Versioned migrations
  Database: 82 applied, highest 0082.
  Pending (1):
    + 0083_location_is_cutover_destination.sql

[4] Repeatables -- target definitions vs this checkout
  462 identical, 0 changed, 1 new on the target.
    NEW      R__Location_Location_ListCutoverDestinationsForLine.sql

[5] Pre-flight gates
  No gates fired.

[8] Plan
  1 migration(s), 1 repeatable(s) in one transaction; then
  R__Descriptions_ExtendedProperties.sql after commit.

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Take the fingerprint from YOUR preview.** ProdSim2 printed `34342e79685f`; prod's will
differ, because the fingerprint covers the target's own state as well as HEAD.

**Stop if:**

- *Pending shows more than `0083`* — prod is behind what this assumes. Reconcile first.
- *Any repeatable is CHANGED* — expected here is **0 changed, 1 new**. A changed one means
  prod drifted from git, or something was committed after `9d700f3a` and never deployed.
  Read the per-object diffs in the report's `diffs` folder.
- *Any gate fires* — gates read live plant data. A block means the release is unsafe now.

### Step 2 — Rehearsal

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint from step 1>
```

```
== transaction open
== [1] migration 0083_location_is_cutover_destination
== [2] R__Location_Location_ListCutoverDestinationsForLine.sql
== verifying inside the transaction
== checks passed
== ROLLED BACK -- nothing was kept

REHEARSAL PASSED. Lock window: 0.3s.
```

If the rehearsal fails, **stop**. It failed against prod's actual rows.

### Step 3 — Execute

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <same fingerprint>
```

Watch `[10]` for `Cutover destinations: TRIM1-STORE, TRIM2-STORE, WHSE` — that is the
migration's own diagnostic confirming it flagged the right three rows on prod's data. If
it prints `(none)`, the location codes on prod differ from Dev and the picker will offer
only the line. That is not a failed deploy, but it needs fixing before operators use it.

### Step 4 — Ignition imports, **Core first**

| Archive | Contents |
|---|---|
| `Core_cutover-destination_2026-09-14_1546.zip` | 3 resources, 7 entries |
| `MPP_cutover-destination_2026-09-14_1546.zip` | 3 resources, 7 entries |

**Core:** `CutoverDestination_ListForLine` (new), `BlueRidge/Cutover/Scan`,
`BlueRidge/Location/Location`.
**MPP:** the Desktop, Phone and Tablet `_CutoverScan` views.

`session-props` is **not** in this release — `destinationLocationId` and `destinationName`
already existed in the session shape; only their source changed.

`MPP_Config` has no changed resources.

> **`loadSession` gained a sixth positional argument.** The Core script and the three
> views must go in together. Core alone leaves the views calling a five-argument function;
> MPP alone leaves the views passing an argument the script does not accept. This is the
> same class of mismatch as the `Lot_Create has too many arguments` error seen on Dev.

---

## 4. Verify

1. Pick a line. **The destination pre-fills with that line** — the operator should never
   see a blank destination.
2. Open the dropdown: the line first, then `Trim Shop 1 - Trim Storage`,
   `Trim Shop 2 - Trim Storage`, `Warehouse`.
3. Pick **Warehouse**, Start Session. The header's DESTINATION cell reads `Warehouse`.
4. Scan one basket, then confirm it landed at the warehouse rather than the line:

```sql
SELECT TOP 1 l.Id, l.LotName, loc.Code, loc.Name
FROM Lots.Lot l
JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
ORDER BY l.Id DESC;
```

Expect `WHSE / Warehouse`.

5. Press **Change** — the destination is still selected.

---

## 5. Rollback

**Database:** restore the COPY_ONLY backup Execute took. `0083` adds a defaulted column and
the proc is `CREATE OR ALTER`, so nothing destructive happened — restore is the sanctioned
path.

**Ignition:** re-import `Core_cutover-machine_2026-09-14_1119.zip` and
`MPP_cutover-machine_2026-09-14_1119.zip` — the release currently live.

Order reverses: **Ignition first, then SQL**, because the old views do not call the new proc.

---

## 6. Verification status — read before deploying

| | |
|---|---|
| SQL suite | **3533 passed, 0 failed** on final HEAD, from a database rebuilt from migrations |
| Dropdown contents, live | ✅ line first, both stores qualified, `Warehouse` clean |
| Header cell, live | ✅ reads `Warehouse`; the row wraps rather than clipping |
| **Basket landed at the chosen destination** | ✅ `CUTOVERTEST001 → WHSE` (test LOT since removed) |
| Change re-seeds the destination | ✅ |
| **Line pre-select (`095bb8c3`)** | ⚠️ **structural only** — JSON parses and the handler sits on `LineDropdown` in all three views, but the gateway's Perspective trial lapsed before it could be exercised |
| **Tablet and Phone layouts** | ⚠️ **structural only** — JSON parse, child ordering and binding shapes confirmed; neither rendered in a browser. Desktop is the layout actually exercised |

The two ⚠️ rows are both small and both cheap to check once deployed — step 4.1 covers the
pre-select, and opening the screen on a tablet covers the other.

---

## 7. Provenance

| | |
|---|---|
| Release commit | `095bb8c3` |
| Commits since prod | 7 (`9d700f3a..095bb8c3`) |
| SQL suite | 3533 passed, 0 failed, exit 0 |
| ProdSim2 preview | Clear to deploy, 0 warnings, fingerprint `34342e79685f` |
| ProdSim2 rehearsal | Passed, rolled back, 0.3s lock window |
| Migration verified on seeded data | `Cutover destinations: TRIM1-STORE, TRIM2-STORE, WHSE` |
| Design + plan | `docs/superpowers/plans/2026-09-14-cutover-destination-picker.md` |
