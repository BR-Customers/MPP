// readability.test.js
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
