# Legacy Zebra Label Templates → MES Data Model Mapping

**Date:** 2026-07-14
**Purpose:** Map every field token in the four legacy Manufacturing Director ZPL templates
(`zebraPrinter/*.zpl`) to a source in the MPP MES data model, so we know which render tokens
and source columns `Lots.LabelTemplate` / `Lots.LotLabel_Print` must gain when we port the
real Honda-format labels onto the GX420d (endpoint / raw-9100 path).

**Legend:** ✅ available today · ⚠️ derivable (needs a join/resolve or a render-proc change) ·
❌ gap (no MES source — needs a schema add or a decision).

Barcode-duplicate tokens (`PART-NUMBER2`, `…-EXTENSION2`, `PART-LEVEL2`, `SERIAL-NUMBER2`,
`QUANTITY:Q{0}`) are the **same source** as their human-readable twin, just rendered into a
`^B3`/`^BX` barcode — collapsed into the base row below.

---

## 1. Lot Label (`Label Template - Lot.zpl`)

The one that matters most for MVP (LTT on every basket at Die Cast / Trim / intermediate Machining).

| Legacy token | Label field | MES source | Status |
|---|---|---|---|
| `LOCATION-NAME` | Area | `Lot.CurrentLocationId` → resolve **Area** ancestor via `Location` hierarchy | ⚠️ derivable — new resolve in render proc |
| `LOT-NAME` (+ barcode) | Lot | `Lot.LotName` | ✅ (already a token: `{LotName}`) |
| `MATERIAL-NAME` | Material | `Item.PartNumber` (Flexware "Material" = our Item) | ✅ (`{ItemCode}`) |
| `MATERIAL-DESCRIPTION` | Material desc | `Item.Description` | ⚠️ new token |
| `QUANTITY` | Quantity | `Lot.PieceCount` | ✅ (`{PieceCount}`) |
| `TIMESTAMP` | Date/Time | `Lot.CreatedAt` (or print time — see note) | ✅ (`{PrintedAt}` = print time; add `{ProducedAt}` if they want LOT birth) |

**Verdict:** ~fully covered. Adds needed: **Area name** resolve + **Item.Description** token.
Everything else already flows through `LotLabel_Print`.

---

## 2. Container Label (`Label Template - Container.zpl`)

Honda finished-goods shipping label — the rich one (rotated, DataMatrix, serial, COO).

| Legacy token | Label field | MES source | Status |
|---|---|---|---|
| `PART-NUMBER` (P) (+ barcode) | PART NO. (P) | `Item.PartNumber` | ✅ |
| `PART-NUMBER-EXTENSION` (C) (+ barcode) | PART NO. EXT (C) | **no column** — Honda color/spec suffix | ❌ gap |
| `2D-BARCODE` | DataMatrix (P+Q+1S+…) | composite string assembled from P/Q/serial/date | ❌ needs Honda 2D format spec + assembly logic |
| `DESCRIPTION` | Description | `Item.Description` | ⚠️ new token |
| `LOT-NUMBER` | MFG LOT NUMBER | source `Lot.LotName` (Container → `Container.LotId` / tray → `ContainerTray.FinishedGoodLotId`) | ⚠️ resolve via container→LOT |
| `DATE` (M/dd/yy) | MFG DATE | `Lot.CreatedAt` (source FG LOT) or `Container.CreatedAt` | ⚠️ new token |
| `AUDITOR` | AUDIT | operator initials — `Lot.CreatedByUserId`→`AppUser`, **or** a distinct QA auditor | ⚠️/❌ which user? (creator vs auditor sign-off — decision) |
| `PART-LEVEL` (2P) (+ barcode) | D/C PART LEVEL (2P) | **no column** — design-change / revision level | ❌ gap |
| `QUANTITY` (Q) (+ `Q`-prefixed barcode) | QUANTITY (Q) | `ContainerTray.PieceCount` (per tray) / `Lot.PieceCount` | ✅ |
| `SERIAL-NUMBER` (1S) (+ barcode) | SERIAL (1S) | container serial — `Container.ContainerName` (unique) or a shipping serial; **part** serial is `SerializedPart.SerialNumber` | ⚠️ decision: container-level 1S vs per-part |
| `COO` | Made In / C.O.O. | `Item.CountryOfOrigin` (ISO alpha-2, added v1.8/OI-19) | ✅ new token |
| (static) | MPP address block | hard-coded in template ("Madison Precision Products…") | ✅ literal |

**Verdict:** 3 genuine gaps — **PART-NUMBER-EXTENSION (C)**, **D/C PART-LEVEL (2P)**, and the
**2D DataMatrix composite**. Plus two decisions (AUDITOR source, 1S serial granularity).

---

## 3. Container Hold Label (`Label Template - Container Hold.zpl`)

Printed when a container/LOT is placed on hold (Sort Cage / Quality).

| Legacy token | Label field | MES source | Status |
|---|---|---|---|
| `SERIAL-NUMBER` (+ barcode) | SERIAL | `Container.ContainerName` / `SerializedPart.SerialNumber` | ⚠️ same 1S decision as above |
| `DATE-PRODUCED` (M/dd/yyyy) | DATE PRODUCED | `Lot.CreatedAt` | ✅ |
| `DATE-OF-HOLD` (M/dd/yyyy) | DATE OF HOLD | `Quality.HoldEvent.PlacedAt` | ✅ |
| `PART-NUMBER` | PART NO. | `Item.PartNumber` | ✅ |
| `QUANTITY` | QUANTITY | `Lot.PieceCount` | ✅ |
| `HOLD-REASON` | CONTROL NUMBER / DEFECT | `HoldEvent.Reason` (+ `HoldTypeCode`, `NonConformance`) | ✅ |

**Verdict:** fully sourceable today (once a Hold-type LabelTemplate + render path exists — the
`Void`/hold label type isn't wired to a hold-print action yet).

---

## 4. Container backup template

`Label Template - Container - backup 20181114.zpl` is an older revision of the Container label
(same token set, minor layout deltas). No new fields — ignore for mapping; keep as layout reference.

---

## Consolidated gaps & what each implies

### ❌ Schema gaps (Item-level, Honda part-marking fields)
1. **Part Number Extension (C)** — Honda color/spec suffix. Options: (a) new `Item.PartNumberExtension NVARCHAR`, (b) it's already embedded in `PartNumber`, (c) sourced from `MacolaPartNumber`. **Needs MPP input** on where this lives today.
2. **D/C Part Level / Design-Change Level (2P)** — revision/EC level. MES has **no** revision column on `Item`. Options: new `Item.DesignChangeLevel NVARCHAR`, or a versioned attribute. **Needs MPP input.**
   - Both (1) and (2) appear on the **container/shipping** label only — not the LTT — so they don't block MVP LTT printing.

### ❌ Rendering / spec gaps
3. **2D DataMatrix composite** — Honda encodes a composite (typically `P`, `Q`, `1S`, date, supplier). Needs: the exact Honda 2D field concatenation spec, then assemble the string in the render proc and emit into `^BXN`. **Needs the Honda label spec** (likely in the FRS shipping appendix or from MPP Quality).

### ⚠️ Decisions
4. **AUDITOR source** — is it the LOT creator (`Lot.CreatedByUserId` initials) or a separate QA auditor sign-off captured at container close? Affects whether we need a new capture point.
5. **Serial (1S) granularity** — on container labels, is "1S" the **container's** unique serial (`Container.ContainerName` / a shipping serial) or a **representative part** serial? Drives which column feeds it.

### ⚠️ Render-proc token expansions (no schema change — all sourceable)
- `Item.Description`, **Area name** (resolve from `Lot.CurrentLocationId`), `Item.CountryOfOrigin`,
  `Container.CreatedAt` / source-LOT `CreatedAt`, container→source-LOT `LotName`, `HoldEvent.PlacedAt` + `Reason`.
- Current render proc (`Lots.LotLabel_Print`) only substitutes 5 tokens
  (`{LotName} {ParentLotNumber} {ItemCode} {PieceCount} {PrintedAt}`). Porting the Container +
  Hold labels means the proc gains per-label-type source resolution (a container label reads
  Container/Tray/Item/Serial; a hold label reads HoldEvent) — i.e. the token set and the
  proc's SELECTs grow, keyed by `LabelTypeCode`.

## Suggested sequencing
1. **LTT / Lot label first** (MVP path): only +2 tokens (Area, Description) — quick win, unblocks GX420d certification.
2. **Container label**: resolve the 3 gaps (C, 2P, 2D spec) with MPP, then port.
3. **Hold label**: wire a hold-print action + Hold LabelTemplate (all fields already sourceable).

## Format / hardware note
GX420d = 203 dpi, 4" direct thermal. The Container templates use rotated fields (`^A0R`) and
~1300-dot-long coordinates — authored for a specific label stock. Confirm physical label
size/orientation renders correctly at 203 dpi (Labelary preview) before certifying.
