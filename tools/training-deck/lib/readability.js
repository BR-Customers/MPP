// readability.js
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
