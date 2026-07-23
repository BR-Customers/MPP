# Location Model Reconciliation — Site → Dev/Seed

**Date:** 2026-07-23
**Status:** Design (not yet approved)
**Authoritative source:** `MPP_MES_Site` database (the confirmed onsite location mapping)

## 1. Governing principle

`MPP_MES_Site` is the **rule** for location identity. Specifically:

- **`Location.Name` is authoritative** and defines a terminal's operational **role**. A terminal's role is realized programmatically by its **`DefaultScreen`** attribute — so *the name dictates the default screen* ("Machining In" → the Machining IN screen, etc.).
- **`Location.Code` is NOT authoritative and is currently wrong** in many places (the code suffix encodes a role that no longer matches the name). Codes **will be corrected** to match the name-derived role, keeping the existing suffix convention (`-MIN` / `-MOUT` / `-AIN` / `-AOUT` / `-ASER`, combined TBD).
- **`Location.Description`** is free-text where notes accumulated; it is not authoritative, but several descriptions contain **real config/task notes** that are captured in §7.
- Site data has **cosmetic accidents** to clean on ingest: double spaces (`Assembly  In`), inconsistent casing on closure values, a duplicated `66B - Ins` row, and deprecated rows to drop.

The Dev DB holds **operational data not present in Site** (PLC device registrations, any tuned attributes) that must be **preserved** — this is a reconciliation, not a wipe-and-replace.

## 2. Role vocabulary → DefaultScreen

| Role | Meaning | Default screen | Gets printer? (§5) |
|---|---|---|---|
| `MIN` | Machining In | Machining IN | No |
| `MOUT` | Machining Out | Machining OUT | **Yes** |
| `AIN` | Assembly In | Assembly IN | No |
| `AOUT` | Assembly Out | Assembly OUT (non-serialized) | **Yes** |
| `ASER` | Assembly (Serialized) | Serialized Assembly | **Yes** (serialized assembly OUT) — confirm |
| `COMBINED` | Machining In **and** Out at one terminal ("In - out" / "Tab View") | Combined Machining IN/OUT tabs (spec: `2026-07-23-combined-machining-in-out-terminal-tabs`) | **Yes** (does Machining OUT) |
| `DIECAST` | Die-cast area/machine terminal | Die Cast | **Conflict — see §5** |
| `TRIM` | Trim shop terminal | Trim | **Conflict — see §5** |
| `INSPECT` | Inspection station (3rd-party validate) | Inspection (may not exist yet) | 3 closure methods — see §6 |
| `FALLBACK` | Unregistered-IP fallback | Terminal selector | No (by design) |

**Authoritative role tally from Site names** (Terminal-tier, def 7): AOUT 18, MIN 17, MOUT 7, AIN 3, COMBINED 2, ASER 2, plus DIECAST 5, TRIM 3, FALLBACK 1.

## 3. Name changes to apply

33 common-code locations have a different (authoritative) `Name` in Site vs Dev. Two categories:

- **Harmless relabels** (most): `6MD` → `6MD Manifold Plate`, `Comp bracket` → `RPY Comp bracket`, etc. Purposeful names like **`METTs Assembly Out`** are kept verbatim (not typos).
- **Role-redefining renames** (the important set — these drive DefaultScreen + code fixes + printer eligibility): see §4.

Discard the Dev leaf labels `Assembly Finished` / `Assembly Out (serialized)` in favor of the Site names (`Assembly Out`, `Assembly (Serialized)`), per the authoritative rule.

## 4. Code corrections (the big blast-radius item)

Because codes encode role and role now comes from the name, every terminal whose **code suffix ≠ name role** gets a corrected code. Confirmed mismatches:

| Current code | Authoritative name | Correct role | New code (proposed) |
|---|---|---|---|
| `MA2-5PA-MIN2` | Machining Out | MOUT | `MA2-5PA-MOUT` |
| `MA2-5PA-MIN3` | Assembly In | AIN | `MA2-5PA-AIN` |
| `MA1-FP6NA-AFIN` | Assembly Out | AOUT | `MA1-FP6NA-AOUT` |
| `MA1-FPRPY-AFIN` | Assembly Out | AOUT | `MA1-FPRPY-AOUT` |
| `MA2-6F9TC-MOUT` | Assembly Out | AOUT | `MA2-6F9TC-AOUT` |
| `MA2-COS-MOUT` | Assembly Out | AOUT | `MA2-COS-AOUT` |
| `MA2-RPYCAM1-AIN` | Cam Holder Machining Out | MOUT | `MA2-RPYCAM1-MOUT-*` |
| `MA2-RPYCAM1-AOUT1` | Assembly In | AIN | `MA2-RPYCAM1-AIN` |
| `MA2-RPYCAM1-MOUT-A` | Rocker Shaft 5 Machining In - out | COMBINED | `MA2-RPYCAM1-MIO-*` (convention TBD) |
| `MA2-RPYCAM2-MIN-A` | Rocker Shaft 5 Machining In - out | COMBINED | `MA2-RPYCAM2-MIO-*` |
| `MA2-RPYCAM2-MOUT-A` | Cam Holders Machining IN | MIN | `MA2-RPYCAM2-MIN-*` |

> **⚠ RPYCAM1 / RPYCAM2 clusters are heavily scrambled** (code↔name↔description all disagree across the 8 terminals on each line). The safe procedure is to **re-key every RPYCAM terminal code off its authoritative name**, not to patch individual suffixes. These two lines need a human eyeball pass — flagged in §9.

**Combined-code convention:** COMBINED terminals need a suffix. Proposed `-MIO` (Machining In/Out). Open for your preference (§9).

## 5. Printer rule

**New rule:** *only Machining-OUT and Assembly-OUT terminals get a printer child.* Today **all 64 terminals** carry a `<code>-P1` printer (def 16, parented under the terminal). Under the rule:

- **Keep** (~27): every `MOUT` and `AOUT` terminal, plus `COMBINED` (it performs Machining OUT). `ASER` — confirm whether serialized-assembly OUT prints.
- **Prune** (~37): all `MIN`, `AIN`, `AFIN`→(now AOUT keeps), `ASER`(TBD), and — pending §9 — die-cast and trim terminals.

**⚠ Conflict to resolve (§9):** the literal rule ("only MOUT/AOUT") would strip printers from **die-cast** and **trim** terminals, but die cast prints **LTT labels** today (and there is a stray `[add 10 printers]` note, §7). Likely the intended reading is *"within a machining/assembly line, only the OUT terminal prints"* — leaving die-cast/trim printing to their own logic. **Do not strip die-cast/trim printers until confirmed.**

Printer association is pure parent/child + `def.Name='Printer'` (no FK/join table), so pruning = not seeding the `-P1` child. `Terminal_GetPrinter` and Ignition `getPrinter()` already tolerate a missing printer (empty → fail-fast on dispatch).

## 6. The three structural exceptions

1. **Trim Storage — one per trim shop.** `TRIM1` and `TRIM2` both exist (ProductionArea). Add an `InventoryLocation` (or SupportArea child) per shop as the neutral post-trim staging that Machining IN pulls from (dovetails the `trim-storage-machining-in-line-assignment` spec). `WHSE` description confirms the upstream half: *"all die cast goes here prior to Trim."*

2. **Inspection area** — a new Area node (`ProductionArea` or `SupportArea`) that:
   - **receives `66B-TC` "66B Thermal Case"** (currently a `ProductionLine` under `MA1`) re-parented under it;
   - **adds a sort-cage `InspectionLine`** (def 6) under it;
   - **has one Terminal carrying all 3 closure methods**, used to validate quality of LOTs and containers. The `66B - Ins` station description states the flow: *"inspect and create new lot, so consume foreign part"* — this is the third-party inspection flow (see `inspection-station-third-party-receiving` spec). `SHIPIN` (*"Receiving dock - pass-through parts"*) is the related receiving point. The inspection screen may not be built yet; the **location model** is what we lock now.
   - Clean up the **duplicated `66B - Ins`** row on ingest.

3. **Closure-method normalization + dropdown.** Site `CurrentClosureMethod` values are free-text and inconsistent (`Weight`, `Vision`, `byCount`, `ByCount`). Normalize to the canonical `ClosureMethodCode` enum (`ByCount` / `ByWeight` / `ByVision`) on ingest, and **change the config entry from free text to a dropdown** bound to `ClosureMethodCode` so values can't drift again. `HasBarcodeScanner` (43 rows) and `RequiresCompletionConfirm` (6 rows) are Site-authoritative and carry over.

## 7. Config / task notes mined from Site descriptions

Actionable items found in `Description`:

- **`[add 10 printers]`** (stray node, empty code) — a reminder to add 10 printers. Where? (die-cast machines?) — §9.
- **`5PA - AO`**: *"Vision through scale, validate tags"* — closure via vision-through-scale; **task: validate OPC tags**.
- **`MA1-FP6NA-AFIN` / `MA1-FPRPY-AFIN`**: *"Assembly Finished - vision through scale"* — closure config; **conflicts** with the `CurrentClosureMethod` attribute (which reads `Weight`) — §9.
- **`MA2-6FBCHOP-MIN`**: *"Machining In check fifo consumption, 2 parts"* — behavior note for FIFO consumption of 2 parts.
- **`MA2-RPYCAM1`**: *"duplicate Line 2 (but rocker shaft 5 machining in is dedicated, not in and out)"* — line-structure note informing the RPYCAM re-key.
- **`MA2-RPYCAM2-MIN-A`**: *"also used for machining Out, Tab View here."* — explicit placement of the **combined tabs screen**.
- **`TRIM1` / `TRIM2`**: *"no sublot split"* — trim config.
- **`WHSE`**, **`SHIPIN`** — flow confirmations (die-cast→WHSE→Trim; SHIPIN = pass-through receiving).

## 8. Blast radius & reconciliation approach

**Seed is generated.** Locations are produced by `sql/seeds/gen_locations_mpp.js` → `sql/seeds/011_seed_locations_mpp_plant.sql` (idempotent, keyed by Code, IDENTITY ids). **Do not hand-edit the SQL** — change the generator (or regenerate it from cleaned Site) and re-emit.

**Recommended approach:**
1. Treat Site as the source for **names, structure, and the Site-authoritative attributes** (closure, scanner, confirm). **Clean on ingest** (drop deprecated + dup, fix double-spaces, normalize closure casing).
2. **Derive DefaultScreen from the authoritative name-role** for every terminal (overriding stale Dev/Site screen assignments — names win).
3. **Correct codes** to match roles (§4), including the RPYCAM re-key.
4. Apply the **printer rule** (§5) and **3 exceptions** (§6) in the generator.
5. **Preserve Dev-only operational data** — PLC device registrations (`TerminalPlcDevice`), and anything not represented in Site — by reconciling on Code, not truncating.
6. Regenerate `011`, apply to a throwaway (`MPP_MES_Test`), run the full suite, fix fallout.

**Test fallout (from the blast-radius sweep):**
- ~45 plant-floor tests (`sql/tests/0020`–`0039`) resolve real locations **by Code**. They survive name/id changes but **break on the code corrections (§4) and parent moves (66B-TC)** — each must be updated to the corrected code.
- **Guaranteed breakers:** `0024…/060_ListMachiningDestinations.sql` (asserts a **MIN** printer exists **and** `Name LIKE 'Machining In%'`), `0023…/050_Eligible_and_AreaCell_reads.sql` (asserts a **DC** printer). Both break on the printer prune + name changes.
- **Procs hardcoding codes** (`WHSE`, `SHIPOUT`, `FALLBACK-TERMINAL`) are safe **only if those codes are unchanged** — they are, so no proc change needed, but re-verify after the RPYCAM re-key.

## 9. Open questions / conflicts (need your call before build)

1. **Die-cast & trim printers** — does the "only MOUT/AOUT" rule strip them, or is the rule scoped to machining/assembly lines only (die-cast/trim keep their label printers)? (Die cast prints LTTs.)
2. **`[add 10 printers]` note** — where do these 10 go?
3. **`MA2-RPY6B2-AFIN` = "Assembly Finished"** — the one AFIN you didn't rename. Is it an **Assembly Out** (→ `-AOUT`, gets printer) or a distinct "final assembly" role?
4. **Closure conflicts** — descriptions say "vision through scale" while the `CurrentClosureMethod` attribute says `Weight` (FP6NA-AFIN, FPRPY-AFIN; and `5PA - AO` desc "Vision" vs attr "Weight"). Which wins — is "vision through scale" `ByVision` or `ByWeight`?
5. **`ASER` printer** — does serialized-assembly OUT print?
6. **COMBINED code suffix** — `-MIO` acceptable?
7. **RPYCAM1/RPYCAM2 re-key** — confirm re-keying every terminal on those two lines off its authoritative name (the scramble is too deep to patch piecewise).
8. **Trim Storage node type** — `InventoryLocation` (Cell) vs `SupportArea` (Area) per trim shop?
9. **Inspection area tier** — `ProductionArea` vs `SupportArea`, and its code?

## 10. Phased implementation plan (TDD)

1. **Cleaned Site extract** → a canonical, de-duplicated, normalized location dataset (drop deprecated/dup, fix spacing, normalize closure, derive role+DefaultScreen from name, corrected codes). Produce as data, review against §9 answers.
2. **Regenerate the generator** (`gen_locations_mpp.js`) from the canonical dataset: structure, names, corrected codes, DefaultScreen per role, printer rule, 3 exceptions, Site-authoritative attributes.
3. **Migration for the moved/added structure** where needed (66B-TC re-parent, inspection area, trim storage) — additive; preserve `TerminalPlcDevice` and Dev operational rows by Code.
4. **Test sweep:** apply to `MPP_MES_Test`, run the full suite, update the ~45 code-keyed tests to corrected codes, fix the printer-assertion + name-assertion breakers.
5. **Closure-method dropdown** in the config UI (bind to `ClosureMethodCode`).
6. **Non-destructive apply to Dev** (CREATE-OR-ALTER / idempotent seed re-run), verifying preserved operational data.
7. Full suite green on Dev; smoke the affected terminals.
