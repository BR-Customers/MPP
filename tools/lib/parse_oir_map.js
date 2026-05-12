// Matches ## or ### headings starting with OI-XX or UJ-XX
const RE_HEADING = /^#{2,3}\s+(OI-\d{2,}|UJ-\d{2,})\b/;
// Matches inline status in heading: ⬜ Open or ✅ Resolved etc.
const RE_STATUS_INLINE = /[⬜✅🔶]\s*(\w[\w\s-]*?)(?:\s*[\/,\(]|$)/;
// Matches a standalone **Status:** line (format used in tests + some older OI entries)
const RE_STATUS_LINE = /^\*\*Status:\*\*\s*(\w[\w-]*)/i;
const RE_FDS = /\bFDS-(\d{2})-(\d{3})\b/g;

function parseOirMap(markdown) {
  const lines = markdown.split(/\r?\n/);
  const items = [];                  // {id, status, body}
  let cur = null;
  for (const line of lines) {
    const h = RE_HEADING.exec(line);
    if (h) {
      if (cur) items.push(cur);
      // Try to extract status from the heading line itself (real OIR format)
      const inlineStatus = RE_STATUS_INLINE.exec(line.slice(h.index + h[0].length));
      cur = {
        id: h[1],
        status: inlineStatus ? inlineStatus[1].trim() : '',
        body: '',
      };
      continue;
    }
    if (!cur) continue;
    if (!cur.status) {
      const s = RE_STATUS_LINE.exec(line);
      if (s) { cur.status = s[1]; continue; }
    }
    cur.body += line + '\n';
  }
  if (cur) items.push(cur);

  const openIds = new Set();
  const reqToOpenOis = new Map();
  for (const it of items) {
    if (!/^open$/i.test(it.status)) continue;
    openIds.add(it.id);
    let m;
    RE_FDS.lastIndex = 0;
    while ((m = RE_FDS.exec(it.body)) !== null) {
      const req = `FDS-${m[1]}-${m[2]}`;
      if (!reqToOpenOis.has(req)) reqToOpenOis.set(req, []);
      const arr = reqToOpenOis.get(req);
      if (!arr.includes(it.id)) arr.push(it.id);
    }
  }
  return { openIds, reqToOpenOis, items };
}

module.exports = { parseOirMap };
