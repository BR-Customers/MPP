// checks.test.js
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
