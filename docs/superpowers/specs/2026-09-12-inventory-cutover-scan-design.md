# Inventory Cutover Scan — Design Spec

**Date:** 2026-09-12
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — cutover tooling. Line-by-line physical inventory capture into the new MES.
**Related:** `MPP_MES_CUTOVER_PLAN.md` (DECISION D1), `notes/2026-09-12_entry-route-sequence-blast-radius.md` (blast radius analysis), `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md` (route-driven queue), `docs/superpowers/specs/2026-09-10-cavity-alpha-code-design.md` (`CavityCode`).
**Mockups:** https://claude.ai/code/artifact/b198811e-e705-4754-98b7-fec93aeddafb

---

## 1. Motivation

When an M&A line is moved onto Ignition, the physical inventory standing at that line and
in the warehouse has to exist in the new MES on day one. There is no usable electronic
source for it.

**Why not migrate it programmatically.** Two source systems, neither trustworthy:

- The SparkMES-lineage `MES` db on `EXCSRV05` covers only **about half the lines** at this
  point, and its data is materially out of step with the floor. It also has no direct
  `Lot.MaterialID` — part identity is derived through `Lot -> WorkOrder -> BomComponent ->
  Material` — and no routing tables at all.
- The remaining lines are tracked in a **separate, manually maintained database**. Pulling
  from it puts substantial work on MPP's side for data we would then still have to
  physically verify.

Quantities in both have been hand-amended on paper for years. A physical recount is not a
fallback here — it is the more accurate answer, and it is the only one that covers every
line uniformly.

**Why this needs new code.** The queue is route-driven: a LOT appears at a terminal when
its lowest-`SequenceNumber` *pending* route step carries that terminal's role
(`R__Lots_Lot_GetWipQueueByLocation`). A casting's route is
`DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut`. A LOT created today with no
`ProductionEvent` rows has its first pending step at **TrimIn**, so scanned inventory would
land in the Trim queues rather than at Machining IN where it physically sits.

**Why not fabricate the missing events.** Writing synthetic `TrimIn` / `TrimOut`
`ProductionEvent` rows would assert that a trim operator ran that basket on our system at a
timestamp. That is false, it lands in OEE and operator attribution, and it is exactly the
kind of assertion that does not survive a Honda audit. The LOT genuinely entered our system
partway through its life. The model should say so.

---

## 2. Decisions locked (from brainstorming)

1. **Cutover is line-by-line**, not plant-wide. Each M&A line is scanned as it moves over —
   inventory at the line and the warehouse stock belonging to it.
2. **Scan at the IN point.** Castings enter at **Machining IN**; sub-assemblies and
   purchased components enter at **Assembly IN**. There is no per-basket "where is this in
   the route" judgement — the entry step is a property of the session, chosen once.
3. **The legacy LTT number becomes the LOT name, verbatim.** No re-tagging, no reprinting.
   The tags come off the same pre-printed stock Die Cast uses today, so the format is
   already ours and `IdentifierSequence` is not a concern. `Lot_Create` already supports
   this via `@LotName` ("caller-supplied identity (pre-printed LTT)").
4. **Route entry is modelled, not faked** — a nullable `Lots.Lot.EntryRouteSequence`.
   Steps before it are not part of that LOT's journey.
5. **No legacy database connection.** Rejected in §9.1.
6. **Cast date is captured** and drives real FIFO. Cavity and die are captured for
   genealogy. Both are keyed by the operator from the tag.
7. **Two distinct flows** — cast part and purchased part — presented as tabs, because they
   differ in where LOT identity comes from, not merely in which fields display.
8. **The session list is the only error check that exists.** Nothing in the plant holds
   trustworthy inventory to reconcile against, so void-last and a live running total are
   in scope, not nice-to-have.
9. **`EntryRouteSequence` is a castings-only mechanism.** Sub-assemblies and purchased
   components need no entry point — see §3.4.
10. **Scan destination is a property of the Line**, defaulting to the line itself. §3.5.
11. **No elevation gate.** An operator does this with a plain PIN sign-in.

---

## 3. The model

### 3.1 `Lots.Lot.EntryRouteSequence`

```sql
ALTER TABLE Lots.Lot ADD EntryRouteSequence INT NULL;
```

**Semantics.** Route steps with `SequenceNumber < EntryRouteSequence` are **not part of this
LOT's journey** and are never pending. `NULL` means the LOT entered at the start of its
route — today's behaviour, and the value every existing row keeps.

The pending predicate gains exactly one clause:

```sql
AND rs.SequenceNumber >= ISNULL(l.EntryRouteSequence, 0)
```

Nullable with no default, so the `ALTER` is metadata-only: online, no table rewrite, no
backfill.

### 3.2 `Lots.Lot.CastDate`

```sql
ALTER TABLE Lots.Lot ADD CastDate DATE NULL;
```

FIFO across migrated stock must reflect real age, not scan order. `NULL` for every
normally-minted LOT (whose arrival order already is its FIFO order); set for migrated
castings from the tag.

**FIFO ordering expression**, applied consistently wherever LOTs are ordered for
consumption:

```sql
ORDER BY COALESCE(CAST(l.CastDate AS DATETIME2(3)), lm.LastMovementAt) ASC, l.Id ASC
```

Because `CastDate` is `NULL` on every existing row, this is **behaviour-identical to today**
until a migrated LOT exists.

### 3.3 Why not backdate `LotMovement.MovedAt`

The obvious alternative — write the initial `LotMovement` with `MovedAt` set to the cast
date, so the existing `ORDER BY lm.LastMovementAt ASC` works untouched — is **rejected**.

`Lots.LotMovement` is partitioned on `MovedAt` (`ps_MonthlyUtc`, `PK (Id, MovedAt)` +
clustered `(LotId, MovedAt)`, per migration `0020`) under the **B1/B2 sliding-window
`TRUNCATE` retention**. A backdated row lands in an old partition that retention maintenance
is designed to sweep. When it does, the `LEFT JOIN` in every queue proc goes `NULL` and the
LOT's FIFO position changes silently — with no error and no audit trail. Putting
FIFO-critical data in a retention-swept partition is the wrong place for it.

`Lots.Lot` is not partitioned. `CastDate` lives there and survives.

### 3.4 Scope — `EntryRouteSequence` applies to castings only

Traced through the three item shapes cutover will scan:

| Scanned item | Route shape | Entry point needed? |
|---|---|---|
| **Casting** | `DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut` | **Yes.** Without it the first pending step is `TrimIn` and the LOT lands in the Trim queues. |

> **"Casting" is a ROLE, not an `ItemType`.** There is no `Casting` item type in this model —
> the seeded codes are `RawMaterial` / `Component` / `SubAssembly` / `FinishedGood` /
> `PassThrough`, and a casting is a `Component`. Identify one by its route: an item whose
> active published route carries a `DieCast` (`OriginMint`) step. Filtering by
> `ItemType.Code = 'Casting'` matches nothing and fails **silently** — it cost the
> pre-cutover readiness check two vacuous sections that returned empty and looked like a
> pass. Route role is the authority here, as everywhere else in the terminal-mint model.
| **SubAssembly** | one step — `MachiningOut` (`ConsumeMint`), sequence 1 | **No.** There is no earlier step to skip; any value is a no-op. |
| **Purchased component** | no published route at all | **No.** `Lot_GetWipQueueByLocation` drops it on the `INNER JOIN` to `RouteTemplate`. |

A scanned **SubAssembly** surfaces correctly with no entry point at all, through
`Lots.Lot_GetComponentsAtCell` **Leg 1** (routeful): the leg returns any open LOT at the
cell at its lowest pending step, and a `ConsumeMint` is unconditionally pending while the
LOT is open — so the SubAssembly appears as an assembly component. Correct behaviour,
arrived at incidentally.

A scanned **purchased component** surfaces through **Leg 2** (routeless), which requires
`Parts.v_EffectiveItemLocation` to show it as `BomDerived`-eligible at the cell — i.e. that
it is genuinely a BOM child of a finished good Direct-eligible there. That is a
**pre-cutover config check**, not code (§10).

**Hard rule — where SubAssembly stock is scanned.** `Lot_GetWipQueueByLocation` filters on
`CurrentLocationId`. A SubAssembly's pending step is permanently its `MachiningOut`
`ConsumeMint`, so if a scanned SubAssembly is placed at a **machining-line** location it
appears in that terminal's Machining OUT queue as a **mint source**, alongside the raw
castings awaiting machining — an operator could select an already-machined LOT as input.
SubAssembly cutover stock **must** be scanned to an assembly-side location. See §11.1.

### 3.5 `Location.DefaultStockLocationId`

```sql
ALTER TABLE Location.Location ADD DefaultStockLocationId BIGINT NULL
    REFERENCES Location.Location(Id);
```

Inventory for an M&A line lives on the line itself, so a cutover session's
`@CurrentLocationId` is the line. That will not always hold — warehouse stock for a line is
foreseeable. A nullable self-FK on the Line names where its scanned stock is deposited;
`NULL` means the line itself, which is today's behaviour and needs no backfill.

Everything else in this spec is unchanged by the value — only the destination moves.

> Note, out of scope: `Lot_Create`'s existing `@DepositToStorage` resolves the warehouse by
> a hard-coded `Code = N'WHSE'` lookup. This column is the eventual right home for that
> too, but converting it is a separate change and is **not** bundled here.

---

## 4. Phase A — extract the pending-step predicate (prerequisite, behaviour-neutral)

### 4.1 The problem

The "is this route step pending?" predicate is **copy-pasted seven times across five procs**:

| Proc | Copies |
|---|---|
| `Lots.Lot_GetWipQueueByLocation` | 1 |
| `Lots.Lot_GetComponentsAtCell` | 1 |
| `Lots.Lot_GetTrimStorageQueueForLine` | 1 |
| `Lots.Lot_MoveToValidated` (`@NextPendingSeq`) | 1 |
| `Workorder.MachiningOut_Mint` | **3** — `@TotalAvail`, `@SrcEligible`, FIFO `@Queue` |

Adding `EntryRouteSequence` to seven sites by hand is the actual risk in this project.
A missed copy fails **silently and asymmetrically**: worst case is inside
`MachiningOut_Mint`, where the availability count and the FIFO walk it then performs would
disagree — producing wrong quantities rather than an error.

This is the same fragmentation logged as the OPEN TODO at the top of `PROJECT_STATUS.md`
(operation-template resolution implemented five ways), in the same schema area.

### 4.2 The extraction

```sql
CREATE OR ALTER FUNCTION Lots.ufn_NextPendingRouteStep (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT TOP (1)
           rs.SequenceNumber,
           rs.OperationTemplateId,
           oty.Code AS OperationTypeCode
    FROM Lots.Lot l
    INNER JOIN Parts.RouteTemplate rt      ON rt.ItemId = l.ItemId
         AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
    INNER JOIN Parts.RouteStep rs          ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty     ON oty.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationRoleKind rk  ON rk.Id  = oty.OperationRoleKindId
    WHERE l.Id = @LotId
      AND (
              rk.Code = N'ConsumeMint'
           OR (rk.Code = N'Advance' AND NOT EXISTS (
                  SELECT 1 FROM Workorder.ProductionEvent pe
                  WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId))
          )
    ORDER BY rs.SequenceNumber ASC;
```

**Inline** table-valued function — not scalar, not multi-statement — so the optimiser folds
it into the calling plan. These procs run on every terminal refresh; a multi-statement TVF
would put a row-by-row barrier in the hot path.

All seven CTEs are replaced with `CROSS APPLY Lots.ufn_NextPendingRouteStep(l.Id)`.

### 4.3 Acceptance

Phase A ships **on its own commit** with **zero behaviour change**. The proof is the 19
existing test files in §8.1 passing **unmodified**. No schema change, no new params, no
Ignition change. If anything in those tests moves, the extraction is wrong.

---

## 5. Phase B — entry point and cast date

### 5.1 Migration

`sql/migrations/versioned/0080_lot_entry_route_sequence.sql`:

- `ALTER TABLE Lots.Lot ADD EntryRouteSequence INT NULL;`
- `ALTER TABLE Lots.Lot ADD CastDate DATE NULL;`
- `ALTER TABLE Location.Location ADD DefaultStockLocationId BIGINT NULL REFERENCES Location.Location(Id);`
- Extended-property descriptions for all three in `R__Descriptions_ExtendedProperties.sql`
  (these feed the generated ERD).

No index on the two `Lot` columns: both are read from an already-fetched `Lot` row.
`DefaultStockLocationId` is read once per session.

### 5.2 `Lots.ufn_NextPendingRouteStep` gains the clause

One line, in one place:

```sql
AND rs.SequenceNumber >= ISNULL(l.EntryRouteSequence, 0)
```

### 5.3 FIFO ordering sites

The `COALESCE` from §3.2 is applied at the four sites that order LOTs for consumption or
display:

- `Lots.Lot_GetWipQueueByLocation`
- `Lots.Lot_GetTrimStorageQueueForLine`
- `Lots.Lot_GetComponentsAtCell`
- `Workorder.MachiningOut_Mint` (the `@Queue` insert)

### 5.4 `Lots.Lot_Create` — new parameters

| Parameter | Type | Notes |
|---|---|---|
| `@EntryRouteSequence` | `INT = NULL` | Straight to the INSERT. |
| `@CastDate` | `DATE = NULL` | Straight to the INSERT. |

Both default `NULL`, so **every existing caller is unaffected**. `@LotName`,
`@VendorLotNumber`, `@ToolId`, `@ToolCavityId`, `@LotOriginTypeId` and `@DepositToStorage`
already exist and need no change.

### 5.5 Validation added to `Lot_Create`

Per the house pattern, all rejecting validations run **before** `BEGIN TRANSACTION`, each
selecting the status row and returning with no open transaction (Msg 3915).

1. **`@EntryRouteSequence` must name a real step** on the item's active published route.
   A sequence that matches no step would make the LOT invisible everywhere.
2. **`@CastDate` may not be in the future.**
3. **Duplicate LTT** — `UQ_Lot_LotName` already enforces uniqueness, but the proc must
   reject it with a readable message rather than surfacing a constraint violation.
   Mirrors `DieCastLot_Open`'s existing "LTT ... is already in use".

### 5.6 Existing `Lot_Create` rules that now matter more

These are not changes, but they will be hit during cutover and must be verified per line
beforehand (see §10):

- `Item.MaxParts` caps, and the consumption-point `ItemLocation.MaxQuantity` below.
  (`Item.MaxLotSize` no longer rejects -- see below.)
- Consumption-point `Parts.ItemLocation.MaxQuantity`.
- Item-location eligibility via `Parts.v_EffectiveItemLocation` — a **casting** must be
  eligible at the **machining line** or the create is refused.

---

## 6. Phase C — the scan surface

### 6.1 Placement

New Perspective view, MPP project, mobile-first, at `/shop-floor/cutover-scan`. It is a
distinct surface from the existing `Components/PlantFloor/InventoryManager` popup, which
stays as-is for normal operations.

`InventoryManager.receiveLoose` is the working reference for the purchased-part path — it
already resolves a scanned-or-picked part via `Item.getByPartNumber`, takes a piece count
and a vendor lot, and calls `Lot.create` with a Received origin. The cutover view's
purchased flow is that logic in a mobile layout.

`InventoryManager.checkIn` is **not** a reference for the cast path: it requires the LOT to
already exist (`Lot.getByName` then `moveToValidated`). Cutover creates.

### 6.2 Session context (set once, latched)

Chosen at session start and displayed persistently in a header that never scrolls away:

| Field | Source |
|---|---|
| Line / location | operator picks; scopes everything below |
| Entry step | `MachiningIn` or `AssemblyIn`; resolves `@EntryRouteSequence` |
| Part | dropdown, scoped by `Parts.Item_ListEligibleForLocation` |
| Die | **resolved, not chosen** — see §6.3 |
| Machine # | operator enters once |

A wrong part is then visible on every basket, rather than buried in a field filled twenty
minutes earlier.

**Destination.** `@CurrentLocationId` resolves as
`ISNULL(Line.DefaultStockLocationId, Line.Id)` (§3.5) — the line itself today. Resolved
once at session start and shown in the latched header, so the operator can always see where
stock is landing.

**Access.** Plain operator PIN sign-in via the existing `InitialsEntry` path. **No
elevation gate** — this is operator work, and nothing in it is a protected action.

### 6.3 Die resolution

`Tools.ToolCavity` is keyed `(ToolId, ItemId, CavityCode)` with a unique index, so
"which dies can run this part" is one indexed lookup. Measured against Dev:

```
Dies per part (mapped parts):   1 die -> 13 parts   (none maps to more than one)
Cavities per (part,die):        1 -> 4   2 -> 8   3 -> 5   4 -> 2
```

> **Corrected 2026-09-12.** An earlier draft of this section reported "6 dies -> 1 part".
> That bucket was `ItemId IS NULL` — cavities with no part mapped — not a part. The query
> grouped by `ToolCavity.ItemId` without joining `Parts.Item`, so every unmapped cavity
> collapsed into one phantom row. Re-measured with the join: **every mapped part resolves
> to exactly one die.** This strengthens the auto-resolve case rather than weakening it.

This is the family-die model — `6MA-A` runs six different part numbers, each with cavities
`a`/`b`. So **part -> die is 1:1 for every mapped part**, even though die -> part is 1:many.

The die therefore renders as a **resolved value with an AUTO marker**, not an input. The
picker appears only when the lookup returns more than one row — which nothing in Dev
currently does. It is retained because the real MPP part list has not been measured and
may not be so uniform; a screen that silently picks the wrong die would be worse than one
that occasionally asks.

New read proc: `Tools.Tool_ListForItem(@ItemId)` and
`Tools.ToolCavity_ListForItemTool(@ItemId, @ToolId)`.

### 6.4 Per-basket loop — cast part

| Field | Behaviour on submit |
|---|---|
| **Scan LTT** | clears, refocuses |
| **Cavity** — 2–4 segmented buttons, labelled with `ToolCavity.CavityCode` | **latches** |
| **Cast date** — stepper, §6.5 | **latches** |
| **Piece count** | clears |

Cavity and cast date latch because baskets come off the rack grouped by both. They are
rendered large and permanently visible rather than as filled form controls, because a stale
latched value is silently wrong in exactly the way a stale part would be.

**Cavity notation.** The tags write `CAV` as `Da` / `Db`. The **capital** letter is the die
**revision**; the **lowercase** letter is the cavity, and maps 1:1 to
`ToolCavity.CavityCode` (migration `0076`). This is well understood on the floor and needs
no translation layer — the buttons carry the lowercase code and the operator taps the
letter they read. The capital revision letter is not captured; die identity is already
carried by `@ToolId`.

### 6.5 The cast-date stepper

`◀  Tue, Aug 4 2026  ▶` with a relative line beneath.

- **Seeded from the last basket scanned**, not from today. Consecutive baskets are same-day
  or one to two days apart, so the common case is zero taps and the next is one.
- **Forward arrow capped at today** and rendered disabled there.
- **Centre tap opens the native date picker** for a real jump.
- **Relative line — "39 days ago" — is the safety net.** The tag writes `8/4` with **no
  year**; the operator supplies it. A value over ~6 months old renders in
  `--mpp-state-warn-fg` with "check the year". This is the only defence against the one
  mistake the tag format actively invites.

### 6.6 Per-basket loop — purchased part

Separate tab. Scan part number -> scan or type quantity -> optional vendor lot -> submit.
No cavity, die, or cast date. `@LotName` is minted server-side; the supplier's lot goes to
`@VendorLotNumber`; origin is Received.

| | Cast part | Purchased part |
|---|---|---|
| LOT name | scanned LTT, verbatim | minted by us |
| Barcodes read | 1 (tag number) | 3 (part, qty, vendor lot) |
| Origin | Manufactured | Received |
| Cavity / die / cast date | required | n/a |
| Vendor lot | n/a | optional |

### 6.7 Session list and void

- **Live running total** — "14 baskets · 41,200 pcs". Someone who knows the line spots a
  wrong order of magnitude immediately. It is the closest thing to a sanity check available.
- **Void on each entry**, newest first and tinted. Voiding calls `Lots.Lot_UpdateStatus` to
  `Closed` with a cutover-correction reason — the LOT is **not** deleted, and the audit
  trail keeps the correction.
- Phone collapses the list to a summary bar; tablet and desktop show it beside the form.

### 6.8 Responsive breakpoints

| Breakpoint | Layout |
|---|---|
| Phone (390 × 844) | single column; session collapsed to a pinned summary bar |
| Tablet (834 × 1112) | two columns — entry left, session panel right |
| Desktop (1280 × 800) | latched header full width; entry + session side by side |

Touch targets at or above `--pf-touch-min`; this is done in gloves.

---

## 7. Worked example

Operator scans tag `10625131` at 6MA Cam Holder Line 1, Machining IN.

1. Session latched: line `6MA Cam Holder Line 1`, entry step `MachiningIn`, part
   `12232-6MA -0000`, die `6MA-A` (auto), machine `10`.
2. Scan `10625131` -> cavity `a` -> cast date `Aug 4 2026` -> count `3298` -> **Add basket**.
3. `Lots.Lot_Create` is called with `@LotName='10625131'`, `@ItemId`, `@LotOriginTypeId`
   = Manufactured, `@CurrentLocationId` = the line, `@PieceCount=3298`, `@ToolId`,
   `@ToolCavityId`, `@CastDate='2026-08-04'`, `@EntryRouteSequence=4`.
4. The LOT's first pending step is now `MachiningIn` — steps 1–3 are behind its entry point.
   It appears in the Machining IN queue and nowhere else.
5. At Machining OUT it is consumed FIFO ordered by `CastDate`, minting `10625131-01` per
   the existing `MachiningOut_Mint` naming (`<oldest source LotName>-NN`).

---

## 8. Testing

### 8.1 Phase A regression set — must pass unmodified

```
0009_Parts_Process/060_Eligibility_hierarchy_cascade
0020_PlantFloor_Foundation/041_Lot_Create_maxparts
0024_PlantFloor_Movement_Trim/030, 031, 040, 060, 065
0027_PlantFloor_Machining/010, 020, 070, 080, 090
0028_PlantFloor_Assembly/096, 097
0045_DieCast_Lifecycle/020, 040, 080
0064_Crt_PartScoped/040, 050, 060
```

### 8.2 New coverage

New folder `sql/tests/0070_Cutover_EntryRoute/`:

1. A LOT with `EntryRouteSequence` past `TrimOut` is **absent** from
   `Lot_GetWipQueueByLocation` for `TrimIn`/`TrimOut` and from
   `Lot_GetTrimStorageQueueForLine`.
2. The same LOT is **present** for `MachiningIn`.
3. It is consumable by `MachiningOut_Mint`, and the minted name follows `<LotName>-NN`
   against an 8-digit numeric parent.
4. `Lot_MoveToValidated` still blocks a backward move to a pre-entry step.
5. FIFO: two LOTs, one migrated with an older `CastDate` but a later `LotMovement`, consume
   cast-date-first.
6. `NULL EntryRouteSequence` behaves exactly as today (explicit regression).
7. `Lot_Create` rejects: an `EntryRouteSequence` matching no step; a future `CastDate`;
   a duplicate `@LotName`.
8. A SubAssembly LOT created at an **assembly cell** with no `EntryRouteSequence` appears in
   `Lot_GetComponentsAtCell` (Leg 1) and is consumable by `Assembly_CompleteTray`.
9. A routeless purchased component created at the same cell appears in
   `Lot_GetComponentsAtCell` (Leg 2) and is absent from `Lot_GetWipQueueByLocation`.
10. `DefaultStockLocationId` set on a Line routes a scanned LOT to the named location;
    `NULL` routes it to the line itself.

Test teardown deletes `LotGenealogyClosure` before LOTs (Msg 547) per the established
Arc 2 pattern.

---

## 9. Rejected alternatives

### 9.1 Prefill from the legacy databases

Scan the LTT, look it up in legacy, prefill part / die / cavity / cast date. **Rejected.**
The Flexware-lineage `MES` db covers only about half the lines and its data is materially
out of step; the other half lives in a separately, manually maintained database. Using
either means two connections, unreliable data, and real ongoing work for MPP — to
auto-fill fields the operator is already holding in their hand on the tag. The manual path
has to exist and be solid regardless, so it should simply be the only path.

### 9.2 Synthetic `ProductionEvent` rows for pre-entry steps

Zero schema change, zero proc changes. **Rejected** — it writes false assertions that a
trim operator processed that basket on our system, which then flow into OEE, operator
attribution, and anything Quality reads. §1.

### 9.3 Cutover-only "migrated" route templates

Publish a parallel route starting at `MachiningIn`. **Rejected** — routes are per-item, so
this doubles the route catalogue and permanently forks part identity.

### 9.4 Backdating `LotMovement.MovedAt`

§3.3. Rejected — partitioned and retention-swept.

### 9.5 Re-tagging baskets with newly minted LOT names

**Rejected** — printing and attaching a tag to every basket in the plant is the slow,
error-prone part of cutover, and it leaves every basket's physical tag disagreeing with its
MES identity until someone gets to it. That is the exact failure this work exists to avoid.

---

## 10. Pre-cutover verification (per line, before the window)

Not code — checks to run against production config before a line is scanned:

- [ ] Every casting to be scanned is **eligible at its machining line** in
      `Parts.v_EffectiveItemLocation`.
- [ ] `Item.MaxParts` and `ItemLocation.MaxQuantity` admit real basket quantities
      (3000+). These still REJECT: they cap what may accumulate at a location, which
      is a physical constraint.
- [ ] `Item.MaxLotSize` is advisory only as of 2026-09-12 -- an over-size basket is
      created with a note appended to the result Message. Raising caps that sit far
      below real basket sizes is optional tidying, not a gate.
- [ ] Every part to be scanned has an active published route whose `MachiningIn` (or
      `AssemblyIn`) step sequence is known — that number is `@EntryRouteSequence`.
- [ ] `Tools.ToolCavity` rows exist for every (part, die) pair on the line.
- [ ] No legacy LTT about to be scanned already exists in `Lots.Lot`.
- [ ] Every **purchased component** to be scanned resolves as `BomDerived` in
      `Parts.v_EffectiveItemLocation` at its assembly cell — otherwise it is created
      successfully and then never appears in Leg 2 (§3.4).
- [ ] `Location.DefaultStockLocationId` is correct for the line (or deliberately `NULL`).
- [ ] **No SubAssembly stock is scanned to a machining-line location** (§3.4, §11.1).

---

## 11. Known interaction — the `ConsumeMint` always-pending wart

### 11.1 What it is

`Lot_GetWipQueueByLocation` treats a `ConsumeMint` step as **unconditionally pending while
the LOT is open**. That is deliberate: it keeps a *decrementing casting* in the Machining
OUT queue across repeated partial mints, so the FIFO pool stays visible until the casting
is exhausted.

The side effect is that a **minted SubAssembly**, whose entire route is one `MachiningOut`
`ConsumeMint` step, has that step pending *forever*. It is therefore eligible for the
Machining OUT queue for the rest of its life. When such a LOT sits at a location the
Machining OUT terminal reads, it appears in the mint **source** pick-list beside the raw
castings still awaiting machining — and an operator can select an already-machined LOT as
mint input.

Verified 2026-08-12, not yet fixed. Latent only because Dev carries two SubAssemblies
(`5G0-SA`, `12270-6NA-M`) with no live LOTs. The real MPP part list adds 26 more.

### 11.2 Why cutover does not trigger it

`Lot_GetWipQueueByLocation` filters on `CurrentLocationId`. SubAssembly cutover stock is
scanned to an **assembly-side** location, where the Machining OUT terminal never looks — and
where `Lot_GetComponentsAtCell` Leg 1 surfaces it correctly as an assembly component (§3.4).

The mitigation is therefore a **placement rule, not code**, and it is on the pre-cutover
checklist (§10). Scanning SubAssembly stock to a machining-line location is the one action
that trips the wart, and there is no reason to do it.

### 11.3 But cutover is likely the event that exposes it

Cutover is the first time live SubAssembly LOTs exist in quantity in production. Any
SubAssembly that later *moves* through a machining-line location — by normal operation, not
by cutover — will surface in the mint pick-list.

**Recommendation: do not bundle the fix.** It is a distinct behavioural change to a proc
every terminal reads, and folding it into cutover work couples two risks that should be
taken separately. The fix belongs in its own task, and the shape is: a `ConsumeMint` step is
pending for a LOT only when that LOT is an **input** to the step, never when the LOT is the
step's own **output**. Post-Phase-A that is a single edit inside
`Lots.ufn_NextPendingRouteStep` — which is a further argument for doing the extraction
first.

---

## 12. Revision History

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 (draft) | 2026-09-12 | Jacques + Claude | Initial design: `EntryRouteSequence` + `CastDate`, `ufn_NextPendingRouteStep` extraction as prerequisite, two-flow mobile scan surface, rejected alternatives, pre-cutover verification list. |
| 0.4 (draft) | 2026-09-12 | Jacques + Claude | "Casting" clarified as a route ROLE, not an ItemType -- there is no such item type, and filtering by one matches nothing silently. LINE means Work Center tier / ProductionLine definition, not Cell tier. |
| 0.3 (draft) | 2026-09-12 | Jacques + Claude | Corrected the dies-per-part measurement in 6.3: the reported "6 dies -> 1 part" was the unmapped `ItemId IS NULL` bucket, not a part. Every mapped part resolves to exactly one die. `Item.MaxLotSize` is now informational rather than a rejection. |
| 0.2 (draft) | 2026-09-12 | Jacques + Claude | Open questions resolved. Cavity `Da`/`Db` = die revision + cavity, maps 1:1 to `CavityCode`, no translation needed. Added `Location.DefaultStockLocationId` (§3.5). Operator access, no elevation gate. New §3.4 scoping `EntryRouteSequence` to castings only, with the SubAssembly placement rule. §11 replaced with the `ConsumeMint` wart analysis. |
