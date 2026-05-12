// Patterns are matched against text-token content only — never inside
// code_inline, links, raw HTML, or strong (so anchor_fds_req keeps priority).
const RE_FDS = /\bFDS-(\d{2})-(\d{3})\b/g;
const RE_OI = /\bOI-(\d{2})\b/g;
const RE_UJ = /\bUJ-(\d{2})\b/g;
const RE_FRS = /\(FRS [\d.]+\)/g;

function buildTableRe(knownTables) {
  if (!knownTables || knownTables.size === 0) return null;
  const keys = [...knownTables.keys()]
    .sort((a, b) => b.length - a.length)              // longest first
    .map((k) => k.replace(/\./g, '\\.'));
  return new RegExp(`\\b(${keys.join('|')})\\b`, 'g');
}

module.exports = function crossDocLink(md, opts = {}) {
  const currentDoc = opts.currentDoc || '';
  const knownTables = opts.knownTables || new Map();
  const tableRe = buildTableRe(knownTables);

  const ruleBody = (state) => {
    walkInline(state.tokens, (children) => {
      let linkDepth = 0;
      for (let i = 0; i < children.length; i++) {
        const tok = children[i];
        if (tok.type === 'link_open') { linkDepth++; continue; }
        if (tok.type === 'link_close') { linkDepth--; continue; }
        if (tok.type !== 'text') continue;
        if (linkDepth > 0) continue;  // inside an existing link — leave untouched
        const replaced = replaceText(tok.content, currentDoc, tableRe, knownTables);
        if (replaced === null) continue;
        const newToks = textToTokens(state, replaced);
        children.splice(i, 1, ...newToks);
        i += newToks.length - 1;
      }
    });
  };

  // Register after anchor_fds_req when it exists (full plugin chain); otherwise push.
  try {
    md.core.ruler.after('anchor_fds_req', 'cross_doc_link', ruleBody);
  } catch (_e) {
    md.core.ruler.push('cross_doc_link', ruleBody);
  }
};

function walkInline(tokens, visit) {
  for (const blockTok of tokens) {
    if (blockTok.type !== 'inline' || !blockTok.children) continue;
    visit(blockTok.children);
  }
}

function replaceText(text, currentDoc, tableRe, knownTables) {
  // If no pattern matches, signal no-op with null.
  if (!RE_FDS.test(text) && !RE_OI.test(text) && !RE_UJ.test(text) && !RE_FRS.test(text)
      && !(tableRe && tableRe.test(text))) {
    // reset lastIndex on the global regexes used in test()
    RE_FDS.lastIndex = RE_OI.lastIndex = RE_UJ.lastIndex = RE_FRS.lastIndex = 0;
    if (tableRe) tableRe.lastIndex = 0;
    return null;
  }
  RE_FDS.lastIndex = RE_OI.lastIndex = RE_UJ.lastIndex = RE_FRS.lastIndex = 0;
  if (tableRe) tableRe.lastIndex = 0;

  let out = escapeHtml(text);
  out = out.replace(RE_FDS, (m, a, b) => {
    const href = currentDoc === 'fds' ? `#fds-${a}-${b}` : `fds.html#fds-${a}-${b}`;
    return `<a class="xref" href="${href}">${m}</a>`;
  });
  out = out.replace(RE_OI, (m, n) => {
    const href = currentDoc === 'oir' ? `#oi-${n}` : `oir.html#oi-${n}`;
    return `<a class="xref" href="${href}">${m}</a>`;
  });
  out = out.replace(RE_UJ, (m, n) => {
    const href = currentDoc === 'oir' ? `#uj-${n}` : `oir.html#uj-${n}`;
    return `<a class="xref" href="${href}">${m}</a>`;
  });
  out = out.replace(RE_FRS, (m) => `<span class="frs-ref">${m}</span>`);
  if (tableRe) {
    out = out.replace(tableRe, (m) => {
      const anchor = knownTables.get(m);
      const href = currentDoc === 'data-model' ? `#${anchor}` : `data-model.html#${anchor}`;
      return `<a class="xref" href="${href}">${m}</a>`;
    });
  }
  return out;
}

function textToTokens(state, html) {
  const t = new state.Token('html_inline', '', 0);
  t.content = html;
  return [t];
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}
