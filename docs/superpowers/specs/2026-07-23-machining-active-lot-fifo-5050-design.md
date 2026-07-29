# Design Note — Machining IN: Active Machined LOT panel 50/50 with FIFO Queue

**Date:** 2026-07-23
**Type:** UI sizing tweak (Perspective flex layout) — design artifact only, no code/view edited by this note
**Customer ask:** "resize the active machined lot, 50/50 with fifo queue." — noted as "just a flex container sizing. nice and simple."

---

## 1. Target view

**File (absolute):**
`C:\Users\JacquesPotgieter\Documents\Dev\MPP\ignition\projects\MPP\com.inductiveautomation.perspective\views\BlueRidge\Views\ShopFloor\MachiningIn\view.json`

This is the **Machining IN** screen (`Title` = "Machining IN"). Its `root` is a **vertical** flex container that stacks three children top-to-bottom:

| # | `meta.name` | Role | Current `position` |
|---|-------------|------|--------------------|
| 1 | `Header` | Title / operator / Refresh / Inventory / Close row | (none → natural height) |
| 2 | `QueuePanel` | **FIFO Queue** ("FIFO Queue - N LOTs awaiting") | `{ "basis": "0", "grow": 1 }` |
| 3 | `ActiveLotPanel` | **Active machined LOT (after pick)** | `{ "shrink": 0 }` |

Because `root.props.direction` = `column`, the two panels are stacked **vertically**. `QueuePanel` grows to fill all remaining height while `ActiveLotPanel` is pinned to its natural (small) content height — so the FIFO queue visually dominates and the Active machined LOT panel is a thin strip at the bottom. That size imbalance is exactly what the customer is flagging.

> Note on the customer's wording: the two panels are stacked **top/bottom**, not literally left/right. "50/50" here means splitting the vertical content area equally. If the customer actually wants them **side by side**, see §5 — that is a larger change, not "just a flex sizing."

**Container holding the two children:** `root` (`ia.container.flex`, `meta.name` = `root`, `props.direction` = `column`).
**The two children to balance:** `QueuePanel` (FIFO Queue) and `ActiveLotPanel` (Active machined LOT).

---

## 2. The change

`QueuePanel` already carries `{ basis: 0, grow: 1 }`. To make the Active machined LOT panel share the remaining height equally, give `ActiveLotPanel` the **same** flex sizing so both grow from a zero basis at grow-factor 1 → 50/50.

**`ActiveLotPanel.position`**

| | Value |
|---|-------|
| **Current** | `{ "shrink": 0 }` |
| **Target** | `{ "basis": "0", "grow": 1, "shrink": 1 }` |

`QueuePanel.position` stays `{ "basis": "0", "grow": 1 }` — **do not touch it.** `Header` stays as-is (no `position`, natural height). After the change, the header keeps its natural height at the top and the two panels split the remaining vertical space 50/50.

Nothing else changes. Inner children (`QueueRepeater`, `ActiveCard`, `ActiveEmpty`, footnotes) keep their existing `shrink:0` / `grow:1` — the repeater already scrolls via `overflowY: auto`.

> Optional polish (not required for 50/50): the Active panel has no overflow rule, so when it grows past its content it just shows empty space (a centered empty-state card / a small result card). That is acceptable. If you want the panel body to behave like the queue, add `"overflowY": "auto"` to `ActiveLotPanel.props.style`. Leave it out to keep the change to the single sizing property the customer described.

---

## 3. HOW TO APPLY — Designer, not a raw file edit

Per **CLAUDE.md § "Ignition file-edit boundary"**, this is an edit to an **existing** view, so it MUST be done in **Ignition Designer**, not by hand-editing `view.json`. Rationale (from the convention): Designer's GSON serializer rewrites `=`/`'`/`<`/`>` as 6-char `\u00XX` escapes that fight literal-string matching, and Designer's in-memory model can conflict with on-disk changes (its "Files vs Gateway" reconciliation can overwrite disk with cached state). A file edit here risks diff churn and a lost change.

**Designer steps (fast):**
1. Open project **MPP** → view `BlueRidge/Views/ShopFloor/MachiningIn`.
2. In the component tree select **`ActiveLotPanel`** (the flex container titled "Active machined LOT (after pick)").
3. In the **Position** section of the Property Editor set:
   - **Grow** = `1`
   - **Shrink** = `1`
   - **Basis** = `0` (or `0px`)
   *(equivalently, this removes the old `shrink: 0` pin.)*
4. Confirm **`QueuePanel`** still reads Grow `1`, Basis `0` (unchanged).
5. Save. The two panels now render at equal height.

**If instead applied at the file level** (only if Designer is unavailable — otherwise prefer the above), the exact JSON is:

```jsonc
// child meta.name = "ActiveLotPanel", replace its "position" object:
"position": { "basis": "0", "grow": 1, "shrink": 1 }
```

After any file-level edit, run `.\scan.ps1` (repo → gateway sync) per the project's Ignition session convention, then reopen the view in Designer to confirm no reconciliation conflict.

---

## 4. Verification

- FIFO Queue and Active machined LOT panels render at equal height (each ~half of the content area below the header).
- Queue still scrolls internally when it has many rows (`QueueRepeater` `overflowY: auto` unchanged).
- Empty state ("No LOT picked yet…") and the post-pick result card still render inside the now-taller Active panel.
- `git diff --stat` on `MachiningIn/view.json` should be small and touch only the `ActiveLotPanel` position block. A large diff means Designer re-serialized/pickled unrelated content — inspect before committing (see the "Designer pickles live data" convention).

---

## 5. Sibling view — likely NOT the target, but check if the customer meant this screen

There is a second machining screen with the same two labels:
`...\ShopFloor\MachiningOutSplit\view.json` — **Machining OUT - Sub-LOT Split**.

Its layout is **already 50/50 side by side**: a `ContentRow` (`direction: row`) holds `QueuePanel` (FIFO Queue, `{basis:0, grow:1}`) and `ActivePanel` (`{basis:0, grow:1}`). So the two columns are equal today — no resize needed there.

Within that right column, `ActivePanel` stacks a small `ParentPanel` (titled **"Active Machined LOT"**, `shrink:0`) above a larger `SplitPanel` (Extract Sub-LOT, `{basis:0, grow:1}`). If the customer's complaint was actually about *that* small "Active Machined LOT" strip, the equivalent one-property tweak is `ParentPanel.position` `{shrink:0}` → `{basis:0, grow:1}` — but that only balances it against the Extract panel **inside the right half**, not against the full-height FIFO queue, so it does not match "50/50 with the FIFO queue" cleanly.

**Recommendation:** apply the §2 change to **MachiningIn** (the screen where the Active machined LOT panel is genuinely undersized versus the FIFO queue and where a single flex property yields a true 50/50). If the customer confirms they were looking at the Sub-LOT Split screen instead, revisit `ParentPanel` per the note above.
