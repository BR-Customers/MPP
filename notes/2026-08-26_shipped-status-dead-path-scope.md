# The Shipped container status is a dead path — scope note

**Date:** 2026-08-26 · **Branch:** `jacques/working` · **Status:** scoped, NOT actioned

Jacques, 2026-08-26: *"there won't be a shipped flag… ever. there is no integration with their
actual shipping infrastructure."*

This note scopes what that implies. **Nothing here has been done** beyond fixing the one report
it was actively breaking (`10bf8b81`). The removal is an FDS-level scope change and is your call.

---

## What is actually there today

`ContainerStatusCodeId = 3` (Shipped) is reachable by exactly one path:

| Layer | Artifact |
|---|---|
| UI | `BlueRidge/Views/ShopFloor/ShippingDock/view.json` — a Ship button |
| Script | `BlueRidge.Lots.Shipping.ship(shippingLabelId, …)` |
| NQ | `lots/Container_Ship` |
| Proc | `Lots.Container_Ship` — sets `ContainerStatusCodeId = 3` |
| Page | route registered in `page-config` for the Shipping Dock |

Nothing else in the codebase writes status 3. Grep confirms: the only other writers are
`Container_Complete` (→ 2), `Hold_Place` / `Terminal_SetClosureMethod` (→ 4), and
`Hold_Release` (→ prior status).

**So it is not integration-driven — it is an operator pressing a button.** That distinction
matters, and it is why this is a decision rather than a fact:

- If an operator at the shipping dock **will** scan each container and press Ship, status 3 is
  real, and the only thing wrong was the report scoping on it.
- If they **will not** — because MPP's own shipping system is where that happens and the MES
  step is duplicate data entry nobody will perform — then the Ship button, the proc, the NQ,
  the entity function and the status-3 code-table row are all dead weight that will read as
  working features at FAT.

Jacques's statement points at the second. This note assumes that but does not act on it.

## Blast radius if it is removed

| Item | Note |
|---|---|
| `ShippingDock` view's Ship button | The view does more than ship — it also reprints labels (`Shipping.reprintLabel`). Removing the Ship action does NOT mean removing the screen. |
| `Lots.Container_Ship` | Also enforces not-on-hold / not-void guards. If the ship action goes, those guards go with it — check nothing else depends on them being exercised. |
| `lots/Container_Ship` NQ + `BlueRidge.Lots.Shipping.ship` | Thin wrappers, safe to drop with the proc. |
| `ContainerStatusCode` row 3 | A code-table row. **Leave it.** Removing a status a shipped database may already carry is a data-migration problem for no benefit; the FUTURE-tag convention covers this. |
| `Container_ListPendingValidation` | References status 3 as "defence in depth" — harmless either way. |
| SQL tests | `0029_.../030_Container_Ship.sql`, `0056_CrtValidation/070_Ship_blocked_when_pending.sql`, `0064_Crt_PartScoped/060_enforcement.sql` all exercise the ship path. They would need retiring, not just deleting — several assert CRT enforcement *through* ship. |
| FDS | FDS-12-011 and the Phase 7 shipping section describe the ship step. Needs an FDS revision + Open Item, not a silent code deletion. |

## Recommendation

**Do not delete anything yet.** Two cheaper steps first:

1. **Confirm the workflow with MPP** — ask whether a shipping-dock operator will mark containers
   shipped in MES at all. This is one question in the next meeting and it settles the whole thread.
2. **If no:** raise it as an Open Item (an `OI-` entry) covering the FDS revision + the code
   retirement together, so the FAT and the docs move with the code. Tag the Ship step FUTURE
   rather than deleting it if there is any chance a later phase adds the integration — the
   project convention is to flag FUTURE, not delete.

Until then the system is **correct**: the report no longer depends on the flag, and the Ship
button still works for anyone who does press it.

## Already done (2026-08-26)

`Lots.Container_ListShipped` rescoped from status-3-only to closed containers
(status 2 or 3), ranged on `CompletedAt`, AIM shipper ID left-joined so an unlabelled
container still appears blank. Commit `10bf8b81`. That was not a design change so much as
applying the header's own stated reasoning — *closure is the ceiling of what this system can
ever know* — to the scope as well as the timestamp.
