# MPP MES — User Journeys

**Project:** Madison Precision Products MES Replacement
**Purpose:** Narrative walkthrough of the two primary user experiences — Configuration and Plant Floor
**Status:** Working draft — assumptions and open decisions flagged at end
**References:** `MPP_MES_SUMMARY.md`, `MPP_MES_DATA_MODEL.md`, Scope Matrix

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 0.1 | 2026-04-06 | Blue Ridge Automation | Initial user journeys — 2 narrative arcs, 19 assumptions, impact matrix, validation log |
| 0.2 | 2026-04-09 | Blue Ridge Automation | Added decision text and status tags to all 19 assumptions. 4 resolved (UJ-06, UJ-15 + mapped OI-01, OI-08, OI-09). 8 pending customer validation, 4 pending internal review (Ben), 7 remain open. Added status legend. |
| 0.3 | 2026-04-09 | Blue Ridge Automation | UpperCamelCase naming convention applied to all DB references. Department references updated to Area per ISA-95. |
| 0.4 | 2026-04-10 | Blue Ridge Automation | Location model references updated for the new three-tier polymorphic model (LocationType → LocationTypeDefinition → LocationAttributeDefinition). See FDS v0.4 for details. |
| 0.5 | 2026-04-15 | Blue Ridge Automation | Aligned to data model v1.3 and Phase 5/6 SQL delivery. Configuration Tool arc now reflects three-state versioning (Draft / Published / Deprecated) for RouteTemplate, OperationTemplate, and Bom — engineers author across sessions, publish to release for production, and deprecate rather than delete. OperationTemplate data collection described via the DataCollectionField junction (configurable per step) instead of hardcoded flags. Location management references the SortOrder + MoveUp/MoveDown arrow-button pattern (no drag-and-drop, per project convention). Plant Floor arc references HoldEvent as a single place/release lifecycle table consistent with DowntimeEvent. Added note that all Configuration Tool screens bind to Ignition Named Queries over stored procs returning a single result set (see FDS §11 FDS-11-011). |
| 0.6 | 2026-04-21 | Blue Ridge Automation | **Security model rewrite (OI-06 closed — Phase C of the 2026-04-20 OI review refactor).** Operator identity narrative updated end-to-end. Carlos Die Cast scene now shows the initials-based presence pattern (`CM` pre-populated on the LOT creation screen, defeasible before submit). UJ-§1 "Operator Authentication & Session Model" renamed to "Operator Identity & Elevation Model" and closed as Resolved. 5-minute timeout, clock number, and PIN references removed. 30-minute idle re-confirmation popup described. Elevated actions use per-action AD prompts (no convenience login). See FDS §4 for the full specification. |
| 0.7 | 2026-04-22 | Blue Ridge Automation | **Phase E Group 4 — narrative additions for OI-11, 15, 20, 22.** Arc 2 now references: (1) the **Track** tool at the Sort Cage scene — Diane enters a serial number into the home-tile Track screen and gets the full genealogy tree without leaving her context (OI-15 / FDS-12-012..014); (2) the **Part Identity Change** at the Casting → Trim Shop boundary — added a short scene showing the operator confirming the rename from the cast part number to the trim part number, creating the `ItemTransform` row (OI-11 / FDS-05-033..035); (3) **Scrap source choice** called out in the Sort Cage disposition — Diane scraps from Location (in-process at the Machine Shop) vs Inventory (unallocated stock), clarifying the two buttons now present on Lot Details (OI-20 / FDS-06-023a); (4) **Hold Management screen** already described at the 1:15pm scene — reference updated to make explicit that it is the dedicated top-level Hold tile (OI-22 / FDS-08-007a). No new assumption rows added — these additions ride on existing UJ-03 (split), UJ-08 (merge), UJ-17 (vision conflict) threads. |
| 0.7-rev | 2026-04-22 | Blue Ridge Automation | **OI-11 reversal — Trim Shop narrative simplified.** The Casting → Trim scene originally described writing a `Parts.ItemTransform` row as the rename bridge. On review the ItemTransform table was redundant with `Workorder.ConsumptionEvent`, so the schema was removed (Data Model v1.8-rev, FDS v0.10-rev). The narrative now describes the same boundary as a normal 1-line BOM consumption — trim part has cast part as its sole component at QtyPer=1; the MES writes a `ConsumptionEvent` + `LotGenealogy` row in the same way as any assembly. Operator-visible flow is unchanged ("Receive as trim part?" prompt stays). OI-11 closed ✅ in Open Issues Register v2.6. |
| 0.9-rev | 2026-05-01 | Blue Ridge Automation | **Screenshot refresh from updated mockup (plantFloor.html + Config Tool).** Five existing screenshots replaced with updated captures: Plant Hierarchy (attribute values filled in), Item Master Container Config + Routes tabs, Operation Templates (DC-5G0 v1 with RequiresSubLotSplit checkbox visible), Tools Attributes tab (Maintenance Interval / Last Maintained / Tonnage values). Three new screenshots added: Tools Cavities tab (DC-042 showing 2 active cavities + 1 closed for porosity), Tools Assignments tab (current mount on DC Machine #7 + full assignment history), and Lineside Inventory supervisory view (ASSY-FRONT Cell #3 with BRG-INSERT-M8 empty and SLV-GASKET-5G0 low — inserted into the 11:30am Assembly section). |
| 0.9 | 2026-04-29 | Blue Ridge Automation | **FDS v0.11m reconciliation pass — UJ aligned to FDS as source of truth.** Three workflow reframes from the FDS continuity + clarity passes (v0.11k/l/m) propagated into the Plant Floor narrative arc plus a batch of assumption-status flips. **8:30am Trim Shop:** scene heading drops "and Changes Identity"; the Casting → Trim part-rename paragraph removed (per FDS-05-033 v0.11m the LOT keeps its cast-part identity through Casting and Trim); replaced with a **Trim is yield loss, not a rename** paragraph (sprue removal / deburr / wash via `RejectEvent` on the same LOT) plus a **Trim OUT — sub-LOT split + route to Machining FIFO** paragraph (FDS-05-009 — split fires at Trim OUT, not Machining IN; operator selects destination Cell by scan or dropdown per FDS-02-009). **10:00am Machining:** whole scene rewritten — operator picks next sub-LOT from the Cell's FIFO queue at Machining IN (no scan-to-receive); BOM-driven part-identity rename `5G0-TRIM` → `5G0-MACHINED` fires here per FDS-05-033; Machining OUT is event-driven via PLC `OperationComplete` with auto-`LotMovement` to the coupled downstream Cell (`CoupledDownstreamCellLocationId` LocationAttribute, FDS-06-008); operator never scans Machining OUT; literal date-prefixed LOT names (`2026-04-06-0001-A/B`) replaced with sequence-minted `LotName` references. Voice changes from Carlos to a separate machining operator. **11:30am Assembly + non-serialized callout:** rewritten for FDS-06-014 tray-level closure — hardcoded "48 parts (4 trays × 12)" replaced with configured-value references (`TraysPerContainer × PartsPerTray` per `Parts.ContainerConfig`); container fill is MES-side accumulation of validated tray closes (no separate `ContainerFullFlag` PLC tag); non-serialized callout now lists three peer `ClosureMethod` values — `ByCount`, `ByWeight`, `ByVision` (the third is new in v0.11m). **End of Shift:** rewritten — minute-level adjustments (`+30`/`+10`/`+110`) removed (FDS-09-009 explicitly forbids); workflow now matches FDS-09-013 — ~15-min visibility window before scheduled shift end, dedicated terminals = single button press, shared terminals = button + initials + time category + lunch yes/no + breaks selected + submit; submission writes `Oee.DowntimeEvent` rows with durations from shift schedule. Open events at the boundary stay open (per OI-03 + FDS-09-010). "Second shift badges in" removed (contradicts the v0.6 initials-only security rewrite); incoming presence established by FDS-04-009 first-action confirmation. **Configuration Tool arc — Building the Plant:** ISA-95 hierarchy wording corrected ("Lines" → "WorkCenters", "Machines" → "Cells"); Cell-tier kinds enumerated from the data model. `NumberOfCavities` removed as a `DieCastMachine` LocationAttribute example (cavity data lives on `Tools.ToolCavity`). **Assumption status flips:** UJ-12 Terminal-to-Machine Mapping → ✅ Resolved (decision text expanded for Dedicated/Shared two-mode model + scan-or-dropdown per FDS-02-009/010/011); UJ-14 Warm-Up Shots → ✅ Resolved (Option A confirmed per OIR v2.14); UJ-16 Hardware Interlock Bypass → ✅ Resolved (Option A — flag on `Lots.ContainerSerial` per OIR v2.14); UJ-18 Event Processing Sync vs Async → ✅ Resolved (OI-01 no-outbox + FDS-01-014 Gateway-script-async + FDS-07-005/006a/b print extraction + UJ-04 AIM pool together close it). |
| 0.8 | 2026-04-24 | Blue Ridge Automation | **Arc 2 model revisions (2026-04-23 session) — narrative alignment with Data Model v1.9 / FDS v0.11.** Arc 2 scenes updated: **6:20am Die Cast (Carlos)** — Tool auto-populates on Cell selection from the active `Tools.ToolAssignment`; Carlos confirms the populated die; an **Edit** button (elevated AD prompt) triggers inline `ToolAssignment_Release` + `_Assign` to correct the system of record when the physical die doesn't match; LOT creation is **lazy and operator-driven** (Carlos logs a LOT whenever he gets to the terminal, not at a prescribed moment); the die's multiple active cavities produce **N parallel independent LOTs, not sublots** (each LOT has its own `ToolCavityId` set at creation, fills at its own rate, closes independently via explicit Complete+Move). **8:30am Trim Shop (Diane)** — "check-in" fires a `Workorder.ProductionEvent` checkpoint row carrying cumulative `ShotCount` / `ScrapCount` as-of-this-moment; deltas since Carlos's die-cast checkout are derived via `LAG()` at read time. **10:00am Machining** — sub-LOT split is still a sublot pattern (parent FK + split genealogy); parent LOT was Machining-origin so it already had NULL `ToolId`/`ToolCavityId`; children inherit NULL. **2:00pm Sort Cage** — merge narrative (when any is triggered) produces a merged LOT with NULL `ToolId` / `ToolCavityId` — Tool-specific trace reconstructed via `LotGenealogy` walk of pre-merge source LOTs. Also: every LOT `LotName` is minted from the new `Lots.IdentifierSequence_Next @Code='Lot'` proc per FDS-16-002 (replaces Flexware's `IdentifierFormat` counter). Assumption UJ-02 (LOT creation) gains lazy-by-operator note. UJ-03 (sub-LOT split) clarified — sublots are the Machining split only; cavity-parallel Die Cast LOTs are not sublots. UJ-08 (merge) adds merged-LOT-has-NULL-Tool note. Source: `docs/superpowers/specs/2026-04-23-arc2-model-revisions.md`. |

---

## Two Story Arcs

The MES has two fundamentally different audiences using the same underlying data model:

| Arc | Who | When | What They See |
|---|---|---|---|
| **Configuration Tool** | Engineers, production control, IT | Before production, during setup changes | Plant model, item master, routes, specs, code tables |
| **Plant Floor MES** | Operators, supervisors, quality, shipping | Every shift, all day | LOT creation, production recording, container packing, holds |

The configuration tool creates the rules. The plant floor MES enforces them.

---

## Arc 1: The Configuration Tool — "Before the First Part Moves"

Before a single LOT can be created on the shop floor, an engineer at Madison Precision Products has to teach the MES what the plant looks like, what it makes, and how it makes it. This is the configuration tool — the Ignition Perspective application that probably lives behind a different navigation root than the shop floor screens, accessible only to users whose AD accounts carry an engineering or admin role in Ignition.

### Building the Plant

The engineer's first job is the plant model. They open the Location Management screen and start building the hierarchy from the top down. Madison Precision Products is the Site. Under it, they create Areas — Die Cast, Trim Shop, Machine Shop, Production Control. Under each Area, **WorkCenters** group related production resources (a paired Machining + Assembly WorkCenter, an inspection line, etc.). Under each WorkCenter, individual **Cells** — die cast presses, CNC machines, assembly stations, terminals, inspection stations, scales, inventory locations. The plant has ~230 Cells across ~7 Areas. Each one is a row in the same `Location` table, differentiated by its `LocationTypeDefinition` (Cell-tier kinds include `DieCastMachine`, `CNCMachine`, `TrimPress`, `AssemblyStation`, `SerializedAssemblyLine`, `InspectionStation`, `InventoryLocation`, `Terminal`, `Scale`).

![Plant Hierarchy — DC Machine #7 selected, Location Details + Attributes panels](<mockup_screenshots/Screenshot 2026-05-01 141117.png>)

*Plant Hierarchy screen: ISA-95 tree on the left (Enterprise → Site → Area → WorkCenter → Cell); Location Details panel on the right with Name, Code, Parent, Description, and Sort Order; Attributes panel below showing filled-in DieCastMachine attribute values (Tonnage = 400 tons, ConfirmationMethod = None, RefCycleTimeSec = 62.5 sec).*

As they create each machine, the system shows them the attribute definitions for that location type. A Die Cast press might need `Tonnage` and `RefCycleTimeSec` (cavity count belongs to the die that's currently mounted, not the press — see `Tools.ToolCavity` in §7 of the Data Model). A machining Cell might need `SpindleCount` and `CoolantType`. These attribute definitions were themselves configured earlier — someone decided what metadata each type of location carries. The engineer fills in the values. They also create the logical locations: Receiving Dock, Shipping Dock, WIP Storage, Sort Cage.

![Add Location modal](<mockup_screenshots/Screenshot 2026-04-30 122618.png>)

*Add Location modal: selects the LocationTypeDefinition from a dropdown, then fills Name, Code, and an optional Description. The new row lands in the tree under its parent.*

![Location Type Definitions modal — Cell tier, DieCastMachine selected](<mockup_screenshots/Screenshot 2026-04-30 122635.png>)

*Location Type Definitions modal: the engineer picks an ISA-95 tier (Cell shown), selects a definition (DieCastMachine), and manages the attribute schema — Name, Data Type, Required, Default Value, UOM, and Description per attribute. Changes here affect all locations of that type immediately.* These are Inventory Location types — they don't have cycle times, but they're real places where LOTs live.

Then they set up terminals. Each Ignition client station on the floor gets a `Terminal` record — its IP address, which location it's at, which Zebra printer it talks to, whether it has a barcode scanner. This is how the system knows that when operator Maria scans a LOT at terminal DC-05, that action happened at Die Cast Machine #5, and any label it prints goes to the Zebra on the table next to her.

### Configuring Dies and Tooling

Before the first shot runs, someone has to load the die catalog. MPP's production depends on a small number of aluminum die cast dies — each die is a tool that runs in a specific press tonnage range, has between one and four cavities, and has a die rank that determines which other dies it can be blended with at the Sort Cage. The engineer opens the Tools screen and creates a record for each die: part number, type, and the custom attributes for that type (Tonnage, RefCycleTimeSec, ConfirmationMethod). Under each die they configure its cavities — Cavity A, Cavity B, etc. Cavities are the actual production units; the Die Cast scene on the floor will ask Carlos which cavity he's logging each LOT against.

Then they configure the Die Rank Compatibility matrix. Die ranks are categories (Rank 1, Rank 2, Rank 3, etc.) used to control which LOTs can be merged at the Sort Cage — only LOTs from compatible-rank dies can be combined without a quality escalation. The matrix is symmetric: if Rank 1 can merge with Rank 2, then Rank 2 can merge with Rank 1. The upper triangle is editable; the lower triangle is a read-only mirror. This config lives in `Tools.DieRankCompatibility` and is referenced when the Sort Cage operator attempts a merge.

Die assignment to a press (which die is physically in which machine right now) is a runtime action, not a config-time action. The floor handles that via `Tools.ToolAssignment` — see the 6:20am Die Cast scene.

![Tools screen — DC-042 Front Cover Die, Attributes tab](<mockup_screenshots/Screenshot 2026-05-01 141430.png>)

*Tools screen: die list on the left with status badges (ACTIVE, UNDER REPAIR, RETIRED). Detail panel shows Code, Name, Tool Type, Die Rank, Status, and Description. Attributes tab displays custom attribute values — Maintenance Interval = 25,000 shots, Last Maintained = 04/01/2026, Tonnage = 800. Shot counts are derived at runtime from production events, not stored on the tool record.*

![Tools — DC-042 Cavities tab, 2 active 1 closed](<mockup_screenshots/Screenshot 2026-05-01 141440.png>)

*Cavities tab on DC-042: three numbered cavities — #1 and #2 ACTIVE (each with optional notes field, Close and Scrap buttons), #3 CLOSED ("Shut off 2026-03-14 — porosity defects," with Reactivate and Scrap buttons). Active cavities appear in the Cavity dropdown on the Die Cast LOT entry screen; closed cavities are excluded.*

![Tools — DC-042 Assignments tab, currently mounted on DC Machine #7](<mockup_screenshots/Screenshot 2026-05-01 141452.png>)

*Assignments tab on DC-042: green active banner shows the die is currently mounted on DC Machine #7 (assigned 2026-04-29 06:02 by CM, Release button). Historical assignment log shows Cell, Assigned At, Released At, Assigned By, Released By, and Notes — including a "Loan from line 7" period on DC Machine #3. Mount to Cell triggers ToolAssignment_Release + ToolAssignment_Assign in one transaction.*

![Add Die modal](<mockup_screenshots/Screenshot 2026-04-30 122911.png>)

*Add Die modal: Code, Name, Die Rank dropdown, and optional Description. Creates the die record; cavities and assignments are added on the detail screen.*

![Tool Attribute Schema — Die](<mockup_screenshots/Screenshot 2026-04-30 122928.png>)

*Tool Attribute Schema modal: defines the custom attributes that appear on every die's Attributes tab. Schema changes affect all dies immediately. Shown with Tonnage (DECIMAL, required), RefCycleTimeSec (DECIMAL, default 60.0), and ConfirmationMethod (NVARCHAR, default None).*

![Die Ranks — merge compatibility matrix](<mockup_screenshots/Screenshot 2026-04-30 122952.png>)

*Die Ranks screen: left panel lists ranks with Edit buttons. Right panel is the merge compatibility matrix — click a cell to toggle green (can merge) / red (blocked). The lower triangle mirrors the upper automatically. This matrix governs which LOTs can be combined at the Sort Cage.*

### Defining What We Make

Next, the item master. The engineer creates items — each one a part number that MPP either manufactures or receives from a vendor. They classify each item: Raw Material, Component, Sub-Assembly, Finished Good, Pass-Through. They set the Macola ERP cross-reference number for each part so the two systems can talk when that integration goes live. They set the default sub-lot quantity — how many pieces go into each sub-LOT when a parent LOT is split at Trim OUT (FDS-05-009). They set `PartsPerBasket` — the maximum pieces per basket — for reasonability checks at LOT creation.

For each finished good that ships to Honda, they create a container configuration. The 5G0 Front Cover, for example, ships in containers with 4 trays, 12 parts per tray, closure method `ByCount` (serial validation), serialized, dunnage code RD-5G0F. The RPY Cam Holder ships 6 trays, 24 per tray, closure method `ByWeight`, not serialized. These configs drive the container lifecycle on the floor — the MES knows when a container is full.

![Item Master — 5G0 Front Cover Assy, Container Config tab](<mockup_screenshots/Screenshot 2026-05-01 141134.png>)

*Item Master screen: header fields (Part Number, Item Type, UOM, Description, Macola Part #, Unit Weight, Weight UOM, Default Sub-LOT Qty, Parts Per Basket) with five tabs below. Container Config tab shown: TraysPerContainer=4, PartsPerTray=12, Serialized=Yes, ClosureMethod=ByCount, DunnageCode=RD-5G0F, CustomerCode=HONDA-5G0.*

![Add Item modal](<mockup_screenshots/Screenshot 2026-04-30 122811.png>)

*Add Item modal: Part Number, Item Type, UOM, Description, Unit Weight, Weight UOM, Default Sub-LOT Qty, Max Lot Size (PartsPerBasket), and Macola Part # fields. Creates the item record; tabs (Routes, BOMs, Quality Specs, Eligibility) are populated on the detail screen.*

### Defining How We Make It

Now routes. The engineer creates a route template for each item — the ordered sequence of operations it passes through. The 5G0 Front Cover route might be: Die Cast → Trim → Machine (CNC) → Assembly Front → Pack & Ship. Each step in the route points to an operation template — a reusable definition of what data to collect at that type of operation. The Die Cast operation template says: collect die info, collect cavity info, collect weight, collect good count, collect bad count. The Assembly operation template says: requires serial number, requires material verification, collects good count. These flags drive the UI — the shop floor screen at an assembly station looks different from the one at a die cast press because the operation template tells it what fields to show.

The engineer also creates the part-to-location eligibility map. Not every machine can run every part. The 5G0 can run on Die Cast machines 3, 7, and 12, but not on machine 15 (wrong tonnage). This map is what lets the MES validate that when an operator starts producing 5G0 parts on machine 7, that's a legal combination.

![Item Master — Routes tab, 5G0 Front Cover v2 Published](<mockup_screenshots/Screenshot 2026-05-01 141214.png>)

*Routes tab: version selector with Published/Draft badge and New Version button. Four-step published route — Die Cast (DC-5G0 v1), Trim Shop (TRIM-5G0 v1), Machine Shop (CNC-5G0 v1), Prod Control (ASSY-FRONT v1). Published routes are read-only — click New Version to begin editing a draft copy.*

![Item Master — BOMs tab, 5G0 Front Cover v1 Published](<mockup_screenshots/Screenshot 2026-04-30 122732.png>)

*BOMs tab: same version/publish pattern as Routes. Each BOM line shows Component, Part Number, Qty, and UOM. Version 1 shows Front Cover Casting (5G0-C, qty 1) and Mounting Pin (PNA, qty 2).*

![Item Master — Eligibility tab, Die Cast area filter](<mockup_screenshots/Screenshot 2026-04-30 122756.png>)

*Eligibility tab: area dropdown filter. Machine Eligibility table lists every Cell in the selected area with its Code, Tonnage, and an Eligible checkbox. DC-015 (250 tons) is unchecked — the 5G0 requires a 400-ton press.*

![Operation Templates — Die Cast 5G0 Front Cover DC-5G0 v1](<mockup_screenshots/Screenshot 2026-05-01 141243.png>)

*Operation Templates screen: left panel groups templates by area with version badges. Detail panel shows Code, Name, Area, Description, Requires Sub-LOT Split checkbox, and a Data Collection Fields table. DC-5G0 v1 shown with 5 required fields: DieInfo, CavityInfo, Weight, GoodCount, BadCount. Arrow buttons reorder fields; × removes a field.*

For assembled products with BOMs, the engineer creates versioned bills of material. The 5G0 Front Cover Assembly consumes one 5G0 casting and two PNA mounting pins. Version 1 of the BOM is effective from January 2026. If engineering changes the design in March, they create version 2 — but every production record from January still points to version 1.

### Defining Quality Standards

The engineer creates quality specs — also versioned. For the 5G0 Front Cover, the spec says: measure surface flatness (target 0.002", lower limit 0.001", upper limit 0.003"), check bore diameter (target 25.40mm ± 0.02mm), visual inspection for porosity (pass/fail). Each attribute has its data type, UOM, target, and limits. When an inspector on the floor takes a sample, the screen they see is generated from this spec — the system knows what to ask for because the engineer defined it here.

They also load the defect codes — approximately 145 of them, organized by department. Die Cast gets codes for porosity (135), cold shut, flash, misrun. Machine Shop gets codes for out-of-tolerance (122 "Dimensional"), tool marks (154), surface finish (143). There are also codes for Trim Shop, Production Control, Quality Control, and a High Speed Supplier Parts (HSP) department for vendor-part defects (codes 247–253). Each code carries an `IsExcused` flag for future OEE quality calculations.

![Item Master — Quality Specs tab, linked specs for 5G0 Front Cover](<mockup_screenshots/Screenshot 2026-04-30 122744.png>)

*Quality Specs tab on the Item Master: lists all quality specs linked to this item, their active version, and Published/Draft status. "Go to spec →" navigates to the spec detail. Two specs shown: 5G0 Dimensional Spec v2 and 5G0 Visual Inspection v1.*

![Quality Specs — 5G0 Dimensional Spec v2, Attributes tab](<mockup_screenshots/Screenshot 2026-04-30 123016.png>)

*Quality Specs screen: item filter dropdown, spec list with version badges. Detail panel shows Name, Linked Item, Linked Operation, version selector, and an Attributes table — each row has Attribute, Type, Target, Lower, Upper, UOM, and Trigger.*

![Defect Codes — all areas](<mockup_screenshots/Screenshot 2026-04-30 123030.png>)

*Defect Codes screen: area filter and search on the left, flat list on the right with Code, Description, Area, and Excused checkbox. Edit button opens an inline editor. Codes span Die Cast (DC-), Machine Shop (MS-), Trim Shop (TS-), and HSP (HSP-).*

### Defining Downtime Vocabulary

Finally, the ~660 downtime reason codes. Equipment failure on the 400-ton press. Mold change on die #7. Quality hold on line 3. Scheduled maintenance. Each code belongs to a department and a type (Equipment, Mold, Quality, Setup, Miscellaneous, Unscheduled), and carries an `IsExcused` flag. Shift schedules get defined here too — first shift 6am–2pm Monday through Friday, second shift 2pm–10pm, weekend overtime pattern.

Every one of these configuration changes is logged to `ConfigLog` — who changed what, when, what the old value was.

![Downtime Codes — all areas and types](<mockup_screenshots/Screenshot 2026-04-30 123057.png>)

*Downtime Codes screen: area + reason-type filters with search and Include Deprecated toggle. Each code shows Code, Description, Area, Type (Equipment / Setup / Quality / Mold), and Excused checkbox.*

![Shift Schedules](<mockup_screenshots/Screenshot 2026-04-30 123110.png>)

*Shift Schedules screen: each row shows Name, Start, End, active day-of-week buttons (M/T/W/T/F/S/S), and Effective date. First Shift 06:00–14:00 weekdays, Second Shift 14:00–22:00 weekdays, Weekend OT 06:00–16:00 Sat/Sun. End-of-shift break buttons derive their times and durations from these records.*

![System — Audit Log](<mockup_screenshots/Screenshot 2026-04-30 123132.png>)

*Audit Log screen: date range, entity type, and user filters. Result table shows Timestamp, User, Entity Type, Entity, Event, and Description of each change. Entries are written by every Configuration Tool mutation stored proc.*

![System — Failure Log](<mockup_screenshots/Screenshot 2026-04-30 123143.png>)

*Failure Log screen: date range, entity type, and procedure filters. Top panels summarize top rejection reasons and top failing procedures over the selected window as bar charts. Detail table below shows the individual failed calls with Timestamp, User, Entity, Procedure, and Failure Reason.*

---

## Arc 2: The Plant Floor MES — "A Day in the Life of a LOT"

It's 6:15am on a Tuesday. First shift has started. The aluminum is already molten.

![Plant Floor Home — Supervisor Dashboard tile](<mockup_screenshots/Screenshot 2026-04-30 125428.png>)

*Supervisor Dashboard (elevated): seven live tiles auto-refreshing every 30 seconds via Gateway broadcast — Open Downtime Events, Paused LOTs, Shift Availability %, AIM Shipper Pool depth by part number, Stranded Prints count, Top Defect shift-to-date, Active Operators, and Containers Shipped Today. All tiles are drillable.*

### 6:20am — Die Cast: A LOT Is Born

Carlos is running die cast machine #7 today. He's making 5G0 Front Covers — die **DC-042**, which is a 2-cavity die running both cavities A and B. The furnace is hot, the die is mounted, and the first shot cycle completes. Castings drop into the trim press, get trimmed, and fall into two separate baskets beside his station — one fed by cavity A, one by cavity B.

![Plant Floor Home — Location Details tab, Press 7 selected](<mockup_screenshots/Screenshot 2026-04-30 123512.png>)

*Home page Location Details view for Press 7: six live status cards (Current LOT, Last Operator, Active Tool, Open Downtime, Cycle Rate, Shift Production) plus four action buttons — View Terminal, Open Current LOT, Edit Tool Assignment, Place Hold. An orange downtime card (EQ-DIE-STICK, awaiting reason confirm) is visible.*

Carlos doesn't rush to the terminal at every shot. He lets the baskets fill while he walks other machines. Some time later the cavity-A basket is full. He peels a pre-printed LTT barcode label off his stack (MPP pre-prints these in batches per FRS 2.2.1) and sticks it on the cavity-A basket. He walks to the Ignition terminal — dedicated to Machine #7, his initials **CM** already set as the active operator presence.

![Operator Presence — Dedicated Terminal initials entry](<mockup_screenshots/Screenshot 2026-04-30 123815.png>)

*Operator Presence screen on a dedicated terminal: single Initials field with a Set Presence button. No password, no PIN — initials map to AppUser_GetByInitials. Presence persists through the shift subject to a 30-minute idle re-confirm.* He scans the LTT barcode.

The MES opens the LOT creation screen. The **Cell** is auto-resolved to Machine #7 from the terminal's machine context. The **Tool** field pre-populates with **DC-042** — this came from `Tools.ToolAssignment_ListActiveByCell(@CellLocationId)` which looked up the currently-mounted tool on Machine #7. Carlos glances at the die, confirms the system is right, and proceeds. (If the physical die had been swapped without anyone updating the MES, Carlos would hit the **Edit** button — an AD elevation prompt fires, a supervisor logs in, the inline `Tools.ToolAssignment_Release` + `_Assign` correct the system of record in one transaction, and the Tool field updates. No production data is captured against the wrong die.)

He picks **Cavity A** from the cavity dropdown (filtered to active cavities on DC-042), confirms piece count (48 pieces), and hits submit. The MES validates: is 48 ≤ `PartsPerBasket` for 5G0 (`Item.PartsPerBasket`)? Yes. Is 5G0 eligible on Machine #7? Yes. Is the tool-cell assignment current? Yes. Is Cavity A active? Yes.

![Die Cast LOT Entry — shared terminal, Press 7, LTT scanned](<mockup_screenshots/Screenshot 2026-04-30 123530.png>)

*Die Cast LOT Entry screen: Active Cell shown at top with a Change button. LTT Barcode field (scanned — mints a new LOT on first scan), Operator Initials (inline on a shared terminal), Item (auto-resolved from the mounted Tool), Tool (auto-populated from ToolAssignment_ListActiveByCell with an Edit button for elevated reassignment), Cavity dropdown (filtered to active cavities on the mounted die), Piece Count (≤ PartsPerBasket), and optional Weight. Right panel shows Cavity A cumulative ShotCount and ScrapCount plus a Reject Entry panel.*

![Change Active Cell modal — shared terminal context selector](<mockup_screenshots/Screenshot 2026-04-30 123743.png>)

*Change Active Cell modal: operator scans a Cell barcode or picks from a dropdown showing descendant Cells of the terminal's parent Location. All dependent fields (Tool, Cavity, FIFO queue, etc.) refresh on confirmation.*

A LOT is created — `LotName` minted via `Lots.IdentifierSequence_Next @Code='Lot'` which returns `MESL1710935` (the counter continues from the Flexware cutover seed). `ToolId` points at DC-042. `ToolCavityId` points at Cavity A. Origin: Manufactured. Status: Good. Location: Machine #7. A first `Workorder.ProductionEvent` checkpoint row is written with cumulative `ShotCount` = total shots through cavity A so far today, cumulative `ScrapCount` = 3 (that porosity run earlier). Since this is the LOT's first event, there's no previous event to diff against yet — the next event will compute its delta via `LAG(ShotCount) OVER (PARTITION BY LotId ORDER BY EventAt)`.

The cavity-B basket fills on its own rhythm. Later — maybe 40 minutes, maybe two hours — Carlos logs it separately. It gets its own LOT (e.g., `MESL1710936`), its own `ToolCavityId = Cavity B`, its own LTT label. **The two LOTs are peers, not sublots.** They share a Tool but nothing else. Each fills independently. Each closes independently via an explicit "Complete + Move" when Carlos walks the finished basket away from the machine.

Carlos had 3 no-good parts from an earlier shot — porosity. The `ScrapCount` on this first checkpoint already reflects them (cumulative counter). Against that ProductionEvent he also records a `RejectEvent` with defect code DC-POR-01 quantity 3. Per FRS Section 4, reject/scrap data is retained for analysis but is not considered part of the permanent production record in the same way good counts are — MPP may elect not to record rejects at every manufacturing step.

He has a downtime event too — the die stuck at 6:45am, took 12 minutes to clear. He logs it: reason code EQ-DIE-STICK, start 6:45, end 6:57. If the PLC had detected it first, the `DowntimeEvent` would have been created automatically with source=PLC, and Carlos would just need to assign the reason code. Note: the legacy paper forms track downtime as cumulative minutes subtracted from a 425-minute base runtime (with adjustments for lunch, breaks, and overtime). The new MES captures discrete start/end events, which is a more granular model — the cumulative shift total is derived from the events rather than entered directly.

### 8:30am — Trim Shop: LOT Moves Through the Plant

The basket with LOT `MESL1710935` gets wheeled to the Trim Shop. An operator there scans the LTT barcode. The MES records a `LotMovement` — from Die Cast Machine #7 to Trim Area.

![Trim Station — Idle, Lineside Inventory queue visible](<mockup_screenshots/Screenshot 2026-05-01 142156.png>)

*Trim Station idle state: Active Cell header (Trim Cell 3) with Change button. Active LOTs at Trim Cell 3 panel shows the currently checked-in LOT (MESL1710931, 5G0-TRIM-4102, 48 pcs) with a Resume → OUT button. Lineside Inventory panel below lists LOTs awaiting pick in FIFO order — Position, LotName, source (Press 7, DC-042/Cavity A), status badge, time in storage, and a Pick → IN button. Scan field auto-disambiguates: a lineside LOT goes to IN, an active LOT resumes to OUT.*

The scan-in also fires a **checkpoint `ProductionEvent`** at the trim station — cumulative `ShotCount` and `ScrapCount` as-of-arrival. Because this is the LOT's second event (the first was Carlos's die-cast checkpoint), deltas pop out immediately from the reader's `LAG()` window: "since last event, this LOT accumulated X shots and Y scrap." Reports that want operator-facing per-event deltas SHALL compute them that way rather than storing per-event `GoodCount` on the event row. Checkpoints are coarse — operators aren't at the terminal per shot, they log at natural breakpoints (basket close, area handoff, complete+move).

The Trim Shop has a different counting method than Die Cast. Parts come out of trim/deburr/wash in bulk, so the operator weighs the basket on a scale, reads the net weight, and the MES calculates a theoretical piece count based on the item's `UnitWeight` (per FRS 2.2.3). If the calculated count differs from the LOT's current piece count, the operator can update it — the MES records the adjustment but takes no further action on a count discrepancy (FRS 2.2.3: "MES takes no specific action if the LOT quantity has changed"). The `LotAttributeChange` table logs the old and new values. The checkpoint `ProductionEvent` captured the current cumulative counters; no per-event good/bad count is recorded — the `PieceCount` adjustment itself carries the truth going forward.

![Trim Station — Check IN, eligibility validation pass](<mockup_screenshots/Screenshot 2026-04-30 124705.png>)

*Check IN state: LTT barcode field with the scanned LOT resolved (LotName, Item, From Location, Pieces). A green eligibility banner confirms the direct ItemLocation match and MaxParts cap check. Operator Initials field (shared terminal), then Submit · Receive at Trim Cell 3.*

**Trim is yield loss, not a rename.** The LOT keeps its cast-part identity (`5G0-TRIM-4102` covers both Casting and Trim work) all the way through Trim OUT. Sprue removal, deburr, and wash are recorded as `Workorder.RejectEvent` rows on the same LOT — no new LOT, no `ConsumptionEvent`. The Honda backward trace from a shipped finished part lands on this single Trim LOT and reads the original Die Cast `ProductionEvent` rows directly without an extra hop. The part-identity rename to a machined Item (`5G0-MACHINED-4102`) fires later, at Machining IN — see the 10:00am scene.

![Trim Station — Check OUT, RequiresSubLotSplit ON](<mockup_screenshots/Screenshot 2026-04-30 124731.png>)

*Check OUT state: OperationTemplate banner (TrimOut · 5G0-TRIM-4102 v3) with RequiresSubLotSplit = ON · split + route shown at right. Closing ProductionEvent (TrimOut) section captures Operator Initials. Reject Entry · Trim Yield Loss section below records RejectEvents against the LOT with Trim-area Defect Code and Quantity.*

**Trim OUT — sub-LOT split + route to Machining FIFO (FDS-05-009).** When the Trim operator finishes their work on the LOT, they trigger Trim OUT. The MES presents a **sub-LOT split confirmation dialog** — the parent LOT splits N ways across N destination Machining Cells (default N=2, evenly split — e.g., 50 → 25/25). The operator MAY adjust the number of sublots and the per-sublot quantities; the total SHALL equal the parent's piece count. For each sub-LOT, the operator selects the destination Machining Cell either by **scan or dropdown** (FDS-02-009) — that selection writes the sub-LOT into the chosen Cell's FIFO queue. On confirm: N child LOTs are created (each inheriting the parent's `5G0-TRIM-4102` Item — the rename hasn't happened yet); `LotGenealogy` records the parent→child Split links; `LotMovement` rows record each sub-LOT moving from the Trim Cell to its destination Machining Cell; the parent LOT closes when all pieces have been distributed; LTT labels print for the children showing both the child and parent `LotName` (FDS-05-024).

![Sub-LOT Distribution — 2 destinations, 48 pcs split 24/24](<mockup_screenshots/Screenshot 2026-04-30 124742.png>)

*Sub-LOT Distribution panel: Total pieces shown at top right. Each row is a destination sub-LOT — operator enters Pieces and selects a Destination Machining Cell from a dropdown showing queue depth. + Add sub-LOT adds another row. Same Flex Repeater renders 1 row when RequiresSubLotSplit=0 (whole move) or N rows when =1. Submit · TrimOut + Split + Route commits in one transaction.*

![Trim Station — Error state, LOT not at this Cell](<mockup_screenshots/Screenshot 2026-04-30 124755.png>)

*Error state: scanned LOT is not in storage and is not currently active here. The CAN'T PROCESS THIS LOT HERE panel shows the scanned LotName, its current location (already past Trim), and who checked it in. Back to storage queue or Open LOT Detail.*

### 10:00am — Machining: Picking from FIFO + Identity Rename

The sub-LOTs that were routed at Trim OUT are now sitting in the destination Machining Cells' FIFO queues, waiting. At CNC machine 12, the machining operator (a different operator, not Carlos) walks up to the Cell's terminal. The screen surfaces the **Machining IN** view — there's no LTT scan-to-receive at this step. The terminal shows the FIFO queue for this Cell with each sub-LOT's `LotName`, parent LOT, piece count, and arrival time. The operator picks the next one in line (or overrides the order if production needs require it, per FRS 2.2.4).

![Machining IN — FIFO queue, 3 sub-LOTs awaiting](<mockup_screenshots/Screenshot 2026-04-30 124828.png>)

*Machining IN screen: no scan-to-receive. FIFO Queue panel lists sub-LOTs in arrival order with Position, LotName, parent LOT, Item, piece count, and arrival time. GOOD badge allows pick; HOLD badge blocks it. Pick (skip queue) is available on non-oldest positions. Active Machined LOT section below fills after a pick confirms.*

On pick, the MES applies the **BOM-driven part-identity rename**. The picked sub-LOT carries Item `5G0-TRIM-4102`; the active `Parts.Bom` for `5G0-MACHINED-4102` has a single `BomLine` with `ChildItemId = 5G0-TRIM-4102` at QtyPer=1. The MES prompts: *"This LOT is 5G0-TRIM-4102. Receive as 5G0-MACHINED-4102?"* The operator confirms. A new destination LOT is created under the machined Item with a fresh `LotName` minted from `Lots.IdentifierSequence_Next @Code='Lot'`; `Workorder.ConsumptionEvent` records the source trim LOT consumed and the machined LOT produced piece-for-piece; `Lots.LotGenealogy` records the parent/child link with `RelationshipType = Consumption`. The operator scans a fresh LTT for the new machined LOT.

![BOM-Driven Rename modal — Machining IN](<mockup_screenshots/Screenshot 2026-04-30 124844.png>)

*Receive sub-LOT — Rename to Machined Item modal: confirms the source sub-LOT (LotName · Item · piece count) and the target Item (BOM-resolved) with the new LotName that will be minted. Confirm Receive fires ConsumptionEvent + LotGenealogy + new LOT creation in one transaction.*

The CNC runs. Some parts come out of tolerance — those are recorded as `RejectEvent` rows against the machined LOT (defect code MS-OOT-01, the operator-entered quantity, the operator's initials). Good parts continue to accumulate.

**Machining OUT — event-driven (FDS-06-008).** When the machine signals completion of the operation on the LOT (PLC `OperationComplete` tag asserts), the MES does this **without operator action**: writes a checkpoint `ProductionEvent` capturing cumulative `ShotCount` and `ScrapCount` as-of-completion; reads the `CoupledDownstreamCellLocationId` LocationAttribute on this Machining Cell (configured at deployment to point at the paired Assembly Cell within the same WorkCenter); writes a `LotMovement` from this Machining Cell to the coupled downstream Cell; updates the LOT's `CurrentLocationId`. The operator never scans Machining OUT — the basket physically rolls to Assembly while the MES records the move. (When `CoupledDownstreamCellLocationId` is NULL — uncoupled / legacy path — completion writes only the `ProductionEvent`, and the LOT stays at the Machining Cell awaiting an operator-driven movement.)

### 11:30am — Assembly: Parts Are Consumed Into Finished Goods

Sub-LOT A (23 x 5G0 castings, machined) arrives at the 5G0 Assembly Front line. This is a serialized line — every finished assembly gets a laser-etched serial number. The line also needs PNA mounting pins — there's a LOT of those staged at the lineside location.

![Lineside Inventory — ASSY-FRONT Cell #3, 2 items needing attention](<mockup_screenshots/Screenshot 2026-05-01 142114.png>)

*Lineside Inventory supervisory view for ASSY-FRONT Cell #3: four header cards (Lineside Capacity 486/800 pcs from the LinesideLimit LocationAttribute, Components Configured = 4 active BOM items, Oldest Staged LOT = 4 h 22 m, Low / Empty Items = 2). Per-item rows sorted attention-first — BRG-INSERT-M8 EMPTY (0 pcs staged, Min 80 / Default 160 / Max 240, blocks assembly with a red error banner) and SLV-GASKET-5G0 LOW (8 pcs, below MinQuantity 50, amber warning). Each item shows a Scan In LOT button for replenishment. Items at OK level appear below the attention items.*

This is where the PLC integration kicks in. The Machine Integration Panel (MIP) is the handshake layer between the assembly automation and the MES. The assembly machine loads a casting from sub-LOT A, presses in two PNA pins, and the laser etches serial number `5G0F-240406-00147`. The PLC writes `DataReady=1`. The MES reads the serial number from `PartSN`, validates it (not a duplicate, correct format), writes `PartValid=1` back to the PLC, and the machine releases the part.

One important mode: the PLC also exposes a `HardwareInterlockEnable` flag (per touchpoint agreement 1.1). When the automation sets this to false, the MES validation is bypassed — the MIP writes `PartSN="NoRead"` and the machine proceeds without MES confirmation. This is an alternative operating mode, not an error state, and the MES must handle `NoRead` serial numbers gracefully.

Behind the scenes, the MES has just written a `ConsumptionEvent` — 1 piece consumed from sub-LOT A (5G0 casting) and 2 pieces consumed from the PNA pin LOT, producing serial number `5G0F-240406-00147`. A `SerializedPart` record is created, permanently linking that serial to sub-LOT A and the PNA LOT. Genealogy: this serial traces back through sub-LOT A → parent LOT `MESL1710935` → Die Cast Machine #7, Die DC-042, Cavity A, Carlos, 6:20am Tuesday. Honda can ask about any serial number and get the full tree.

The finished part drops into a container tray. The MES tracks which tray position it went into via `ContainerSerial`. **Closure is tray-level** (FDS-06-014): each tray validates as it closes per the `Parts.ContainerConfig.ClosureMethod` configured for the Item — for the 5G0 serialized line that's per-piece serial validation accumulating up to `PartsPerTray`, and the PLC asserts `TrayFullFlag` once that's reached. Container fill is the **MES-side accumulation** of validated tray closes. When the running count reaches the configured container capacity (`TraysPerContainer × PartsPerTray` per `ContainerConfig`), the MES closes the container and calls AIM — Honda's EDI system — to get a shipping ID. `GetNextNumber` returns shipper ID `SH-240406-0089`. The Zebra prints a ZPL shipping label. The `ShippingLabel` table records the print. The container status goes from Open to Complete.

![Assembly 5G0F Serialized Line — ByVision tray fill, container 3 of 4 in progress](<mockup_screenshots/Screenshot 2026-04-30 124910.png>)

*Assembly 5G0F Serialized Line: header cards show Active Source LOT, Lineside PNA Pins LOT, Container · Tray (3 of 4 · 8 of 12), and AIM Pool Depth. Tray Fill panel visualizes each tray position as a serial badge — green for validated, dashed for empty, orange for hardware-interlock-bypassed. Workorder Completion Gate panel appears when the container reaches full capacity — Confirm Completion claims an AIM ID, inserts a ShippingLabel row, and dispatches Zebra print.*

![Material Substitute · Supervisor Override Required modal](<mockup_screenshots/Screenshot 2026-04-30 124930.png>)

*Material Substitute override modal (UJ-09): fires when the operator scans a lineside LOT whose Item is not on the active BOM. Shows the scanned LOT vs. what the BOM expects. Requires Supervisor AD Username, Password, and a mandatory Reason for Substitute. Both operator and supervisor AppUserId are logged to Audit.OperationLog.*

> **Note on non-serialized lines:** The flow above describes the 5G0 serialized assembly line with full PLC/MIP integration. Non-serialized lines (e.g., 6B2 Cam Holder, RPY Assembly Sets) use the same **tray-level** validation model with a different `ClosureMethod` — three peers are configured per Item: **`ByCount`** (operator confirms tray quantity), **`ByWeight`** (OmniServer scale asserts the per-tray target on the PLC's `TargetWeightMetFlag`), and **`ByVision`** (camera validates each part pass/fail; PLC asserts `TrayFullFlag` at `PartsPerTray`). In every case the validation gate is the tray; the container fill is the MES-side accumulation of closed trays — no separate `ContainerFullFlag` PLC tag is required. The `TraysPerContainer` and `PartsPerTray` columns on `Parts.ContainerConfig` carry the configured capacities per Item.

![Assembly 6B2 Non-Serialized Line — ByWeight, live scale reading](<mockup_screenshots/Screenshot 2026-04-30 124949.png>)

*Assembly 6B2 Non-Serialized Line (ByWeight): Per-Tray Close panel shows a live scale reading (17.83 lb, approaching the 18.4 lb target) and TrayFullFlag status. Auto-close fires when the PLC asserts the flag. Container Completion Gate at bottom has the same atomic AIM-claim-and-print flow as the serialized line.*

### 1:15pm — A Quality Hold

The quality supervisor, Diane, gets a call from Honda. They've found a dimensional issue on 5G0 parts from yesterday's shipment. Diane doesn't know yet which LOTs are affected, but she needs to stop everything precautionary.

She goes to her terminal, opens the Hold Management screen, and searches for all open 5G0 LOTs and containers.

![LOT Search — cross-area lookup, 5 results](<mockup_screenshots/Screenshot 2026-04-30 125337.png>)

*LOT Search tab (elevated): search by LotName prefix, serial number, AIM Shipper ID, vendor lot, or part number. Status and Origin filters. Results sorted by recency — each row shows LotName, Item, piece count, location, status badge, and an Open button. CLOSED LOTs (split parents) appear with a note explaining why they closed.* She selects them and places a hold — type: CUSTOMER_COMPLAINT, reason: "Honda dimensional concern, pending investigation." The MES writes a `HoldEvent` for each LOT. Each LOT's status transitions from GOOD to HOLD. The `LotStatusHistory` records each transition. The `BlocksProduction` flag on the HOLD status code is true — from this moment, the MES prevents any further manufacturing operation completion activities against these LOTs (per FRS 3.16.10). The exact interlock point — whether the MES blocks at LOT selection time or at operation completion — is a design decision, but the effect is the same: held LOTs cannot progress through production.

![Hold Management — open LOTs and containers, batch place/release](<mockup_screenshots/Screenshot 2026-04-30 125404.png>)

*Hold Management screen (elevated): filter by LotName, AIM Shipper ID, Item, or Location; Hold Type and Reason fields. Left panel shows Open LOTs (4) with status badges and area context. Right panel shows Open Containers (3) with AIM Shipper ID and status. Select any combination across both panels and Place Hold on Selected or Release Selected Holds in one batch operation. Pre-shipped containers also fire AIM PlaceOnHold async.*

There's a container already packed and staged at the Shipping Dock — container `CTR-5G0-0412`, shipper ID `SH-240406-0089`. Diane places that on hold too. The MES calls AIM: `PlaceOnHold` with the shipper ID. AIM acknowledges. The container status goes to HOLD. It's not going on the truck.

### 2:00pm — The Sort Cage

After investigation, Diane determines the issue is isolated to cavity A of die #42, from yesterday's second shift only. From her desk she clicks the **Track** tile on the MES home page (FDS-12-012), types in one of the Honda-reported serial numbers, and immediately sees the full genealogy tree — cavity, die, Carlos, timestamp, and forward through to the containers and shipper IDs where that serial landed.

![Genealogy Lookup — tree for serial 5G0F-240429-00147, depth 4](<mockup_screenshots/Screenshot 2026-04-30 125350.png>)

*Genealogy Lookup tab (elevated): enter a LotName or SerialNumber, choose direction (ancestors, descendants, or both). Tree walks the closure table in one read (or recursive CTE if not materialized). Nodes are: SerializedPart at leaf → machined LOT → trim sub-LOT → cast/trim parent LOT → die-cast origin LOT at root. Each node shows its LotName, Item, origin, and status badge. Honda's "give me everything for serial X" lands at the ORIGIN node in one read.* From that tree she pivots into a search on `die=42 AND cavity=A AND createdAt BETWEEN yesterday 14:00 AND 22:00`. Three LOTs come back. Two are already in containers at the dock. One is still in WIP storage at the Machine Shop.

The WIP LOT is easy — she splits it. The MES creates a new child LOT with the 12 suspect pieces, leaves the remaining 36 in the original. She scraps the suspect child from the **Selected Location** (the Machine Shop Cell where the in-process pieces are) — not from Inventory — because the parts haven't yet returned to unallocated LOT stock. The `Workorder.ProductionEvent.ScrapSourceId` on the resulting scrap event records `Location` per FDS-06-023a so the scrap-rate analytics tie cleanly to the Machine Shop Cell. The suspect child LOT's status goes to SCRAP. The original stays on HOLD until she releases it.

> **Scope note:** This split-and-scrap workflow uses the LOT split and hold mechanisms, both of which are MVP. Formal NCM disposition codes (USE_AS_IS, REWORK, SCRAP, RETURN_TO_VENDOR) and structured failure analysis are FUTURE capabilities. In MVP, Diane uses holds and LOT splits as the operational tools for quality disposition; the `NonConformance` table is not populated. MPP currently uses Intelex for formal NCM/failure analysis tracking, separate from the MES.

![LOT Detail — MESL1710935, History tab](<mockup_screenshots/Screenshot 2026-04-30 125310.png>)

*LOT Detail screen: header cards show LotName, Item, Piece Count, Current Location, Tool, and Cavity. Four tabs — History (chronological event timeline), Genealogy, Paused-at, and Linked Container. History tab shows LotCreated, Die Cast ProductionEvent, RejectEvent, LotMovement, and Trim IN ProductionEvent — each with timestamp, event type, and key values. Place Hold, Scrap, and Back to Home actions at bottom.*

The two containers go to the Sort Cage — a physical location in the plant where containers are unpacked, parts re-inspected, and re-packed. The containers move (location: Sort Cage). Operators unpack them, inspect each part. Good parts get re-packed into new containers — the MES must support "part replacement" within containers (per FRS 2.1.10 and 2.2.7). For serialized parts, the MES handles serial number migration — the `ContainerSerial` records are updated to point to the new containers and tray positions.

![Sort Cage Workflow — Serialized, per-serial migration](<mockup_screenshots/Screenshot 2026-04-30 125013.png>)

*Sort Cage Workflow (serialized, UJ-05 update-in-place default): Source Container header (Container, AIM Shipper ID, Item, Total Serials). Per-Serial Migration table — each row shows a serial number and a Destination Container · Tray · Position dropdown; PASS/FAIL badge. Suspect-only filter and Select All button for bulk operations. Submit Bulk Migration commits all rows in one call; ShippingLabel_Void fires on the source, Container_Complete fires on the destination claiming a fresh AIM ID.*

![Sort Cage Workflow — Non-Serialized, ByVision camera re-pack](<mockup_screenshots/Screenshot 2026-04-30 125038.png>)

*Sort Cage Workflow (non-serialized): same Cognex camera as the Assembly non-serialized line. Per-Tray Close · ByVision panel shows a live camera feed, PASS/FAIL result, Trays Validated counter, Operator Scrap count (visually rejected before tray placement), and Source Remaining count. Active Destination Container selector and Force-Close Tray override. End Session button completes the flow.* When containers are re-packed, AIM must also be updated via `UpdateAim` (which accepts `serial` and `previousSerial` parameters, per Appendix L). New LTT labels print for any new LOTs created during re-sort. New shipping labels print for the re-packed containers. Old shipping labels are voided (`is_void=1`, `VoidedAt` recorded). AIM gets updated: `ReleaseFromHold` for the new good containers, the old shipper IDs are cancelled.

Diane releases the hold on the good LOTs. The `HoldEvent` gets `ReleasedByUserId` and `ReleasedAt` populated. LOT status goes back to GOOD. Production can resume.

### 3:30pm — Receiving Dock: A Pass-Through Part Arrives

A truck pulls up with a delivery of 6MA Cam Holder housings from an outside supplier. These are pass-through parts — MPP doesn't manufacture them, just assembles them. The receiving operator scans the packing slip, creates a LOT in the MES: origin type Received, vendor lot number `VND-88721`, piece count 500, part number 6MA-HSG. The LOT enters the system at the Receiving Dock location.

![Receiving Dock terminal](<mockup_screenshots/Screenshot 2026-04-30 123957.png>)

*Receiving Dock screen: Active Location header (Receiving Dock A) with Change button. New Received LOT form: packing slip barcode scan auto-fills Part Number, Vendor LOT, and Piece Count when present. Part Number resolves to Parts.Item.Id. Optional serial range (Min/Max) for vendor-issued serials validated at Assembly. Operator Initials field. Today's Receiving Log sidebar shows the day's inbound LOTs with timestamps, item codes, and piece counts.*

> **Scope note:** Receiving pass-through parts into the MES is MVP (Scope Matrix row 3). Once created, a received LOT is identical to a manufactured LOT — same movement tracking, hold management, consumption, and genealogy. The data model makes no distinction beyond `LotOriginType`. The "Future" note on Scope Matrix row 20 refers to the dedicated operational workflows — Perspective screens for receiving inspection, vendor lot verification, and staging procedures specific to pass-through parts — not to the underlying tracking capability.

### 4:45pm — Shipping: The Truck Leaves

The released containers — the good ones from this morning's production, plus the re-sorted containers from the Sort Cage — are loaded onto the Honda truck. The shipping operator scans each container's shipping label. The MES confirms: status Complete (not HOLD, not VOID), AIM shipper ID valid. Each container's location moves to Shipping Dock → Shipped. The truck rolls out. Honda can trace every part on it back to the melt.

![Shipping Dock — active manifest TRUCK-MFG-240430-002](<mockup_screenshots/Screenshot 2026-04-30 125103.png>)

*Shipping Dock screen: Active Manifest header (truck ID, carrier, scheduled departure) with per-part-number progress tiles (5G0F 8/16, 5G0R 3/6, 6B2 1/2). Scan Container Shipping Label field — per-scan validation fires Lots.Container_Ship. Scanned list below shows loaded (green), on-hold (red), and void-label (orange) entries with their Shipper IDs, Container codes, and timestamps. Pending Containers sidebar shows READY containers at the dock. Today's Stats panel at bottom right.*

### End of Shift

Around 4:30pm — about 15 minutes before scheduled shift end — Carlos's terminal surfaces the **End-of-Shift Time Entry** control (FDS-09-013).

![End-of-Shift Time Entry — Dedicated terminal, button-toggle mode](<mockup_screenshots/Screenshot 2026-04-30 125159.png>)

*End-of-Shift Time Entry screen: terminal mode badge (Dedicated · button-based, derived from parent Location tier per FDS-02-010). Three large toggle buttons — Lunch (30 min · 11:30 start), Break 1 (15 min · 09:00 start), Break 2 (15 min · 13:30 start) — tap to select, tap again to deselect. Submit Shift End writes one Oee.DowntimeEvent per selected break using shift-schedule start times and durations — no numeric entry. Zero-button submission valid. Shift Handover Summary below shows Open Downtime Events, Open Paused LOTs, and In-Process LOTs spanning the boundary.* His terminal is dedicated (Cell-parented), so the entry is a single button press: tap once, the MES writes `Oee.DowntimeEvent` rows for the lunch period and each break period defined on the shift schedule, with each row's `StartedAt` / `EndedAt` populated from the schedule (no operator-entered durations, no minute-level adjustments). On a shared terminal it would prompt for initials, time category (Regular default), lunch yes/no, which breaks were taken, and submit. Either way the operator never types a number — they're confirming what's already configured.

Open downtime and pause events at the shift boundary stay open. The next shift's operator closes them when the machine resumes — the MES doesn't auto-split events at the boundary (per OI-03 + FDS-09-010). Available time for the shift = scheduled shift duration − sum of downtime events that fell inside the shift window. There are no `+30` / `+10` / `+110` operator adjustments anywhere in the model — runtime is derived from event durations, not entered.

The incoming shift's operator establishes their presence by entering initials at first action (or accepting the 30-min idle re-confirmation popup if a shared terminal already has someone logged in). No badging.

Everything that happened today — every LOT creation, movement, split, production event, consumption event, reject, downtime event, hold, release, label print, AIM call — is in the `OperationLog` and `InterfaceLog` tables. Immutable. 20 years from now, if Honda asks "who made serial number `5G0F-240406-00147` and what aluminum went into it," the answer is there.

> **Note on Productivity DB replacement:** Today, MPP staff enter production data into a separate Productivity Database (PD) application approximately 2 hours after shift end — a data entry clerk manually keys in the numbers from the paper sheets. The new MES is intended to eliminate this double-entry by capturing data at the point of action in real time (per FRS 5.6.6). This is a fundamental process change, not just a UI replacement, and will require change management on the shop floor. The reports that currently come from the PD (Die Shot Report, Rejects Report, Downtime Report, Production Report) should be generated directly from MES data.

---

## Assumptions & Open Decisions

These are the places where the narrative filled in gaps that the FRS and data model don't fully prescribe. Each one needs an answer before the corresponding Perspective screens can be designed.

**Status legend:** ✅ Resolved | 🔶 Pending Customer Validation / Pending Internal Review | ⬜ Open

### 1. Operator Identity & Elevation Model — ✅ Resolved

**Assumption made (pre-2026-04-20):** Operators badge in once at shift start with clock number + PIN, and stay authenticated for the shift at that terminal. Every action is attributed to them without re-authentication.

**Decision (2026-04-20, OI-06 closed):** Operators don't authenticate at all. They are identified on a terminal by their **initials** (no clock number, no PIN), which establish an operator presence context and pre-populate an editable Initials field on every mutation screen. Dedicated terminals (approx. 80% of the plant, one-to-one with a Cell) retain the presence through the shift, subject only to a 30-minute idle re-confirmation popup ("Operate as CM? Yes / No — change"). Shared terminals prompt for initials on first action after any idle period. Elevated actions (holds, overrides, scrap, maintenance WOs, admin edits) require a fresh Active Directory login at the moment of action — no session-sticky elevation, no 5-minute-timeout. Operator `AppUser` rows are managed by the Configuration Tool (Admin screen); operators have no AD account. *See FDS §4.*

### 2. LOT Creation Flow at Die Cast — 🔶 Pending Customer Validation

**Assumption made:** LTT tags are pre-printed in blocks (physical stickers with barcodes), and the operator grabs one, sticks it on a basket, then scans it to create the LOT in MES.

**Decision (2026-04-09):** LTT tags are pre-printed, but the first scan of a barcode creates the LOT record in the MES. No pre-registration of barcodes. No LOT tag inventory feature. Confirms FDS-05-002.

**Addendum (2026-04-23, v0.8):** LOT creation is **lazy and operator-driven**. The system does not prescribe when Carlos logs a LOT — it can be at basket-full, after the prior LOT is done, or any other moment he chooses. No auto-create of N LOTs at run start. Physical-but-unlogged baskets exist until the operator logs them. Tool + Cavity assignment happens at `Lot_Create` time (operator selects/confirms which cavity). See FDS-05-036.

### 3. When and How Sub-LOT Splits Happen — 🔶 Pending Internal Review

**Assumption made:** The machining operator manually initiates the split — they scan the parent LOT and tell the MES "split this into batches of 24."

**Decision (2026-04-09, corrected 2026-04-29 per FDS v0.11m):** At **Trim OUT**, the Trim operator triggers the sub-LOT split. The system presents a confirmation dialog — default N=2 sublots, evenly split — and the operator selects a destination Machining Cell for each child by scan or dropdown. Sublots are treated as LOT splits in the data model (`LotGenealogy` with `RelationshipType = Split`). Operator can adjust quantities or sublot count before confirming; total must equal parent piece count. Needs review with Ben on per-Item override quantities.

**Clarification (2026-04-23, v0.8):** Sub-LOT split is the **Trim OUT** sublot pattern (parent FK + split genealogy). **Cavity-parallel LOTs at Die Cast are NOT sublots** — a multi-cavity die produces N first-class peer LOTs, each with its own `ToolCavityId` set at creation. The 2026-04-20 meeting notes conflated the two concepts; OI-09 closes this by locking the cavity-parallel-as-peer model in Data Model v1.9. See FDS-05-022 (sublots, Machining) and FDS-05-034 (cavity-parallel LOTs, Die Cast).

### 4. Container Lifecycle on Non-Serialized Lines — ✅ Resolved

**Assumption made:** The narrative focused heavily on the serialized assembly line (5G0) where the PLC handshake fills containers part-by-part. For non-serialized lines, the story is much less clear.

**Decision (2026-04-29, FDS-06-014):** Non-serialized lines use the same **tray-level** closure model as serialized lines, but with a different `ClosureMethod` configured per Item on `Parts.ContainerConfig`. Three peer methods: `ByCount` (operator confirms tray quantity at a terminal), `ByWeight` (OmniServer scale asserts `TargetWeightMetFlag`), `ByVision` (camera validates each part pass/fail, PLC asserts `TrayFullFlag`). Container fill is MES-side accumulation of closed trays — `TraysPerContainer × PartsPerTray` per `ContainerConfig`. AIM shipper ID is claimed atomically at container close from the `AimShipperIdPool`. *OI-02 closed.*

### 5. Sort Cage Serial Number Migration — ⬜ Open

**Assumption made:** When a serialized container is sent to Sort Cage and parts are re-inspected and re-packed, the MES updates `ContainerSerial` records to point to new containers.

**Decision (2026-04-09):** Greatest risk for losing traceability. Flagged for discussion with customer. The void-and-recreate vs. update-in-place decision affects whether a `ContainerSerialHistory` table is needed.

### 6. Off-Site Receiving — ✅ Resolved

**Assumption made:** The off-site receiving uses the same Ignition Perspective app, just accessed remotely (VPN or published gateway).

**Decision (2026-04-09):** Online capability confirmed. No concerns about network reliability or offline requirements. Standard Ignition Perspective via VPN/published gateway.

### 7. Work Order Visibility and Lifecycle — ⬜ Open

**Assumption made:** Operators "never see" work orders, but the data model has them and the scope matrix lists them as CONDITIONAL.

**Decision (2026-04-09):** Work orders included but hidden (MVP-lite) — auto-generated, invisible to operators, no WO screens. Work orders can also be derived from an external ERP system, but the ERP integration spec is undefined. Lifecycle triggers need customer discussion. *Maps to OI-07.*

### 8. LOT Merge Business Rules — ⬜ Open

**Assumption made:** Merges exist in the data model (`GenealogyRelationshipType` has MERGE) but the narrative skipped over them because the FRS explicitly says "business rules TBD."

**Decision (2026-04-09):** Configurable business rules recommended. Examples for MPP: same part number, same die, same cavity. Where these rules are defined (configuration screen vs. code) needs discussion with Ben. *Maps to OI-05.*

**Addendum (2026-04-23, v0.8):** Post-merge LOT carries **NULL `ToolId` and `ToolCavityId`** — blended-origin material can't be denormalized into a single FK pair. Tool-specific trace reconstructed via `LotGenealogy` walk of the pre-merge source LOTs (each retains its own Tool/Cavity FKs immutably). See FDS-05-030.

### 9. What "Material Verification" Means at Assembly — 🔶 Pending Customer Validation

**Assumption made:** The operation template flag `RequiresMaterialVerification` means the operator must scan the source LOT barcode before consuming it, proving the right material is being used.

**Decision (2026-04-09):** BOM-based check. The scanned source LOT's part number must match a component in the active BOM version. Substitute parts are rejected. Needs MPP confirmation.

### 10. Shift Boundary Handling — ⬜ Open

**Assumption made:** The narrative cleanly ended a shift and started another. Reality is messier.

**Decision (2026-04-09):** Flagged for discussion with customer. Open downtime events, partial containers, and in-progress LOTs at shift boundary all need MPP input. *Maps to OI-03.*

### 11. Paper to Screen Transition — ⬜ Open

**Assumption made:** The narrative assumed clean digital workflows where operators enter data in real time at the machine.

**Decision (2026-04-09):** Flagged for discussion with Ben. Whether Perspective screens replace paper at point-of-action or some stations retain paper-first workflow is a process change that requires MPP commitment.

### 12. Terminal-to-Machine Mapping — ✅ Resolved

**Assumption made:** Each terminal is at a fixed location (one terminal per machine, or per small group of machines).

**Decision (2026-04-09 → expanded 2026-04-24, OI-08 / FDS-02-009/010/011):** Terminal mode is derived from the parent Location's ISA-95 tier — there is no `TerminalMode` LocationAttribute. Cell-parented terminals operate in **Dedicated** mode (Cell context = parent Cell, fixed, no selector — Carlos's 6:20am Die Cast scene is the canonical example). WorkCenter- or Area-parented terminals operate in **Shared** mode (operator selects the active Cell at session start by **scan or dropdown**, MAY switch mid-session by either mechanism — both paths resolve to the same `LocationId` on subsequent events). Descendant Cells of the terminal's parent Location define the eligible context set on Shared terminals. Terminal IP / printer / scanner config is stored as `LocationAttribute` entries on the Terminal Location row.

### 13. Weight vs. Count-Based Container Closure — ✅ Resolved

**Assumption made:** The narrative describes container closure by part count (48 parts = 4 trays x 12 parts). But OPC tags show weight-based closure on some lines — `TargetWeightValue`, `TargetWeightMetFlag` via OmniServer scales (per Appendix C).

**Decision (2026-04-29, FDS-06-014):** Resolved alongside #4. Three peer `ClosureMethod` values are configured per Item on `Parts.ContainerConfig` — `ByCount`, `ByWeight`, `ByVision`. Each is a first-class tray-level closure method. The validation gate is always the tray; the container-full signal is always the MES-side accumulation of closed trays. The OPC `TargetWeightMetFlag` is the PLC side of the `ByWeight` path. *OI-02 closed.*

### 14. Warm-Up Shots and Setup Tracking — ✅ Resolved

**Assumption made:** The narrative now mentions warm-up shots at Die Cast but doesn't fully resolve how they flow through the data model.

**Decision (2026-04-09 → closed 2026-04-27, OIR v2.14):** Warm-up shots tracked as a downtime sub-category (`DowntimeReasonType` = Setup). The warm-up shot count is stored as a `ShotCount` attribute on the `DowntimeEvent` record itself. Good/bad production shot counts remain on `ProductionEvent`. Confirmed Option A — `ShotCount` lives on `DowntimeEvent` (not `ProductionEvent`) so warm-up time and shot count stay in a single record.

### 15. Multi-Part-Number Lines — ✅ Resolved

**Assumption made:** The narrative assumes 1:1 mapping of part number to production run. But MS1FM production sheets show multiple part numbers on single lines — e.g., MS1FM-1028 runs 59B, 5PA, and 6NA Fuel Pump variants on one inspection line.

**Decision (2026-04-09):** Lines run one part number at a time, not concurrently. The operator selects the active LOT for consumption, which determines the part number. Changeover between part numbers is an operator action. No mixed-part containers. *Maps to OI-09.*

### 16. Hardware Interlock Bypass Mode — ✅ Resolved

**Assumption made:** The narrative now mentions `HardwareInterlockEnable=false` and `PartSN="NoRead"`. But the full implications aren't resolved.

**Decision (2026-04-09 → closed 2026-04-27, OIR v2.14, Option A):** A `HardwareInterlockBypassed BIT NOT NULL DEFAULT 0` column lands on `Lots.ContainerSerial` to mark the specific serial-to-container assignment as having skipped MES validation when the PLC asserted `HardwareInterlockEnable=false`. The flag lives on `ContainerSerial` rather than `ProductionEvent` because the bypass is observed at the per-piece serial-assignment level — broader event-level tracking via `ProductionEvent` would lose the per-piece granularity. Schema add deferred to Arc 2 Phase 7 alongside the rest of the Container schema CREATE.

### 17. Vision System vs. Barcode Confirmation — 🔶 Pending Internal Review

**Assumption made:** The narrative assumes operators confirm part numbers by barcode scan. But OPC tags show `VisionPartNumber` on some MicroLogix PLCs (6B2, 6C2/6MA Oil Pan lines per Appendix C).

**Decision (2026-04-09):** Vision conflict resolution: auto-hold LOT + supervisor override popup (per OI-04). Flagged for discussion with Ben. *Maps to OI-04.*

### 18. Event Processing: Synchronous vs. Asynchronous — ✅ Resolved

**Assumption made:** The narrative describes immediate, synchronous calls — operator scans LTT, LOT is created, label prints instantly, AIM is called as soon as a container closes.

**Decision (2026-04-09 → closed 2026-04-27, OIR v2.14):** Two architectural commitments together close this:
1. **No outbox pattern (OI-01).** External calls are made directly from the Ignition application layer with results logged to `Audit.InterfaceLog` — the FRS only requires logging of all sent and received content (FRS 3.17.4), not an SQL outbox table.
2. **Gateway-script-async for all external integrations (FDS-01-014, UJ-18 closure).** Perspective sessions never block on AIM, label printers, or any other external system. Dispatch is via `system.util.sendMessage` (fire-and-forget) or `system.util.sendRequestAsync` (when the caller needs error surfacing — print path, AIM Hold/Update). The label-printing latency concern at container close is addressed by extracting print dispatch from the atomic close transaction (FDS-07-005/006a/b) — the close commits with the AIM ID claimed from the local pool (UJ-04), then a Gateway message handler fires the print with 3 retries (2s gap) and surfaces failures via a per-terminal banner with Acknowledge action (FDS-07-006b).

### 19. Productivity DB Replacement and Change Management — ⬜ Open

**Assumption made:** The narrative assumes real-time data entry at the machine replaces the legacy paper-then-clerk workflow.

**Decision (2026-04-09):** Flagged for discussion with customer. The transition from paper-then-clerk to real-time operator entry is a process change, not just technology. MPP must confirm commitment at all stations. Four PD reports (Die Shot, Rejects, Downtime, Production) must be replicated in MES reporting.

---

## Impact Matrix

The assumptions above don't just affect documentation — they gate screen design. Here's how they cluster:

| Decision Cluster | Blocks | Affected Screens |
|---|---|---|
| **Auth & session model** (#1) | Every screen | Login, all operator interactions |
| **LOT creation flow** (#2, #3, #14) | Die Cast and Machining screens | LOT creation, sub-LOT split, warm-up shot entry |
| **Container lifecycle** (#4, #5, #13, #15) | Assembly and Shipping screens | Container management, Sort Cage, weight vs. count closure, multi-part lines |
| **Work order model** (#7) | Production tracking architecture | Whether WO screens exist at all |
| **Merge rules** (#8) | LOT management screens | Merge workflow (if it exists in MVP) |
| **Material verification & interlocks** (#9, #16, #17) | Assembly screens | Consumption recording, interlock behavior, hardware bypass, vision confirmation |
| **Shift boundaries** (#10) | All production screens | Handoff workflows, downtime continuity |
| **Paper vs. real-time** (#11, #12, #19) | All operator screens | UX patterns, screen complexity, terminal count, PD replacement |
| **System architecture** (#18) | All label/AIM touchpoints | Sync vs. async event processing, UX latency expectations |

---

## Related Documents

| Document | Relevance |
|---|---|
| `MPP_MES_SUMMARY.md` | Primary source for requirements, scope flags, and data model overview |
| `MPP_MES_DATA_MODEL.md` | Column-level schema backing every table referenced in the narratives |
| `MPP_MES_ERD.html` | Visual ERD with scope badges showing MVP/Future table status |
| `reference/5GO_AP4_Automation_Touchpoint_Agreement.md` | Plc handshake protocol for the serialized assembly line described in Arc 2 |
| `reference/Excel Prod Sheets.xlsx` | Paper forms that Arc 2's screens replace |
| `reference/MS1FM-*.xlsx` | Line-specific production sheets showing per-line data entry fields |

---

## Validation Log — 2026-04-06

Narratives validated against all source documents. Changes made:

| Source | Finding | Action Taken |
|---|---|---|
| FRS 2.2.2 | LOT creation requires manual data entry (part, die, cavity), not pre-populated from terminal config | **Corrected** — Die Cast narrative updated |
| FRS 2.2.3 | Trim Shop uses weight-based piece count estimation, not physical count confirmation | **Corrected** — Trim narrative expanded |
| FRS 2.2.4–2.2.5 | Machining uses IN/OUT screens and FIFO queue with operator override | **Corrected** — Machining narrative expanded |
| FRS Section 4 | Reject/scrap data is "not considered part of the permanent production records"; recording is optional per step | **Corrected** — reject entry caveat added |
| FRS 3.16.10 | Hold blocks "operation completion activities", not necessarily LOT selection | **Corrected** — hold interlock wording softened |
| FRS 2.1.10, 2.2.7 | Sort Cage requires "part replacement" capability; AIM `UpdateAim` supports `previousSerial` | **Added** — Sort Cage narrative expanded |
| Appendix E | Defect code count is ~145, not ~170; includes HSP department | **Corrected** |
| Appendix C OPC tags | Non-serialized lines have defined PLC integration (PartDisposition, ContainerName), not undefined | **Added** — non-serialized line note in Assembly |
| Appendix C OPC tags | Weight-based container closure exists on some lines (OmniServer scales) | **Added** — assumption #13 |
| Touchpoint Agreement 1.1 | `HardwareInterlockEnable=false` is a valid bypass mode, not an error | **Added** — assumption #16 |
| DCFM paper sheets | Warm-up shots tracked separately from production shots | **Added** — warm-up shots in Die Cast narrative + assumption #14 |
| DCFM paper sheets | Shift runtime adjustments (lunch, breaks, overtime) are manual additions | **Added** — End of Shift narrative expanded |
| FRS 5.6.6 / Appendix F | PD application replacement is a process change; clerk enters data 2hr post-shift | **Added** — PD replacement note + assumption #19 |
| Spark Dependency Register B.12 | Event outbox + background worker pattern makes AIM/label calls async | **Added** — assumption #18 |
| Scope Matrix row 14 | NCM/Failure Analysis is FUTURE; Sort Cage uses holds-only in MVP | **Added** — scope note in Sort Cage narrative |
| Scope Matrix row 20 | Pass-through full workflow is FUTURE; receiving is MVP | **Added** — scope note in Receiving narrative |
| MS1FM production sheets | Multi-part inspection lines (59B/5PA/6NA on one line) | **Added** — assumption #15 |
| Appendix C OPC tags | Vision-based part confirmation on some lines (VisionPartNumber) | **Added** — assumption #17 |
| Appendix B | Machine count of ~230 confirmed (230 entries in FRS) | Verified — no change needed |
| Appendix D | Downtime code count of ~660 confirmed (662 entries in FRS) | Verified — no change needed |
| Appendix L | AIM interface methods (GetNextNumber, UpdateAim, PlaceOnHold, ReleaseFromHold) confirmed | Verified — no change needed |
| Appendix H, I | Legacy UI screens and work instructions are placeholder-only in FRS — cannot validate operator workflows | Noted — no action possible |
