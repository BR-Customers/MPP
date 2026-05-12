const { slugify } = require('../lib/slugify');

module.exports = function headingPermalinks(md) {
  md.core.ruler.push('heading_permalinks', (state) => {
    const seen = new Map();
    for (let i = 0; i < state.tokens.length; i++) {
      const tok = state.tokens[i];
      if (tok.type !== 'heading_open') continue;
      if (tok.tag !== 'h2' && tok.tag !== 'h3') continue;
      const inline = state.tokens[i + 1];
      if (!inline || inline.type !== 'inline') continue;
      const text = inline.content;
      const existingId = tok.attrGet('id');
      const id = existingId || slugify(text, seen);
      if (!existingId) tok.attrSet('id', id);
      // Append a permalink anchor as the last inline child.
      const linkOpen = new state.Token('html_inline', '', 0);
      linkOpen.content = ` <a class="heading-permalink" href="#${id}" aria-label="Permalink">#</a>`;
      inline.children = inline.children || [];
      inline.children.push(linkOpen);
    }
  });
};
