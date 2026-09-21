// crop.js
// A full 1600x1000 terminal screenshot shrunk onto a slide makes every label
// unreadable. Step slides therefore show only the area around their markers,
// cropped to the slide's image-box shape so it fills the box.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

/** Crop rect (px) around `rects`, padded, at `aspect` (w/h), inside the image. */
function cropFor(rects, imgW, imgH, aspect, { pad = 90, minW = 900 } = {}) {
  let x0 = Math.min(...rects.map((r) => r.x)) - pad;
  let y0 = Math.min(...rects.map((r) => r.y)) - pad;
  let x1 = Math.max(...rects.map((r) => r.x + r.w)) + pad;
  let y1 = Math.max(...rects.map((r) => r.y + r.h)) + pad;
  const needW = Math.min(Math.max(x1 - x0, minW), imgW);
  const needH = Math.min(y1 - y0, imgH);
  // Grow the short side toward the box aspect, capped at the image. Never
  // shrink below what the targets need: a marked control cut in half is worse
  // than a slightly letterboxed picture.
  let w = needW, h = needH;
  if (w / h > aspect) h = Math.min(w / aspect, imgH); else w = Math.min(h * aspect, imgW);
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  const x = clamp(Math.round(cx - w / 2), 0, imgW - Math.round(w));
  const y = clamp(Math.round(cy - h / 2), 0, imgH - Math.round(h));
  return { x, y, w: Math.round(w), h: Math.round(h) };
}

function shiftRect(r, origin) {
  return { x: r.x - origin.x, y: r.y - origin.y, w: r.w, h: r.h };
}

/** Write the cropped PNG to a temp cache and return its path. */
function writeCrop(srcPng, crop, key) {
  const { PNG } = require('pngjs');
  const src = PNG.sync.read(fs.readFileSync(srcPng));
  const out = new PNG({ width: crop.w, height: crop.h });
  PNG.bitblt(src, out, crop.x, crop.y, crop.w, crop.h, 0, 0);
  const dir = path.join(os.tmpdir(), 'training-deck-crops');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${key}.png`);
  fs.writeFileSync(file, PNG.sync.write(out));
  return file;
}

module.exports = { cropFor, shiftRect, writeCrop };
