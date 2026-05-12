function buildToc(renderedHtml) {
  const headingRe = /<h([23])\s+id="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/g;
  const items = [];
  let m;
  while ((m = headingRe.exec(renderedHtml)) !== null) {
    const level = Number(m[1]);
    const id = m[2];
    let text = m[3]
      .replace(/<span[^>]*class="[^"]*scope-pill[^"]*"[^>]*>[\s\S]*?<\/span>/g, '') // strip pill/badge elements with their text
      .replace(/<[^>]+>/g, '')         // strip remaining inline HTML (code, anchors, etc.)
      .replace(/\s+/g, ' ')
      .trim();
    items.push({ level, id, text });
  }
  if (items.length === 0) return '<ul></ul>';

  // Nest: h3s go under the most recent h2.
  let html = '<ul>';
  let openSub = false;
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    if (it.level === 2) {
      if (openSub) { html += '</ul></li>'; openSub = false; }
      else if (i > 0) html += '</li>';
      html += `<li><a href="#${it.id}">${it.text}</a>`;
      // Peek ahead — if next is h3, open sublist
      if (items[i + 1] && items[i + 1].level === 3) { html += '<ul>'; openSub = true; }
    } else if (it.level === 3) {
      html += `<li><a href="#${it.id}">${it.text}</a></li>`;
    }
  }
  if (openSub) html += '</ul></li>';
  else html += '</li>';
  html += '</ul>';
  return html;
}

module.exports = { buildToc };
