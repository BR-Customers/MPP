// crop.test.js
const test = require('node:test');
const assert = require('node:assert');
const { cropFor, shiftRect } = require('../lib/crop');

const A = 8.5 / 5.8;   // the slide's image box aspect

test('crop covers every target and keeps the box aspect when it fits', () => {
  const c = cropFor([{ x: 400, y: 380, w: 200, h: 40 }, { x: 700, y: 600, w: 100, h: 40 }], 1600, 1000, A);
  assert.ok(c.x <= 400 && c.x + c.w >= 800, JSON.stringify(c));
  assert.ok(c.y <= 380 && c.y + c.h >= 640, JSON.stringify(c));
  assert.ok(Math.abs(c.w / c.h - A) < 0.01, `aspect ${c.w / c.h}`);
});

test('a full-width target is never cut: the aspect gives way instead', () => {
  const c = cropFor([{ x: 1100, y: 380, w: 200, h: 40 }, { x: 30, y: 370, w: 1520, h: 66 }], 1600, 1000, A);
  assert.ok(c.x <= 30 && c.x + c.w >= 1550, JSON.stringify(c));
  assert.ok(c.y <= 370 && c.y + c.h >= 436, JSON.stringify(c));
});

test('a small target still gets a readable amount of context', () => {
  const c = cropFor([{ x: 800, y: 500, w: 50, h: 20 }], 1600, 1000, A, { minW: 900 });
  assert.ok(c.w >= 900, JSON.stringify(c));
});

test('crop never leaves the image', () => {
  for (const t of [{ x: 0, y: 0, w: 40, h: 20 }, { x: 1560, y: 980, w: 40, h: 20 }]) {
    const c = cropFor([t], 1600, 1000, A);
    assert.ok(c.x >= 0 && c.y >= 0 && c.x + c.w <= 1600 && c.y + c.h <= 1000, JSON.stringify(c));
  }
});

test('shiftRect moves a rect into crop coordinates', () => {
  assert.deepStrictEqual(shiftRect({ x: 500, y: 400, w: 10, h: 10 }, { x: 300, y: 250 }), { x: 200, y: 150, w: 10, h: 10 });
});
