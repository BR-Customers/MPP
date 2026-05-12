const DOCS = [
  { key: 'fds', label: 'FDS', href: 'fds.html' },
  { key: 'data-model', label: 'Data Model', href: 'data-model.html' },
  { key: 'oir', label: 'OIR', href: 'oir.html' },
  { key: 'erd', label: 'ERD', href: 'erd.html' },
];

function escape(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function renderShell({ activeDoc, title, contentHtml, tocHtml, sourcePath, generatedAt }) {
  const navLinks = DOCS.map((d) => {
    const cls = d.key === activeDoc ? 'nav-link active' : 'nav-link';
    return `<a href="${escape(d.href)}" class="${escape(cls)}">${escape(d.label)}</a>`;
  }).join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${escape(title)} — MPP MES Docs</title>
<link rel="stylesheet" href="assets/portal.css">
</head>
<body data-active-doc="${escape(activeDoc)}">
<header class="portal-header">
  <div class="brand">MPP MES Docs</div>
  <nav class="doc-nav">${navLinks}</nav>
  <button id="search-trigger" class="search-trigger" aria-label="Search">🔍</button>
</header>
<div class="portal-body">
  <aside class="portal-toc" aria-label="Section navigation">${tocHtml}</aside>
  <main class="portal-main">${contentHtml}</main>
</div>
<footer class="portal-footer">
  <span>Source: <code>${escape(sourcePath)}</code></span>
  <span>Generated: <time datetime="${escape(generatedAt)}">${escape(generatedAt)}</time></span>
</footer>
<div id="search-modal" class="search-modal" hidden></div>
<script src="assets/minisearch.min.js"></script>
<script src="assets/portal.js"></script>
</body>
</html>`;
}

module.exports = { renderShell, DOCS };
