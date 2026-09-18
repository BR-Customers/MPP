**Subject:** MES update – September 18: shift confirmation, line inventory, shipping label reprint, and more

Hi all,

We released an update to the MES this afternoon, and it is already live on every terminal. Below is what changed, organized by area, and what (if anything) you need to do.

---

### Die Cast

- **Pick your reporting shift every time.** The shift box on Reconcile Shift now starts blank. This stops shift output from accidentally being recorded against the wrong shift.
- **Submit now asks you to confirm the shift.** When you press Submit Shift Entry, a confirmation shows the shift in large letters. If it's wrong, pick the right one there. The numbers are recalculated, nothing is submitted, and you press Submit again.
- **Cleaner screen when switching presses.** Changing presses, or leaving the screen and coming back, now clears the previous press's numbers, so you never see another press's figures.
- **Released baskets show "–" under Good.** A basket released earlier in the shift has nothing more to credit, so it shows a dash instead of a confusing 0. You can still enter scrap against it.
- **No more duplicate pop-up messages** on the Die Cast screen.

### Trim

- **Trim OUT is easier to use.** Scrap reason buttons now wrap to fit the screen instead of running off the edge. The scrap list scrolls on its own, and the Trim OUT button always stays visible.
- LOT cards in the trim inventory are more compact.

### Machining & Assembly

- **New Line Inventory panel** on the right side of the Machining and Assembly screens:
  - It shows what's on hand at the line, part by part.
  - Rows turn **orange** when running low and **red** when critical, based on the maximum set for that part at that line.
  - Boxed parts can be checked in with one tap (for example "+5,000"). Other parts use **+ LOT** to enter a count.
  - **Line-wide** shows everything at the line, not just this station's parts.
  - **Tolerances** is where the maximum for each part is set.
- **The maximum is also the most a line can hold.** A check-in that would go over it is refused. Stock that is **on hold does not count** toward the maximum.
- The old inventory sidebar and the low-inventory pop-up have been retired in favor of the new panel.

### Shipping labels (Assembly OUT)

- **Reprint Shipping Label** (bottom of the Assembly OUT screen): pick the label from the last 10 printed at this line, choose a reason, and have a supervisor approve with their login. The label prints right away with the same serial number. Please throw away the damaged label it replaces.
- **Reprint** (top of the Assembly OUT screen): quickly reprints the last label printed at this terminal.
- The print-failure banner now has a Reprint button as well.

### Downtime

- **Changing a downtime reason no longer needs a supervisor** during the current shift or within 30 minutes after it ends. After that, a supervisor is still required.
- **Downtime is now recorded against the machines and lines set up for it.** All presses, trim machines and production lines were set up automatically, so nothing changes day to day. Please use the **Downtime** button at the top of the screen. The old *Downtime Entry (legacy)* menu item now only works for presses and trim machines.
- **Station-level downtime is coming line by line**, starting with 6MA Cam Holder Line 1. On those lines, the Downtime list shows the line plus its stations (for example Assembly Conveyor A and B). Choose the station that went down, or the line if the whole line stopped.

### Inventory Cutover Scan

- It now starts with **where the stock is**: Warehouse, Tumble Trim Storage, Blast Trim Storage, or a line. It opens on Warehouse.
- The part list shows castings only.
- After each basket, the LTT field keeps its prefix, and the cavity clears.
- The cast date has a date picker.

### Configuration Tool

- The Configuration Tool now requires an **Active Directory username and password**. Only AD users can access it.

---

### What we need from you

- **Supervisors:** please let die cast operators know about the blank shift box and the new confirmation step before their next shift entry.
- **Line leads / materials:**
  - Set the **maximum per part** for each line using **Tolerances** on the Machining or Assembly screen. The Line Inventory colors only work once these are set.
  - Set the **Box Quantity** for purchased parts in Item Master, which turns on one-tap check-in.

### Known issues and what's next

- **Part categories are being renamed** in the next update to match how MPP talks about parts: *MPP Cast*, *Components* (purchased parts) and *Pass Through*, along with Sub-Assemblies and Finished Goods. Until then, purchased parts still show as "Pass-Through" in Item Master. Nothing is wrong with the data.
- On narrower screens, the Assembly OUT header is crowded, and some buttons on the right can be hard to reach. It looks fine at normal widths, and a fix is planned.
- The Paused LOT list pop-up is missing its row display. A fix is planned.

If anything looks wrong or doesn't work the way you expect, grab a screenshot and send it to Jacques.

Thanks,
Jacques
