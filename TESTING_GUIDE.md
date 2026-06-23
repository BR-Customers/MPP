# MPP MES — Dev Testing Guide

Everything you need to walk through and test the application in the dev environment.

---

## 0. What you can test vs. what's simulated

| Layer | Status |
|---|---|
| SQL procs / data layer | **Fully testable** (1817-assertion suite green) |
| Screen data + actions (queues, picks, splits, holds, ship, sort, AIM) | **Fully testable** with seeded data |
| PLC `OperationComplete`, MIP per-piece handshake | **Simulated / no-op** in dev (no PLC). Assembly/Machining auto-moves won't fire. |
| Zebra label printing (ZPL) | **Simulated** — `ShippingDispatcher`/`LotLabel` are sim-ready no-ops; no physical print. |
| AIM (Honda EDI) HTTP — topup, place-on-hold, update | **Simulated** — the AIM pool is **pre-seeded** (~100 IDs/part) so completion works; live HTTP is commissioning. |
| OmniServer scale, Cognex vision | **Simulated** — operator-entered counts work; no live device. |

---

## 1. Prerequisites

- SQL Server `MPP_MES_Dev` reachable at `localhost` (Windows auth).
- Ignition gateway running, with the MPP project pointed at this repo.
- `sqlcmd` on PATH (ships with SSMS / SQL Server).

---

## 2. Setup (and full reset)

### 2a. Load the test data — one command
```powershell
.\sql\scratch\Seed-SmokeData.ps1
```
This **rebuilds** `MPP_MES_Dev` from scratch (all migrations + base seed, guarded so the gateway releases) and layers the scenario data:
- **phase3_diecast** — Die Cast lots + mounted tools
- **phase5_7** — the whole production arc (machining queues, assembly containers, a completed/shippable container, a sort-cage serial set, holds, AIM pool)
- **phase8** — downtime + shift data

The run ends by printing a **"WHAT TO SMOKE"** table with the exact IDs to use — keep that handy.

> **Quick arc-only refresh** (no full rebuild, e.g. after you've shipped/picked things and want a fresh arc): run `sql\scratch\smoke_seed_phase5_7.sql` directly — it self-cleans. (The full `Seed-SmokeData.ps1` is the only reliable way to reset *everything*.)

### 2b. Pick up the project in Ignition
1. **Designer → Update Project** (loads all the view/script changes from disk).
2. **Restart the gateway once** after pulling new Named Queries (a scan isn't enough for NQ visibility).

---

## 3. The DEV NAV toolbar

A red **DEV NAV** bar is docked at the top of every page (it's a dev-only tool; remove the `top` dock in `page-config/config.json` + the `Views/Dev/TestNavHeader` view to retire it).

- **20 buttons** jump straight to each screen — no home-tile wiring needed.
- The **4 dedicated-terminal buttons** (`Mach IN`, `Mach OUT`, `Asm Ser`, `Asm NonSer`) **bind the matching cell** into the session as you click them — watch the **`Cell:`** indicator change. This *simulates a dedicated terminal* so the screen lands on its seeded data.
- **`Clear Cell`** resets the bound cell (use it to see the "No cell bound to this terminal" empty state).
- **`Initials (popup)`** opens the operator-initials popup directly so you can test it.

---

## 4. Operator identity

Two ways, both fine:
- **Do nothing** — actions attribute to a dev fallback user (`AppUser.Id = 2`, "DEV") automatically. Good enough to test every action.
- **Use the initials popup** (the real flow) — enter a seeded operator's initials. Use **`JD`** (John Doe, Operator). Other seeded initials: `DEV`, `MIN`, `UPH` (supervisor).

---

## 5. Dedicated vs. shared terminals (why some screens have no cell picker)

- **Dedicated** (Machining IN/OUT, Assembly Ser/NonSer): the cell is fixed by the terminal — **no picker**; they read `session.custom.cell`. The DEV NAV binds it for you.
- **Shared** (Trim, Die Cast, End of Shift): the operator picks/scans the cell — these keep their picker.

---

## 6. Per-screen walkthrough

> IDs below are from a fresh `Seed-SmokeData.ps1` run — **confirm against the seed's printed "WHAT TO SMOKE" table** if anything looks off.

| # | Screen (DEV NAV button) | Do this | Expect |
|---|---|---|---|
| 1 | **Mach IN** | Cell auto-binds `MA1-5GOF-MIN`. See the FIFO queue. Click **Pick** on a *Good* row → confirm the BOM-rename modal. | 3 LOTs: `SMK-MIN-1`/`-2` (Good), `SMK-MIN-3` (Hold, Pick disabled). On confirm: a machined LOT is created, toast, queue refreshes. |
| 2 | **Mach OUT** | Cell auto-binds `MA1-5GOF-MOUT`. Enter two piece counts that **sum to 48**, pick two **Assembly** destinations, Submit. | Parent LOT `SMK-MOUT-1` (48 pcs). Split succeeds (proc enforces sum=48); toast. |
| 3 | **Asm Ser** | Cell auto-binds `MA1-5GOF-ASER`. | Open 5G0 container, fill 0 / 48. (Confirm Completion needs filled trays — PLC/MIP territory.) |
| 4 | **Asm NonSer** | Cell auto-binds `MA1-COMPBR-AOUT`. Close a tray (position + count). | Open 5G0-C container, 0 / 144; tray-close toast. |
| 5 | **Shipping** | Enter **ShippingLabel Id `1`** → Ship. | Container ships → status Shipped; toast. (Reprint button also works.) |
| 6 | **Sort Cage** | Enter ContainerSerial Id **`1`**, New Container Id **`5`**, tray `1` → Migrate. | Serial migrates to the destination container; toast. |
| 7 | **Hold** | Place: LOT name `SMK-MIN-1` *or* Container Id `1` + a hold type → Place. Release: Hold Event Id **`1`** (the pre-seeded hold on `SMK-MIN-3`). | Place/Release toasts; `SMK-MIN-3` is already on hold (visible as the Hold pill in Mach IN). |
| 8 | **AIM Config** | View thresholds; edit + Save. | Loads 50 / 30 / 20 / 10; save toast. |
| 9 | **Supervisor / Downtime / End Shift / Shift Sum** | Open each. | Downtime/shift data from the phase8 seed. |
| 10 | **Die Cast** *(shared — has a cell picker)* | Pick a cell; see mounted tool + eligible items. | Die-cast lots + tools from phase3. |
| 11 | **Initials (popup)** | Click it → enter `JD`. | Popup resolves the operator. |

---

## 7. Reset / refresh

- **Full reset to clean state:** re-run `.\sql\scratch\Seed-SmokeData.ps1`.
- **Arc-only refresh:** `sqlcmd -S localhost -d MPP_MES_Dev -E -C -I -i sql\scratch\smoke_seed_phase5_7.sql`.
- Walking the flow **mutates data** (picks consume LOTs, splits close parents, ship marks shipped) — re-seed to start over.

---

## 8. Known gaps (not bugs — flagged for follow-up)

- **`phase2` (lot-lifecycle) and `phase4` (trim/receiving) seeds error** on the current schema (legacy drift) and are **excluded** from the seeder. Effect: **LOT Search / Genealogy / LOT Detail** show only the lots created by the other seeds; **Trim** has no LOT staged at a trim cell to scan, and **Receiving** has no dedicated data. Repairing those two seeds is a separate task.
- **Unbacked list placeholders** (render the structure, labeled "read pending"): Hold Mgmt open-LOTs/Containers columns, Shipping loaded-container queue, Sort Cage live camera. These need follow-up read procs.
- **Trim** is a *shared* terminal but currently shows a read-only Active Cell (no picker / no "Change cell"); its OUT action still works by scanning a LOT name.

---

## 9. Tools reference

| Tool | What it does |
|---|---|
| `sql\scratch\Seed-SmokeData.ps1` | Full reset + seed (the setup/reset button) |
| `sql\scratch\smoke_seed_phase5_7.sql` | Arc-only re-seed (self-cleaning) |
| `sql\tests\Run-Tests.ps1` | Full SQL proc test suite (guarded; 1817 assertions) |
| `sql\scripts\Reset-DevDatabase.ps1` | Rebuild DB only (no scenario seed) |
| `.\scan.ps1` | Trigger an Ignition project resource scan |
| DEV NAV bar (in the app) | Navigate + simulate the dedicated-terminal cell + open the initials popup |
