const RE_FDS_INLINE = /^FDS-(\d{2})-(\d{3})$/;
const RE_FDS_HEADING = /^FDS-(\d{2})-(\d{3})\b/;

module.exports = function oiBadge(md, opts = {}) {
  const map = opts.reqToOpenOis || new Map();
  function badgeHtmlFor(ois) {
    return ois.map((id) => {
      const n = id.replace(/^OI-/, '').toLowerCase();
      return `<a class="oi-badge" href="oir.html#oi-${n}">🔓 ${id}</a>`;
    }).join('');
  }
  const installer = (state) => {
    // Pass 1: h4 headings whose inline content begins with FDS-XX-NNN
    for (let i = 0; i < state.tokens.length; i++) {
      const tok = state.tokens[i];
      if (tok.type !== 'heading_open' || tok.tag !== 'h4') continue;
      const inline = state.tokens[i + 1];
      if (!inline || inline.type !== 'inline') continue;
      const m = RE_FDS_HEADING.exec((inline.content || '').trim());
      if (!m) continue;
      const req = `FDS-${m[1]}-${m[2]}`;
      const ois = map.get(req);
      if (!ois || ois.length === 0) continue;
      const badgeTok = new state.Token('html_inline', '', 0);
      badgeTok.content = ' ' + badgeHtmlFor(ois);
      inline.children = inline.children || [];
      inline.children.push(badgeTok);
    }
    // Pass 2: bold-inline **FDS-XX-NNN** within block content
    for (const blockTok of state.tokens) {
      if (blockTok.type !== 'inline' || !blockTok.children) continue;
      const kids = blockTok.children;
      for (let i = 0; i < kids.length; i++) {
        const t = kids[i];
        if (t.type !== 'strong_open') continue;
        const text = kids[i + 1];
        const close = kids[i + 2];
        if (!text || text.type !== 'text' || !close || close.type !== 'strong_close') continue;
        const m = RE_FDS_INLINE.exec(text.content.trim());
        if (!m) continue;
        const req = `FDS-${m[1]}-${m[2]}`;
        const ois = map.get(req);
        if (!ois || ois.length === 0) continue;
        const badgeTok = new state.Token('html_inline', '', 0);
        badgeTok.content = badgeHtmlFor(ois);
        // Skip past strong_close and any html_inline closing anchor that anchor_fds_req added.
        let insertAt = i + 3;
        while (kids[insertAt] && kids[insertAt].type === 'html_inline' && /^<\/a>/.test(kids[insertAt].content)) {
          insertAt++;
        }
        kids.splice(insertAt, 0, badgeTok);
        i = insertAt;
      }
    }
  };
  // Be composable with both ordered (in full chain) and standalone (in tests) plugin sets.
  try { md.core.ruler.after('anchor_fds_req', 'oi_badge', installer); }
  catch (_) { md.core.ruler.push('oi_badge', installer); }
};
