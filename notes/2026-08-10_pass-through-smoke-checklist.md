# Pass-Through Parts Screen — Operator Smoke Checklist

**Screen:** `/shop-floor/third-party-inspection` (title "Pass-Through Parts")
**Branch:** `hunter/explore` · **Plan:** `docs/superpowers/plans/2026-08-06-pass-through-parts-screen.md` Task 5

---

## Setup

| | |
|---|---|
| **Terminal** | `MA2-6FBCHOP-AOUT` — zone **6FB CH/OP** = cell **162** |
| **Operator initials** | `DEV` (or `SYS`) |
| **Finished good** | item 23 `11200-6FB -A000`, published BOM 8 |
| **BOM children** | `92900-06014-1B` (1 per) · `94301-08100` (2 per) |
| **Pack-out** | 3 parts/tray, 2 trays/container — both `ByCount` and `ByVision` configured |
| **Stock at 162 now** | `11200-6FB -A000` 6 · `92900-06014-1B` 6 · `94301-08100` 12 |

Bind the terminal at `/shop-floor/terminal-selector` (tree: Machining & Assembly 2 → 6FB CH/OP → the AOUT terminal, or scan `MA2-6FBCHOP-AOUT`).

> **⚠️ STOP AT "CLOSE TRAY". Do not press "Complete".**
> `AimPostingEnabled` is now `0`, so nothing posts to Honda's AIM server. But that flag gates the
> **HTTP post only, not the pool claim** — `Container_Complete` still consumes one of the 73 real
> pooled serials, irreversibly. Complete exercises the container/AIM path, which is not part of this
> feature.

---

## Already verified 2026-08-07 — skip unless something looks off

- [x] Title reads "Pass-Through Parts"; exactly two tabs, **Inventory** and **Assembly**, correctly styled
- [x] Subtitle shows the real zone ("6FB CH/OP"), and tracks a terminal rebind
- [x] Initials popup appears **once**, not twice
- [x] **Close button hidden** when embedded (`display:none`, 0×0)
- [x] On-hand panel renders correct stock; header reads "On hand at this station"
- [x] Tab switch works (Assembly tab activates)
- [x] **Standalone `/shop-floor/receiving` unaffected** — Close visible, no on-hand panel, no tabs

---

## 1. Receive a pass-through LOT — Inventory tab

- [ ] Part Number: pick **`94301-08100`**
- [ ] Piece Count: **10**
- [ ] Vendor LOT Number: anything, e.g. `VND-SMOKE-1` (optional)
- [ ] Tap **Create LOT**

**Expect:** "LOT created" toast → LTT print attempt → **form clears** → **screen does NOT navigate away** → new LOT appears in the on-hand panel with a **GOOD** pill.

**Fails if:** the screen jumps to LOT Detail (the `embedded` param isn't reaching the embed).

*If the printer isn't reachable you'll get a print-failure toast plus a "Reprint LTT" button — that's expected and does not fail this step; the LOT still exists. See step 6.*

## 2. ⭐ The cross-tab broadcast — the one thing nothing else has proven

- [ ] Switch to the **Assembly** tab. **Do not press Refresh.**

**Expect:** the component projection already reflects the receive — `94301-08100` availability is 10 higher than before.

**Fails if:** it's stale until you hit Refresh (the page-scoped `inventoryChanged` message isn't landing).

*This is the highest-value check in the whole list — it's the only runtime proof of the new wiring, and it's also what `FAT-INSP-040` now tests.*

## 3. Consume it into a finished good

- [ ] On the Assembly tab, finished good = `11200-6FB -A000`, parts count = **3**
- [ ] Tap **Close Tray** — **then stop. Do not press Complete.**

**Expect:** FG LOT minted. It consumes 3 × `92900-06014-1B` and 6 × `94301-08100` from cell 162.

- [ ] Open the new FG LOT in **LOT Detail → genealogy**

**Expect:** both component LOTs appear as consumed children, and the received LOT from step 1 is among them.

## 4. Rejection path — ineligible part

- [ ] Inventory tab: pick **`5G0-FG`** (or `5G0-c` / `5G0-SA`), any piece count → **Create LOT**

**Expect:** error toast `Item is not eligible at the specified location.` and **no LOT created**.

*These three are the only active parts not eligible at cell 162 — verified against `v_EffectiveItemLocation`.*

> **Two rejection tests from the plan are NOT runnable as configured, so they're dropped:**
> - **Over `MaxLotSize`** — `MaxLotSize` is NULL on both parts eligible here. To test it, set a
>   `MaxLotSize` on item 21 or 22 in Config Tool → Item Master first.
> - **Over `MaxParts`** — cell 162 has no `MaxParts` attribute configured. Set one on the location first.
>
> Both are pre-existing gates with SQL test coverage (`041_Lot_Create_maxparts`); skipping them here
> only leaves them unproven *through this screen*.

## 5. ⭐ The status pill tells the truth

- [ ] Place a hold on one of the on-hand LOTs at cell 162 — AppMenu → **Hold Management**, or LOT Detail
- [ ] Return to the **Inventory** tab

**Expect:** that row's pill reads **HOLD**, not GOOD.

**Fails if:** it still reads GOOD — that's the bug this work fixed (`getLineInventoryCards` used to hardcode `"Good"`).

- [ ] Now try a Close Tray that needs the held part

**Expect:** an insufficient-stock toast that **names the short part** — `Assembly_CompleteTray` skips `BlocksProduction = 1` LOTs.

> **Known cosmetic limit:** the pill is binary — `if(lotStatusCode = 'Good', 'Good', 'Hold')`. A
> **Scrap** LOT will also render "Hold". Logged as T1-M1; wrong-but-conservative, and still a big
> improvement on the old always-"Good". Don't report it as a new bug.

## 6. Print-failure path

- [ ] Point the terminal at an unreachable printer (or stop it) and receive another LOT

**Expect:** "LOT created" succeeds, print toast reports the failure, the **"Last LTT did not print…"** hint and **Reprint LTT** button appear — **and the Assembly tab still refreshed**, because the broadcast fires before the print call.

- [ ] While you're here: after a failed print, the form does **not** clear. Press **Create LOT** a second time.

**Expect (known behaviour, not a regression):** a *second* LOT is minted. This is pre-existing standalone behaviour (T5-N7), but the embedded screen keeps the operator in place, which makes a double-press likelier. Worth deciding whether to guard it.

---

## Environment notes

- The gateway still reports **Trial Mode Active**; its Session Status modal reopens over content and
  won't dismiss. Reset the trial if it gets in the way.
- Persistent `icons/mpp.svg` 404 on every page load — cosmetic, pre-existing, unrelated.

## After the run

Tell me what passed and what didn't and I'll fold the results into `PROJECT_STATUS.md` and the SDD
ledger, then take the branch through merge/PR if you want it.
