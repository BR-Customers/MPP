# MPP MES — Dev Testing Guide

Everything you need to walk through and test the application in the dev environment.

---

## 0. What you can test vs. what's simulated

| Layer | Status |
|---|---|
| SQL procs / data layer | **Fully testable** (full assertion suite green — run `sql\tests\Run-Tests.ps1`) |
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
.\sql\scripts\Reset-DevDatabase.ps1
```
This **rebuilds** `MPP_MES_Dev` from scratch (all migrations + repeatables + the clean parts config in `sql\seeds`), then runs `sql\scratch\seed_demo.sql` to build the **continuous golden-thread dataset** — one connected run per finished good plus WIP staged at every terminal, all built through the real production procs (authentic genealogy / audit).

The demo threads cover the clean part matrix:
- **6MA** (non-serialized FG) — a completed + shipped run, plus WIP at die-cast / trim / machining-in / machining-out / assembly.
- **5G0** (serialized FG) — mid-flow: machined LOT with serials placed in an open container + an active quality hold.
- **RD-BRKT** (pass-through) — one LOT on the receiving dock, one already shipped.
- Cross-cutting: an open pause, an open hold, an open downtime.

The run ends by printing a **"WHAT TO SMOKE"** checklist with the exact live IDs / LOT names to use — **that printout is the source of truth; keep it handy** (the per-screen table in §6 below is illustrative — the IDs come from the printout).

> **Config only (no demo threads / LOT-free):** `.\sql\scripts\Reset-DevDatabase.ps1 -SkipDemoSeed`. This is what `Run-Tests.ps1` uses so the suite runs against clean config.
>
> **Quick re-seed of the threads only** (no full rebuild — e.g. after you've shipped/picked things and want the golden thread back): `.\Seed-Demo.ps1`. It's idempotent (wipes its own transactional footprint first, then rebuilds), so config / tools / locations are untouched.

### 2b. Pick up the project in Ignition
1. **Designer → Update Project** (loads all the view/script changes from disk).
2. After a **full `Reset-DevDatabase.ps1`**, **restart the gateway** — the reset **drops and recreates** the database, leaving the running gateway holding a **stale/faulted DB connection**. Symptom if you skip it: screens load and session UI works (e.g. the bound cell name shows) but **all DB-backed data is empty** (queues, containers, etc.). A project scan does **not** fix this — only a gateway restart (or reconnecting the `MPP` database connection in the Gateway web UI) does.
3. After a **`.\Seed-Demo.ps1`** re-seed (no schema/DB drop), a gateway restart is **not** needed — run **`.\scan.ps1`** so the gateway picks up the refreshed data.

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

**The authoritative walkthrough is the "WHAT TO SMOKE" checklist that `seed_demo.sql` prints** at the end of `Reset-DevDatabase.ps1` (or `.\Seed-Demo.ps1`). It lists, per screen, the route + cell + the exact live LOT name / ID / container to act on — those IDs vary per reseed, so always read them from the printout rather than hardcoding.

The golden thread walks (see the printout for the live IDs):

1. **Die Cast** *(shared — cell picker)* — a WIP `6MA-C` cast LOT waits at `DC1-M01` (tool `DEMO-DC-6MA` mounted); pick it up or shoot a new one.
2. **Trim** — a WIP cast LOT waits at `TRIM1`; trim it out to `MA1-FPRPY-MIN`.
3. **Machining IN** — an **unworked arrival** waits at `MA1-FPRPY-MIN`; pick it (records the checkpoint; it drops off the unworked queue).
4. **Machining OUT** (extract-one split) — a machined `6MA-M` LOT at `MA1-FPRPY-MOUT` (paused + a 2-pc reject on it); extract a sub-LOT → `MA1-FPRPY-AFIN`, parent stays open.
5. **Assembly Non-Serialized** — an open `6MA` container at `MA1-FPRPY-AFIN` (1 of 2 trays closed); complete tray 2 → it fills + auto-completes (mints the FG LOT).
6. **Shipping** — the completed `6MA` container is already shipped (its ShippingLabel Id is in the printout); the pass-through `RD-BRKT` has one LOT on the dock + one shipped.
7. **Serialized Assembly** — the `5G0` container at line `MA1-5GOF` has serials placed (FG-LOT completion deferred, A4).
8. **Hold Management** — release the active hold on the `5G0` machined LOT.
9. **Paused-LOT / Resume** — resume the pause on the machining-out LOT.
10. **Downtime / Supervisor** — end the open downtime on line `MA1-FPRPY`.
11. **LOT Search / Genealogy / Audit Browser** — trace the `6MA` machined LOT → split sublots → FG LOTs → shipped container.
12. **Initials (popup)** — enter `JD` to resolve an operator.

> **Screen-wiring note:** the DEV NAV dedicated-terminal buttons bind the **5GOF** line cells (`MA1-5GOF-*`), so the serialized-assembly / machining screens land on the **5G0** thread's line-resident data. The **6MA** thread lives on the `MA1-FPRPY` line, which has no DEV-NAV/DefaultScreen wiring yet — reach its data via LOT Search / Genealogy / the shared Die Cast + Trim screens.

---

## 7. Reset / refresh

- **Full reset to clean state:** re-run `.\sql\scripts\Reset-DevDatabase.ps1` (config + golden thread; restart the gateway after).
- **Threads-only refresh** (no DB drop): `.\Seed-Demo.ps1`, then `.\scan.ps1`.
- **Config only (LOT-free):** `.\sql\scripts\Reset-DevDatabase.ps1 -SkipDemoSeed`.
- Walking the flow **mutates data** (picks record checkpoints, splits close parents, ship marks shipped) — re-seed to start over.

---

## 8. Known gaps (not bugs — flagged for follow-up)

- **Cast → machined genealogy edge:** post-machining-rework (RecordPick model), no proc links a cast LOT to its machined LOT. `seed_demo.sql` mints the machined LOT directly (mirrors the machining tests), so the proc-built genealogy chain runs **machined → split sublots → FG → container**; the cast LOTs are real, audited WIP but not genealogy-linked. If the demo needs the full cast→machined→FG tree, a transformation/rename proc has to be (re)built.
- **6MA / `MA1-FPRPY` line not screen-wired:** no DEV-NAV / DefaultScreen rows target the FPRPY terminals yet, so the 6MA thread is reachable via LOT Search / Genealogy / Die Cast / Trim, not the dedicated machining/assembly screens (those bind the 5GOF line).
- **Serialized FG-LOT completion (A4)** is deferred: the 5G0 thread stops at serial placement in an open container.
- **Unbacked list placeholders** (render the structure, labeled "read pending"): Hold Mgmt open-LOTs/Containers columns, Shipping loaded-container queue, Sort Cage live camera. These need follow-up read procs.

---

## 9. Tools reference

| Tool | What it does |
|---|---|
| `sql\scripts\Reset-DevDatabase.ps1` | Full rebuild + golden-thread seed (the setup/reset button) |
| `sql\scripts\Reset-DevDatabase.ps1 -SkipDemoSeed` | Full rebuild, config only (LOT-free — what the test suite uses) |
| `.\Seed-Demo.ps1` | Re-seed the golden thread only (no DB drop; idempotent) |
| `sql\scratch\seed_demo.sql` | The golden-thread builder itself (prints the "WHAT TO SMOKE" checklist) |
| `sql\tests\Run-Tests.ps1` | Full SQL proc test suite (resets `-SkipDemoSeed` first) |
| `.\scan.ps1` | Trigger an Ignition project resource scan |
| DEV NAV bar (in the app) | Navigate + simulate the dedicated-terminal cell + open the initials popup |
