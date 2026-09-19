# Die Cast Training Deck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `docs/training/diecast/MPP_DieCast_Training.pptx` — a 25-slide, grade 7–8 training deck for die cast operators and team leads, with real Dev screenshots annotated by measured, numbered PowerPoint markers.

**Architecture:** A capture script drives the live Perspective die cast screens in headless Chrome (existing harness `tools/perspective-capture/`) and writes, per screenshot, a PNG plus a JSON of the pixel rectangles of every control a slide will point at. A content file holds all slide wording. A pptxgenjs generator joins the two: screenshot as an image, markers and zones as native shapes positioned from the measured rectangles, checked for readability and consistency before the file is written.

**Tech Stack:** Node 24 (ESM `.mjs` for capture, CommonJS for the generator), pptxgenjs, `node:test`, sqlcmd against `MPP_MES_Dev`, PowerPoint COM (PowerShell) for rendering slides to PNG in QA, the pptx skill's `validate.py`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-18-diecast-operator-training-deck-design.md` — every task's requirements include it.
- Reading level: on-screen slide text Flesch–Kincaid grade **≤ 8.0**; speaker notes **≤ 9.0**. Screen labels (written `**Like This**` in content) and tokens containing digits are excluded from scoring.
- Markers: amber `FFB400`, **1.5 pt** outline, thin dark halo; numbered discs 0.28" with black numeral. Zones: 1.5 pt outline in the zone's colour, lettered tag.
- Numbers = actions, letters = areas. Never mixed on one slide.
- Font: Calibri. Layout: `LAYOUT_WIDE` (13.333" × 7.5"). No accent bars/stripes, no title underlines.
- Environment: Dev only (`MPP_MES_Dev`, gateway `http://localhost:8088`), machine `DC1-M11`, terminal `DC1-T1`, die `DMO125`.
- Capture Chrome on CDP port **9333** (never 9222 — Ignition Designer uses it).
- **Credentials are never typed by a script.** The team lead capture pauses for Jacques to type the AD account himself in a visible Chrome window.
- ASCII only in content strings (CLAUDE.md seed rule applies to anything that may be pasted into the MES): plain hyphens, straight quotes, no middle-dot or em-dash.
- Commits on `jacques/working`, explicit paths only (`git add <path>`), no `Co-Authored-By: Claude` trailer (CLAUDE.md).

## File Structure

| File | Responsibility |
|---|---|
| `tools/training-deck/lib/readability.js` | Flesch–Kincaid grade of a string, label/number-aware |
| `tools/training-deck/lib/geometry.js` | Screenshot pixel rect → slide-inch rect for a placed image |
| `tools/training-deck/lib/checks.js` | Content ↔ shot consistency checks (markers, steps, zones, bounds) |
| `tools/training-deck/lib/measure.mjs` | In-browser element finder → rectangles; `capture()` writes PNG + JSON |
| `tools/training-deck/lib/dc_db.mjs` | Dev SQL helpers keyed by cavity CODE (open/release/void/clear) |
| `tools/training-deck/setup_training_operator.sql` | Creates the fictional training operator through `Location.AppUser_Create` |
| `tools/training-deck/capture_diecast.mjs` | Drives the screens, writes `docs/training/diecast/shots/*.png|json` |
| `tools/training-deck/diecast_content.js` | Every slide's words, markers, zones, notes |
| `tools/training-deck/build_diecast_deck.js` | pptxgenjs renderer + pre-write checks |
| `tools/training-deck/render_slides.ps1` | PowerPoint COM: export every slide to PNG for QA |
| `tools/training-deck/test/*.test.js` | `node:test` unit tests for the three libs + content |
| `docs/training/diecast/` | Output deck, `shots/` |

---

### Task 1: Readability scorer

**Files:**
- Create: `tools/training-deck/lib/readability.js`
- Test: `tools/training-deck/test/readability.test.js`

**Interfaces:**
- Produces: `fkGrade(text: string) -> number` (Flesch–Kincaid grade, 1 decimal); `stripLabels(text: string) -> string` (removes `**...**` spans and digit-bearing tokens).

- [ ] **Step 1: Write the failing test**

```js
// tools/training-deck/test/readability.test.js
const test = require('node:test');
const assert = require('node:assert');
const { fkGrade, stripLabels } = require('../lib/readability');

test('stripLabels removes bold screen labels and tokens with digits', () => {
  assert.strictEqual(stripLabels('Tap **Scan LTT** on row 12232-6MA now.').replace(/\s+/g, ' ').trim(),
    'Tap on row now.');
});

test('short plain sentences score low', () => {
  const g = fkGrade('Find the empty cavity. Tap the box. Scan the ticket.');
  assert.ok(g < 4, `got ${g}`);
});

test('long technical prose scores high', () => {
  const g = fkGrade('The reconciliation identity attributes unaccounted production variance to indeterminate operational circumstances requiring disposition.');
  assert.ok(g > 14, `got ${g}`);
});

test('empty text scores zero', () => {
  assert.strictEqual(fkGrade(''), 0);
  assert.strictEqual(fkGrade('**Compute**'), 0);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tools/training-deck/test/readability.test.js`
Expected: FAIL — `Cannot find module '../lib/readability'`

- [ ] **Step 3: Write minimal implementation**

```js
// tools/training-deck/lib/readability.js
// Flesch-Kincaid grade level. Screen labels (**Like This**) and anything with a
// digit (part numbers, counter readings) are removed first: an operator reads
// "Scan LTT" off the screen, it is not prose they have to decode.

function stripLabels(text) {
  return String(text || '')
    .replace(/\*\*[^*]+\*\*/g, ' ')
    .split(/\s+/)
    .filter((t) => !/\d/.test(t))
    .join(' ');
}

function syllables(word) {
  let w = word.toLowerCase().replace(/[^a-z]/g, '');
  if (!w) return 0;
  if (w.length <= 3) return 1;
  w = w.replace(/(?:[^laeiouy]es|[^laeiouy]ed|[^laeiouy]e)$/, '').replace(/^y/, '');
  const groups = w.match(/[aeiouy]{1,2}/g);
  return Math.max(1, groups ? groups.length : 1);
}

function fkGrade(text) {
  const clean = stripLabels(text);
  const words = clean.split(/\s+/).map((w) => w.replace(/[^A-Za-z']/g, '')).filter(Boolean);
  if (words.length === 0) return 0;
  const sentences = Math.max(1, (clean.match(/[.!?]+(\s|$)/g) || []).length);
  const syl = words.reduce((n, w) => n + syllables(w), 0);
  const g = 0.39 * (words.length / sentences) + 11.8 * (syl / words.length) - 15.59;
  return Math.round(Math.max(0, g) * 10) / 10;
}

module.exports = { fkGrade, stripLabels, syllables };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test tools/training-deck/test/readability.test.js`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/lib/readability.js tools/training-deck/test/readability.test.js
git commit -m "feat(training-deck): Flesch-Kincaid scorer that ignores screen labels"
```

---

### Task 2: Pixel-to-slide geometry

**Files:**
- Create: `tools/training-deck/lib/geometry.js`
- Test: `tools/training-deck/test/geometry.test.js`

**Interfaces:**
- Produces: `placeImage(imgW, imgH, box:{x,y,w,h}) -> {x,y,w,h}` (fit image inside a slide box, inches, aspect kept, top-left aligned); `toSlide(rect:{x,y,w,h} px, placed:{x,y,w,h} in, imgW, imgH, pad=0 px) -> {x,y,w,h}` in inches; `insideImage(rect px, imgW, imgH) -> boolean`.

- [ ] **Step 1: Write the failing test**

```js
// tools/training-deck/test/geometry.test.js
const test = require('node:test');
const assert = require('node:assert');
const { placeImage, toSlide, insideImage } = require('../lib/geometry');

test('placeImage keeps aspect and fits the width-limited box', () => {
  const p = placeImage(1600, 1000, { x: 0.4, y: 1.2, w: 8.4, h: 6 });
  assert.deepStrictEqual(p, { x: 0.4, y: 1.2, w: 8.4, h: 5.25 });
});

test('placeImage fits the height-limited box', () => {
  const p = placeImage(1600, 1000, { x: 1, y: 1, w: 12, h: 5 });
  assert.deepStrictEqual(p, { x: 1, y: 1, w: 8, h: 5 });
});

test('toSlide maps a pixel rect proportionally, with padding', () => {
  const placed = { x: 0.4, y: 1.2, w: 8.4, h: 5.25 };
  const r = toSlide({ x: 800, y: 500, w: 160, h: 100 }, placed, 1600, 1000, 0);
  assert.deepStrictEqual(r, { x: 4.6, y: 3.825, w: 0.84, h: 0.525 });
  const rp = toSlide({ x: 800, y: 500, w: 160, h: 100 }, placed, 1600, 1000, 10);
  assert.ok(rp.x < r.x && rp.w > r.w);
});

test('insideImage rejects rects that leave the image', () => {
  assert.strictEqual(insideImage({ x: 10, y: 10, w: 100, h: 20 }, 1600, 1000), true);
  assert.strictEqual(insideImage({ x: 1550, y: 10, w: 100, h: 20 }, 1600, 1000), false);
  assert.strictEqual(insideImage({ x: 10, y: -5, w: 100, h: 20 }, 1600, 1000), false);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tools/training-deck/test/geometry.test.js`
Expected: FAIL — `Cannot find module '../lib/geometry'`

- [ ] **Step 3: Write minimal implementation**

```js
// tools/training-deck/lib/geometry.js
const r3 = (n) => Math.round(n * 1000) / 1000;

function placeImage(imgW, imgH, box) {
  const scale = Math.min(box.w / imgW, box.h / imgH);
  return { x: box.x, y: box.y, w: r3(imgW * scale), h: r3(imgH * scale) };
}

function toSlide(rect, placed, imgW, imgH, pad = 0) {
  const sx = placed.w / imgW, sy = placed.h / imgH;
  return {
    x: r3(placed.x + (rect.x - pad) * sx),
    y: r3(placed.y + (rect.y - pad) * sy),
    w: r3((rect.w + 2 * pad) * sx),
    h: r3((rect.h + 2 * pad) * sy),
  };
}

function insideImage(rect, imgW, imgH) {
  return rect.x >= 0 && rect.y >= 0 && rect.x + rect.w <= imgW && rect.y + rect.h <= imgH;
}

module.exports = { placeImage, toSlide, insideImage };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test tools/training-deck/test/geometry.test.js`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/lib/geometry.js tools/training-deck/test/geometry.test.js
git commit -m "feat(training-deck): map measured screen rects onto slide inches"
```

---

### Task 3: Content ↔ shot consistency checks

**Files:**
- Create: `tools/training-deck/lib/checks.js`
- Test: `tools/training-deck/test/checks.test.js`

**Interfaces:**
- Consumes: `fkGrade` (Task 1), `insideImage` (Task 2).
- Produces: `checkSlide(slide, shot) -> string[]` (list of problems, empty = OK). Slide shapes used by every later task:
  - steps slide: `{ id, kind:'steps', title, kicker, shot:'<shotId>', steps:[string], markers:[{n, target}], tip?:string, notes:string }`
  - overview slide: `{ id, kind:'overview', title, kicker, shot, zones:[{letter, target, color, label}], notes }`
  - other kinds (`title`, `concept`, `glossary`, `divider`, `summary`) have no `shot`.
  - shot JSON (written by Task 4): `{ image:'<file>.png', width, height, targets:{ <name>:{x,y,w,h} } }`

- [ ] **Step 1: Write the failing test**

```js
// tools/training-deck/test/checks.test.js
const test = require('node:test');
const assert = require('node:assert');
const { checkSlide } = require('../lib/checks');

const shot = { image: 'a.png', width: 1600, height: 1000,
  targets: { row: { x: 30, y: 370, w: 1520, h: 66 }, ltt: { x: 1100, y: 386, w: 200, h: 34 } } };

const good = { id: 's7', kind: 'steps', title: 'Open a basket', shot: 'a',
  steps: ['Find the empty cavity.', 'Tap **Scan LTT**. Scan the ticket.'],
  markers: [{ n: 1, target: 'row' }, { n: 2, target: 'ltt' }],
  notes: 'Show the row. Then scan.' };

test('a consistent steps slide has no problems', () => {
  assert.deepStrictEqual(checkSlide(good, shot), []);
});

test('marker without a step, and step without a marker, are both reported', () => {
  const s = { ...good, markers: [{ n: 1, target: 'row' }, { n: 3, target: 'ltt' }] };
  const p = checkSlide(s, shot);
  assert.ok(p.some((x) => /marker 3/.test(x)));
  assert.ok(p.some((x) => /step 2/.test(x)));
});

test('unknown target and out-of-image target are reported', () => {
  const s = { ...good, markers: [{ n: 1, target: 'nope' }, { n: 2, target: 'ltt' }] };
  assert.ok(checkSlide(s, shot).some((x) => /nope/.test(x)));
  const badShot = { ...shot, targets: { ...shot.targets, ltt: { x: 1500, y: 386, w: 200, h: 34 } } };
  assert.ok(checkSlide(good, badShot).some((x) => /outside/.test(x)));
});

test('hard words fail the grade limit', () => {
  const s = { ...good, steps: ['Subsequently reconcile indeterminate operational variance dispositions.', 'Tap.'] };
  assert.ok(checkSlide(s, shot).some((x) => /grade/.test(x)));
});

test('overview zones need targets and unique letters', () => {
  const o = { id: 'o', kind: 'overview', title: 'T', shot: 'a', notes: 'Look.',
    zones: [{ letter: 'A', target: 'row', color: '2E86DE', label: 'Rows' },
            { letter: 'A', target: 'ltt', color: 'C0392B', label: 'Box' }] };
  assert.ok(checkSlide(o, shot).some((x) => /letter A/.test(x)));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tools/training-deck/test/checks.test.js`
Expected: FAIL — `Cannot find module '../lib/checks'`

- [ ] **Step 3: Write minimal implementation**

```js
// tools/training-deck/lib/checks.js
const { fkGrade } = require('./readability');
const { insideImage } = require('./geometry');

const SLIDE_MAX = 8.0, NOTES_MAX = 9.0;

function slideText(s) {
  return [s.title, ...(s.steps || []), s.tip, ...(s.zones || []).map((z) => z.label),
    ...(s.bullets || []), ...(s.terms || []).map((t) => t.meaning)].filter(Boolean).join(' ');
}

function checkTarget(p, shot, name, what) {
  const r = shot.targets[name];
  if (!r) { p.push(`${what}: target "${name}" not in shot`); return; }
  if (!insideImage(r, shot.width, shot.height)) p.push(`${what}: target "${name}" is outside the image`);
}

function checkSlide(s, shot) {
  const p = [];
  const g = fkGrade(slideText(s));
  if (g > SLIDE_MAX) p.push(`slide text grade ${g} > ${SLIDE_MAX}`);
  const gn = fkGrade(s.notes || '');
  if (gn > NOTES_MAX) p.push(`notes grade ${gn} > ${NOTES_MAX}`);

  if (s.kind === 'steps') {
    if (!shot) { p.push(`no shot "${s.shot}"`); return p; }
    const ns = new Set(s.markers.map((m) => m.n));
    s.markers.forEach((m) => {
      if (m.n < 1 || m.n > s.steps.length) p.push(`marker ${m.n} has no matching step`);
      checkTarget(p, shot, m.target, `marker ${m.n}`);
    });
    s.steps.forEach((_, i) => { if (!ns.has(i + 1)) p.push(`step ${i + 1} has no marker`); });
  }
  if (s.kind === 'overview') {
    if (!shot) { p.push(`no shot "${s.shot}"`); return p; }
    const seen = new Set();
    s.zones.forEach((z) => {
      if (seen.has(z.letter)) p.push(`letter ${z.letter} used twice`);
      seen.add(z.letter);
      checkTarget(p, shot, z.target, `zone ${z.letter}`);
    });
  }
  return p;
}

module.exports = { checkSlide, slideText, SLIDE_MAX, NOTES_MAX };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test tools/training-deck/test/`
Expected: PASS (13 tests across three files)

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/lib/checks.js tools/training-deck/test/checks.test.js
git commit -m "feat(training-deck): content vs screenshot consistency checks"
```

---

### Task 4: Capture plumbing — measuring, Dev helpers, training operator

**Files:**
- Create: `tools/training-deck/lib/measure.mjs`
- Create: `tools/training-deck/lib/dc_db.mjs`
- Create: `tools/training-deck/setup_training_operator.sql`

**Interfaces:**
- Consumes: harness `tools/perspective-capture/cdp.mjs` (`connect`, `setViewport`, `evalJs`, `sleep`).
- Produces:
  - `measure(cdp, specs) -> {name:{x,y,w,h}}` where each spec is `{ text?, placeholder?, tag?='*', nth?=0, exact?=true, up?=0, maxChars?, pad?=0 }` or `{ union:[name,...] }` (computed after the others). Throws naming the spec it could not find.
  - `capture(cdp, dir, id, specs) -> shot` writes `<dir>/<id>.png` and `<dir>/<id>.json` in the shot JSON shape of Task 3.
  - `dumpControls(cdp) -> [{tag,text,placeholder,x,y,w,h}]` for discovery.
  - `dc_db.mjs`: `DIE='DMO125'`, `MACHINE='DC1-M11'`, `PIN` from `setup_training_operator.sql`; `clearDie()`, `openBasket({code, desc, ltt})`, `releaseBasket({code, desc, reading})`, `openLots() -> [{desc, code, ltt, pieces}]`.

- [ ] **Step 1: Write `setup_training_operator.sql`** (idempotent; goes through the proc so it carries its audit row)

```sql
-- Creates the fictional training operator whose name shows in the training
-- screenshots. Dev only. PIN 24680 (leading digit non-zero on purpose: it is a
-- made-up person, not a full-time employee code).
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Pin = N'24680')
BEGIN
    DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @R EXEC Location.AppUser_Create
        @Initials = N'ST', @DisplayName = N'Sam Taylor', @Pin = N'24680',
        @AdAccount = NULL, @IgnitionRole = NULL, @AppUserId = 1;
    SELECT Status, Message, NewId FROM @R;
END
ELSE SELECT 'exists' AS Status, Id FROM Location.AppUser WHERE Pin = N'24680';
```

Run: `sqlcmd -S localhost -E -C -I -b -d MPP_MES_Dev -i tools/training-deck/setup_training_operator.sql`
Expected: `1 | ...Created... | <id>` (or `exists` on re-run)

- [ ] **Step 2: Write `lib/dc_db.mjs`**

```js
// Dev-only helpers for the training captures, keyed by cavity CODE + description
// (DMO125 repeats letters a/b once per part, so a letter alone is ambiguous).
// Every write goes through the same procs the screens call.
import { execFileSync } from 'node:child_process';

export const DIE = 'DMO125', MACHINE = 'DC1-M11', PIN = '24680';

export function sql(q) {
  return execFileSync('sqlcmd', ['-S', 'localhost', '-d', 'MPP_MES_Dev', '-E', '-C', '-W', '-I', '-b',
    '-s', '|', '-h', '-1', '-Q', 'SET NOCOUNT ON;\n' + q], { encoding: 'utf8' }).trim();
}

const cav = (desc) => `(SELECT c.Id FROM Tools.ToolCavity c JOIN Tools.Tool t ON t.Id=c.ToolId
  WHERE t.Code=N'${DIE}' AND c.Description=N'${desc}' AND c.DeprecatedAt IS NULL)`;
const user = `(SELECT Id FROM Location.AppUser WHERE Pin=N'${PIN}')`;

export function openBasket({ desc, ltt }) {
  return sql(`DECLARE @C BIGINT=${cav(desc)};
DECLARE @T BIGINT=(SELECT ToolId FROM Tools.ToolCavity WHERE Id=@C), @I BIGINT=(SELECT ItemId FROM Tools.ToolCavity WHERE Id=@C);
DECLARE @M BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'${MACHINE}'), @U BIGINT=${user};
DECLARE @Term BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'DC1-T1');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.DieCastLot_Open @ItemId=@I,@CurrentLocationId=@M,@ToolId=@T,@ToolCavityId=@C,
  @LotName=N'${ltt}',@AppUserId=@U,@TerminalLocationId=@Term;
SELECT Status, Message FROM @R;`);
}

export function releaseBasket({ desc, reading }) {
  return sql(`DECLARE @C BIGINT=${cav(desc)}, @U BIGINT=${user};
DECLARE @M BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'${MACHINE}');
DECLARE @Term BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'DC1-T1');
DECLARE @S BIGINT=(SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id DESC);
DECLARE @L BIGINT=(SELECT l.Id FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId
  WHERE s.Code=N'Open' AND l.ToolCavityId=@C);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.DieCastLot_Release @LotId=@L,@StorageLocationId=NULL,@FinalPieceDelta=NULL,
  @CounterReading=${reading},@ShiftId=@S,@AppUserId=@U,@TerminalLocationId=@Term,@CellLocationId=@M;
SELECT Status, Message FROM @R;`);
}

export function openLots() {
  const out = sql(`SELECT c.Description, c.CavityCode, l.LotName, l.PieceCount
FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId AND s.Code=N'Open'
JOIN Tools.ToolCavity c ON c.Id=l.ToolCavityId JOIN Tools.Tool t ON t.Id=c.ToolId AND t.Code=N'${DIE}'
ORDER BY c.Id;`);
  return out ? out.split('\n').map((l) => { const [desc, code, ltt, pieces] = l.split('|');
    return { desc, code, ltt, pieces: Number(pieces) }; }) : [];
}

/** Dev playground reset for DMO125: remove every LOT, contribution, reject and
 *  counter anchor this die has, so each capture run starts from an empty die.
 *  Dev only -- Import-ConfigSnapshot left Dev with no production history. */
export function clearDie() {
  return sql(`DECLARE @T BIGINT=(SELECT Id FROM Tools.Tool WHERE Code=N'${DIE}');
IF DB_NAME() <> N'MPP_MES_Dev' THROW 50000, 'clearDie is Dev only', 1;
DECLARE @L TABLE (Id BIGINT PRIMARY KEY); INSERT INTO @L SELECT Id FROM Lots.Lot WHERE ToolId=@T;
DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId=@T;
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @L) OR ToolCavityId IN (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@T);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @L) OR ToolId=@T;
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @L) OR DescendantLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @L) OR ChildLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotLabel WHERE LotId IN (SELECT Id FROM @L) OR ParentLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.PauseEvent WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @L);
SELECT 'cleared', COUNT(*) FROM @L;`);
}
```

- [ ] **Step 3: Write `lib/measure.mjs`**

```js
// Finds on-screen controls and records their rectangles next to the screenshot,
// so slide markers are placed from measurement, never guessed pixels.
import fs from 'node:fs';
import path from 'node:path';
import { evalJs } from '../../perspective-capture/cdp.mjs';

const FINDER = `(spec) => {
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2; };
  let els = [...document.querySelectorAll(spec.tag || '*')].filter(vis);
  if (spec.placeholder) els = els.filter((e) => e.placeholder === spec.placeholder);
  if (spec.text) {
    const want = spec.text.toLowerCase();
    els = els.filter((e) => { const t = (e.innerText || e.value || '').trim().toLowerCase();
      return spec.exact === false ? t.includes(want) : t === want; });
    // innermost only: drop any element that contains another match
    els = els.filter((e) => !els.some((o) => o !== e && e.contains(o)));
  }
  els.sort((a, b) => { const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
    return (ra.y - rb.y) || (ra.x - rb.x); });
  let el = els[spec.nth || 0];
  if (!el) return null;
  for (let i = 0; i < (spec.up || 0) && el.parentElement; i++) {
    const p = el.parentElement;
    if (spec.maxChars && (p.innerText || '').length > spec.maxChars) break;
    el = p;
  }
  const r = el.getBoundingClientRect();
  return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
}`;

export async function measure(cdp, specs) {
  const out = {};
  for (const [name, spec] of Object.entries(specs)) {
    if (spec.union) continue;
    const r = await evalJs(cdp, `(${FINDER})(${JSON.stringify(spec)})`);
    if (!r) throw new Error(`measure: "${name}" not found: ${JSON.stringify(spec)}`);
    const pad = spec.pad || 0;
    out[name] = { x: r.x - pad, y: r.y - pad, w: r.w + 2 * pad, h: r.h + 2 * pad };
  }
  for (const [name, spec] of Object.entries(specs)) {
    if (!spec.union) continue;
    const rs = spec.union.map((n) => { if (!out[n]) throw new Error(`union ${name}: ${n} missing`); return out[n]; });
    const x = Math.min(...rs.map((r) => r.x)), y = Math.min(...rs.map((r) => r.y));
    out[name] = { x, y, w: Math.max(...rs.map((r) => r.x + r.w)) - x, h: Math.max(...rs.map((r) => r.y + r.h)) - y };
  }
  return out;
}

export async function capture(cdp, dir, id, specs = {}) {
  fs.mkdirSync(dir, { recursive: true });
  const targets = await measure(cdp, specs);
  const r = await cdp.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(dir, `${id}.png`), Buffer.from(r.data, 'base64'));
  const size = await evalJs(cdp, '({w: innerWidth, h: innerHeight})');
  const shot = { image: `${id}.png`, width: size.w, height: size.h, targets };
  fs.writeFileSync(path.join(dir, `${id}.json`), JSON.stringify(shot, null, 2));
  console.log(`captured ${id} (${Object.keys(targets).length} targets)`);
  return shot;
}

export async function dumpControls(cdp) {
  return evalJs(cdp, `[...document.querySelectorAll('button,input,[role=button],a')]
    .map(e => ({ e, r: e.getBoundingClientRect() })).filter(o => o.r.width > 2)
    .map(o => ({ tag: o.e.tagName, text: (o.e.innerText||o.e.value||'').trim().slice(0,40),
      placeholder: o.e.placeholder || '', x: Math.round(o.r.x), y: Math.round(o.r.y),
      w: Math.round(o.r.width), h: Math.round(o.r.height) }))`);
}
```

- [ ] **Step 4: Smoke-test the plumbing against Dev**

Create operator (Step 1 command), then:

Run:
```bash
node --input-type=module -e "import('./tools/training-deck/lib/dc_db.mjs').then(m => { console.log(m.clearDie()); console.log(m.openBasket({desc:'In 2-Da', ltt:'70000001'})); console.log(m.openLots()); console.log(m.clearDie()); })"
```
Expected: `cleared|0`, then `1|Basket opened (70000001).`, then `[ { desc: 'In 2-Da', code: 'a', ltt: '70000001', pieces: 0 } ]`, then `cleared|1`.

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/lib/measure.mjs tools/training-deck/lib/dc_db.mjs tools/training-deck/setup_training_operator.sql
git commit -m "feat(training-deck): measured captures, cavity-code Dev helpers, training operator"
```

---

### Task 5: Capture the operator screens (slides 4–10)

**Files:**
- Create: `tools/training-deck/capture_diecast.mjs`
- Output: `docs/training/diecast/shots/` — `lot_overview`, `pin_gate`, `pin_unknown`, `cell_pick`, `open_basket_before`, `open_basket_after`, `open_all`, `release_dialog`, `void_row` (`.png` + `.json` each)

**Interfaces:**
- Consumes: `measure/capture/dumpControls` (Task 4), `dc_db` (Task 4), harness `lib.mjs` (`URL`, `signIn`, `pickCell`, `tab`, `text`, `sleep`, `evalJs`, `clickText`), `cdp.mjs` (`connect`, `setViewport`, `click`, `typeText`).
- Produces: shot ids above with target names used by Task 8 (listed per capture below).

Chrome must be running first:
```powershell
Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList "--remote-debugging-port=9333","--user-data-dir=$env:TEMP\training-capture-profile","--headless=new","--window-size=1600,1000","--disable-background-timer-throttling","--disable-backgrounding-occluded-windows","--disable-renderer-backgrounding","about:blank"
```

- [ ] **Step 1: Discovery pass.** Before writing each capture, open the state and dump controls so every `text`/`placeholder` in the specs below is confirmed against the live screen:

```js
// scratch: node tools/training-deck/capture_diecast.mjs --discover <state>
// prints dumpControls() as a table for the named state (see STATES below)
```

Adjust any spec whose label differs on screen; the screen wins over this plan.

- [ ] **Step 2: Write `capture_diecast.mjs` (operator part)**

```js
// Drives the Dev die cast terminal and writes annotated-screenshot sources for
// the training deck. Dev only. Usage:
//   node tools/training-deck/capture_diecast.mjs [--only <group>] [--discover <state>]
// Groups: operator | reconcile | teamlead | dashboard
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { connect, setViewport, click, typeText } from '../perspective-capture/cdp.mjs';
import { URL, signIn, pickCell, tab, text, sleep, evalJs, clickText } from '../perspective-capture/lib.mjs';
import { capture, dumpControls } from './lib/measure.mjs';
import * as db from './lib/dc_db.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(HERE, '../../docs/training/diecast/shots');
const CELL = 'DC1-M11 - Machine 11';
const args = process.argv.slice(2);
const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null;
const want = (g) => !only || only === g;

async function clickEl(cdp, spec) {
  const { measure } = await import('./lib/measure.mjs');
  const r = (await measure(cdp, { t: spec })).t;
  await click(cdp, r.x + r.w / 2, r.y + r.h / 2);
}

async function freshSession() {
  const cdp = await connect(URL);
  await setViewport(cdp, 1600, 1000);
  await cdp.send('Page.navigate', { url: URL });
  await sleep(9000);
  return cdp;
}

// Row of a cavity on Lot Management: the cavity name, walked up to its row box.
const row = (desc, nth = 0) => ({ text: desc, tag: 'div,span', up: 6, maxChars: 260, nth });

async function operator() {
  db.clearDie();
  let cdp = await freshSession();
  await capture(cdp, OUT, 'pin_gate', {
    display: { text: 'Enter your PIN', tag: 'div,span', up: 3, maxChars: 80 },
    keypad: { text: '5', tag: 'button', up: 2, maxChars: 60 },
  });
  // Unknown PIN: a made-up PIN nobody has.
  for (const d of '13579') await clickText(cdp, d, { tag: 'button', settle: 250 });
  await sleep(2500);
  await capture(cdp, OUT, 'pin_unknown', {
    retype: { text: 'Re-type PIN', tag: 'button,div' },
    register: { text: 'Register New User', tag: 'button,div' },
  });
  await clickText(cdp, 'Re-type PIN', { settle: 1500 });
  await signIn(cdp, db.PIN);
  // Active Cell dropdown opened.
  await clickEl(cdp, { tag: 'div', text: 'ACTIVE CELL', exact: false, up: 0 });
  await pickCell(cdp, CELL);
  await sleep(2500);
  await capture(cdp, OUT, 'lot_overview', {
    header: { text: 'Supervisor Access', tag: 'button,div', up: 4, maxChars: 200 },
    cell: { text: CELL, tag: 'div,span', up: 1, maxChars: 40 },
    tabs: { union: ['tabLot', 'tabRec'] },
    tabLot: { text: 'Lot Management', tag: 'div,span' },
    tabRec: { text: 'Reconcile Shift', tag: 'div,span' },
    die: { union: ['dieLabel', 'dieMount'] },
    dieLabel: { text: 'DIE', tag: 'div,span' },
    dieMount: { text: 'Die Mount', tag: 'button,div' },
    rows: { union: ['firstRow', 'lastVisibleRow'] },
    firstRow: { text: '12232-6MA -0000', tag: 'div,span', up: 4, maxChars: 40 },
    lastVisibleRow: row('In 4 Da'),
    footer: { union: ['openAll', 'clear'] },
    openAll: { text: 'OPEN ALL EMPTY CAVITIES', tag: 'button,div' },
    clear: { text: 'Clear', tag: 'button,div' },
    operator: { text: 'Operator: ST', tag: 'div,span', exact: false },
  });
  // Open one basket through the screen: scan box on the first empty row.
  await capture(cdp, OUT, 'open_basket_before', {
    row: row('In 2-Da'),
    scan: { placeholder: 'Scan LTT', nth: 0 },
  });
  await clickEl(cdp, { placeholder: 'Scan LTT', nth: 0 });
  await typeText(cdp, '70000101');
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await sleep(3000);
  await capture(cdp, OUT, 'open_basket_after', {
    row: row('In 2-Da'),
    basket: { text: '70000101', tag: 'div,span', exact: false },
  });
  // Changeover: fill two scan boxes, then OPEN ALL EMPTY CAVITIES.
  await clickEl(cdp, { placeholder: 'Scan LTT', nth: 0 }); await typeText(cdp, '70000102');
  await clickEl(cdp, { placeholder: 'Scan LTT', nth: 1 }); await typeText(cdp, '70000103');
  await sleep(1200);
  await capture(cdp, OUT, 'open_all', {
    scan1: { placeholder: 'Scan LTT', nth: 0 },
    scan2: { placeholder: 'Scan LTT', nth: 1 },
    copyPart: { text: 'Copy part to empty rows', tag: 'button,div' },
    openAll: { text: 'OPEN ALL EMPTY CAVITIES', tag: 'button,div' },
  });
  await clickText(cdp, 'OPEN ALL EMPTY CAVITIES', { settle: 3500 });
  // Release: give the first basket pieces through a reading, then open the dialog.
  await clickEl(cdp, { text: 'Release', tag: 'button', nth: 0 });
  await sleep(2500);
  const rin = { placeholder: '0', tag: 'input', nth: 0 };   // confirm in discovery
  await clickEl(cdp, rin); await typeText(cdp, '420');
  await sleep(1500);
  await capture(cdp, OUT, 'release_dialog', {
    reading: rin,
    boxes: { text: 'basket closes at', tag: 'div,span', exact: false, up: 3, maxChars: 300 },
    releaseBtn: { text: 'Release basket', tag: 'button' },
    fixCounter: { text: 'Counter reset / wrong total?', tag: 'button,div', exact: false },
  });
  await clickText(cdp, 'Release basket', { tag: 'button', settle: 3500 });
  // Void: the basket opened as 70000103 has no pieces.
  await capture(cdp, OUT, 'void_row', {
    row: { text: '70000103', tag: 'div,span', exact: false, up: 6, maxChars: 260 },
    voidBtn: { text: 'Void', tag: 'button', nth: 0 },
  });
  cdp.close();
}

const STATES = { operator };
if (args.includes('--discover')) {
  const cdp = await freshSession();
  await signIn(cdp, db.PIN); await pickCell(cdp, CELL);
  console.table(await dumpControls(cdp));
  process.exit(0);
}
if (want('operator')) await operator();
process.exit(0);
```

- [ ] **Step 3: Run it**

Run: `node tools/training-deck/capture_diecast.mjs --only operator`
Expected: nine `captured <id> (N targets)` lines, no `measure: ... not found`. Any "not found": run `--discover`, correct the spec's text/placeholder to what the screen prints, re-run.

- [ ] **Step 4: Eyeball every PNG** (Read tool) — correct state shown (PIN pad, unknown dialog, rows, filled scan boxes, release dialog with 420 typed, Void visible). Re-capture if a toast covers a target.

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/capture_diecast.mjs docs/training/diecast/shots
git commit -m "feat(training-deck): capture operator Lot Management screens"
```

---

### Task 6: Capture Reconcile Shift, Fix counter, Downtime, hand-over (slides 11–18)

**Files:**
- Modify: `tools/training-deck/capture_diecast.mjs` — add `reconcile()` and register in `STATES`, `want('reconcile')`.
- Output shots: `rec_overview`, `rec_compute`, `rec_diewide`, `rec_scrap`, `rec_variance`, `rec_submit`, `fix_counter`, `downtime`, `handover`.

**Interfaces:**
- Consumes: Task 4/5 functions.
- Produces: the shot ids above; target names are listed in each `capture()` call.

- [ ] **Step 1: Discovery.** Sign in, pick the cell, open **Reconcile Shift**, pick the shift, type `600`, press **Compute**; `dumpControls` at each state: after Compute, after tapping a cavity's scrap number, after tapping an amber variance, after **Fix counter**, after **Downtime**, after tapping the operator chip. Record the exact labels.

- [ ] **Step 2: Add `reconcile()`** (labels below are the live ones seen on 2026-09-18; confirm in Step 1)

```js
async function reconcile() {
  db.clearDie();
  ['In 2-Da', 'In 2-Db', 'In 3 Da', 'In 3 Db'].forEach((d, i) => db.openBasket({ desc: d, ltt: `7000020${i}` }));
  const cdp = await freshSession();
  await signIn(cdp, db.PIN); await pickCell(cdp, CELL);
  await tab(cdp, 'Reconcile Shift', 'THIS ENTRY');
  await capture(cdp, OUT, 'rec_overview', {
    entry: { text: 'THIS ENTRY', tag: 'div,span', up: 2, maxChars: 400 },
    diewide: { text: 'Warm-up shots', tag: 'div,span', up: 4, maxChars: 400 },
    percavity: { text: 'PER CAVITY', tag: 'div,span', up: 1, maxChars: 120 },
    totals: { text: 'UNACCOUNTED', tag: 'div,span', up: 3, maxChars: 200 },
    submit: { text: 'SUBMIT SHIFT ENTRY', tag: 'button,div' },
  });
  await clickEl(cdp, { text: 'Select a shift', tag: 'div,span' });
  await sleep(900);
  await clickEl(cdp, { text: 'Second Shift', tag: 'div,span', exact: false, nth: 1 });
  await clickEl(cdp, { placeholder: '', tag: 'input', nth: 0 });   // counter box; confirm in discovery
  await typeText(cdp, '600');
  await capture(cdp, OUT, 'rec_compute', {
    shift: { text: 'REPORTING SHIFT', tag: 'div,span', up: 1, maxChars: 80 },
    counter: { text: 'PRESS COUNTER', tag: 'div,span', exact: false, up: 1, maxChars: 80 },
    compute: { text: 'Compute', tag: 'button,div' },
  });
  await clickText(cdp, 'Compute', { settle: 3500 });
  await clickEl(cdp, { text: 'Warm-up shots', tag: 'div,span', up: 3, maxChars: 200 });
  await typeText(cdp, '5');
  await capture(cdp, OUT, 'rec_diewide', {
    warmup: { text: 'Warm-up shots', tag: 'div,span', up: 2, maxChars: 120 },
    qtest: { text: 'Quality test shots', tag: 'div,span', up: 2, maxChars: 120 },
    addDw: { text: 'Add die-wide scrap', tag: 'button,div', exact: false },
  });
  // Cavity scrap: tap the scrap number on the first cavity row, pick a defect, qty 3.
  await clickEl(cdp, { text: 'In 2-Da', tag: 'div,span', up: 6, maxChars: 300 });
  await capture(cdp, OUT, 'rec_scrap', {
    good: { text: 'In 2-Da', tag: 'div,span', up: 6, maxChars: 300 },
  });
  await capture(cdp, OUT, 'rec_variance', {
    variance: { text: 'UNACCOUNTED', tag: 'div,span', up: 2, maxChars: 120 },
  });
  await capture(cdp, OUT, 'rec_submit', {
    submit: { text: 'SUBMIT SHIFT ENTRY', tag: 'button,div' },
  });
  await clickText(cdp, 'Fix counter', { settle: 2500 });
  await capture(cdp, OUT, 'fix_counter', {});
  await clickText(cdp, 'Cancel', { settle: 1500 });
  await clickText(cdp, 'Downtime', { tag: 'button,div', settle: 3000 });
  await capture(cdp, OUT, 'downtime', {});
  cdp.close();
  const cdp2 = await freshSession();
  await signIn(cdp2, db.PIN);
  await clickEl(cdp2, { text: 'Operator: ST', tag: 'div,span', exact: false });
  await sleep(2000);
  await capture(cdp2, OUT, 'handover', {
    display: { text: 'Enter your PIN', tag: 'div,span', up: 3, maxChars: 80 },
  });
  cdp2.close();
}
```

After Step 1, **fill in** the empty `{}` target maps of `rec_scrap`, `rec_variance`, `fix_counter`, `downtime`, `handover` with the controls each slide numbers (the Task 8 content names them: `scrapNum`, `defect`, `qty`, `addScrap`; `amber`, `reason`, `note`; `fcReading`, `fcReason`, `fcConfirm`; `dtReason`, `dtSave`; `display`). A target a slide uses that is missing fails the Task 9 build, so the build enforces this.

- [ ] **Step 3: Run**, `node tools/training-deck/capture_diecast.mjs --only reconcile` — expected nine `captured` lines, no `not found`.

- [ ] **Step 4: Eyeball each PNG**; re-run a capture whose state is wrong.

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/capture_diecast.mjs docs/training/diecast/shots
git commit -m "feat(training-deck): capture Reconcile Shift, Fix counter, Downtime, hand-over"
```

---

### Task 7: Capture team lead screens (slides 21–24)

**Files:**
- Modify: `tools/training-deck/capture_diecast.mjs` — add `teamlead()` and `dashboard()`.
- Output shots: `sup_access`, `sup_elevated`, `die_mount`, `reset_terminal`, `dash_overview`.

**Interfaces:**
- Consumes: Task 4/5 functions.
- Produces: shot ids above.

`teamlead()` needs a **visible** Chrome on port 9334 (a separate window, so the headless one is untouched):
```powershell
Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList "--remote-debugging-port=9334","--user-data-dir=$env:TEMP\training-capture-visible","--window-size=1600,1100","about:blank"
```
Run with `CDP_PORT=9334`. The harness `connect()` refuses a non-headless Chrome, so `teamlead()` passes `{ allowVisible: true }` — add that option to `tools/perspective-capture/cdp.mjs` `connect(url, { allowVisible = false } = {})`, skipping the HeadlessChrome check only when set.

- [ ] **Step 1: Add the `allowVisible` option to `connect()`** in `tools/perspective-capture/cdp.mjs`:

```js
export async function connect(url, { allowVisible = false } = {}) {
  const ver = await httpJson('/json/version');
  if (!allowVisible && !/HeadlessChrome/.test(ver['User-Agent'] || '')) {
    throw new Error(`port ${PORT} is not a headless Chrome (${ver['User-Agent']}). Start the capture Chrome with --headless=new on this port.`);
  }
  // ... unchanged below
```

- [ ] **Step 2: Add `teamlead()` + `dashboard()`**

```js
async function waitForHuman(cdp, needle, minutes = 5) {
  console.log(`\n>>> In the visible Chrome window: sign in at the Supervisor Access popup yourself.`);
  console.log(`>>> Waiting up to ${minutes} min for "${needle}" to appear...\n`);
  const t0 = Date.now();
  while (Date.now() - t0 < minutes * 60000) {
    if ((await text(cdp)).includes(needle)) return;
    await sleep(1000);
  }
  throw new Error('timed out waiting for the supervisor sign-in');
}

async function teamlead() {
  const { connect: c2 } = await import('../perspective-capture/cdp.mjs');
  const cdp = await c2(URL, { allowVisible: true });
  await setViewport(cdp, 1600, 1000);
  await cdp.send('Page.navigate', { url: URL });
  await sleep(9000);
  await signIn(cdp, db.PIN); await pickCell(cdp, CELL);
  await clickText(cdp, 'Supervisor Access', { tag: 'button,div', settle: 2500 });
  await capture(cdp, OUT, 'sup_access', {});      // targets filled after discovery
  await waitForHuman(cdp, 'Operator: ');          // confirm the elevated marker in discovery
  await capture(cdp, OUT, 'sup_elevated', {});
  await clickText(cdp, 'Die Mount', { tag: 'button,div', settle: 2500 });
  await capture(cdp, OUT, 'die_mount', {});
  await clickText(cdp, 'Cancel', { settle: 1500 });
  await clickText(cdp, 'Reset Terminal', { tag: 'button,div', settle: 2500 });
  await capture(cdp, OUT, 'reset_terminal', {});
  await clickText(cdp, 'Cancel', { settle: 1500 });
  cdp.close();
}

async function dashboard() {
  // Give the dashboard something to show: release two baskets and submit a shift entry first
  // (reconcile() leaves four open baskets on DMO125).
  db.releaseBasket({ desc: 'In 2-Da', reading: 300 });
  db.releaseBasket({ desc: 'In 2-Db', reading: 300 });
  const cdp = await connect('http://localhost:8088/data/perspective/client/MPP/shop-floor/die-cast/supervisor');
  await setViewport(cdp, 1600, 1000);
  await sleep(9000);
  await capture(cdp, OUT, 'dash_overview', {
    area: { text: 'AREA', tag: 'div,span', up: 1, maxChars: 60 },
    refresh: { text: 'Refresh', tag: 'button,div' },
    tiles: { union: ['tCur', 'tChange'] },
    tCur: { text: 'CURRENT SHIFT', tag: 'div,span', exact: false, up: 2, maxChars: 120 },
    tChange: { text: 'CHANGE', tag: 'div,span', up: 2, maxChars: 80 },
    current: { text: 'Current shift', tag: 'div,span', exact: false, up: 2, maxChars: 2000 },
    previous: { text: 'Previous shift', tag: 'div,span', exact: false, up: 2, maxChars: 2000 },
  });
  cdp.close();
}
```

Register both in `STATES` and the `want()` dispatch. Discovery (Step 3) fills the `{}` maps: `sup_access` → `account`, `password`, `signin`; `sup_elevated` → `who`; `die_mount` → controls the Die Mount popup shows; `reset_terminal` → `confirm`, `cancel`.

- [ ] **Step 3: Discovery with Jacques present**, then run `CDP_PORT=9334 node tools/training-deck/capture_diecast.mjs --only teamlead`. **Jacques types the AD account and password** when the prompt says so. Then `node tools/training-deck/capture_diecast.mjs --only dashboard`.
Expected: `captured` lines for all five shots.

- [ ] **Step 4: Eyeball each PNG.** The dashboard must show non-zero current-shift numbers; if it shows 0, submit a Reconcile Shift entry (Task 6 flow) and re-capture — the dashboard counts registered production.

- [ ] **Step 5: Commit**

```bash
git add tools/perspective-capture/cdp.mjs tools/training-deck/capture_diecast.mjs docs/training/diecast/shots
git commit -m "feat(training-deck): capture team lead screens and the production dashboard"
```

---

### Task 8: Slide content

**Files:**
- Create: `tools/training-deck/diecast_content.js`
- Test: `tools/training-deck/test/content.test.js`

**Interfaces:**
- Consumes: slide shape from Task 3; shot ids + target names from Tasks 5–7.
- Produces: `module.exports = { meta:{title, subtitle, date}, slides:[...] }` — 25 slides in outline order.

- [ ] **Step 1: Write the failing test**

```js
// tools/training-deck/test/content.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { checkSlide } = require('../lib/checks');
const content = require('../diecast_content');
const SHOTS = path.resolve(__dirname, '../../../docs/training/diecast/shots');

test('25 slides in two parts', () => {
  assert.strictEqual(content.slides.length, 25);
  assert.strictEqual(content.slides[19].kind, 'divider');
});

test('every slide passes the checks against its shot', () => {
  for (const s of content.slides) {
    const shot = s.shot ? JSON.parse(fs.readFileSync(path.join(SHOTS, `${s.shot}.json`), 'utf8')) : null;
    assert.deepStrictEqual(checkSlide(s, shot), [], `slide ${s.id}`);
  }
});

test('every slide has speaker notes', () => {
  content.slides.forEach((s) => assert.ok(s.notes && s.notes.length > 20, `slide ${s.id}`));
});
```

- [ ] **Step 2: Run to verify it fails** — `node --test tools/training-deck/test/content.test.js` → FAIL (`Cannot find module '../diecast_content'`).

- [ ] **Step 3: Write `diecast_content.js`.** One entry per outline row (spec §5). The Lot Management overview and the "Open a basket" slide, written in full, set the pattern every other entry follows:

```js
// tools/training-deck/diecast_content.js
// Every word on the slides. Grade 7-8: short sentences, one idea each. Screen
// labels are written **like this**, exactly as the screen prints them.
const AMBER = 'FFB400';
const ZONE = { blue: '2E86DE', orange: 'E67E22', purple: '8E44AD', teal: '16A085', red: 'C0392B', gold: 'B7950B' };

module.exports = {
  meta: { title: 'Die Cast Terminal Training', subtitle: 'Operators and team leads', date: 'September 2026' },
  slides: [
    { id: 'title', kind: 'title', notes: 'Welcome. Today we learn the die cast screen. It tracks every basket from the press to Honda.' },
    { id: 'why', kind: 'concept', title: 'Why we record baskets',
      bullets: ['Each basket gets a ticket.', 'The ticket follows the parts all the way to Honda.', 'If Honda finds a bad part, we can find its basket fast.'],
      notes: 'Honda asks where every part came from. The ticket on the basket is how we answer. A missed scan breaks the chain.' },
    { id: 'words', kind: 'glossary', title: 'Words you will see',
      terms: [
        { term: 'Die', meaning: 'The mold on the press.' },
        { term: 'Cavity', meaning: 'One spot in the die that makes one part.' },
        { term: 'Basket', meaning: 'The bin the parts drop into.' },
        { term: 'LTT ticket', meaning: 'The barcode tag on the basket.' },
        { term: 'Press counter', meaning: 'The shot number on the press.' },
        { term: 'Shift', meaning: 'Your work period, like Second Shift.' },
        { term: 'Scrap', meaning: 'Bad parts that cannot be used.' },
      ],
      notes: 'Go through each word. Point to a real die and basket if you can.' },
    { id: 'lot-overview', kind: 'overview', kicker: 'Screen tour', title: 'The Lot Management screen', shot: 'lot_overview',
      zones: [
        { letter: 'A', target: 'header', color: ZONE.blue, label: 'Top bar: who is signed in, the shift, Downtime' },
        { letter: 'B', target: 'cell', color: ZONE.orange, label: 'Your machine' },
        { letter: 'C', target: 'tabs', color: ZONE.purple, label: 'The two tabs' },
        { letter: 'D', target: 'die', color: ZONE.teal, label: 'The die on this machine' },
        { letter: 'E', target: 'rows', color: ZONE.red, label: 'One row for each cavity' },
        { letter: 'F', target: 'footer', color: ZONE.gold, label: 'Open many baskets at once' },
      ],
      notes: 'This is the screen you use most. Each row is one cavity. The rows are grouped by part.' },
    // ... slides 5-6 (pin, cell) in the same steps shape ...
    { id: 'open-basket', kind: 'steps', kicker: 'Baskets', title: 'Open a basket', shot: 'open_basket_before',
      steps: ['Find the empty cavity. It says **no basket**.', 'Tap **Scan LTT**. Scan the ticket on the basket.'],
      markers: [{ n: 1, target: 'row' }, { n: 2, target: 'scan' }],
      tip: 'Wrong part in the box? Stop and call your team lead.',
      notes: 'After the scan, the row shows the basket number. If nothing happens, scan again. Do not type a made-up number.' },
    // ... remaining slides 8-25 ...
  ],
};
```

Write the remaining 20 entries in that shape, in outline order, using the shot ids and target names from Tasks 5–7. Wording rules: ≤ 12 words per step, verbs first ("Tap", "Type", "Check"), controls in `**bold**`, one tip at most. Specific content each must carry:
- **Release (9):** type the counter number from the press; if you swapped the basket earlier, use the number you wrote down then; check the three boxes; tap **Release basket**. Red button = no reading or short basket (notes).
- **Reconcile (12–15):** shift picker lists the last 3 shifts; warm-up shots and quality test shots are entered in **shots**, not pieces; tap a cavity's scrap number to add a reason and quantity; an amber number needs a reason, **Unknown** is always allowed and needs a short note; **Submit shift entry** stays grey until every amber number has a reason.
- **Notes on 15:** a submitted entry cannot be changed at the terminal — call the team lead (spec §9).
- **Fix counter (16):** use it when the counter was reset or a wrong number went in; type what the counter reads now; pick why; pieces already on baskets do not change.
- **Supervisor Access (21):** your own account, for protected actions; everything done until it times out is credited to you (`beginElevatedWindow`, 300 s).
- **Quick reference (19)** and **checklist (25):** `kind:'summary'`, `columns:[{heading, items:[...]}]`.

- [ ] **Step 4: Run** `node --test tools/training-deck/test/` — expected PASS. A grade failure means rewrite the sentence shorter, not relax the limit.

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/diecast_content.js tools/training-deck/test/content.test.js
git commit -m "feat(training-deck): die cast slide content, grade-checked"
```

---

### Task 9: Deck generator

**Files:**
- Create: `tools/training-deck/build_diecast_deck.js`
- Modify: `package.json` (devDependency `pptxgenjs`, script `build:training`)

**Interfaces:**
- Consumes: `diecast_content.js` (Task 8), `checkSlide` (Task 3), `placeImage`/`toSlide` (Task 2), shots (Tasks 5–7).
- Produces: `docs/training/diecast/MPP_DieCast_Training.pptx`; exit code 1 and a problem list if any check fails (nothing written).

- [ ] **Step 1: Install pptxgenjs**

Run: `npm install --save-dev pptxgenjs`
Expected: `package.json` devDependencies gains `"pptxgenjs"`.

- [ ] **Step 2: Write the generator**

```js
// tools/training-deck/build_diecast_deck.js
// node tools/training-deck/build_diecast_deck.js
const fs = require('node:fs');
const path = require('node:path');
const pptxgen = require('pptxgenjs');
const content = require('./diecast_content');
const { checkSlide } = require('./lib/checks');
const { placeImage, toSlide } = require('./lib/geometry');

const ROOT = path.resolve(__dirname, '../..');
const SHOTS = path.join(ROOT, 'docs/training/diecast/shots');
const OUT = path.join(ROOT, 'docs/training/diecast/MPP_DieCast_Training.pptx');
const NAVY = '12263F', AMBER = 'FFB400', INK = '1B1B1B', MUTED = '5A6472', TINT = 'EEF2F7', FONT = 'Calibri';
const IMG_BOX = { x: 0.45, y: 1.25, w: 8.5, h: 5.8 };
const PANEL = { x: 9.25, y: 1.25, w: 3.65 };

const loadShot = (id) => JSON.parse(fs.readFileSync(path.join(SHOTS, `${id}.json`), 'utf8'));

// "Tap **Scan LTT** now" -> pptxgenjs runs with bold labels.
function runs(text, size, color = INK) {
  return text.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((part) => {
    const bold = part.startsWith('**');
    return { text: bold ? part.slice(2, -2) : part, options: { bold, color: bold ? NAVY : color, fontSize: size, fontFace: FONT } };
  });
}

function header(slide, s) {
  if (s.kicker) slide.addText(s.kicker.toUpperCase(), { x: 0.45, y: 0.3, w: 8, h: 0.3, fontFace: FONT, fontSize: 12, bold: true, color: 'B36B00', charSpacing: 2, margin: 0, isTextBox: true });
  slide.addText(s.title, { x: 0.45, y: 0.55, w: 12.4, h: 0.6, fontFace: FONT, fontSize: 32, bold: true, color: NAVY, margin: 0, isTextBox: true });
}

function screenshot(slide, shot) {
  const placed = placeImage(shot.width, shot.height, IMG_BOX);
  slide.addImage({ path: path.join(SHOTS, shot.image), ...placed, altText: 'Screenshot of the die cast terminal' });
  return placed;
}

function disc(slide, n, x, y, d = 0.28) {
  slide.addShape('ellipse', { x, y, w: d, h: d, fill: { color: AMBER }, line: { color: '111111', width: 0.75 } });
  slide.addText(String(n), { x, y, w: d, h: d, fontFace: 'Arial', fontSize: 12, bold: true, color: '111111', align: 'center', valign: 'middle', margin: 0, isTextBox: true });
}

function outline(slide, r, color) {
  slide.addShape('rect', { x: r.x - 0.01, y: r.y - 0.01, w: r.w + 0.02, h: r.h + 0.02, fill: { type: 'none' }, line: { color: '000000', width: 2.5, transparency: 45 } });
  slide.addShape('rect', { ...r, fill: { type: 'none' }, line: { color, width: 1.5 } });
}

function stepsSlide(pres, s) {
  const slide = pres.addSlide(); header(slide, s);
  const shot = loadShot(s.shot); const placed = screenshot(slide, shot);
  s.markers.forEach((m) => {
    const r = toSlide(shot.targets[m.target], placed, shot.width, shot.height, 4);
    outline(slide, r, AMBER);
    disc(slide, m.n, Math.max(placed.x, r.x - 0.16), Math.max(placed.y, r.y - 0.16));
  });
  let y = PANEL.y;
  s.steps.forEach((t, i) => {
    disc(slide, i + 1, PANEL.x, y + 0.04, 0.34);
    slide.addText(runs(t, 17), { x: PANEL.x + 0.48, y, w: PANEL.w - 0.48, h: 0.9, valign: 'top', margin: 0, isTextBox: true });
    y += 1.0;
  });
  if (s.tip) slide.addText(runs(s.tip, 13, MUTED), { x: PANEL.x, y: y + 0.1, w: PANEL.w, h: 0.9, fill: { color: TINT }, margin: 8, valign: 'top', isTextBox: true });
  slide.addNotes(s.notes);
}

function overviewSlide(pres, s) {
  const slide = pres.addSlide(); header(slide, s);
  const shot = loadShot(s.shot); const placed = screenshot(slide, shot);
  s.zones.forEach((z) => {
    const r = toSlide(shot.targets[z.target], placed, shot.width, shot.height, 3);
    outline(slide, r, z.color);
    slide.addShape('roundRect', { x: r.x, y: Math.max(placed.y, r.y - 0.27), w: 0.26, h: 0.26, rectRadius: 0.04, fill: { color: z.color }, line: { color: z.color } });
    slide.addText(z.letter, { x: r.x, y: Math.max(placed.y, r.y - 0.27), w: 0.26, h: 0.26, fontFace: 'Arial', fontSize: 11, bold: true, color: 'FFFFFF', align: 'center', valign: 'middle', margin: 0, isTextBox: true });
  });
  let y = PANEL.y;
  s.zones.forEach((z) => {
    slide.addShape('roundRect', { x: PANEL.x, y, w: 0.34, h: 0.34, rectRadius: 0.05, fill: { color: z.color }, line: { color: z.color } });
    slide.addText(z.letter, { x: PANEL.x, y, w: 0.34, h: 0.34, fontFace: 'Arial', fontSize: 14, bold: true, color: 'FFFFFF', align: 'center', valign: 'middle', margin: 0, isTextBox: true });
    slide.addText(runs(z.label, 15), { x: PANEL.x + 0.5, y: y - 0.03, w: PANEL.w - 0.5, h: 0.6, valign: 'top', margin: 0, isTextBox: true });
    y += 0.72;
  });
  slide.addNotes(s.notes);
}

function darkSlide(pres, title, sub, notes) {
  const slide = pres.addSlide(); slide.background = { color: NAVY };
  slide.addText(title, { x: 0.8, y: 2.6, w: 11.7, h: 1.2, fontFace: FONT, fontSize: 44, bold: true, color: 'FFFFFF', margin: 0, isTextBox: true });
  if (sub) slide.addText(sub, { x: 0.8, y: 3.8, w: 11.7, h: 0.6, fontFace: FONT, fontSize: 22, color: AMBER, margin: 0, isTextBox: true });
  slide.addNotes(notes);
}

function conceptSlide(pres, s) {
  const slide = pres.addSlide(); header(slide, s);
  s.bullets.forEach((b, i) => {
    const y = 1.6 + i * 1.6;
    disc(slide, i + 1, 0.8, y + 0.05, 0.6);
    slide.addText(runs(b, 24), { x: 1.7, y, w: 10.5, h: 1.0, valign: 'middle', margin: 0, isTextBox: true });
  });
  slide.addNotes(s.notes);
}

function glossarySlide(pres, s) {
  const slide = pres.addSlide(); header(slide, s);
  s.terms.forEach((t, i) => {
    const col = i < 4 ? 0 : 1, row = i % 4, x = 0.45 + col * 6.3, y = 1.4 + row * 1.35;
    slide.addShape('roundRect', { x, y, w: 6.0, h: 1.15, rectRadius: 0.08, fill: { color: TINT }, line: { color: TINT } });
    slide.addText(t.term, { x: x + 0.25, y: y + 0.12, w: 5.5, h: 0.4, fontFace: FONT, fontSize: 20, bold: true, color: NAVY, margin: 0, isTextBox: true });
    slide.addText(t.meaning, { x: x + 0.25, y: y + 0.55, w: 5.5, h: 0.5, fontFace: FONT, fontSize: 16, color: INK, margin: 0, isTextBox: true });
  });
  slide.addNotes(s.notes);
}

function summarySlide(pres, s) {
  const slide = pres.addSlide(); header(slide, s);
  const n = s.columns.length, w = (12.4 - (n - 1) * 0.3) / n;
  s.columns.forEach((c, i) => {
    const x = 0.45 + i * (w + 0.3);
    slide.addShape('roundRect', { x, y: 1.35, w, h: 5.7, rectRadius: 0.08, fill: { color: TINT }, line: { color: TINT } });
    slide.addText(c.heading, { x: x + 0.25, y: 1.5, w: w - 0.5, h: 0.5, fontFace: FONT, fontSize: 20, bold: true, color: NAVY, margin: 0, isTextBox: true });
    // One paragraph per item: bullet on the item's first run, breakLine on its last.
    const items = c.items.flatMap((it, j) => {
      const rs = runs(it, 15);
      rs[0].options.bullet = true;
      if (j < c.items.length - 1) rs[rs.length - 1].options.breakLine = true;
      return rs;
    });
    slide.addText(items, { x: x + 0.25, y: 2.1, w: w - 0.5, h: 4.8, valign: 'top', paraSpaceAfter: 8, margin: 0, isTextBox: true });
  });
  slide.addNotes(s.notes);
}

function main() {
  const problems = [];
  content.slides.forEach((s) => {
    const shot = s.shot ? loadShot(s.shot) : null;
    checkSlide(s, shot).forEach((p) => problems.push(`${s.id}: ${p}`));
  });
  if (problems.length) { console.error(problems.join('\n')); process.exit(1); }

  const pres = new pptxgen();
  pres.layout = 'LAYOUT_WIDE';
  pres.title = content.meta.title;
  pres.author = 'Blue Ridge Automation';
  content.slides.forEach((s) => {
    switch (s.kind) {
      case 'title': return darkSlide(pres, content.meta.title, `${content.meta.subtitle} - ${content.meta.date}`, s.notes);
      case 'divider': return darkSlide(pres, s.title, s.subtitle, s.notes);
      case 'concept': return conceptSlide(pres, s);
      case 'glossary': return glossarySlide(pres, s);
      case 'overview': return overviewSlide(pres, s);
      case 'steps': return stepsSlide(pres, s);
      case 'summary': return summarySlide(pres, s);
      default: throw new Error(`unknown kind ${s.kind}`);
    }
  });
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  return pres.writeFile({ fileName: OUT }).then(() => console.log(`wrote ${OUT}`));
}

main();
```

Add to `package.json` scripts: `"build:training": "node tools/training-deck/build_diecast_deck.js"`, `"test:training": "node --test tools/training-deck/test/"`.

- [ ] **Step 3: Build and validate**

Run: `npm run test:training && npm run build:training && python "<pptx skill dir>/scripts/office/validate.py" docs/training/diecast/MPP_DieCast_Training.pptx`
Expected: tests PASS, `wrote ...MPP_DieCast_Training.pptx`, validator reports no failures.

- [ ] **Step 4: Commit**

```bash
git add tools/training-deck/build_diecast_deck.js package.json package-lock.json docs/training/diecast/MPP_DieCast_Training.pptx
git commit -m "feat(training-deck): pptxgenjs generator for the die cast deck"
```

---

### Task 10: Visual QA and fixes

**Files:**
- Create: `tools/training-deck/render_slides.ps1`
- Modify: whichever of `diecast_content.js` / `build_diecast_deck.js` / `capture_diecast.mjs` the QA finds fault in.

- [ ] **Step 1: Write the renderer**

```powershell
# tools/training-deck/render_slides.ps1 -- export every slide to PNG via PowerPoint.
param([string]$Deck = "docs\training\diecast\MPP_DieCast_Training.pptx",
      [string]$OutDir = "$env:TEMP\training-deck-render")
$ErrorActionPreference = "Stop"
$deckPath = (Resolve-Path $Deck).Path
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$pp = New-Object -ComObject PowerPoint.Application
try {
    $pres = $pp.Presentations.Open($deckPath, $true, $false, $false)   # read-only, no window
    foreach ($s in $pres.Slides) { $s.Export((Join-Path $OutDir ("slide-{0:D2}.png" -f $s.SlideIndex)), "PNG", 1920, 1080) }
    $pres.Close()
} finally { $pp.Quit(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($pp) }
Get-ChildItem $OutDir | Select-Object -ExpandProperty FullName
```

- [ ] **Step 2: Render and inspect every slide** (Read each PNG): overflow, text cut off, markers off target, overlapping discs, low contrast, uneven gaps, anything under 0.4" from an edge. List the defects.

- [ ] **Step 3: Fix** in the generator/content/capture (never by hand in the .pptx), rebuild, re-render only changed slides, re-inspect.

- [ ] **Step 4: Fresh-eyes text pass** — dump slide text with python-pptx and read it as an operator:

```bash
python -c "from pptx import Presentation; p=Presentation('docs/training/diecast/MPP_DieCast_Training.pptx'); [print(i+1, ' | '.join(sh.text_frame.text.replace(chr(10),' / ') for sh in s.shapes if sh.has_text_frame and sh.text_frame.text.strip())) for i,s in enumerate(p.slides)]"
```

- [ ] **Step 5: Commit**

```bash
git add tools/training-deck/render_slides.ps1 tools/training-deck docs/training/diecast
git commit -m "fix(training-deck): visual QA pass"
```

---

### Task 11: Hand-off

**Files:**
- Create: `tools/training-deck/README.md` (how to re-capture, rebuild, render; the pause-for-sign-in step; Chrome ports 9333/9334)
- Modify: `PROJECT_STATUS.md` (append a dated entry: deck location, how to rebuild, the out-of-scope shift repair view as an open item)

- [ ] **Step 1: Write both** (README: commands from Tasks 5–10 in order, prerequisites, "the screen wins over the spec labels").
- [ ] **Step 2: Run the full chain once more** — `npm run test:training && npm run build:training` → PASS + `wrote`.
- [ ] **Step 3: Commit**

```bash
git add tools/training-deck/README.md PROJECT_STATUS.md
git commit -m "docs(training-deck): how to rebuild the die cast training deck"
```
