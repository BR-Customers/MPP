// geometry.test.js
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
