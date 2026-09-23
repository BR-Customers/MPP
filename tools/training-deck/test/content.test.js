// content.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { checkSlide } = require('../lib/checks');
const content = require('../diecast_content');
const SHOTS = path.resolve(__dirname, '../../../docs/training/diecast/shots');

const KINDS = ['title', 'concept', 'glossary', 'overview', 'steps', 'summary', 'divider', 'placeholder', 'image'];

test('two parts: operator slides, one divider, then team lead slides', () => {
  const kinds = content.slides.map((s) => s.kind);
  assert.strictEqual(kinds.filter((k) => k === 'divider').length, 1);
  const div = kinds.indexOf('divider');
  assert.ok(div > 10 && div < kinds.length - 2, `divider at ${div}`);
  kinds.forEach((k, i) => assert.ok(KINDS.includes(k), `slide ${i} kind ${k}`));
});

test('slide ids are unique', () => {
  const ids = content.slides.map((s) => s.id);
  assert.strictEqual(new Set(ids).size, ids.length);
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

test('content is ASCII only', () => {
  const raw = fs.readFileSync(path.join(__dirname, '../diecast_content.js'), 'utf8');
  const bad = [...raw].filter((c) => c.charCodeAt(0) > 126);
  assert.deepStrictEqual(bad, []);
});
