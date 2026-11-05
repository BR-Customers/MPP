**Subject:** MES update – November [5]: OEE dashboard, super-lots, scale station, AIM failure log, and more

Hi all,

We released an update to the MES this [morning/afternoon], and it is now live on every terminal. Below is what changed, organized by area, followed by what (if anything) you need to do. At the end there is a short section for IT/OT.

---

### OEE dashboard (new)

- **A new OEE Dashboard** is in the main menu.
  - It shows **availability** and **quality** for the whole plant, then for each area (Die Cast, Trim, Machining & Assembly), down to each press, trim machine and line.
  - It opens on the **last completed shift**. Use the arrows to step back through shifts, or switch to **Day** or **Week**.
  - Each machine has its own page with downtime by reason, scrap by defect, and the list of downtime entries for the shift.
  - Supervisors can **correct a downtime entry** right from that list. It asks for a supervisor login, as the Downtime screen does.
- **Shift Availability tile.** The tile on the Supervisor Dashboard is now live. It shows plant availability for the last completed shift; tap it to open the dashboard.
- **OEE Summary report.** A new report on the Reports page, for a shift, a day or a week, printable as a PDF.
- The dashboard has the full history back to go-live. Performance and overall OEE will follow in a later update; for now they show as "coming in a future deployment".
- **Machining & Assembly good counts** come from the lines that record production in the MES (today, MA2-6MACH).

**Availability may read a little lower than before for some shifts.** It is now the total of the downtime actually entered for that shift. Previously, two downtime entries that overlapped at the end of a shift were merged into one. A shift whose schedule was changed later now also shows the hours it actually ran. Both changes make the numbers more accurate.

### Quality: super-lots (new)

This delivers MPP's two nonconformance change orders.

- **Super-lots** let Quality group suspect LOTs and finished containers into one tracked unit. Every member is put on Controlled Run Tag (CRT) and a super-lot label can be printed. Optionally, the super-lot can keep collecting new production of one part on one line for a set window.
- **For each member, Quality records the result:** accepted, scrapped, use-as-is (under a signed deviation), or return to vendor.
- **Containers can be repacked.** The old shipping serial is voided and a new one is issued when the container is completed again.
- **LOTs can be sent back through Trim as a tracked rework.** When a supervisor moves a LOT back into Trim IN, the LOT is now flagged as rework. It reappears in the Trim queue, and its next Trim OUT closes the rework. Rework is counted separately from normal trim production.
- **Members are released with a signed statement**, which is written onto each LOT's history.
- **Where to find it:**
  - The **Super-lots** page, reached from the **Open super-lots** tile on the Supervisor Dashboard.
  - LOT Detail, which has a new **Super-lots** tab and a marker on LOTs that are in one.
  - Track & Trace and the Genealogy viewer, which mark super-lot members.
  - A **Super-lot** report on the Reports page.
  - A **Parts to return** tile on the Supervisor Dashboard.
- **Nothing changes on the floor until Quality opens a super-lot.**

### Shipping

- **A container holding a LOT that is on hold can no longer be shipped.** Until now, the Shipping Dock only refused containers that were themselves on hold. Now a hold on any tray LOT inside the container also stops it, and the message names the LOT. Completing the container still works as before. To ship it, release the hold on that LOT or pull the tray.

### Machining & Assembly

- **Assembly OUT, By Weight lines: the scale station.**
  - The screen now shows a scale station panel: the part running, the last presses of the scale's Print button, a shift tally, and recent boxes.
  - **A box now closes when the operator presses Print on the scale.** The **Weigh & Close** button is gone.
  - The scale's own UNDER / OVER / OK lights are recorded for comparison, but the MES makes the accept/reject decision.
- **Scrap with more than one reason.** The scrap pop-up on Machining and Assembly now uses reason tiles, as Trim does, so several reasons can be entered in one go.

### Die Cast

- **Each die cast terminal can show its usual presses as buttons**, with **Show all** for the rest. Until a terminal is set up, it shows every press, as today.

### Configuration Tool

- **AIM failures now appear in the Failure Log** (Audit → Failure Log).
  - Each failed attempt to post a shipping serial to AIM, or to fetch new serials, is logged with the line and the LOT involved.
  - The Failure Log has new **Location** and **LOT** filters and columns.
- **Plant Hierarchy:** each terminal has a new **Default machines** setting. This is where the die cast press buttons above are chosen.
- **Fewer false "unsaved changes" prompts.** Several editors (Item Master sections, Tools, Plant Hierarchy, Operation Templates, Quality Specs) no longer ask about unsaved changes when nothing was changed.

### Other fixes

- **Print PDF works again on the Reports page** for every report.
- Supervisor sign-ins made for Quality work stay active longer (30 minutes idle, up to 4 hours) so a Quality review isn't interrupted.

---

### What we need from you

- **Shipping and Quality:** a container that holds a LOT that is on hold will now be stopped at the dock. Please check that holds which are no longer needed have been released. We will send you a list of any containers in that state at the time of the update: [list / "none"].
- **Assembly OUT By Weight operators:** a box closes from the scale's **Print** button now. Please let operators know before their next shift.
- **Supervisors:** the OEE Dashboard and the Shift Availability tile are ready to use. Let us know if any machine's numbers look off.
- **Die cast leads (optional):** tell us which presses each die cast terminal should show by default, or set them in Plant Hierarchy.

### Known issues and what's next

- Performance and overall OEE are planned for a later update.
- On the OEE dashboard, adding a new location (for example a terminal or printer) in the Configuration Tool makes the dashboard recalculate its history in the background over the next hour or so. The numbers don't change and nothing needs to be done.
- We still have a few open questions on super-lot edge cases from our walkthrough (for example, how zero-piece members should be released). We'll follow up separately.
- **Part categories** (MPP Cast / Components / Pass Through) are still on the list for an upcoming update.

---

### For IT/OT

- **Database:** SQL Server `MPP_MES_Prod` was updated in a single transaction, after a verified full backup.
  - Database changes: 9 schema updates (`0109`–`0117`) and 137 stored procedures and functions.
  - Production tables were locked for [N] seconds. No data was rewritten.
  - After the update, the OEE history was calculated once ([N] seconds, one shift at a time).
- **Ignition:** the Core, MPP and MPP_Config projects were updated with only the changed screens, scripts and queries. Open terminals were refreshed.
- **New gateway timers:** two new OEE timers run on the gateway:
  - `OeeSummaryRefresh` (every 15 minutes): keeps the stored shift figures current.
  - `OeeSummaryNightly` (once a day): a 7-day safety recalculation.
  - Both are light and run on their own thread, separate from the PLC watchers.
- **AIM:** no change to how serials are posted. Failed attempts are now also written to the MES Failure Log. If AIM is unreachable for a while, expect up to about 50 Failure Log entries a minute until it comes back. That is expected, and it gives a record of the outage.
- **No network, firewall, PLC, printer or AD changes.**
- **Rollback:** the update is additive. A backup from just before the update is kept, and the previous Ignition screens can be restored from the prepared rollback files if needed.

If anything looks wrong or doesn't work the way you expect, grab a screenshot and send it to Jacques.

Thanks,
Jacques
