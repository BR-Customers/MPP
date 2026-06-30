# Arc 2 Phase 2 — Genealogy Viewer (Ignition) — Design

**Date:** 2026-06-12
**Status:** Draft for review
**Scope:** The **Genealogy Viewer** — the Honda-audit query surface that walks a LOT's ancestors/descendants and renders the genealogy tree. Third of the four deferred Phase 2 views.

## 1. Source of truth

Canonical mockup: `mockup/plantFloor.html` → `div[data-panel="genealogy"]` ("Genealogy Lookup"). Elevated audit surface. Input: LotName or Serial Number; Direction (Both / Ancestors only / Descendants only); "Walk Tree" → an indented vertical tree, each node a LOT with its relationship to the line above, click node → LOT Detail.

## 2. Reconciliation to Phase 2 SQL

Fully backed by the shipped `Lots.Lot_GetGenealogyTree` (closure-table walk) — no new genealogy proc needed.

- `Lot_GetGenealogyTree @LotId, @Direction` returns one flat result set: `(LotId, LotName, ItemId, ItemCode, Depth, Direction)`, `ORDER BY Direction, Depth, LotName`. The self-row (Depth 0) is excluded. **`Direction`** is `Ancestor` / `Descendant`; **`Depth`** is the indent level. This maps directly onto the mockup's depth-indented vertical tree.
- Root LOT is resolved from the typed LotName via the existing `Lots.Lot_Get @LotName`.

**Limitations (note, don't fix this push):**
- **Serial-number entry is deferred** — `Lots.SerializedPart` is Phase 3. Input accepts **LotName** only for now (placeholder updated accordingly).
- **No per-edge relationship label.** The tree proc carries `Direction` + `Depth`, not the `RelationshipType` (Split / Merge / Consumption) of each edge. So nodes render with a generic "ancestor / descendant · depth N" label, not the mockup's precise "Split from / Consumed from" captions. Surfacing per-edge relationship would mean extending `Lot_GetGenealogyTree` to project the closure edge's relationship — out of scope here; revisit if the audit team needs it.
- `Depth` is recorded-order depth, not guaranteed shortest path (documented in the proc) — fine for a readable ordered walk.

## 3. Rendering approach (decision)

Perspective has no native genealogy-DAG renderer, and the mockup is **already a flat, depth-indented vertical list** — so render the result set with a **flex-repeater**, one instance per node, left-margin/indent = `Depth × 18px`, grouped into an **Ancestors** section (the root's parents, above) and a **Descendants** section (below), with the searched root shown between them. This matches the mockup 1:1 and avoids fighting `ia.display.tree` (which wants single-parent path strings; genealogy is a DAG). Recommended over the tree component.

## 4. Data contract

| UI element | Proc (shipped) | NQ (Core) | Entity method |
|---|---|---|---|
| Resolve LotName → root | `Lots.Lot_Get` (exists; NQ `lots/Lot_Get` exists) | — | `Lot.get(lotName=<text>)` (exists) |
| Tree walk | `Lots.Lot_GetGenealogyTree` | **NEW** `lots/Lot_GetGenealogyTree` (params `lotId` s3, `direction` s7) | **NEW** `Lot.getGenealogyTree(lotId, direction)` → list[dict] |

(`Lot.getParents` / `getChildren` from the LOT Detail spec are the one-hop reads; the Viewer uses the full closure walk instead.)

## 5. View

- MPP `BlueRidge/Views/ShopFloor/GenealogyViewer` + route `/shop-floor/genealogy` (title "Genealogy").
- Read-only. `view.custom`: `query` (text), `direction` (`"Both"` default), `rootLot` (shaped-empty dict), `nodes` (`[]`).
- `walk()` customMethod: `root = Lot.get(lotName=query)`; if `root`, `nodes = Lot.getGenealogyTree(root.Id, direction)` and `rootLot = root`; assign both. Wired to "Walk Tree" button and the Query field `dom.onBlur`.
- Render: header line "Tree for `<LotName>` · `<len(nodes)>` nodes"; Ancestors repeater (`nodes` filtered `Direction=='Ancestor'`) and Descendants repeater (`Direction=='Descendant'`) — filter via two `runScript`/transform-derived custom props (`ancestors`, `descendants`) since Ignition expressions can't iterate (see `feedback_ignition_no_foreach_in_expressions`). Each node row: indent by `Depth`, show `LotName · ItemCode · depth N`, click → `/shop-floor/lot-detail?lotId=<LotId>`. Empty-state when `len(nodes)==0` (gen-0 / leaf LOT).
- Pre-declare every bound custom prop with a shaped default.
- **Auth:** elevated, per mockup — gate the view/nav entry; confirm security level at build.

## 6. Done when

- `/shop-floor/genealogy`: entering a LotName + Direction + Walk renders the ancestors-above / descendants-below indented list; a split sub-LOT shows its parent chain up to the die-cast origin; clicking any node opens it in LOT Detail; a gen-0 LOT shows the empty-state.
- `lots/Lot_GetGenealogyTree` NQ + `Lot.getGenealogyTree` added; no new SQL proc (existing one reused).
- Designer smoke against a known split LOT (parent → children) and a merged LOT (multiple parents).

## 7. Out of scope

Serial-number entry, per-edge relationship captions (both later). Other Phase 2 views — separate specs. Viewer navigates to LOT Detail; does not embed it.
