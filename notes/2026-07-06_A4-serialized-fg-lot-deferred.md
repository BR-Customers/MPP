# A4 (serialized assembly mints FG LOT) — DEFERRED 2026-07-06

**Context:** Spec 2 (machining/assembly flow reconciliation) Task A4. Non-serialized assembly now mints a finished-good LOT via `Workorder.Assembly_CompleteTray` (tray = LOT, consumes BOM FIFO). A4 was to bring the **serialized** path to the same model — each `Lots.SerializedPart.ProducingLotId` pointing at the minted FG LOT.

**Why deferred (decision by Jacques, 2026-07-06):**
There is a chicken-and-egg the plan's one-paragraph A4 does not resolve:
- `Lots.SerializedPart.ProducingLotId` is **NOT NULL** and is set at **etch/mint time** (`Lots.SerializedPart_Mint @ProducingLotId`), i.e. as each part is laser-etched.
- `Assembly_CompleteTray` mints the FG LOT only at **tray completion** (after all serials are placed).

So a part can't be etched against the FG LOT (it doesn't exist yet), and completion-time minting requires either a provisional producing LOT + a repoint step, or minting the FG LOT at tray-open with a fixed `PieceCount = PartsPerTray`. Which is correct depends on the **physical process** — when parts are laser-etched relative to when the tray/LOT is formed — a customer/domain question.

Serialized lines are the minority of MPP lines (most are non-serialized). The non-serialized reconciliation (A1–A3, A5, A6) plus M2/M3 and the inventory popup deliver the bulk of Spec 2 value without this.

**To resume A4:** confirm with the customer the etch-vs-tray-completion ordering, then pick:
1. **Completion-time repoint** — etch serials against a provisional producing LOT (their source machined/sub-assembly LOT); at completion, `Assembly_CompleteSerializedTray` mints the FG LOT (`PieceCount = #placed serials`) and `UPDATE`s each placed `SerializedPart.ProducingLotId` to it.
2. **Mint-at-open** — mint the FG LOT when the serialized tray is opened (`PieceCount = PartsPerTray`, consume BOM upfront); serials etch directly against it.

Reference: `docs/superpowers/plans/2026-07-02-machining-assembly-plant-floor-flow.md` Task A4; `sql/migrations/repeatable/R__Lots_SerializedPart_Mint.sql`, `R__Lots_ContainerSerial_Add.sql`.
