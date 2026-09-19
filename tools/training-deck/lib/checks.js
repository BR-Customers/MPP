// checks.js
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
