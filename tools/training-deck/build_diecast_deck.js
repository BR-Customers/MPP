// tools/training-deck/build_diecast_deck.js
// node tools/training-deck/build_diecast_deck.js
const fs = require('node:fs');
const path = require('node:path');
const pptxgen = require('pptxgenjs');
const content = require('./diecast_content');
const { checkSlide } = require('./lib/checks');
const { placeImage, toSlide } = require('./lib/geometry');
const { cropFor, shiftRect, writeCrop } = require('./lib/crop');

const ROOT = path.resolve(__dirname, '../..');
const SHOTS = path.join(ROOT, 'docs/training/diecast/shots');
// TRAINING_OUT: write elsewhere, e.g. while the deck is open in PowerPoint (it locks the file).
const OUT = process.env.TRAINING_OUT || path.join(ROOT, 'docs/training/diecast/MPP_DieCast_Training.pptx');
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

// A step slide shows only the part of the screen around its markers, so the
// controls being taught are big enough to read on a projector or a printout.
function croppedShot(s, full) {
  const names = [...s.markers.map((m) => m.target), ...(s.arrows || []).map((a) => a.target)];
  const crop = cropFor(names.map((n) => full.targets[n]), full.width, full.height, IMG_BOX.w / IMG_BOX.h);
  const file = writeCrop(path.join(SHOTS, full.image), crop, s.id);
  const targets = {};
  for (const n of names) targets[n] = shiftRect(full.targets[n], crop);
  return { file, width: crop.w, height: crop.h, targets };
}

function stepsSlide(pres, s) {
  const slide = pres.addSlide(); header(slide, s);
  const shot = croppedShot(s, loadShot(s.shot));
  const placed = placeImage(shot.width, shot.height, IMG_BOX);
  slide.addImage({ path: shot.file, ...placed, altText: 'Screenshot of the die cast terminal' });
  s.markers.forEach((m) => {
    const r = toSlide(shot.targets[m.target], placed, shot.width, shot.height, 4);
    outline(slide, r, AMBER);
    disc(slide, m.n, Math.max(placed.x, r.x - 0.16), Math.max(placed.y, r.y - 0.16));
  });
  // Arrows point at text that a box alone would not make obvious. Default
  // comes up from below-left; `from: 'above'` comes down from above-right,
  // for text whose row below is busy. They stop just short of the target.
  (s.arrows || []).forEach((a) => {
    const r = toSlide(shot.targets[a.target], placed, shot.width, shot.height, 2);
    const len = 0.55, h = len * 0.8;
    let geo;
    if (a.from === 'above') {
      // tip at the target's top edge, a third of the way in; line runs up-right
      const tipX = r.x + Math.min(0.35, r.w / 3), tipY = r.y - 0.03;
      geo = { x: tipX, y: tipY - h, w: len, h, flipH: true };
    } else {
      const tipX = r.x + Math.min(0.35, r.w / 3), tipY = r.y + r.h + 0.03;
      geo = { x: tipX - len, y: tipY, w: len, h, flipV: true };
    }
    slide.addShape('line', { ...geo, line: { color: '000000', width: 4.5, transparency: 40 } });
    slide.addShape('line', { ...geo, line: { color: AMBER, width: 2.5, endArrowType: 'triangle' } });
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
  const zoneRects = [];
  s.zones.forEach((z) => {
    const r = toSlide(shot.targets[z.target], placed, shot.width, shot.height, 3);
    outline(slide, r, z.color);
    zoneRects.push(r);
  });
  // Letter tags, placed in the preferred order below, moving to the next
  // position only when a spot is off the usable area, or would sit on another
  // tag or another zone's box. A zone may pin a position with `pos`.
  //   1 above, left-justified     2 middle, left of the box
  //   3 below, left-justified     4 middle, right of the box
  //   5 above, right-justified    6 below, right-justified
  const T = 0.26, G = 0.05;
  const at = (r, n) => ({
    1: { x: r.x, y: r.y - T - G },
    2: { x: r.x - T - G, y: r.y + r.h / 2 - T / 2 },
    3: { x: r.x, y: r.y + r.h + G },
    4: { x: r.x + r.w + G, y: r.y + r.h / 2 - T / 2 },
    5: { x: r.x + r.w - T, y: r.y - T - G },
    6: { x: r.x + r.w - T, y: r.y + r.h + G },
  })[n];
  const hit = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  const placedTags = [];
  s.zones.forEach((z, i) => {
    const r = zoneRects[i];
    const usable = (t) => t.x >= 0.05 && t.y >= 1.2 && t.x + T <= PANEL.x - 0.1 && t.y + T <= 7.45
      && !placedTags.some((o) => hit(t, o))
      && !zoneRects.some((o, j) => j !== i && hit(t, o));
    const order = z.pos ? [z.pos] : [1, 2, 3, 4, 5, 6];
    let spot = null;
    for (const n of order) {
      const c = at(r, n); const t = { x: c.x, y: c.y, w: T, h: T };
      if (z.pos || usable(t)) { spot = t; break; }
    }
    if (!spot) { const c = at(r, 1); spot = { x: c.x, y: c.y, w: T, h: T }; }   // nothing fits: fall back to 1
    placedTags.push(spot);
    slide.addShape('roundRect', { x: spot.x, y: spot.y, w: T, h: T, rectRadius: 0.04, fill: { color: z.color }, line: { color: 'FFFFFF', width: 0.75 } });
    slide.addText(z.letter, { x: spot.x, y: spot.y, w: T, h: T, fontFace: 'Arial', fontSize: 11, bold: true, color: 'FFFFFF', align: 'center', valign: 'middle', margin: 0, isTextBox: true });
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

// Team lead screens not captured yet: what the job is for, plus a clear
// "pictures coming" box so nobody mistakes it for a finished slide.
function placeholderSlide(pres, s) {
  const slide = pres.addSlide(); header(slide, s);
  s.bullets.forEach((b, i) => {
    const y = 1.55 + i * 1.05;
    disc(slide, i + 1, 0.8, y + 0.08, 0.42);
    slide.addText(runs(b, 22), { x: 1.5, y, w: 11.2, h: 0.7, valign: 'middle', margin: 0, isTextBox: true });
  });
  slide.addShape('roundRect', { x: 0.45, y: 5.75, w: 12.4, h: 0.95, rectRadius: 0.08, fill: { color: TINT }, line: { color: 'C9D2DE', width: 1, dashType: 'dash' } });
  slide.addText('Screen pictures and step-by-step for this job come in the next version of this deck.',
    { x: 0.75, y: 5.75, w: 11.8, h: 0.95, fontFace: FONT, fontSize: 16, italic: true, color: MUTED, valign: 'middle', margin: 0, isTextBox: true });
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
      const rs = runs(it, 18);
      rs[0].options.bullet = true;
      if (j < c.items.length - 1) rs[rs.length - 1].options.breakLine = true;
      return rs;
    });
    slide.addText(items, { x: x + 0.25, y: 2.1, w: w - 0.5, h: 4.8, valign: 'top', paraSpaceAfter: 10, margin: 0, isTextBox: true });
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
      case 'placeholder': return placeholderSlide(pres, s);
      default: throw new Error(`unknown kind ${s.kind}`);
    }
  });
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  // Never overwrite hand edits. The deck is built from diecast_content.js, so
  // anything typed into the .pptx in PowerPoint is lost on the next build --
  // which happened once (2026-09-22). The hash of every deck we write is kept
  // beside it; if the deck on disk no longer matches, someone edited it, and
  // the new build goes to a side file instead. --force overwrites anyway.
  const crypto = require('node:crypto');
  const HASH = OUT + '.lastbuild';
  const sha = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
  let target = OUT;
  if (!process.argv.includes('--force') && fs.existsSync(OUT) && fs.existsSync(HASH)
      && sha(OUT) !== fs.readFileSync(HASH, 'utf8').trim()) {
    target = OUT.replace(/\.pptx$/, '.new.pptx');
    console.error(`  ${path.basename(OUT)} has been edited since the last build -- NOT overwriting it.`);
    console.error('  Move the edits into tools/training-deck/diecast_content.js, then rebuild with --force.');
    console.error(`  This build goes to ${path.basename(target)}.`);
  }
  return pres.writeFile({ fileName: target }).then(() => {
    if (target === OUT) fs.writeFileSync(HASH, sha(OUT));
    console.log(`wrote ${target}`);
  });
}

main();
