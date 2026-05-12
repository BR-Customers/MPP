const RE_FDS = /^FDS-(\d{2})-(\d{3})$/;

module.exports = function oiBadge(md, opts = {}) {
  const map = opts.reqToOpenOis || new Map();
  const installer = (state) => {
    for (const blockTok of state.tokens) {
      if (blockTok.type !== 'inline' || !blockTok.children) continue;
      const kids = blockTok.children;
      for (let i = 0; i < kids.length; i++) {
        const t = kids[i];
        if (t.type !== 'strong_open') continue;
        const text = kids[i + 1];
        const close = kids[i + 2];
        if (!text || text.type !== 'text' || !close || close.type !== 'strong_close') continue;
        const m = RE_FDS.exec(text.content.trim());
        if (!m) continue;
        const req = `FDS-${m[1]}-${m[2]}`;
        const ois = map.get(req);
        if (!ois || ois.length === 0) continue;
        const badgeHtml = ois.map((id) => {
          const n = id.replace(/^OI-/, '').toLowerCase();
          return `<a class="oi-badge" href="oir.html#oi-${n}">🔓 ${id}</a>`;
        }).join('');
        const badgeTok = new state.Token('html_inline', '', 0);
        badgeTok.content = badgeHtml;
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
