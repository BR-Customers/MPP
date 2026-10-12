# Super-lot piece 5 — Rework and Return to Vendor as real outcomes

> **Status: DRAFT 2026-10-12. NOT APPROVED. NOT BUILT.** Handoff for another agent.
> Fifth of six pieces. Short on purpose: almost nothing here can be designed until MPP
> describe what they physically do. **Section 5 comes before any plan.**

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`; the piece
3 spec (`2026-10-12-controlled-run-results-and-signoff-design.md`) — this piece gives
material effect to two of the outcomes piece 3 only counts; `CLAUDE.md`.
**Branch:** `jacques/controlled-run-super-lot`. Nothing deploys until all six pieces are in.

---

## 1. Problem

Change order B lists the standard dispositions: Pending, Use-As-Is, Rework, Scrap, Return
to Vendor. Jacques confirmed (2026-10-12) that Rework, Scrap and Return to Vendor are all
needed, as outcomes of a super-lot inspection.

After piece 3, Scrap moves material (through `Workorder.RejectEvent`), Use-As-Is is a
signed deviation, and **Rework and Return to Vendor are only numbers on a results row.**
The pieces they describe are still counted in their LOT as good stock. This piece makes
the two outcomes mean something to inventory and genealogy.

## 2. What exists

- `Quality.DispositionCode`: `Rework` and `ReturnToSupplier` rows exist; nothing uses
  them. Change order B says "Return to Vendor".
- **Rework routing was tagged FUTURE** in the FDS (FDS-07-018: "Formal NCM disposition
  codes and rework routing are FUTURE capabilities"). There is no rework operation, no
  rework location definition and no rework route.
- Routes drive everything (CLAUDE.md, "Terminal-mint model"): a LOT's queue position is
  its lowest pending route step. Sending a LOT "back" has no expression in that model.
- Holds: `Quality.HoldEvent` + `LotStatus = Hold` block production. `Lots.Lot_Split` is
  the exception path for same-part divisions (holds, quality, logistics) and currently
  **refuses a CRT LOT**.
- Received material: `LotOriginType` `Received` / `ReceivedOffsite`; `VendorLotNumber` on
  the LOT; a Receiving Dock view. There is no vendor entity and no outbound-to-vendor
  movement.
- Location definitions carry `IsProductionDestination`, used by CRT to block moves onto
  a line while allowing moves to inspection, inventory, receiving and support areas.

## 3. Rework — options

The question underneath is whether reworked parts **keep their LOT**.

- **(a) Rework in place.** The pieces never leave the LOT. Rework is recorded (how many,
  what was done, by whom) and the LOT stays on CRT until the reworked pieces are
  re-inspected and released through piece 3. Nothing new in the model beyond a record.
  Fits "rework" that is a bench operation on a few parts.
- **(b) Split the reworked pieces out** into a child LOT that carries its own tag and its
  own results, so the good remainder can be released without waiting. Needs `Lot_Split`
  to be allowed from within a super-lot (it refuses CRT LOTs today), and the child must
  join the super-lot automatically — piece 1's `Descendant` join already does that when
  `IncludeDescendants` is on.
- **(c) Route-driven rework**: a rework operation the LOT is sent back through. This is
  the FUTURE capability the FDS deferred, and it cuts across the route model. Out of
  scope unless Jacques says otherwise.

Recommended starting point: **(a)**, with **(b)** when MPP say the good remainder cannot
wait. Do not start (c) inside this feature.

A reworked piece that is then scrapped is an ordinary Scrap result. A reworked piece that
passes is an `Accepted` result. Rework is therefore a **state the pieces pass through**,
not a final outcome — which suggests the results model in piece 3 needs "rework sent" and
"rework returned" rather than a single Rework count. Raise this with whoever builds
piece 3 before its table shape is frozen.

## 4. Return to Vendor — options

- Only meaningful for **received** material (`Received` / `ReceivedOffsite`). A
  manufactured LOT cannot be returned to a vendor; refuse it in SQL.
- The pieces must leave available stock. Options: a subtractive event that is **not** a
  reject (returning stock to a vendor is not MPP's scrap, and the reject reports charge
  scrap to a party); or a `Lot_Split` of the returned quantity into a child LOT that is
  moved to a "return" location and closed when it ships back.
- It probably needs paperwork: a return reference, the vendor, the vendor's lot number
  (already on the LOT). There is no vendor table; `VendorLotNumber` is free text.
- Whether the charge-to-party machinery (migration `0067`) should record the vendor as
  the charged party is a question for Jacques.

## 5. Questions that come first

For MPP (through Jacques):

1. What is "rework" at MPP for a casting, a machined part and a finished good — a bench
   touch-up, re-machining, a re-run through an operation?
2. Do reworked parts go back into the basket or container they came from?
3. Does the good remainder of a LOT wait for its reworked parts, or move on without them?
4. Return to Vendor: which parts does it apply to, what paperwork goes with it, and is
   the return tracked until the vendor acknowledges it?
5. Is there a physical rework area and a physical return-staging area? (They would be
   new location definitions, non-production destinations.)

For Jacques:

6. Rework option (a), (b) or (c).
7. Return to Vendor as a non-reject subtractive event, or as a split-and-move.
8. Does the Rework result in piece 3 need to become two steps (sent / returned)?

## 6. Constraints

As pieces 2 and 3. In addition: anything that changes a LOT's quantity must keep the two
materialized quantities (`PieceCount`, `InventoryAvailable`) in step — CLAUDE.md notes
there is **no audited repair path** if they diverge.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft: options and questions, written as a handoff. Not approved. |
