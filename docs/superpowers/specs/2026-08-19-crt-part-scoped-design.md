# CRT — Part-Scoped Controlled Run Tag

> **Status: DESIGN, APPROVED 2026-08-19. NOT BUILT.** Supersedes the "CRT" entry in
> `notes/2026-08-19_backlog_crt_and_shop_floor.md`, which recorded the requirement and
> its open questions. Every question there is now answered below.

---

## 1. Problem

CRT (Controlled Run Tag) marks material as suspect so it cannot advance through the
plant until Quality releases it.

Today CRT is **terminal-scoped and assembly-only**: a CRT capability attribute on an
assembly-out terminal (migration `0058`) causes `Workorder.Assembly_CompleteTray` to
mint the finished-good LOT with `Lots.Lot.CrtActive = 1`. That blocks shipping
(`Lots.Container_Ship`), holds the AIM shipper ID, and drives the 200% downstream
inspection prompt (`Quality.Crt_GetRequiredInspections`). Quality releases a whole
container via `Lots.Container_ValidateCrt`.

That covers finished goods and nothing upstream. A suspect casting or machined
sub-assembly cannot be tagged at all, and there is no way to say "every LOT of this
part is suspect until further notice".

## 2. What already exists and is REUSED unchanged

Nothing in this design replaces working machinery.

| existing | role after this change |
|---|---|
| `Lots.Lot.CrtActive` | still the per-LOT truth. No schema change. |
| `Lots.Lot_SetCrt` / `Lot_ClearCrt` | the Quality toggle calls these directly |
| `Quality.Crt_GetRequiredInspections` | unchanged — still drives the 200% prompt |
| `Quality.Crt_FlagMissedInspection` | unchanged |
| `Lots.Container_Ship` | already refuses to ship a CRT-active LOT. Unchanged. |
| `Lots.AimShipperIdPool_ListUnposted` | already holds AIM while CRT-active. Unchanged. |
| `Lots.Container_ValidateCrt` | unchanged — container-level release stays for the FG path |
| Terminal CRT attribute (`0058`) | **kept** — see D1 |
| `Lots.LotLabel_Reprint` | how a cleared LOT gets a clean ticket |

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **Part flag OR terminal switch.** A LOT mints CRT-active if its part is flagged, OR its minting terminal has the CRT attribute on, OR it consumed a CRT-active input. | "We just found a problem on this line, tag everything" is a real quality scenario and the terminal switch already delivers it. Removing it would lose a capability to gain nothing. |
| **D2** | **CRT propagates through consumption, and clearing stops further propagation.** | Without propagation a flagged casting silently stops being tracked the moment it is machined, which defeats the purpose. Without a release valve one flagged casting taints an entire day of finished goods with no way to stop it short of shipping. |
| **D3** | **Propagation is evaluated AT MINT TIME ONLY.** Once stamped, `CrtActive` changes only by Quality's toggle. | Makes the rule total and cheap: no cascading updates, no walking the genealogy closure on every clear. Clearing a casting stops it tainting FUTURE mints; LOTs already minted from it keep their own tag and are judged on their own. |
| **D4** | **The block is on CONSUME / ADVANCE, never on finishing the current step.** | "Cannot advance until Quality clears" is what CRT is for. An operator mid-basket is not the risk; handing suspect material downstream is. Also avoids depending on remembering which terminal minted a LOT. |
| **D5** | **LOT movement is blocked BY DESTINATION.** `Lots.Lot_MoveTo` / `Lot_MoveToValidated` refuse a CRT LOT moving to a PRODUCTION destination, and allow a move to inspection, inventory, receiving or a support area. | Movement is how a LOT arrives at Trim and Assembly, so leaving it entirely unblocked would let suspect material reach a press. Blocking it entirely would stop someone moving it to quarantine or inspection — the exact thing you want them to do. Classification is data-driven (see D5a), not a hardcoded list. |
| **D5a** | **Production-vs-not is a flag on `Location.LocationTypeDefinition`**, not a hardcoded list of definition codes in a proc. | The polymorphic location model already classifies every location by definition. A column there is one migration, is visible in the Config Tool, and lets a new definition declare itself rather than requiring a proc edit. |
| **D6** | **Clearing is PER-LOT ONLY**, via a toggle button on Lot Detail. No bulk clear, no clear-with-descendants. | Hunter's call. Keeps the audit trail one row per decision and the UI to one control. If a long run proves painful in practice, a bulk action can be added later without reshaping anything. |
| **D7** | **The toggle is elevation-gated** with a new `CrtToggle` action code, both directions. | Consistent with every other protected action (Changeover, MoveOverride, SupervisorAccess). See §8 for the limitation this carries. |
| **D8** | **A `{CrtMark}` token in the EXISTING label templates**, not separate CRT template variants. | Labels are ZPL with `{Token}` substitution. One template per label type, no duplication and no drift. The mark is a record on the ticket, not a visual stop signal — enforcement lives in the procs. |
| **D9** | **One creation popup per SUBMIT**, listing the CRT LOTs minted. | Bulk basket open mints one LOT per cavity in a single press. One dialog per LOT would train operators to dismiss dialogs reflexively, which defeats the point. Degrades naturally to a single LOT at Trim or Machining. |

### Deliberately not built

- **No effective-dated part flag.** A plain `BIT` suffices: history lives on the LOT,
  which stamps `CrtActive` at mint and keeps it after the part flag is switched off.
  "Which LOTs were minted while the bit was on" is answered by querying the LOTs.
- **No bulk clear** (D6) and **no clear-with-descendants** (D2/D3 make it unnecessary).
- **No role check.** There is no role system to hook into — see §8.
- **No retroactive propagation.** Turning the part flag on does not tag LOTs that
  already exist. Quality tags those individually if they matter.

## 4. Schema

Two columns. No new tables.

```sql
ALTER TABLE Parts.Item ADD CrtEnabled BIT NOT NULL CONSTRAINT DF_Item_CrtEnabled DEFAULT 0;

ALTER TABLE Location.LocationTypeDefinition
    ADD IsProductionDestination BIT NOT NULL CONSTRAINT DF_LTD_IsProductionDestination DEFAULT 0;
```

`IsProductionDestination` seeds to 1 for `DieCastMachine`, `TrimPress`, `CNCMachine`,
`AssemblyStation`, `SerializedAssemblyLine`, `ProductionLine` and `ProductionArea`; 0 for
`InspectionStation`, `InspectionLine`, `InventoryLocation`, `Receiving`, `SupportArea`,
and for the non-material definitions (`Printer`, `Scale`, `Terminal`). The seed is part
of the migration and is idempotent.

Edited on the Item Master **Identity** section in the Config Tool, alongside the other
per-part switches. Audited through the existing Item update path, whose
`Audit.ConfigLog` Description already follows `<SUBJECT> · <CATEGORY?> · <ACTION>`.

A new versioned migration; next free ordinal at build time (`0061` is taken — check the
directory, and note `main` carries additional migrations from other branches).

## 5. The three functions

Everything else in this design is a call to one of these. None duplicates logic that
already exists elsewhere.

### `Lots.ufn_CrtForMint(@ItemId, @TerminalLocationId, @InputLotIdsCsv)` → `BIT`

The single place the three-way OR of D1 is evaluated:

1. `Parts.Item.CrtEnabled = 1` for `@ItemId`, **or**
2. the terminal at `@TerminalLocationId` carries the CRT attribute (migration `0058`), **or**
3. any LOT id in `@InputLotIdsCsv` has `CrtActive = 1`.

`@TerminalLocationId` and `@InputLotIdsCsv` are both optional — die cast mints have no
input LOTs; a manual mint may have no terminal.

Called by every minting proc:

| proc | inputs passed |
|---|---|
| `Lots.Lot_Create` (die cast, incl. bulk open) | none |
| `Workorder.MachiningOut_Mint` | the consumed casting |
| `Workorder.Assembly_CompleteTray` | the consumed sub-assemblies and components |
| `Lots.Lot_Split` / `Lots.Lot_Merge` | the source LOT(s) |

`Assembly_CompleteTray` currently inlines the terminal-switch check; that logic **moves
into the resolver** so this decision is made in exactly one place.

### `Lots.ufn_CrtBlocksMoveTo(@LotId, @ToLocationId)` → `BIT`

True when the LOT is `CrtActive` **and** the destination's
`LocationTypeDefinition.IsProductionDestination = 1`. This is what implements D5: a CRT
LOT can be moved to inspection or quarantine, but not onto a press or line.

### `Lots.ufn_CrtBlocksAdvance(@LotId)` → `BIT`

True when the LOT is `CrtActive`. Trivial today, but it is the seam: if the block ever
needs to consider hold state, inspection status or a grace period, it changes here and
every caller inherits it.

## 6. Enforcement

**Blocks** — each rejects **before `BEGIN TRANSACTION`**, returning `Status 0` and a
message naming the LOT and what to do:

| proc | what the operator is stopped from doing |
|---|---|
| `Lots.Lot_MoveTo` / `Lot_MoveToValidated` | moving it to a PRODUCTION destination — this is what a Trim IN or Assembly IN scan actually is. A move to inspection, inventory, receiving or a support area still succeeds (D5). |
| `Workorder.MachiningIn_RecordPick` | picking it into a machining cell |
| `Workorder.MachiningOut_Mint` | consuming it into a sub-assembly |
| `Workorder.Assembly_CompleteTray` | consuming it into a finished good |
| `Lots.Container_Ship` | **already blocks — unchanged** |

**Does not block:** `Lots.Lot_Create`, `Lots.DieCastLot_Release`,
`Workorder.DieCastShiftOutput_Record`, Trim OUT scrap/count on a LOT already at Trim,
and **movement to a non-production destination** (D5).

`Lot_MoveTo` already rejects a blocked LOT (Hold / Scrap / Closed) before anything else,
so it has precedent for holding opinions about whether a move is allowed; the CRT check
joins that existing guard rather than introducing a new pattern.

The pre-transaction placement is not stylistic: a `ROLLBACK` inside a proc invoked via
`INSERT-EXEC` throws Msg 3915 (FDS-11-011), so the CATCH block is the only legal
ROLLBACK site and every rejecting validation must precede the transaction.

**The procs are authoritative.** The terminals additionally call a cheap read before
submitting so the operator gets a proper blocking dialog rather than a bare error toast,
but the block holds even if a screen forgets to check.

## 7. UI

**Lot Detail** — a CRT badge on the header so the state is visible, and a button at the
bottom reading **"Enable CRT"** or **"Disable CRT"** per `Lot.CrtActive`. Calls
`Lot_SetCrt` / `Lot_ClearCrt` behind the `CrtToggle` elevation gate. Both procs already
audit.

**Creation popup** — one per submit, listing the CRT LOTs minted
("3 of 5 baskets are marked CRT: 000000012, 000000013, 000000014"). Informational;
acknowledge and continue. The minting procs already return what they created, so no new
read is needed.

**Blocking popup** — at each blocking terminal: *"This LOT is marked CRT and cannot be
used until Quality clears it."* Names the LOT.

**Config Tool** — the `CrtEnabled` checkbox on Item Master → Identity.

## 8. Known limitations, stated rather than hidden

- **"Only a Quality person can clear it" is not enforceable today.** There is no role
  system in this codebase: every existing gate resolves to *any active AppUser whose
  password validates*. `CrtToggle` behaves identically. Making it genuinely
  Quality-only needs an action→role map, and note the only AD-linked dev user has
  `IgnitionRole` NULL, so a role gate added today would lock Dev out.
- **Elevation now points at an "Active Directory" user source that does not yet exist
  on the dev gateway** (`_ELEVATION_USER_SOURCE`, set 2026-08-19). Until MPP IT
  provisions it, EVERY elevation is denied — including the `CrtToggle` gate this design
  depends on. Testing the toggle locally requires creating that source or temporarily
  repointing the constant.
- **A label printed before clearing still says CRT.** The paper is a snapshot; the
  system is the truth. Reprint via `LotLabel_Reprint` if a clean ticket is needed.
- **Clearing does not un-tag descendants** (D3). LOTs already minted from a cleared
  parent keep their own tag and must be judged individually.
- **Turning the part flag on is not retroactive.** Existing LOTs of that part are
  untouched.
- **There is no Quarantine location definition today.** D5 lets a CRT LOT move to
  `InventoryLocation`, `InspectionStation` or a `SupportArea`, which is where quarantined
  material would go in the current model. If MPP wants a dedicated Quarantine
  definition, it is one more seed row with `IsProductionDestination = 0` — no code
  change.

## 9. Testing

SQL suite under `sql/tests/`, run against a private throwaway database (never
`MPP_MES_Test`, which concurrent work drops, and never `MPP_MES_Dev`). Grep results for
**both** `FAIL` and `ERROR running` — this class of breakage surfaces as a runner
exit-1 with green assertion counts.

**`ufn_CrtForMint`** — each of the three triggers alone sets the bit; all three off
leaves it clear; a NULL terminal and an empty input list are both valid; one CRT input
among several non-CRT inputs still sets it.

**Propagation** — a CRT casting consumed at `MachiningOut_Mint` yields a CRT
sub-assembly even though the sub-assembly's part is not flagged; that sub-assembly
consumed at `Assembly_CompleteTray` yields a CRT finished good; clearing the casting
first yields a CLEAN sub-assembly (D2's release valve); clearing the casting AFTER the
sub-assembly exists leaves the sub-assembly tagged (D3).

**Enforcement** — every proc in §6's block table rejects a CRT LOT with `Status 0` and
writes nothing; each rejection happens with no transaction open; every proc in the
does-not-block list succeeds with a CRT LOT.

**Movement by destination (D5)** — a CRT LOT moving to a `DieCastMachine`, `TrimPress`
or `ProductionLine` is rejected; the same LOT moving to an `InspectionStation`,
`InventoryLocation`, `Receiving` or `SupportArea` succeeds; a NON-CRT LOT moves to a
production destination normally; and the existing Hold / Scrap / Closed rejections in
`Lot_MoveTo` still fire and still take precedence.

**Toggle** — set then clear round-trips `CrtActive`; both write audit rows; clearing an
already-clear LOT and setting an already-set LOT are both no-ops rather than errors.

**Labels** — `{CrtMark}` resolves to `CRT` when active and to empty when not; the
non-CRT label is otherwise byte-identical to today's output.

**Regression** — the existing assembly-out terminal-switch path still mints CRT finished
goods, and `Container_Ship` still refuses them. This design must not disturb the working
FG flow.
