# Cutover machine eligibility dropdown + `Lot.ProducedAtLocationId` — verification record

**Date:** 2026-09-14
**Branch:** `jacques/working`
**Spec:** `docs/superpowers/specs/2026-09-14-cutover-machine-eligibility-design.md`
**Plan:** `docs/superpowers/plans/2026-09-14-cutover-machine-eligibility.md` (Task 7)

This is the record the production release runbook cites. It covers the SQL
regression gate, the live Perspective verification done against Dev, and what
was found but not fixed.

---

## 1. Full-suite SQL regression — the release gate

```
cd sql/tests
powershell -NoProfile -File Run-Tests.ps1 -DatabaseName MPP_MES_Test_T7
```

```
|  Total:  3523                         |
|  Passed: 3523                         |
|  Failed: 0                            |
  Test run PASSED.
EXITCODE=0
```

**3523 passed / 0 failed, exit 0.** The previous full-suite figure was
3521/0; the two new assertions are the ones this work's test-strengthening pass
added (§ 2 below).

The run was deliberately pointed at a throwaway database named
`MPP_MES_Test_T7` rather than the default `MPP_MES_Test`, so a concurrent
worktree's test run could not collide with it. `Run-Tests.ps1` DROPs and
rebuilds its target from the versioned migrations and then all repeatables, so
this run also proves that **migration `0082` and the three touched repeatables
apply cleanly to a virgin database, in order** — not merely to a database that
already had them.

`0067` was additionally run on its own (`-Filter "0067"`): 35/35, exit 0.

---

## 2. Test strengthening: `0067_Lot_SearchAdvanced/060_cutover_machine.sql`

Case (4) of that file — *"LOTs with no machine at all never match"* — guards
against the new `ProducedAtLocationId` OR widening `Lot_SearchAdvanced`'s
machine filter into "return everything". It was **vacuous under a filtered
run**. Every file in `0067_Lot_SearchAdvanced` tears its own fixtures down, so
under `-Filter "0067"` the only LOT alive when case (4) evaluated was the
file's own `ZZCM-0001`, which *has* a machine. There was no candidate row for
the assertion to reject, so it passed by absence. It only bit under the full
suite, where earlier folders happen to leave ~74 machine-less LOTs behind — an
accident of suite ordering, not a property of the test.

**Change:** a second fixture LOT `ZZCM-0002` — a plain `Lot_Create` with no
`@ProducedAtLocationId` and no `Workorder.DieCastContribution` rows — created
before case (4) runs, with the pre-flight cleanup and teardown extended to
mirror `ZZCM-0001` exactly. Two assertions added (creation, and a premise guard
that the distractor is still present and still machine-less at the moment case
(4) evaluates). **No existing assertion changed.**

**Proof that it now bites.** The file was temporarily instrumented with a
forced-fail probe computing case (4)'s exact expression against an *unfiltered*
`Lot_SearchAdvanced` call — i.e. what the assertion would see if the machine
predicate had been widened away:

| Search | Distractor rows returned | Case (4) expression |
|---|---|---|
| Real filter, `@MachineLocationId = @Mach` | 0 | **0** (passes) |
| Widened (no machine predicate) | 1 | **1** (would fail) |

The probe was removed before commit. The assertion is now non-vacuous standalone.

---

## 3. Live UI verification (Perspective client, Dev, 2026-09-14)

Verified against a running Perspective client on the shared gateway and the
shared `MPP_MES_Dev` database.

### Confirmed working

| # | Behaviour | Result |
|---|---|---|
| 1 | **Machine # is a dropdown**, in both the Desktop and the Phone views (it was an `ia.input.text-field`) | Renders as a dropdown in both |
| 2 | **Eligibility shortlist** — part `12232-6MA -0000` | Exactly one option: `Die Cast 1 - Machine 10` |
| 3 | **Fallback** — part `11200-6MAA-J010`, which has no machine-tier `Parts.ItemLocation` row | All 22 machines offered |
| 4 | **Label disambiguation** — the area prefix is carried | `Die Cast 1 - Machine 01` vs `Die Cast 2 - Machine 01` are distinguishable; ordering is area then code |
| 5 | **Changing the part clears a now-ineligible machine selection** | Works — and clears in the **setup form**, i.e. *earlier* than the plan assumed. The plan expected the clear only at `loadSession` |
| 6 | **Change button reseeds the machine on reopen** | Round trip holds |
| 7 | **Die-name change** (`b8b55230`, a separate Ignition-only feature riding the same branch) | Header DIE reads `6MA Family Die`, not `6MA-A` |

Item 5 is the only behavioural difference from the plan, and it is a
difference in the *safe* direction: the ineligible selection is cleared sooner
than specified, not later.

### Not verified

- **The end-to-end basket → database write.** It needs the LTT and piece-count
  text inputs, and the in-app browser cannot commit an input binding. This is a
  **known environment limitation, not a defect** (see the
  `feedback_ignition_browser_input_commit` memory). `Lots.Lot.ProducedAtLocationId`
  and the `LotCreated` event's `ProducedAt` JSON are therefore proven from the
  **SQL side only** — by `sql/tests/0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql`
  (twelve assertions: accept, write, event JSON code + name, audit Description,
  omitted-parameter default, non-machine rejection, deprecated-machine
  rejection, and no-LOT-on-rejection), all passing.

---

## 4. Issues found

### 4.1 Header clipping — a regression from this work — RESOLVED

The two changes together added roughly 30 characters to the latched header KV
row: DIE went `DMO126` → `6MA Family Die` and MACHINE went `1` →
`Die Cast 1 - Machine 10`. At 1920px the row fit; at **1366px and 1280px the
`ENTERING AT` value was clipped**, the row overflowing 1365px into 1301px and
scrolling.

This was recorded as unresolved during the live pass, then fixed in
**`f1cdaba4`** before this note was written. Root cause: `LatchedKvRow`
already carried `style.flexWrap: wrap`, which is **inert** —
`ia.container.flex` writes its own inline `flex-wrap` from `props.wrap`, so the
style never applied. A latent no-op that shorter content had hidden. Setting
`props.wrap` (what the other 43 wrapping containers in this project use) makes
it real; verified computed `flex-wrap: wrap`, `scrollWidth == clientWidth`, no
overflow. Desktop and Tablet only — Phone's `LatchedKvRow` has no `direction`
prop, so it defaults to column and stacks vertically, and nothing can clip
horizontally there.

The alternative fix considered and **not** taken was shortening the label by
using `AreaCode` (`DC1 - Machine 10`, 7 characters shorter) instead of
`AreaName`. It remains available if the plant-floor terminal resolution turns
out to be narrower than 1280px, but it costs legibility on the shop floor and
the wrap fix makes it unnecessary at every resolution tested.

### 4.2 A casting with no `ToolCavity` rows cannot be basketed — pre-existing

**Not caused by this work.** A part with no `Tools.ToolCavity` rows — e.g.
`11200-6MAA-J010` — shows a green `AUTO` badge beside a **blank die name** and
renders **no cavity tiles**. Because a cavity is required, `addBasket` can
never succeed for that part.

This is the failure mode for **any casting missing die or cavity
configuration**. It is worth flagging now because the real MPP part list is
about to be seeded, which will multiply the number of parts in this state. The
badge claiming `AUTO` beside an empty die name is the misleading part: it reads
as "resolved" when nothing resolved.

---

## 5. Commits on `jacques/working`

Every commit was inspected with `git show --stat`. The shared working tree
holds ~440 dirty/untracked paths — gateway churn under `ignition/`, plus
another person's in-flight work (`MPP_MES_SEEDING_REGISTRY.md`,
`reference/seed_data/README.md`, the die-roster CSVs and parser, the IND570
reference material, and `sql/scratch/` prod extracts). **None of it was swept
into any of these commits**; every commit stages only its own files.

| Commit | Subject | Scope |
|---|---|---|
| `82f22734` | `docs(spec)` cutover machine — eligibility dropdown + `Lot.ProducedAtLocationId` | spec only |
| `b776f225` | `docs(plan)` cutover machine eligibility dropdown + `ProducedAtLocationId` | plan only |
| `b8b55230` | `feat(cutover)` identify the die by name, not asset number | **separate Ignition-only feature** riding the same branch |
| `0b0b3306` | `feat(sql)` 0082 `Lot.ProducedAtLocationId` | Task 1 |
| `3dd9561d` | `feat(sql)` die cast machines for a part | Task 2 |
| `e3167db8` | `docs` renumber the 0082 data-model revision 2.4 → 2.5 | docs fix |
| `9702aa1d` | `feat(sql)` `Lot_Create` records the producing die cast machine | Task 3 |
| `d46f0bb0` | `feat(ignition)` die cast machine dropdown source | Task 4 |
| `298ef3a3` | `docs(plan)` Task 3 has twelve `ProducedAt` assertions, not eleven | docs fix |
| `c421870e` | `feat(cutover)` carry the machine as a `LocationId` through to `Lot_Create` | Task 5 |
| `af9cdf0b` | `feat(cutover)` Machine # is an eligibility-driven dropdown, not free text | Task 6 |
| `8f7ad9d2` | `docs(plan)` add Task 6b | plan addendum |
| `bf0808f3` | `feat(sql)` LOT Search finds cutover LOTs by their recorded die cast machine | Task 6b |
| `f1cdaba4` | `fix(cutover)` header KV row wraps instead of clipping | § 4.1 fix |
| `e699c476` | `test(sql)` machine-less distractor LOT so case (4) bites standalone | § 2 |

---

## 6. Handoff to the production release

This change carries a schema migration, so it ships through the five-part
production release — preview, rehearsal, execute with `-ExpectedPlan`, scoped
git-verified exports, published instruction guide. **That is separate work with
its own runbook and is deliberately not started here.**

What the release will need, **Core imports first**:

- **Core:** `location/DieCastMachine_ListForItem`, `lots/Lot_Create`,
  `BlueRidge/Location/Location`, `BlueRidge/Lots/Lot`, `BlueRidge/Cutover/Scan`
- **SQL:** migration `0082`, plus repeatables
  `R__Location_Location_ListDieCastMachinesForItem`, `R__Lots_Lot_Create`,
  **`R__Lots_Lot_SearchAdvanced`** (Task 6b — added after the plan's original
  export list was written), and `R__Descriptions_ExtendedProperties`
- **MPP:** `session-props`, the three `_CutoverScan` views (Desktop, Tablet,
  Phone — Desktop and Tablet also carry the § 4.1 wrap fix)

### Two things the runbook author must know

1. **`R__Descriptions_ExtendedProperties.sql` carries a large documentation
   catch-up.** Commit `0b0b3306` shows **+363 / −54** on that file, against
   only 2 lines of actual data-model change. The generator rewrites the whole
   file from `MPP_MES_DATA_MODEL.md`, and it picked up descriptions that were
   written into the data model in **earlier** commits but never regenerated.
   That backlog will land in production with this release. It is
   `sp_addextendedproperty` / `sp_updateextendedproperty` only — comment
   metadata, no schema or data effect — but the preview diff will look far
   larger than this feature, and that is expected rather than a sign the wrong
   file was staged.

2. **The die-name change (`b8b55230`) is a separate feature on the same
   branch.** Ignition-only: `Tools.Tool.Name` instead of `Code` in the die
   dropdown and header, touching the three `_CutoverScan` views,
   `Cutover/Scan`, and `session-props`. It is now **committed**, not
   uncommitted as the plan's note assumed. Because it shares files with Task 6
   it cannot practically be split out — it rides along. The header wrap fix in
   `f1cdaba4` exists partly because of it.
