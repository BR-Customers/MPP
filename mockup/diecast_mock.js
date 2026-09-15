(function () {
  var root = document.documentElement;
  var DOT = '·';
  var CODES = ['111 ' + DOT + ' Flash', '135 ' + DOT + ' Porosity', '121 ' + DOT + ' Cracks',
               '112 ' + DOT + ' Short Shot', '109 ' + DOT + ' Stuck Part', '104 ' + DOT + ' Flatness'];

  /* Workorder.DieCastVarianceReason (spec D15) */
  var REASONS = [
    { code: 'MiscountedBasket',     name: 'Basket count corrected',          note: false },
    { code: 'CounterSuspect',       name: 'Press counter reading suspect',   note: false },
    { code: 'ScrapNotRecorded',     name: 'Scrap produced but not recorded', note: false },
    { code: 'PartsRemovedFromLine', name: 'Parts removed from the line',     note: true  },
    { code: 'Unknown',              name: 'Unknown',                         note: true  }
  ];
  function reasonOf(code) {
    for (var i = 0; i < REASONS.length; i++) if (REASONS[i].code === code) return REASONS[i];
    return null;
  }

  /* ---------- density control ---------- */
  var seg  = document.querySelector('.seg');
  var base = { base: 20, md: 22, sm: 17, touch: 40 };
  function px(n, s) { return Math.round(n * s) + 'px'; }
  seg.addEventListener('click', function (e) {
    var b = e.target.closest('button[data-s]'); if (!b) return;
    var s = parseFloat(b.dataset.s);
    root.style.setProperty('--scale', s);
    seg.querySelectorAll('button').forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
    document.getElementById('ro-base').textContent  = px(base.base, s);
    document.getElementById('ro-md').textContent    = px(base.md, s);
    document.getElementById('ro-sm').textContent    = px(base.sm, s);
    document.getElementById('ro-touch').textContent = px(base.touch, s);
  });

  /* ---------- the two real prod dies ---------- */
  function cav(o) {
    var d = { lines: [], good: null, note: null, lot: null, reason: '', reasonNote: '' };
    for (var k in o) d[k] = o[k];
    return d;
  }

  var DIES = {
    DM0126: {
      die: 'DM0126', dieName: '6MA Oil Pan E', press: 'DC1-M11', area: 'Die Cast 1',
      life: '118,450 / 250,000', reading: '1,240', watermarkNote: 'is at 1,180 for this shift',
      readingAdds: 60,
      dieWide: [ { name: 'Warm-up shots', code: 'DC-999', qty: 6 },
                 { name: 'Quality test shots', code: '107', qty: 2 } ],
      cavs: [ cav({ k: 'a', part: '11200-6MAA-J010', cavDesc: '6MA oil Pan', lot: '10627612',
                    raw: 60, shiftGood: 1148, shiftScrap: 32, pieces: 50, cap: 60,
                    lines: [{ code: CODES[1], qty: 2 }] }) ]
    },
    DM0124: {
      die: 'DM0124', dieName: '6MA IN 1&5 EX 1&5 - D', press: 'DC1-M04', area: 'Die Cast 1',
      life: '412,880 / 500,000', reading: '2,016', watermarkNote: 'is at 1,150 for this shift',
      readingAdds: 866,
      dieWide: [ { name: 'Warm-up shots', code: 'DC-999', qty: 20 },
                 { name: 'Quality test shots', code: '107', qty: 4 } ],
      cavs: [
        cav({ k:'a', part:'12231-6MA -0000', cavDesc:'In 1 Da', lot:'10627577', raw:866, shiftGood:1980, shiftScrap:48, pieces:1980, cap:2016, lines:[{code:CODES[0],qty:12}] }),
        cav({ k:'b', part:'12231-6MA -0000', cavDesc:'In 1 Db', lot:'10627580', raw:866, shiftGood:1842, shiftScrap:24, pieces:1842, cap:2016 }),
        cav({ k:'c', part:'12231-6MA -0000', cavDesc:'In 1 Dc', lot:'10627581', raw:866, shiftGood:1798, shiftScrap:24, pieces:1798, cap:2016 }),
        cav({ k:'a', part:'12235-6MA -0000', cavDesc:'In 5 Da', lot:'10627583', raw:866, shiftGood:1776, shiftScrap:24, pieces:1776, cap:2016 }),
        cav({ k:'b', part:'12235-6MA -0000', cavDesc:'In 5 Db', lot:'10627584', raw:866, shiftGood:1204, shiftScrap:24, pieces:1204, cap:2016, good:838 }),
        cav({ k:'c', part:'12235-6MA -0000', cavDesc:'In 5 Dc', lot:'10627585', raw:866, shiftGood:1802, shiftScrap:24, pieces:1802, cap:2016 }),
        cav({ k:'b', part:'12241-6MA -0000', cavDesc:'Ex 1 Db', lot:'10627586', raw:866, shiftGood:1788, shiftScrap:24, pieces:1788, cap:2016 }),
        cav({ k:'c', part:'12241-6MA -0000', cavDesc:'Ex 1 Dc', lot:null, note:'no basket since 02:10', raw:116, shiftGood:1900, shiftScrap:24 }),
        cav({ k:'a', part:'12245-6MA -0000', cavDesc:'Ex 5 Da', lot:'10627588', raw:866, shiftGood:1810, shiftScrap:24, pieces:1810, cap:2016 }),
        cav({ k:'b', part:'12245-6MA -0000', cavDesc:'Ex 5 Db', lot:'10627589', raw:866, shiftGood:1794, shiftScrap:24, pieces:1794, cap:2016 }),
        cav({ k:'c', part:'12245-6MA -0000', cavDesc:'Ex 5 Dc', lot:'10627590', raw:866, shiftGood:1772, shiftScrap:24, pieces:1772, cap:2016 })
      ]
    }
  };

  var n   = function (v) { return Number(v).toLocaleString('en-US'); };
  var esc = function (t) { return String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;'); };

  function dw(D)      { return D.dieWide.reduce(function (t, r) { return t + (r.qty || 0); }, 0); }
  function running(D) { return D.cavs.length; }
  function scrapOf(c) { return c.lines.reduce(function (t, l) { return t + (l.qty || 0); }, 0); }
  function netOf(D,c) { return Math.max(0, c.raw - dw(D)); }
  function goodOf(D,c){ if (!c.lot) return 0;
                        return c.good === null ? Math.max(0, netOf(D,c) - scrapOf(c)) : c.good; }
  function varOf(D,c) { return netOf(D,c) - goodOf(D,c) - scrapOf(c); }
  function needsReason(D,c) { return varOf(D,c) !== 0 && !c.reason; }
  function key(D,i)   { return D.die + '|' + i; }
  function open(k)    { return openRows[k] || (openRows[k] = { s: false, v: false }); }

  function opts(sel) {
    return CODES.map(function (c) {
      return '<option' + (c === sel ? ' selected' : '') + '>' + esc(c) + '</option>';
    }).join('');
  }
  function reasonOpts(sel) {
    return '<option value=""' + (sel ? '' : ' selected') + '>Pick a reason…</option>' +
      REASONS.map(function (r) {
        return '<option value="' + r.code + '"' + (r.code === sel ? ' selected' : '') + '>' +
          esc(r.name) + '</option>';
      }).join('');
  }

  /* ---------- editors shown inside an expanded row ---------- */
  function scrapEditor(D, c, i, lead) {
    var kk = key(D, i);
    var lines = c.lines.map(function (l, j) {
      return '<div class="sline"><span class="lead">' + (j ? '' : lead) + '</span>' +
        '<select class="fld sm" data-code="' + kk + '|' + j + '">' + opts(l.code) + '</select>' +
        '<input class="fld sm" data-qty="' + kk + '|' + j + '" type="text" value="' + l.qty + '">' +
        '<button class="btn ghost sm" data-rm="' + kk + '|' + j + '">Remove</button></div>';
    }).join('');
    return '<div class="slines">' + lines +
      '<div class="sline"><span class="lead">' + (c.lines.length ? '' : lead) + '</span>' +
      '<button class="btn ghost sm" data-add="' + kk + '">+ Add scrap line</button></div></div>';
  }

  function reasonEditor(D, c, i) {
    var kk = key(D, i), r = reasonOf(c.reason), v = varOf(D, c);
    return '<div class="slines reasonbox"><div class="sline">' +
      '<span class="lead">Variance ' + n(v) + '</span>' +
      '<select class="fld sm auto" data-reason="' + kk + '">' + reasonOpts(c.reason) + '</select>' +
      (r && r.note
        ? '<input class="fld sm note" data-rnote="' + kk + '" type="text" placeholder="Required — what happened?" value="' + esc(c.reasonNote) + '">'
        : '') +
      (c.reason ? '<button class="btn ghost sm" data-rclear="' + kk + '">Clear</button>' : '') +
      '</div>' +
      (r && r.note && !c.reasonNote
        ? '<div class="sline"><span class="lead"></span><span class="reqnote">A note is required for this reason.</span></div>'
        : '') +
      '</div>';
  }

  /* ---------- die-wide block ---------- */
  function dieWideHtml(D) {
    var r = running(D), solo = r === 1;
    var rows = D.dieWide.map(function (d, i) {
      return '<div class="dwrow"><span class="name">' + esc(d.name) +
        ' <span class="code">' + d.code + '</span></span>' +
        '<input class="fld' + (d.qty ? ' edited' : '') + '" data-dw="' + D.die + '|' + i + '" type="text" value="' + d.qty + '">' +
        '<span class="math' + (d.qty ? '' : ' zero') + '">' +
          (solo ? '= <b>' + n(d.qty) + ' pc</b>'
                : '&times; ' + r + ' cavities = <b>' + n(d.qty * r) + ' pc</b>') +
        '</span><span class="grow"></span><span class="pill">Non-reject scrap</span></div>';
    }).join('');
    return '<div class="diewide">' + rows +
      '<div class="dwrow"><span class="name"><button class="btn ghost">+ Add die-wide scrap</button></span><span class="grow"></span></div>' +
      '<div class="dwsum"><b>' + n(dw(D)) + ' shots</b> die-wide &mdash; already subtracted from ' +
        (solo ? 'the shot count below.' : 'every running cavity&rsquo;s shot count below.') + '</div></div>';
  }

  /* ---------- N = 1 : a form, not a grid ---------- */
  function soloHtml(D) {
    var c = D.cavs[0], i = 0, kk = key(D, i), sc = scrapOf(c), v = varOf(D, c);
    var o = open(kk), need = needsReason(D, c);
    return '<div class="sect">This cavity <span class="note">' + esc(c.part) + ' ' + DOT + ' ' + esc(c.cavDesc) +
      (c.lot ? ' ' + DOT + ' LOT ' + c.lot : '') + '</span></div>' +
      '<div class="solo">' +
        '<div class="soloband">' +
          '<div class="sq"><span>Shots to account</span><b>' + n(netOf(D,c)) + '</b>' +
            '<i>' + n(c.raw) + ' &minus; ' + dw(D) + ' die-wide</i></div>' +
          '<div class="op">&minus;</div>' +
          '<div class="sq"><span>Good</span>' +
            '<input class="fld big' + (c.good !== null ? ' edited' : '') + '" data-good="' + kk + '" type="text" value="' + goodOf(D,c) + '">' +
            '<i>counted into the basket</i></div>' +
          '<div class="op">&minus;</div>' +
          '<div class="sq"><span>Scrap</span>' +
            '<b><button class="scrapbtn big' + (sc ? '' : ' z') + '" data-x="' + kk + '">' + n(sc) + '</button></b>' +
            '<i>' + c.lines.length + ' reason' + (c.lines.length === 1 ? '' : 's') + '</i></div>' +
          '<div class="op">=</div>' +
          '<div class="sq ' + (v === 0 ? 'ok' : 'attn') + '"><span>Variance</span>' +
            '<b>' + (v === 0 ? n(v) : '<button class="scrapbtn big var" data-v="' + kk + '">' + n(v) + '</button>') + '</b>' +
            '<i>' + (v === 0 ? 'balanced' : (c.reason ? esc(reasonOf(c.reason).name) : 'needs a reason')) + '</i></div>' +
        '</div>' +
        (o.s ? scrapEditor(D, c, i, 'Scrap') : '') +
        ((o.v || need) && v !== 0 ? reasonEditor(D, c, i) : '') +
        '<div class="soloctx">Shift to date &mdash; good <b>' + n(c.shiftGood) + '</b> ' + DOT +
          ' scrap <b>' + n(c.shiftScrap) + '</b></div>' +
      '</div>';
  }

  /* ---------- N > 1 : grid grouped by part ---------- */
  function gridHtml(D) {
    var html = '<div class="sect">Per cavity <span class="note">grouped by part &mdash; ' +
      'good is pre-filled and editable</span></div>' +
      '<table class="grid"><thead><tr>' +
      '<th class="l">Cavity</th><th class="l">Basket</th><th>Shots</th><th>Good</th>' +
      '<th>Cavity scrap</th><th>Variance</th><th>Shift good</th><th>Shift scrap</th>' +
      '</tr></thead><tbody>';
    var lastPart = null;
    D.cavs.forEach(function (c, i) {
      var kk = key(D, i);
      if (c.part !== lastPart) {
        html += '<tr class="partrow"><td class="l" colspan="8"><span class="part">' + esc(c.part) +
          '</span> <span class="dim">' + D.cavs.filter(function (x) { return x.part === c.part; }).length +
          ' cavities</span></td></tr>';
        lastPart = c.part;
      }
      var sc = scrapOf(c), v = varOf(D, c), o = open(kk);
      var anyOpen = o.s || o.v;
      html += '<tr class="' + (c.lot ? '' : 'attn ') + (anyOpen ? 'nb' : '') + '">' +
        '<td class="l"><span class="cav' + (c.lot ? '' : ' off') + '">' + c.k + '</span>' +
          '<span class="dim">' + esc(c.cavDesc) + '</span></td>' +
        '<td class="l">' + (c.lot ? '<span class="lot">' + c.lot + '</span>'
                                  : '<span class="nobk">' + c.note + '</span>') + '</td>' +
        '<td><div class="shots"><span class="net">' + n(netOf(D,c)) + '</span>' +
          '<span class="calc">' + n(c.raw) + ' &minus; ' + dw(D) + '</span></div></td>' +
        '<td><input class="fld' + (c.good !== null ? ' edited' : '') + '" data-good="' + kk + '"' +
          (c.lot ? '' : ' disabled title="No basket - nothing to credit"') +
          ' type="text" value="' + goodOf(D,c) + '"></td>' +
        '<td><div class="scell"><button class="scrapbtn' + (sc ? '' : ' z') + '" data-x="' + kk + '">' +
          n(sc) + '</button>' + (c.lines.length ? '<span class="chip">' + c.lines.length + '</span>' : '') + '</div></td>' +
        '<td>' + (v === 0
            ? '<span class="varok">0</span>'
            : '<div class="scell"><button class="scrapbtn var" data-v="' + kk + '">' + n(v) + '</button>' +
              (c.reason ? '<span class="chip ok" title="' + esc(reasonOf(c.reason).name) + '">✓</span>'
                        : '<span class="chip need">!</span>') + '</div>') + '</td>' +
        '<td><span class="num dim">' + n(c.shiftGood) + '</span></td>' +
        '<td><span class="num dim">' + n(c.shiftScrap) + '</span></td></tr>';
      if (anyOpen) {
        html += '<tr class="expand' + (c.lot ? '' : ' attn') + '"><td colspan="8">' +
          (o.s ? scrapEditor(D, c, i, 'Cavity scrap') : '') +
          (o.v ? reasonEditor(D, c, i) : '') + '</td></tr>';
      }
    });
    return html + '</tbody></table>';
  }

  /* ---------- Lot Management ---------- */
  function lotsHtml(D) {
    var solo = D.cavs.length === 1, rows = '', lastPart = null;
    D.cavs.forEach(function (c) {
      if (!solo && c.part !== lastPart) {
        rows += '<tr class="partrow"><td class="l" colspan="5"><span class="part">' + esc(c.part) + '</span></td></tr>';
        lastPart = c.part;
      }
      rows += '<tr class="' + (c.lot ? '' : 'attn') + '">' +
        '<td class="l"><span class="cav' + (c.lot ? '' : ' off') + '">' + c.k + '</span>' +
          '<span class="dim">' + esc(c.cavDesc) + '</span></td>' +
        '<td class="l">' + (solo ? '<span class="part">' + esc(c.part) + '</span>' : '') + '</td>' +
        '<td class="l">' + (c.lot ? '<span class="lot">' + c.lot + '</span>'
                                  : '<span class="nobk">' + c.note + '</span>') + '</td>' +
        '<td>' + (c.lot ? '<span class="num">' + n(c.pieces) + '</span>' : '<span class="zero">&mdash;</span>') + '</td>' +
        '<td><div class="acts">' + (c.lot
            ? '<button class="btn primary">Release</button><button class="btn ghost">Void</button>'
            : '<button class="btn primary">Open basket</button>') + '</div></td></tr>';
    });
    return '<div class="sect">Cavities &mdash; ' + D.die + ' <span class="note">' +
        D.cavs.filter(function (c) { return c.lot; }).length + ' running ' + DOT + ' ' +
        D.cavs.filter(function (c) { return !c.lot; }).length + ' empty</span></div>' +
      '<table class="grid"><thead><tr><th class="l">Cavity</th><th class="l">Part</th>' +
      '<th class="l">Basket</th><th>Pieces</th><th>&nbsp;</th></tr></thead><tbody>' + rows + '</tbody></table>';
  }

  /* ---------- totals ---------- */
  function totalsHtml(D) {
    var shots = 0, good = 0, scrap = dw(D) * running(D), need = 0;
    D.cavs.forEach(function (c) {
      shots += c.raw; good += goodOf(D,c); scrap += scrapOf(c);
      if (needsReason(D,c)) need++;
      var r = reasonOf(c.reason);
      if (r && r.note && !c.reasonNote) need++;
    });
    var v = shots - good - scrap;
    return '<div class="totals">' +
      '<div class="tot"><span>Shots</span><b>' + n(shots) + '</b></div>' +
      '<div class="tot"><span class="op">&minus;</span></div>' +
      '<div class="tot"><span>Good</span><b>' + n(good) + '</b></div>' +
      '<div class="tot"><span class="op">&minus;</span></div>' +
      '<div class="tot"><span>Scrap</span><b>' + n(scrap) + '</b></div>' +
      '<div class="tot"><span class="op">=</span></div>' +
      '<div class="tot ' + (v === 0 ? '' : 'attn') + '"><span>Unaccounted</span><b>' + n(v) + '</b></div>' +
      '<div style="flex:1"></div>' +
      (need ? '<span class="gatemsg">' + need + ' ' + (need === 1 ? 'cavity needs' : 'cavities need') + ' a reason</span>' : '') +
      '<button class="btn big primary"' + (need ? ' disabled' : '') + '>Submit shift entry</button></div>';
  }

  /* ---------- a whole terminal ---------- */
  function terminalHtml(D, activeTab) {
    var solo = D.cavs.length === 1;
    return '<div class="apphead">' +
        '<div class="titleblock"><span class="ttl">Die Cast</span>' +
          '<span class="meta">Shared terminal ' + DOT + ' DC1-T1</span></div>' +
        '<div class="hdrdiv"></div>' +
        '<label class="f hdrf"><span>Active cell</span><select class="fld"><option>' +
          D.press + ' ' + DOT + ' ' + D.area + '</option><option>Scan or pick a cell…</option></select></label>' +
        '<span class="pill mono">' + D.die + '</span>' +
        '<span class="pill warn">' + D.life + ' shots</span>' +
        '<span class="spacer"></span>' +
        '<span class="meta">3rd shift ' + DOT + ' 03:12</span>' +
        '<button class="btn ghost opbtn"><span class="opdot"></span>JH ' + DOT + ' John Horn</button>' +
        '<div class="hdrdiv"></div><button class="btn ghost">Refresh</button><button class="btn ghost">Close</button>' +
      '</div>' +
      '<div class="tabs" role="tablist">' +
        '<button type="button" role="tab" data-tab="lots|' + D.die + '" aria-selected="' + (activeTab === 'lots') + '">Lot Management</button>' +
        '<button type="button" role="tab" data-tab="rec|' + D.die + '" aria-selected="' + (activeTab === 'rec') + '">Reconcile Shift</button>' +
        '<div class="tabfill"></div></div>' +
      '<div class="panel" data-active="' + (activeTab === 'lots') + '">' + lotsHtml(D) + '</div>' +
      '<div class="panel" data-active="' + (activeTab === 'rec') + '">' +
        '<div class="toprow">' +
          '<div class="topcol entrycol">' +
            '<div class="sect">This entry</div>' +
            '<div class="entrybar">' +
              '<label class="f"><span>Shift</span><select class="fld"><option>3rd ' + DOT + ' 09-13 23:00</option></select></label>' +
              '<label class="f"><span>Press counter reading</span><input class="fld wide" type="text" value="' + D.reading + '"></label>' +
              '<div class="ctx">' + D.die + ' ' + esc(D.watermarkNote) + '.<br>This reading adds <b>' +
                n(D.readingAdds) + '</b> shots. <span class="pill" style="margin-left:6px">Fix counter</span></div>' +
            '</div>' +
          '</div>' +
          '<div class="topcol">' +
            '<div class="sect">Die-wide <span class="note">' +
              (solo ? 'one lost shot costs one part' : 'one lost shot costs one part on every running cavity') +
            '</span><span class="grow"></span><button class="helpbtn">?</button></div>' +
            dieWideHtml(D) +
          '</div>' +
        '</div>' +
        (solo ? soloHtml(D) : gridHtml(D)) + totalsHtml(D) +
      '</div>';
  }

  /* ---------- state + render ---------- */
  var openRows = {};
  var tabState = { DM0126: 'rec', DM0124: 'rec' };

  function render() {
    Object.keys(DIES).forEach(function (k) {
      document.getElementById('term-' + k).innerHTML = terminalHtml(DIES[k], tabState[k]);
    });
  }

  function findCav(k) { var a = k.split('|'); return { D: DIES[a[0]], c: DIES[a[0]].cavs[+a[1]], i: +a[1] }; }
  var num = function (v) { var x = parseInt(String(v).replace(/[^0-9-]/g, ''), 10); return isNaN(x) ? 0 : x; };

  document.addEventListener('click', function (e) {
    var t;
    if ((t = e.target.closest('button[data-tab]'))) {
      var p = t.dataset.tab.split('|'); tabState[p[1]] = p[0]; return render();
    }
    if ((t = e.target.closest('[data-x]'))) {
      var o = open(t.dataset.x), r = findCav(t.dataset.x);
      o.s = !o.s;
      if (o.s && !r.c.lines.length) r.c.lines.push({ code: CODES[0], qty: 0 });
      return render();
    }
    if ((t = e.target.closest('[data-v]'))) { open(t.dataset.v).v = !open(t.dataset.v).v; return render(); }
    if ((t = e.target.closest('[data-add]'))) {
      findCav(t.dataset.add).c.lines.push({ code: CODES[0], qty: 0 }); return render();
    }
    if ((t = e.target.closest('[data-rm]'))) {
      var a = t.dataset.rm.split('|');
      findCav(a[0] + '|' + a[1]).c.lines.splice(+a[2], 1); return render();
    }
    if ((t = e.target.closest('[data-rclear]'))) {
      var rc = findCav(t.dataset.rclear); rc.c.reason = ''; rc.c.reasonNote = ''; return render();
    }
  });

  document.addEventListener('change', function (e) {
    var t = e.target, a, r;
    if (t.dataset.qty)    { a = t.dataset.qty.split('|');  findCav(a[0]+'|'+a[1]).c.lines[+a[2]].qty  = num(t.value); return render(); }
    if (t.dataset.code)   { a = t.dataset.code.split('|'); findCav(a[0]+'|'+a[1]).c.lines[+a[2]].code = t.value;      return render(); }
    if (t.dataset.good)   { r = findCav(t.dataset.good); r.c.good = t.value === '' ? null : num(t.value);             return render(); }
    if (t.dataset.dw)     { a = t.dataset.dw.split('|');  DIES[a[0]].dieWide[+a[1]].qty = num(t.value);               return render(); }
    if (t.dataset.reason) { r = findCav(t.dataset.reason); r.c.reason = t.value; if (!t.value) r.c.reasonNote = '';   return render(); }
    if (t.dataset.rnote)  { r = findCav(t.dataset.rnote);  r.c.reasonNote = t.value;                                  return render(); }
  });

  render();
})();
