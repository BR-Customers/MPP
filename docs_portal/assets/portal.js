// MPP MES Docs Portal — client-side behavior
(function () {
  'use strict';

  // 1. Active-section highlight in TOC via IntersectionObserver
  function setupTocActiveHighlight() {
    const toc = document.querySelector('.portal-toc');
    const main = document.querySelector('.portal-main');
    if (!toc || !main) return;

    const headings = main.querySelectorAll('h2[id], h3[id]');
    const tocLinks = new Map();
    toc.querySelectorAll('a[href^="#"]').forEach((a) => {
      tocLinks.set(a.getAttribute('href').slice(1), a);
    });

    const visible = new Set();
    function updateActive() {
      tocLinks.forEach((a) => a.classList.remove('active'));
      // Pick the topmost visible heading
      let topId = null;
      let topOffset = Infinity;
      visible.forEach((id) => {
        const el = document.getElementById(id);
        if (!el) return;
        const top = el.getBoundingClientRect().top;
        if (top < topOffset) { topOffset = top; topId = id; }
      });
      if (topId && tocLinks.has(topId)) tocLinks.get(topId).classList.add('active');
    }

    const obs = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) visible.add(e.target.id);
        else visible.delete(e.target.id);
      });
      updateActive();
    }, { rootMargin: '-72px 0px -50% 0px', threshold: 0 });

    headings.forEach((h) => obs.observe(h));
  }

  // 2. Permalink-chip click → copy to clipboard
  function setupPermalinkCopy() {
    document.addEventListener('click', (e) => {
      const a = e.target.closest('a.heading-permalink');
      if (!a) return;
      const url = new URL(a.getAttribute('href'), window.location.href).href;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        e.preventDefault();
        navigator.clipboard.writeText(url).then(() => {
          a.dataset.copied = '1';
          setTimeout(() => delete a.dataset.copied, 1200);
        });
      }
    });
  }

  // 3. Search modal — wired in Phase 6 (Task 14). Trigger toggles visibility.
  function setupSearchModal() {
    const trigger = document.getElementById('search-trigger');
    const modal = document.getElementById('search-modal');
    if (!trigger || !modal) return;
    trigger.addEventListener('click', () => openSearch());
    document.addEventListener('keydown', (e) => {
      if (e.key === '/' && !['INPUT', 'TEXTAREA'].includes(document.activeElement.tagName)) {
        e.preventDefault();
        openSearch();
      } else if (e.key === 'Escape' && !modal.hidden) {
        modal.hidden = true;
      }
    });
    function openSearch() {
      if (!modal.dataset.initialized) initSearch(modal);
      modal.hidden = false;
      const input = modal.querySelector('input');
      if (input) { input.value = ''; input.focus(); modal.querySelector('.results').innerHTML = ''; }
    }
  }

  function initSearch(modal) {
    modal.dataset.initialized = '1';
    modal.innerHTML = '<input type="search" placeholder="Search docs… (Esc to close)" autocomplete="off"><div class="results"></div>';
    const input = modal.querySelector('input');
    const results = modal.querySelector('.results');

    // Lazy-load the index
    let indexPromise = null;
    function getIndex() {
      if (!indexPromise) {
        indexPromise = fetch('search-index.json')
          .then((r) => {
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            return r.json();
          })
          .then((raw) => {
            // eslint-disable-next-line no-undef
            const idx = MiniSearch.loadJSON(JSON.stringify(raw.index), raw.options);
            return { idx, byId: new Map(raw.docs.map((d) => [d.id, d])) };
          })
          .catch((err) => {
            const isFileProto = window.location.protocol === 'file:';
            const hint = isFileProto
              ? 'Chrome and Edge block fetch() from file:// URLs. Run `npm run serve:portal` (or any local HTTP server) and open the portal via http://localhost:8080/ instead.'
              : `Failed to load search-index.json: ${err.message}`;
            results.innerHTML = `<div class="search-result" style="cursor: default;"><div>Search unavailable</div><div class="snippet">${hint}</div></div>`;
            // Re-throw so subsequent calls don't reuse the failed promise
            indexPromise = null;
            throw err;
          });
      }
      return indexPromise;
    }

    let debounce;
    input.addEventListener('input', () => {
      clearTimeout(debounce);
      debounce = setTimeout(() => runSearch(input.value), 80);
    });
    function runSearch(q) {
      results.innerHTML = '';
      if (!q || q.trim().length < 2) return;
      getIndex().then(({ idx, byId }) => {
        const hits = idx.search(q, { prefix: true, fuzzy: 0.15, combineWith: 'AND' }).slice(0, 30);
        results.innerHTML = hits.map((h) => renderResult(byId.get(h.id), q)).join('');
      });
    }
    function renderResult(doc, q) {
      if (!doc) return '';
      const snippet = makeSnippet(doc.body || '', q);
      const scopeHtml = doc.scope ? `<span class="scope-pill scope-${doc.scope.toLowerCase()}">${doc.scope}</span> ` : '';
      return `<a class="search-result" href="${doc.id}">
        <div><span class="doc-badge">${doc.doc}</span>${scopeHtml}${escapeHtml(doc.title || '')}</div>
        <div class="snippet">${snippet}</div>
      </a>`;
    }
    function makeSnippet(body, q) {
      const lc = body.toLowerCase();
      const term = q.toLowerCase().split(/\s+/).filter(Boolean)[0] || '';
      const idx = term ? lc.indexOf(term) : -1;
      const start = idx >= 0 ? Math.max(0, idx - 60) : 0;
      const slice = body.slice(start, start + 220);
      return escapeHtml(slice).replace(new RegExp(escapeRe(term), 'gi'), (m) => `<mark>${m}</mark>`);
    }
    function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
    function escapeHtml(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
  }

  document.addEventListener('DOMContentLoaded', () => {
    setupTocActiveHighlight();
    setupPermalinkCopy();
    setupSearchModal();
  });
})();
