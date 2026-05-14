// Only matches the pattern **FDS-XX-NNN** (bold marker). Plain-text FDS-XX-NNN
// is handled by cross_doc_link (linking, not anchoring).
const RE = /^FDS-(\d{2})-(\d{3})$/;

module.exports = function anchorFdsReq(md) {
  md.core.ruler.after('inline', 'anchor_fds_req', (state) => {
    for (const blockTok of state.tokens) {
      if (blockTok.type !== 'inline' || !blockTok.children) continue;
      const kids = blockTok.children;
      for (let i = 0; i < kids.length; i++) {
        const t = kids[i];
        if (t.type !== 'strong_open') continue;
        // Look for: strong_open, text(FDS-XX-NNN), strong_close
        const textTok = kids[i + 1];
        const closeTok = kids[i + 2];
        if (!textTok || textTok.type !== 'text' || !closeTok || closeTok.type !== 'strong_close') continue;
        const m = RE.exec(textTok.content.trim());
        if (!m) continue;
        const id = `fds-${m[1]}-${m[2]}`;
        const linkOpen = new state.Token('html_inline', '', 0);
        linkOpen.content = `<a id="${id}" class="fds-req-anchor" href="#${id}">`;
        const linkClose = new state.Token('html_inline', '', 0);
        linkClose.content = '</a>';
        kids.splice(i, 0, linkOpen);
        kids.splice(i + 4, 0, linkClose);
        i += 4;
      }
    }
  });
};
