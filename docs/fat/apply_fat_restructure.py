# apply_fat_restructure.py -- edits the CANONICAL FAT sources, then the workbook
# is regenerated with `node build_fat_workbook.js`. Never edits the .xlsx.
#
#   1. Merges 6 Environment tests that duplicate a downstream test; the survivor
#      inherits the retired test's FDS via the ';'-separated FDS field.
#   2. Relocates 8 tests to the sheet where their preconditions can exist.
#   3. Retargets the affected requirements' Area in fds_index.csv, because a
#      test only files under a banner if its FDS is indexed to that area.
#
# NOT done here, deliberately: the 34 rows dropped from the practice workbook.
# Those were N/A *for a code-inspection practice run* (no hardware, pre-cutover),
# not invalid tests -- e.g. FAT-DC-010/020 Die Cast Production Screen,
# FAT-TRIM-030/040/050 weight-based piece count. Deleting them from the canonical
# CSVs orphaned 16 in-scope requirements. They stay.

import csv, io, os, sys

FAT = os.path.dirname(os.path.abspath(__file__))
AREAS = os.path.join(FAT, 'areas')
INDEX = os.path.join(FAT, 'fds_index.csv')

# --- 2. duplicate -> surviving downstream test that inherits its FDS ----------
MERGE = {
    'FAT-ENV-070': 'FAT-AUD-050',
    'FAT-ENV-130': 'FAT-USR-070',
    'FAT-ENV-140': 'FAT-USR-030',
    'FAT-ENV-150': 'FAT-USR-160',
    'FAT-ENV-160': 'FAT-USR-020',
    'FAT-ENV-180': 'FAT-LBL-150',
}

# --- 3. relocations: TestID -> destination area slug --------------------------
# Only requirements whose every test moves together are listed; a requirement
# has a single Area, so a test sharing its FDS with a stay-put sibling cannot
# be relocated without splitting the requirement.
MOVES = {
    'FAT-ENV-060': 'traceability',
    'FAT-ENV-110': 'plc-mapping',
    'FAT-ENV-120': 'plc-mapping',
    'FAT-ENV-170': 'labels',
    'FAT-CC-050':  'movements',
    'FAT-CC-060':  'movements',
    'FAT-PH-110':  'movements',
    'FAT-PH-120':  'movements',
}

# --- 4. requirement -> new area slug -----------------------------------------
REINDEX = {
    'FDS-01-005': 'traceability',
    'FDS-01-006': 'audit',
    'FDS-01-008': 'plc-mapping',
    'FDS-01-009': 'plc-mapping',
    'FDS-01-010': 'users',
    'FDS-01-011': 'users',
    'FDS-01-012': 'users',
    'FDS-01-014': 'labels',
    'FDS-03-014': 'movements',
    'FDS-03-019': 'movements',
    'FDS-03-020': 'movements',
}

# ENV-160 asserted TerminalLocationId; USR-020 did not. Keep the assertion.
USR020_SUFFIX = ('; the record also carries the TerminalLocationId of the acting '
                 'terminal, and system-triggered events are attributed to the system account')

FIELDS = ['TestID', 'FDS', 'Workflow', 'Precondition', 'Step',
          'Expected Result', 'Result', 'Witness', 'Date', 'Notes']


def load(slug):
    with io.open(os.path.join(AREAS, slug + '.csv'), encoding='utf-8', newline='') as fh:
        return list(csv.DictReader(fh))


def save(slug, rows):
    with io.open(os.path.join(AREAS, slug + '.csv'), 'w', encoding='utf-8', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS, lineterminator='\n')
        w.writeheader()
        for r in rows:
            w.writerow({k: (r.get(k) or '') for k in FIELDS})


slugs = [f[:-4] for f in sorted(os.listdir(AREAS)) if f.endswith('.csv')]
data = {s: load(s) for s in slugs}
index = {r['TestID'].strip(): s for s in slugs for r in data[s] if r.get('TestID')}

for t in list(MERGE) + list(MOVES):
    if t not in index:
        sys.exit('ABORT: %s not found in any area CSV' % t)
for t in MERGE.values():
    if t not in index:
        sys.exit('ABORT: merge target %s not found' % t)

# ---- 2. merges: survivor inherits the retired test's FDS --------------------
merged = []
for dup, keeper in MERGE.items():
    if dup not in index:
        continue
    dup_row = next(r for r in data[index[dup]] if r['TestID'].strip() == dup)
    dup_fds = (dup_row.get('FDS') or '').strip()
    keep_row = next(r for r in data[index[keeper]] if r['TestID'].strip() == keeper)
    ids = [x.strip() for x in (keep_row.get('FDS') or '').split(';') if x.strip()]
    if dup_fds and dup_fds not in ids:
        ids.append(dup_fds)
    keep_row['FDS'] = '; '.join(ids)
    if keeper == 'FAT-USR-020':
        cur = (keep_row.get('Expected Result') or '').rstrip(' .;')
        if 'TerminalLocationId' not in cur:
            keep_row['Expected Result'] = cur + USR020_SUFFIX
    data[index[dup]] = [r for r in data[index[dup]] if r['TestID'].strip() != dup]
    merged.append((dup, keeper, dup_fds))
index = {r['TestID'].strip(): s for s in slugs for r in data[s] if r.get('TestID')}

# ---- 3. relocations ---------------------------------------------------------
moved = []
for tid, dest in MOVES.items():
    if tid not in index:
        continue
    src = index[tid]
    row = next(r for r in data[src] if r['TestID'].strip() == tid)
    data[src] = [r for r in data[src] if r['TestID'].strip() != tid]
    data[dest].append(row)
    moved.append((tid, src, dest))

for s in slugs:
    save(s, data[s])

# ---- 4. retarget the requirements' Area ------------------------------------
with io.open(INDEX, encoding='utf-8', newline='') as fh:
    rdr = csv.DictReader(fh)
    idx_fields, idx_rows = rdr.fieldnames, list(rdr)
reindexed = []
for r in idx_rows:
    new = REINDEX.get((r.get('FDS') or '').strip())
    if new and r.get('Area') != new:
        reindexed.append((r['FDS'], r['Area'], new))
        r['Area'] = new
with io.open(INDEX, 'w', encoding='utf-8', newline='') as fh:
    w = csv.DictWriter(fh, fieldnames=idx_fields, lineterminator='\n')
    w.writeheader()
    w.writerows(idx_rows)

print('merged (%d):' % len(merged))
for d, k, f in merged:
    print('   %-14s -> %-14s (%s inherited)' % (d, k, f))
print('relocated (%d):' % len(moved))
for t, a, b in moved:
    print('   %-14s %-18s -> %s' % (t, a, b))
print('fds_index Area retargeted (%d):' % len(reindexed))
for f, a, b in reindexed:
    print('   %-12s %-18s -> %s' % (f, a, b))
print('remaining tests: %d' % sum(len(v) for v in data.values()))
