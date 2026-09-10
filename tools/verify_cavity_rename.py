# -*- coding: utf-8 -*-
"""Blast-radius audit for the cavity numeric-ordinal -> per-part alpha-code rename.

Spec: docs/superpowers/specs/2026-09-10-cavity-alpha-code-design.md
Migration: 0076_toolcavity_alpha_code.sql

The rename touches seven layers (SQL procs, SQL tests, named queries,
script-python, Perspective views, docs, extended properties). A leftover in
any one of them fails DIFFERENTLY and mostly LATE:

  * a proc still selecting CavityNumber          -> Invalid column name, at run time
  * a named query still typed sqlType 2          -> silent int coercion of 'a' -> error
  * a view still binding params.cavityNumber     -> blank cell, no error at all
  * Python still calling int(cavityNumber)       -> ValueError on the first save
  * a doc still saying CavityNumber              -> nobody notices for a year

So this is a token audit, not a column audit. It looks for every FORM the old
identifier takes, including the unicode-escaped forms Designer rewrites into
view.json, and including the two numeric-coercion sites that are not the word
"CavityNumber" at all (int(newNumber) in Cavities, sqlType 2 in the NQ).

    python tools/verify_cavity_rename.py                  # classified inventory
    python tools/verify_cavity_rename.py --mode baseline  # freeze the fingerprint
    python tools/verify_cavity_rename.py --mode verify    # exit 1 if anything survives

--mode verify returning 0 is the definition of DONE for the rename. It asserts
nothing about behaviour; that is the SQL test suite.
"""
import argparse
import io
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# What counts as a leftover
# ---------------------------------------------------------------------------
# Designer serializes '=' '<' '>' and friends as 6-char unicode escapes inside
# view.json, so a literal-string search for python written into an event script
# can miss. Every pattern below is matched against the RAW file text, and the
# view-json patterns are duplicated in their escaped form.

TOKENS = [
    # (id, regex, human description)
    # 'col' must NOT swallow ToolCavityNumber -- that is Lot_Get's result-set
    # ALIAS (tc.CavityNumber AS ToolCavityNumber), consumed by four views and
    # by Lot/code.py's _EMPTY shape. It renames to ToolCavityCode, but it is a
    # different edit in a different place, so it gets its own token.
    ('col',        r'(?<!Tool)CavityNumber',     'CavityNumber (SQL column / JSON key)'),
    ('colalias',   r'ToolCavityNumber',          'ToolCavityNumber (Lot_Get result alias)'),
    ('param',      r'cavityNumber',              'cavityNumber (NQ param / view param / dict key)'),
    ('int_cav',    r'int\(\s*cavityNumber\s*\)', 'int(cavityNumber) coercion'),
    ('int_new',    r'int\(\s*newNumber\s*\)',    'int(newNumber) coercion'),
    ('int_num',    r'int\(\s*num\s*\)',          'int(num) coercion'),
    ('trycast',    r'TRY_CAST\([^)]*CavityNumber[^)]*AS\s+INT\)',
                                                 'TRY_CAST(CavityNumber AS INT)'),
    ('ge1',        r'CavityNumber\s*[<>]=?\s*\d','CavityNumber numeric comparison'),
    ('orderby',    r'ORDER\s+BY[^;\n]*CavityNumber',
                                                 'ORDER BY CavityNumber (needs PartNumber first)'),
    ('numinput',   r'ia\.input\.numeric-entry-field',
                                                 'numeric-entry-field (cavity views only)'),
    ('sqltype2',   r'"sqlType"\s*:\s*2\b',       'sqlType 2 / integer (cavity NQs only)'),
]

# Two tokens are only defects in specific files -- numeric-entry-field and
# sqlType 2 are perfectly legitimate everywhere else in the project.
SCOPED_TOKENS = {
    'numinput': ('_Tools/CavityRow',),
    'sqltype2': ('named-query/parts/ToolCavity_Create',),
}

# ---------------------------------------------------------------------------
# Where to look, and what each hit means
# ---------------------------------------------------------------------------
SCOPES = [
    # (label, root, file filter, change class)
    ('sql/migrations/repeatable', os.path.join('sql', 'migrations', 'repeatable'),
     lambda p: p.endswith('.sql'), 'rename in place'),
    ('sql/tests', os.path.join('sql', 'tests'),
     lambda p: p.endswith('.sql'), 'rename + new cases'),
    ('sql/seeds', os.path.join('sql', 'seeds'),
     lambda p: p.endswith('.sql'), 'rename in place'),
    ('named-query', os.path.join('ignition', 'projects'),
     lambda p: os.sep + 'named-query' + os.sep in p, 'rename + sqlType'),
    ('script-python', os.path.join('ignition', 'projects'),
     lambda p: p.endswith('code.py'), 'rename + drop int()'),
    ('perspective views', os.path.join('ignition', 'projects'),
     lambda p: p.endswith('view.json'), 'DESIGNER EDIT'),
    ('docs', '.', None, 'prose'),  # explicit file list, see DOC_FILES
]

DOC_FILES = [
    'MPP_MES_DATA_MODEL.md',
    'MPP_MES_SUMMARY.md',
    'MPP_MES_FDS.md',
    'MPP_MES_USER_JOURNEYS.md',
    'MPP_MES_CONFIGURATION_UI_SPEC.md',
]

# ---------------------------------------------------------------------------
# Allowlist -- files that legitimately KEEP the old name forever
# ---------------------------------------------------------------------------
# Versioned migrations are history: 0010 created CavityNumber INT and 0020
# created Lot.CavityNumber. A forward-only repo never edits an applied
# migration -- Reset-DevDatabase replays them and then applies 0076. Editing
# them would make the replayed schema disagree with every deployed database.
#
# Specs, plans, notes and meeting minutes are dated records of what was true
# when written. Rewriting them is falsification, not maintenance.
ALLOW_PREFIXES = [
    os.path.join('sql', 'migrations', 'versioned'),
    # sql/scratch is NOT allowlisted, despite the name. Reset-DevDatabase.ps1
    # runs seed_demo.sql by default and seed_jp_validation.sql under
    # -JpValidation ("Jacques's canonical Dev config"), so those two are the
    # dev-database bootstrap, not scratch. Allowlisting the folder hid both
    # from this audit while the rename broke them, and Run-Tests could not
    # catch it because it resets with -SkipDemoSeed.
    os.path.join('docs', 'superpowers', 'specs'),
    os.path.join('docs', 'superpowers', 'plans'),
    os.path.join('docs', 'handoffs'),
    os.path.join('docs', 'proposals'),
    'notes',
    'Meeting_Notes',
    'mpp_frs_md',
    'reference',
    'dist',
    'docs_portal',          # generated
    '.claude',              # worktrees
    '.superpowers',
    '.tmp',
    '.git',
    'node_modules',
]
ALLOW_FILES = [
    'MPP_MES_FDS_CHANGELOG.md',
    os.path.join('tools', 'verify_cavity_rename.py'),   # this file names the tokens
]

BASELINE = os.path.join('tools', 'cavity_rename_baseline.json')


def allowed(relpath):
    norm = relpath.replace('/', os.sep)
    for p in ALLOW_PREFIXES:
        if norm == p or norm.startswith(p + os.sep):
            return True
    return norm in ALLOW_FILES


def read(path):
    try:
        with io.open(path, 'r', encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except (IOError, OSError):
        return ''


def scan_file(path, relpath):
    """Return ({token_id: count}, pickled) for one file, honouring SCOPED_TOKENS.

    `pickled` flags a view.json carrying Designer-pickled RUNTIME data -- rows
    fetched at design time and saved into the component's default property
    value, recognisable by the QualifiedValue "$ts" timestamps that come with
    them. Those hits are NOT rename targets: the right fix is to strip the
    data, not to rewrite a column name inside a stale audit payload. Renaming
    them would preserve the defect and make it look intentional.
    See feedback_designer_pickles_live_data.
    """
    text = read(path)
    if not text:
        return {}, False
    pickled = relpath.endswith('view.json') and '"$ts"' in text
    hits = {}
    for tid, pattern, _desc in TOKENS:
        scope = SCOPED_TOKENS.get(tid)
        if scope and not any(s.replace('/', os.sep) in relpath for s in scope):
            continue
        n = len(re.findall(pattern, text, re.IGNORECASE if tid == 'orderby' else 0))
        if n:
            hits[tid] = n
    return hits, pickled


def walk(root, predicate):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in ('.git', 'node_modules', '__pycache__',
                                    '.claude', '.superpowers')]
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, '.')
            if allowed(rel):
                continue
            if predicate and not predicate(full):
                continue
            yield full, rel


def collect():
    """-> list of {scope, path, class, hits, total}, sorted by scope then path."""
    seen = set()
    rows = []
    for label, root, predicate, klass in SCOPES:
        if label == 'docs':
            candidates = [(f, f) for f in DOC_FILES if os.path.exists(f)]
        else:
            if not os.path.isdir(root):
                continue
            candidates = list(walk(root, predicate))
        for full, rel in candidates:
            if rel in seen:
                continue
            hits, pickled = scan_file(full, rel)
            if not hits:
                continue
            seen.add(rel)
            rows.append({
                'scope': label,
                'path': rel.replace(os.sep, '/'),
                'class': 'PICKLED DATA -- strip' if pickled else klass,
                'hits': hits,
                'total': sum(hits.values()),
            })
    rows.sort(key=lambda r: (r['scope'], r['path']))
    return rows


def token_desc(tid):
    for t, _p, d in TOKENS:
        if t == tid:
            return d
    return tid


def print_inventory(rows):
    out = sys.stdout
    by_scope = {}
    for r in rows:
        by_scope.setdefault(r['scope'], []).append(r)

    out.write('\nCAVITY RENAME -- BLAST RADIUS\n')
    out.write('=' * 78 + '\n')

    for label, _root, _pred, klass in SCOPES:
        group = by_scope.get(label)
        if not group:
            continue
        files = len(group)
        total = sum(r['total'] for r in group)
        out.write('\n%s  --  %d file%s, %d occurrence%s  [%s]\n'
                  % (label, files, '' if files == 1 else 's',
                     total, '' if total == 1 else 's', klass))
        out.write('-' * 78 + '\n')
        for r in sorted(group, key=lambda x: -x['total']):
            detail = ', '.join('%s x%d' % (t, n) for t, n in sorted(r['hits'].items()))
            name = r['path']
            if len(name) > 56:
                name = '...' + name[-53:]
            out.write('  %-56s %4d  %s\n' % (name, r['total'], detail))

    out.write('\n' + '=' * 78 + '\n')
    out.write('TOTAL: %d files, %d occurrences\n'
              % (len(rows), sum(r['total'] for r in rows)))

    # Token legend, so the detail column is readable without the source.
    used = sorted({t for r in rows for t in r['hits']})
    out.write('\nTokens seen:\n')
    for t in used:
        out.write('  %-10s %s\n' % (t, token_desc(t)))

    designer = [r for r in rows if r['class'] == 'DESIGNER EDIT']
    if designer:
        out.write('\n%d view%s need Designer edits (file edits to EXISTING views are\n'
                  'unreliable -- see feedback_ignition_view_edit_boundary):\n'
                  % (len(designer), '' if len(designer) == 1 else 's'))
        for r in designer:
            short = r['path'].split('views/BlueRidge/')[-1].replace('/view.json', '')
            out.write('  - %-52s %s\n'
                      % (short, ', '.join(sorted(r['hits']))))

    pickled = [r for r in rows if r['class'].startswith('PICKLED')]
    if pickled:
        out.write('\n%d view%s Designer-pickled runtime data. These hits are NOT\n'
                  'rename targets -- strip the pickled rows instead (the column name is\n'
                  'buried in a stale audit payload that should never have been committed):\n'
                  % (len(pickled), ' carries' if len(pickled) == 1 else 's carry'))
        for r in pickled:
            short = r['path'].split('views/BlueRidge/')[-1].replace('/view.json', '')
            out.write('  - %-52s %d hit(s)\n' % (short, r['total']))
    out.write('\n')


def do_baseline(rows):
    payload = {
        'spec': 'docs/superpowers/specs/2026-09-10-cavity-alpha-code-design.md',
        'files': len(rows),
        'occurrences': sum(r['total'] for r in rows),
        'rows': rows,
    }
    with io.open(BASELINE, 'w', encoding='utf-8') as fh:
        fh.write(json.dumps(payload, indent=2, sort_keys=True))
        fh.write(u'\n')
    print('Baseline written: %s  (%d files, %d occurrences)'
          % (BASELINE, payload['files'], payload['occurrences']))
    return 0


def do_verify(rows):
    # Markdown docs are ADVISORY, never a failure. MPP_MES_DATA_MODEL.md and the
    # FDS carry dated Revision History entries that describe what the schema WAS
    # -- "Pre-v1.9 Lot.CavityNumber columns are now legacy", and so on. Those are
    # records, not leftovers; rewriting them would be falsification. Only the LIVE
    # spec rows are renamed, and a reviewer checks those by reading the diff.
    advisory = [r for r in rows if r['scope'] == 'docs']
    blocking = [r for r in rows if r['scope'] != 'docs']

    if advisory:
        print('ADVISORY -- %d doc file(s) still mention the old name. Confirm each is '
              'a dated Revision History entry (legitimate), not a live spec row:'
              % len(advisory))
        for r in advisory:
            print('  %-40s %d mention(s)' % (r['path'], r['total']))
        print('')

    if not blocking:
        print('PASS -- no cavity-rename leftovers outside the allowlist.')
        return 0

    rows = blocking

    print('FAIL -- %d file%s still carry the old cavity identifier '
          '(%d occurrence%s).\n'
          % (len(rows), '' if len(rows) == 1 else 's',
             sum(r['total'] for r in rows),
             '' if sum(r['total'] for r in rows) == 1 else 's'))

    prior = None
    if os.path.exists(BASELINE):
        try:
            prior = json.loads(read(BASELINE))
        except ValueError:
            prior = None

    for r in rows:
        detail = ', '.join('%s x%d' % (t, n) for t, n in sorted(r['hits'].items()))
        print('  %-64s %s' % (r['path'], detail))

    if prior:
        done = prior['occurrences'] - sum(r['total'] for r in rows)
        pct = (100.0 * done / prior['occurrences']) if prior['occurrences'] else 0.0
        print('\nAgainst baseline: %d of %d occurrences cleared (%.0f%%).'
              % (done, prior['occurrences'], pct))
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mode', choices=('inventory', 'baseline', 'verify'),
                    default='inventory')
    args = ap.parse_args()

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(here)

    rows = collect()
    if args.mode == 'baseline':
        return do_baseline(rows)
    if args.mode == 'verify':
        return do_verify(rows)
    print_inventory(rows)
    return 0


if __name__ == '__main__':
    sys.exit(main())
