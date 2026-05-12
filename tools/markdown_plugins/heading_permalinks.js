const { slugify } = require('../lib/slugify');

const RE_FDS_HEADING = /^(FDS-(\d{2})-(\d{3}))\b/;
const RE_OIR_HEADING = /^(OI|UJ)-(\d{2})\b/;

module.exports = function headingPermalinks(md) {
  md.core.ruler.push('heading_permalinks', (state) => {
    const seen = new Map();
    for (let i = 0; i < state.tokens.length; i++) {
      const tok = state.tokens[i];
      if (tok.type !== 'heading_open') continue;
      if (tok.tag !== 'h2' && tok.tag !== 'h3' && tok.tag !== 'h4') continue;
      const inline = state.tokens[i + 1];
      if (!inline || inline.type !== 'inline') continue;
      const text = inline.content;
      const existingId = tok.attrGet('id');
      let id;
      if (existingId) {
        id = existingId;
      } else {
        const fdsM = RE_FDS_HEADING.exec(text.trim());
        if (fdsM) {
          // Canonical FDS requirement slug — keep separate dedup track so
          // 'fds-05-009' isn't mangled by slugify's seen Map collisions.
          id = `fds-${fdsM[2]}-${fdsM[3]}`;
        } else {
          const oirM = RE_OIR_HEADING.exec(text.trim());
          if (oirM) {
            id = `${oirM[1].toLowerCase()}-${oirM[2]}`;
          } else {
            id = slugify(text, seen);
          }
        }
        tok.attrSet('id', id);
      }
      // Append a permalink anchor as the last inline child.
      const linkOpen = new state.Token('html_inline', '', 0);
      linkOpen.content = ` <a class="heading-permalink" href="#${id}" aria-label="Permalink">#</a>`;
      inline.children = inline.children || [];
      inline.children.push(linkOpen);
    }
  });
};
