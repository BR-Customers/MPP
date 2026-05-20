# MPP Open Items Discussion — 2026-04-30

**Source:** Junior engineer notes from a discussion with MPP covering several outstanding OIR items. Notes are paraphrased and unedited. Analysis below maps each topic to OIR items, draws design implications, and lists clarifying questions to send back to MPP.

---

## Raw Notes from MPP

**Automation tab of MES app:**

> Only works for part 5G0, on 5GO line there is interlocks, used to toggle interlocks to keep line running. Two different tabs, only works for rear, container counts, mes interlocks. Customer to provide screenshots.

**Report / Notification Tile:**

> Customer has no plant overview screen. Customer does not really use, would have flexware do the search and get them a report. Customer has not used this functionality. Many of the reports could be from the original, before they added more parts and machine shop. When looking for lot information, looking for part components and where they are at.

> Customer has to configure where parts are eligible to be at, used to configure at BOM. Flexware always did this configuration. Customer to maybe provide sheet that they would give flexware.

> Plant managers don't get notifications if something is wrong. Right now lineside associates are flagging issues and word of mouth elevated. Potentially to develop a plant view to allow supervisors to see potential issues.

**AIM IDs / pool / batch printing:**

> Customer would like to have the pool of AIM ids, have notifications.
>
> When they batch print, they have a timeline and have to select a part.
>
> When using batch printed label, they can't track inventory, they are losing traceability from the lot.
>
> It is directly printed from AIM.
>
> AIM has a database of 0–whatever number to pull an id from, they go to AIM, their shipping section, and print a label, it pulls the ID from the database. Having a pool of labels would not cause an issue as long as there are no duplicates, AIM labels are pulled part specific, part number is linked to a container id, which will need to be able to linked to RFID later.
>
> AIM creates a container id.
>
> There is no difference between serialized and non when it comes to AIM.
>
> MES is creating the serials until they need to go to AIM, then it creates the serial.
>
> They have ran into issues before with duplicate numbers, that is why flexware moved to a point where they thought AIM would never reach.

**Machining → Assembly flow:**

> When parts go into machining, they then go directly to assembly. Some have machining in and assembly in.

---

## Analysis

### 1. Automation tab — maps to OI-24

**What the notes say:** This is a line-specific override surface, not a generic OPC management UI. Scoped to 5G0 (rear), with two tabs: container counts + MES-side interlocks. The interlock toggles are how operators bust through software gates that would otherwise stop the line.

**Implications**

- OI-24 narrows considerably. It's not a discovery item that requires us to inventory a generic Automation tile — it's a single line-specific override panel.
- This is dangerous functionality (override of MES-enforced gates) and almost certainly belongs behind elevation + audit. Should land in `Audit.OperationLog` with the toggled gate name and reason.
- "Container counts on Automation tab" is suspicious — that data already lives in our LOT/container model. Is the Automation-tab counter a *display* of MES state, or a *manual edit* of it? If the latter, it's a forensics nightmare.
- 5G0 already has a Cell-level flag pattern (e.g., `RequiresCompletionConfirm`). This becomes a `LocationAttribute` set: `HasInterlockOverridePanel BIT`, `OverridableInterlockSet NVARCHAR` (or a child table) on the affected Cells.

**Clarifying questions**

- Which interlocks are toggleable — production-count gates, quality gates, AIM-handshake gates, all?
- Are "container counts" displayed (read-only) or editable? If editable, what's the audit trail today and is anyone reviewing it?
- When toggled, does the interlock auto-reset (next cycle, end of shift, etc.) or stay off until someone explicitly toggles it back?
- Who is authorized to use this — supervisor, engineering, technician?
- Did we ever see this in the Storyboards / IPAddresses 2012 review? Worth re-checking before MPP sends screenshots.

---

### 2. Reports / Notifications tile — maps to OI-25, OI-30, UJ-19

**What the notes say:** The legacy Reports tile is largely abandoned dead weight. When MPP needs data, they email Flexware and Flexware runs the query. The actual reporting need they articulate is genealogy + WIP location ("part components and where they are at"). Many legacy reports predate Machine Shop and are stale.

**Implications**

- **OI-30 mostly closes** — the legacy Reports tile is not a requirements surface for the new MES. We don't have to faithfully port whatever it contains. Strong push to ask MPP to nominate the *very few* reports they actually want, and tag the rest as "do not port."
- **UJ-19 may be smaller than feared** — the "four PD reports" might shrink to one or two once they review honestly.
- **The real ask** ("part components and where they are at") is exactly what the Global Trace Tool (FDS-12-5) + the Home Page LOT Search / Genealogy panels deliver. We've already built that surface in the mockup.
- **The "ask Flexware to run a query" pattern is institutional debt** — they got used to outsourcing data access. Worth flagging that the new MES gives them self-serve, and asking who at MPP becomes the report-running authority post-cutover. Otherwise they'll keep emailing Blue Ridge for queries.

**Clarifying questions**

- Of the legacy reports, is there a non-zero list MPP still uses? (If they say "none," we have a clean slate.)
- "Part components and where they are at" — does this mean *current location of in-process LOTs* (live WIP map), *historical genealogy of finished parts*, or both?
- Who currently emails Flexware for queries — supervisors, plant managers, quality, all of the above? Each role's information needs may differ.
- Are there any *scheduled* reports (daily production summary, weekly OEE) Flexware emits today, or is it all ad-hoc?

---

### 3. Plant overview / supervisor notifications — net-new requirement, intersects OI-25

**What the notes say:** No real-time visibility into plant health today. Issues escalate by associates physically walking and word-of-mouth. Customer wants a plant-view screen for supervisors so they can see emerging issues.

**Implications**

- This isn't a port-the-legacy item — it's a **net-new MVP-EXPANDED requirement** the customer is asking for. Worth a fresh OI to track.
- The Supervisor Dashboard already mocked up in `plantFloor.html` (Home Page → Supervisor Dashboard tab with AIM Pool Wallboard tile) is directly on point. We should expand that tab to be a real plant-status view — line up/down, holds active, downtime in progress, AIM pool tier, scrap rate spike.
- This couples to OI-25 Notifications. If MPP wants *push* (email / SMS / page), that's a bigger build. If *pull* (dashboard refresh that supervisors check), it's an extension of the Home Page.
- A plant-view that surfaces active issues will pressure-test our event sourcing — every issue type has to have a queryable representation (HoldEvent, DowntimeEvent open without a close, AIM pool depth, alarm condition).

**Clarifying questions**

- What's the audience hierarchy — shift supervisor (real-time), plant manager (summary)? They probably want different views.
- What constitutes "an issue" — list the types: line stop > N min, scrap rate above threshold, AIM pool low, hold raised, machine alarm, missed shift target, what else?
- Push or pull? If push, what's the delivery channel — Ignition push notifications, email, SMS?
- Does this need to be on a wallboard somewhere physically in the plant (manager's office, common area)?
- Is this MVP or pilot-discovery? They've never had this so they don't know what they actually want — pilot might be the honest answer.

---

### 4. Part-to-Location eligibility configuration — maps to OI-32, FDS-02-012, S-06

**What the notes say:** MPP has never directly configured part-location eligibility. Flexware has always done it for them. There's a "sheet" MPP hands Flexware — that sheet is potentially the real authoring artifact. They might be able to provide it.

**Implications**

- This recasts **OI-32 Material Allocation** significantly. If MPP doesn't author Item-Location eligibility today, they may not need a self-serve configuration screen — they need an import + occasional engineering-staff edit. The "Material Allocation operator screen" premise (which Jacques already challenged in OIR v2.10) takes another hit. Likely a "close as not-reproduced" + the configuration is engineering-only behind elevation.
- The "sheet" is gold — it's the actual format and structure of the requirements. Could replace S-06 BOM export *or* augment it. Either way, get it.
- **BOM-derived eligibility (FDS-02-012)** is the right design choice — it gives them eligibility for free off the BOM rather than authoring a per-Item-per-Cell row matrix. The "sheet" probably maps cleanly into BOM + a small set of direct ItemLocation overrides.
- Post-cutover support question: is MPP planning to take over this configuration, or do they expect Blue Ridge to keep doing it? If the latter, that's a post-cutover service contract conversation.

**Clarifying questions**

- Can MPP send us a recent example of the sheet they hand Flexware? (Critical — answers most of the open design questions on this in one shot.)
- Who at MPP currently authors that sheet — engineering, production control? They become the post-cutover owner of the equivalent function.
- When MPP introduces a new part today, what's the lead time between "we need this part configured" and "Flexware has it live"? (If it's days, our self-serve story is a value-add. If it's hours, they're satisfied with status quo.)
- Are there parts with *direct* ItemLocation rows that don't come from BOM (e.g., supply parts received at receiving)? Those need explicit handling outside BOM-derivation.

---

### 5. AIM pool, batch printing, serial creation — maps to OI-33, UJ-04, FDS-07-010

This is the densest block. Several distinct points worth separating.

| Statement from MPP | What it tells us |
|---|---|
| "Customer would like the pool of AIM IDs, have notifications" | Confirms UJ-04 / FDS-07-010 pool design AND extends it: they want **proactive low-pool alarms**, not just hard-fail at zero |
| "Batch print, timeline, select a part" | This is a current legacy workflow we may not have surfaced — pre-printing labels in batches |
| "Batch printed labels lose traceability from the LOT" | They know it's a problem with current behavior; they're admitting the workaround is broken |
| "Directly printed from AIM" | Today, labels print from AIM directly — no MES involvement at print time |
| "AIM has DB 0..N, pull ID, print label, ID is part-specific, container ID linked to part number" | Confirms partitioned-by-part pool design |
| "Will need to be linked to RFID later" | FUTURE flag |
| "AIM creates a container ID" | Confirms AIM is the source-of-truth for container IDs |
| "No difference between serialized and non for AIM" | One container ID per shipping container regardless of per-piece serialization |
| "MES creates serials until they need to go to AIM, then [AIM] creates the serial" | **This may not match our current design** — needs decoding |
| "Duplicate-number incident; Flexware moved counter forward" | Real Honda-traceability incident; the historical "why" behind hard-fail |

**Implications**

- **OI-33 partially resolves** — hard-fail confirmed, BUT they also want notifications BEFORE the pool empties. Good news: our tiered-alarm design (e.g., yellow at 50%, red at 25%, hard-fail at 0%) covers this. Need to confirm the tiers with them.
- **Batch printing is a legacy workaround we have to consciously eliminate** — the new MES prints labels at the moment of container closure (FDS-07-006b broadcast script), tied to a specific LOT, traceable. This is a positive story for MPP. We should call this out as a deliberate improvement, not a regression of "you used to be able to batch print."
- **Duplicate-number incident** — should be cited in the OI-33 resolution rationale. It's the strongest possible argument for hard-fail: their *own* history shows what happens with sloppy AIM ID issuance.
- **"MES creates serials until they need to go to AIM, then [AIM] creates the serial"** — this is the line that needs careful unpacking. Our read: MES generates *internal* serials for in-process per-piece tracking on serialized lines (5G0 etc.). Those internal serials are NOT the AIM-issued container IDs. At shipping, when a container closes, the MES claims an AIM ID from the pool — that's the "AIM creates the serial" the customer is referring to. **If that's the right read, our design is already aligned.** But it may also mean the customer thinks each piece gets an AIM-issued serial, which would be a much bigger ask. Needs explicit walkthrough.
- **AIM serializes containers, not pieces** — confirmed by "no difference between serialized and non." This means our `Lots.AimShipperIdPool` claims one ID per container, regardless of piece-level serialization on the line. Already aligned.
- **RFID future** — note for FUTURE; the AIM-ID-to-RFID-tag binding likely lives on `ShippingLabel` when that comes.

**Clarifying questions**

- **Walkthrough request:** "Walk us through one container of 5G0 from cast to shipped — at each step, who creates what serial number, where does it come from, where does it land in the system?" This single question disambiguates the "MES creates serials until..." line.
- Pool notification tiers: at what pool depths should we alarm — what's "low" vs "critical" vs "empty" in MPP's view? Default is yellow 50% / red 25% / hard-fail 0%, but they might want 25% / 10% / 0% or different thresholds per part.
- Batch print today: what's the operator workflow exactly? Is it "print 200 labels at start of shift, slap them on as containers fill"? Knowing this lets us write the migration story for operators.
- Duplicate-number incident: how was it caught (downstream by Honda? internal QC?) and how was it resolved? Any procedural rules MPP retained from the incident?
- "AIM IDs are part-specific" — does that mean the pool partitions by Part Number or by Part Family / Container Type? Important for pool sizing.
- RFID timeline: years out? Next 5-year plan? Determines whether `Lots.ShippingLabel` should pre-allocate an `RfidTagId` column now or defer.

---

### 6. Machining → Assembly flow — maps to FDS-06-008, FDS-05-033

**What the notes say:** Default flow is Machining direct to Assembly with no buffer. BUT "some have machining in and assembly in" — meaning some parts require explicit IN scans at both Machining and Assembly. This is at odds with the auto-move design (FDS-06-008 via `CoupledDownstreamCellLocationId`).

**Implications**

- The auto-move design is right for *coupled* cells. For parts that have both Machining IN and Assembly IN, the cells are *decoupled* — there's a physical buffer or queue between them, and the operator manually scans into Assembly.
- Our `CoupledDownstreamCellLocationId` LocationAttribute already supports this: NULL = decoupled (operator must explicitly scan IN at next cell), non-NULL = coupled (PLC-driven auto-move). What's NOT clear is whether the coupling is a *Cell* attribute, a *Part* attribute, or a *Part-at-Cell* attribute. Customer note implies it's *part-specific*: "some have machining in and assembly in."
- If part-specific, the `CoupledDownstreamCellLocationId` design needs to move — it can't live on the Cell alone. Options: a `Parts.PartFlow` table (Part × FromCell × ToCell × IsCoupled), or a flag on the Part's RouteTemplate steps.
- This may be why FDS-05-033 (Trim → Machining rename) ended up where it did — at a workflow seam where coupling differs by part.

**Clarifying questions**

- Which parts have Machining IN + Assembly IN, and which auto-flow? Is it a property of the part, the line, or the cell-pair?
- When there's a buffer between Machining and Assembly, how big is it physically — a tray rack? A WIP shelf? A supermarket queue?
- Is "Assembly IN" a per-piece scan, per-LOT scan, or per-tray scan?
- Could the same part have a coupled flow on one Cell-pair and a decoupled flow on another? (That would force the per-Cell-pair model.)

---

## Summary — OIR Movements Suggested

| Item | Current state | After this discussion |
|---|---|---|
| OI-24 Automation tile | Open — discovery needed | Narrowed: line-specific 5G0-rear override panel. Awaits screenshots; spec a `LocationAttribute` model. |
| OI-25 Notifications | Open | Re-couples to net-new plant-overview requirement (below). |
| OI-30 Reports tile | Open | Mostly closes — legacy reports largely unused. Need MPP to nominate any non-zero list. |
| UJ-19 PD replacement | Open | Likely smaller scope than feared — ties to genealogy + WIP location, already covered by Global Trace + LOT Search. |
| OI-32 Material Allocation | Open (premise challenged) | Further weakens the operator-screen premise. Customer never authored eligibility themselves. Likely close + engineering-only config behind elevation. |
| OI-33 AIM hard-fail | Open | Hard-fail confirmed; **add proactive notification tiers** (already designed). Awaits walkthrough of serial-creation lifecycle. |
| **NEW OI-36 (proposed)** | — | Plant Overview / Supervisor Issue Dashboard — net-new MVP-EXPANDED requirement. Expand mocked Supervisor Dashboard tab. |
| **NEW OI-37 (proposed)** | — | Cell coupling granularity — Cell-level vs Part-level vs Part-at-Cell. Affects `CoupledDownstreamCellLocationId` placement. |

---

## Action Items

1. **MPP to send screenshots** of the Automation tab (5G0 rear).
2. **MPP to send the eligibility sheet** they hand Flexware today.
3. **Clarification questions** above to be sent back as a structured follow-up — recommend one document, not six emails.
4. **Walkthrough session** on AIM serial creation lifecycle — single 30-minute session would unlock OI-33 close.
5. **Open OI-36 (Plant Overview Dashboard)** in next OIR sweep.
6. **Open OI-37 (Cell coupling granularity)** in next OIR sweep — gates Phase 5 SQL design.
