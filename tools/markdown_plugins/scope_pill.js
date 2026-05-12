const TAGS = new Set(['MVP', 'MVP-EXPANDED', 'CONDITIONAL', 'FUTURE']);

module.exports = function scopePill(md) {
  md.core.ruler.after('inline', 'scope_pill', (state) => {
    for (const blockTok of state.tokens) {
      if (blockTok.type !== 'inline' || !blockTok.children) continue;
      for (const t of blockTok.children) {
        if (t.type !== 'code_inline') continue;
        const content = t.content;
        if (!TAGS.has(content)) continue;
        t.type = 'html_inline';
        t.content = `<span class="scope-pill scope-${content.toLowerCase()}">${content}</span>`;
      }
    }
  });
};
