# -*- coding: utf-8 -*-
"""Fuse the Die Shots Report (part x die rows) with the die asset register
into one row per PHYSICAL DIE, with its cavities."""
import re, csv, json, os, sys
from collections import defaultdict, Counter
import openpyxl

# parsers/ -> seed_data/ -> reference/
REF = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REF, 'seed_data')

# ---------------------------------------------------------------- report
h = open(os.path.join(REF, 'Aug 17_ 2026 Die Shots Report.html'),
         encoding='utf-8', errors='replace').read()


def _cells(tr):
    cs = re.findall(r'<td.*?>(.*?)</td>', tr, re.S)
    return [re.sub(r'<[^>]+>', '', c).replace('&nbsp;', ' ').replace('&amp;', '&').strip()
            for c in cs]


rep = []
cust = None
for tr in re.findall(r'<tr.*?</tr>', h, re.S):
    c = _cells(tr)
    if len(c) == 1:
        cust = c[0]
    elif len(c) == 6 and c[0] != 'Status':
        m = re.match(r'(\d+-090)\.\s*(.*)$', c[1])
        rep.append(dict(customer=cust, status=c[0],
                        macola=m.group(1) if m else '',
                        partname=(m.group(2) if m else c[1]).strip(),
                        die=c[2], total=int(c[3]), good=int(c[4]), life=int(c[5])))

# ------------------------------------------------------- normalisation
ALIAS = {'5BAA': '5BA', '5BS': '5BA', '64AA': '64A', '6FBA': '6FB', '6MAA': '6MA',
         '5G0': '5GO', '5J6-1': '5J6', '5J6-A000': '5J6', '66VT': '66V',
         '6MDW': '6MD', 'RNOX': 'RNO'}
FAMS = ['5J6-A000', '5J6-1', '6MAA', '6FBA', '5BAA', '6MDW', '66VT', '64AA', 'SZAX',
        '5J6', '6MA', '6FB', '5BA', '5BS', '6MD', '66V', '64A', '5GO', '5G0', '59B',
        '5PA', 'RPY', '6NA', '6VJ', '6B2', '6GF', '4DOA', '5A2', '5K8', '5MH', '5LA',
        'RNOX', 'RNA', 'RNO', 'RXO', 'R1A', 'R5A', 'RDJ', 'PGE', 'P8A', 'R70']


def families(s):
    """Every part family named in a string, normalised, order preserved."""
    u = s.upper()
    found, used = [], []
    for f in FAMS:
        for m in re.finditer(re.escape(f), u):
            if any(m.start() < e and m.end() > b for b, e in used):
                continue
            used.append((m.start(), m.end()))
            n = ALIAS.get(f, f)
            if n not in found:
                found.append(n)
    return found


def family(s):
    f = families(s)
    return f[0] if f else None


COMP = [('OIL PASS', 'OilPassage'), ('OIL PAN', 'OilPan'), ('FUEL PUMP', 'FuelPump'),
        ('SIDE COVER', 'SideCover'), ('COMPRESSOR BRACKET', 'CompressorBracket'),
        ('COMP BRACKET', 'CompressorBracket'), ('MANIFOLD', 'IntakeManifold'),
        ('INNER HOUSING', 'InnerHousing'), ('INVERTER', 'InverterCover'),
        ('INTERMEDIATE', 'IntermediateCase'), ('HEAT SINK', 'HeatSink'),
        ('WATER PUMP', 'WaterPump'), ('ADAPTOR', 'Adaptor'), ('THERMO', 'ThermoCover'),
        ('HALF SHAFT', 'HalfShaftSupport'), ('HOLDER COMP', 'CamHolder'),
        ('HOLDCOMP', 'CamHolder'), ('CAM HOLDER', 'CamHolder'),
        ('CAMHOLDER', 'CamHolder'), ('C/H', 'CamHolder'), ('CAM', 'CamHolder')]


def component(s):
    u = s.upper()
    if re.search(r'R/S|RKR SHAFT|ROCKER SHAFT', u):
        return 'RockerShaft'
    for k, v in COMP:
        if k in u:
            return v
    return None


# MPP runs family dies as SETS -- e.g. a "#1,5" die and a "#2,3,4" die of the
# same generation letter. Both carry the same (family, component, letter) key,
# so the journal positions and the intake/exhaust axis are the only things that
# tell them apart.
def _strip_families(s):
    u = s.upper()
    for f in FAMS:
        u = u.replace(f, ' ')
    return u


def positions(s):
    """Journal / cylinder positions named in a die or part description."""
    u = _strip_families(s)
    u = re.sub(r'\(DC\)|\bDC\b|\bMPP\b', ' ', u)
    out = set()
    for a, b in re.findall(r'(\d)\s*-\s*(\d)', u):        # "1-4" -> 1,2,3,4
        if int(a) < int(b):
            out.update(range(int(a), int(b) + 1))
    u = re.sub(r'\d\s*-\s*\d', ' ', u)
    for m in re.findall(r'\d+', u):
        if len(m) == 1:                                   # positions are 1..9
            out.add(int(m))
    return out


def axes(s):
    """Which cam bank(s) a die or part belongs to: IN / EX / EXLWR."""
    u = s.upper()
    out = set()
    if re.search(r'\bLWR\b|\bLOWER\b', u):
        out.add('EXLWR')
    if re.search(r'\bEX\b|\bEX\.|EXH|EXHAUST|/EX', u):
        out.add('EXLWR' if 'EXLWR' in out and len(out) == 1 else 'EX')
    if re.search(r'\bIN\b|\bIN\.|INTAKE|IN/', u):
        out.add('IN')
    return out


def part_axis(name):
    u = name.upper()
    if re.search(r'LWR|LOWER', u):
        return 'EXLWR'
    if re.search(r'\bEX\b|EXH|EXHAUST', u):
        return 'EX'
    if re.search(r'\bIN\b|INTAKE|IN CAM', u):
        return 'IN'
    return None


def variant(s):
    """Astemo / Hitachi dies are distinguished by Single vs Dual, not position."""
    u = s.upper()
    if 'DUAL' in u:
        return 'DUAL'
    if 'SINGLE' in u:
        return 'SINGLE'
    return None


# ------------------------------------------ cluster report rows -> dies
# A physical die = one cluster of near-identical shot counts inside a
# (family, component, die-letter) bucket. Near-identical because the legacy
# counters are per (part, die) row and drift a few hundred counts apart.
buckets = defaultdict(list)
for r in rep:
    r['family'] = family(r['partname'])
    r['component'] = component(r['partname'])
    buckets[(r['family'], r['component'], r['die'].upper())].append(r)

TOL = 0.02          # observed drift < 0.5%; campaign splits are > 50%
dies = []
for (fam, comp, dl), rows in buckets.items():
    rows.sort(key=lambda x: x['total'])
    clusters = []
    for r in rows:
        placed = False
        for cl in clusters:
            ref = cl[0]['total']
            if abs(r['total'] - ref) <= max(5, ref * TOL):
                cl.append(r)
                placed = True
                break
        if not placed:
            clusters.append([r])
    for cl in clusters:
        sts = Counter(x['status'] for x in cl).most_common()
        dies.append(dict(
            family=fam, component=comp, dieletter=dl, customer=cl[0]['customer'],
            status=sts[0][0], statusmixed=len(sts) > 1,
            total=max(x['total'] for x in cl),
            good=max(x['good'] for x in cl),
            life=max(x['life'] for x in cl),
            cavities=sorted({(x['macola'], x['partname']) for x in cl}),
            variant=next((variant(x['partname']) for x in cl if variant(x['partname'])), None),
            pos={p for x in cl for p in positions(x['partname'])},
            pairs={(part_axis(x['partname']), p)
                   for x in cl for p in positions(x['partname'])}))

# ------------------------------------------------------- asset register
wb = openpyxl.load_workbook(os.path.join(REF, "Copy of Asset #'s for Dies.xlsx"),
                            data_only=True)
VENDOR_FIX = {'accu-die': 'Accu-Die', 'accudie': 'Accu-Die', 'accu die': 'Accu-Die',
              'accu- die': 'Accu-Die', 'accudie-die': 'Accu-Die',
              'metts a die': 'Metts', 'davis': 'Davis Tool', 'davis tool': 'Davis Tool',
              'meiwa': 'Meiwa Mold', 'meiwa mold': 'Meiwa Mold',
              'meiwa mold international': 'Meiwa Mold', 'hanson': 'Hanson Int.',
              'hanson int.': 'Hanson Int.', 'hanson mold': 'Hanson Int.',
              'pedereson': 'Pederson Tool', 'pederson': 'Pederson Tool',
              'pederson tool': 'Pederson Tool', 'metts': 'Metts',
              'sunset tool': 'Sunset Tool', 'griffin tool': 'Griffin Tool',
              'mangas tool': 'Mangas Tool', 'hellebusch': 'Hellebusch'}


# The register's descriptions degrade over time -- later years drop the
# component word, the family, or both ("2,3,4 M"). These restate the handful
# that no general rule can recover; each was read off its neighbours in the
# same generation. Flagged in the note as register rows MPP should restate.
DESC_FIX = {
    'DM0087': '6MDW Intake Manifold trim #1',
    'DM0088': '5GO Rocker Shaft trim #1 (4 cavity)',
    'DM0089': 'RPY Rocker Shaft #1 die J',
    'DM0090': 'RPY Rocker Shaft #2,3,4 die J',
    'DM0095': '5J6-1 Oil Pan die L',
    'DM0097': '5J6-1 Oil Pan die L',
    'DM0099': '6B2 Rocker Shaft #5 die F',
    'DM0106': '59B/5PA Fuel Pump die V',
    'DM0108': '59B Cam Holder #2,3,4 die M',
    'DM0113': 'RPY Cam Holder Ex Lower 1,2,3,4 die H',
    'DM0114': 'RPY Cam Holder Ex 1,2,3,4 die H',
    'DM0115': 'Astemo Inner Housing die A',
    'DM0117': 'Astemo Intermediate Case Single die A',
    'DM0118': '5J6-1 Oil Pan die M',
    'DM0124': '6MA Cam Holder #1,5 die D',
    'DM0125': '6MA Cam Holder #2,3,4 die D',
    'DM0126': '6MA Oil Pan die E',
    'DM0130': '59B Cam Holder #2,3,4 die N',
    'DM0131': '5J6-1 Oil Pan die N',
    'DM0132': '64A Oil Pan die G',
    'DM0133': 'Astemo Intermediate Case Single die B',
    'DM0134': 'Astemo Inverter Cover Single die B',
    'DM0135': 'Astemo Inner Housing die B',
    'DM0139': 'RPY Rocker Shaft #5 die A',
    'DM0141': 'RPY Rocker Shaft #1 die K',
    'DM0142': 'RPY Rocker Shaft #2,3,4 die K',
    'DM0143': '5BA Rocker Shaft #5 die O',
    'DM0146': '6FB Cam Holder #1 die C',
    'DM0147': '6MA Cam Holder #1,5 die F',
    'DM0155': '64A Oil Pan die I',
    'DM0156': '6VJ Fuel Pump die E',
    'DM0160': '59B Cam Holder #1,2,3,4 die O',
    'DM0164': '5J6-1 Oil Pan die O',
    'DM0166': '6MA Cam Holder #1,5 die G',
    'DM0168': '4DOA Oil Pan die A',
    'DM0169': '6MDW Intake Manifold die C',
    'DM0170': '5GO Rocker Shaft die N (4 cavity)',
    'DM0067': 'RPY Cam Holder Ex #1-4 die G',
    'DM0073': 'RPY Cam Holder Ex Lower #1-4 die G',
    'DM0116': 'Astemo Inverter Cover Single die A',
    'DM0137': 'Astemo Inverter Cover Dual die A',
    'DM0138': 'Astemo Intermediate Case Dual die A',
    'DM0163': '6VJ Fuel Pump ejector insert',
    'DM0013': 'RPY Cam Holder Ex #1-4 die D',
}

NOISE = r'\b(DIE|DIES|CAVITY|CAV|TRIM|ONLY|DESIGN|PLATE|INSERT|EJECTOR|FOR|' \
        r'ORDERED|NO|COMP|COMP\.|HOLDER|SHAFT|ROCKER|RKR|CAM|OIL|PAN|PASSAGE|' \
        r'PASS|FUEL|PUMP|SIDE|COVER|BASE|SUPPORT|HALF|INNER|HOUSING|INVERTER|' \
        r'INTERMEDIATE|CASE|HEAT|SINK|WATER|ADAPTOR|THERMO|MANIFOLD|INTAKE|' \
        r'EXHAUST|COMPRESSOR|BRACKET|HITACHI|ASTEMO|SINGLE|DUAL|IN|EX|LWR|LOWER|' \
        r'INT|R/S|C/H)\b'


def dieletter(s):
    u = s.upper().replace('"', '').replace("'", '')
    u = re.sub(r'\(.*?\)', ' ', u)                       # drop parentheticals
    for pat in (r'\bDIE\s+([A-Z])\b', r'\b([A-Z])\s+DIE\b'):
        m = re.search(pat, u)
        if m:
            return m.group(1)
    # otherwise: strip everything that is not the generation letter and see
    # what single letter is left standing
    t = _strip_families(u)
    t = re.sub(NOISE, ' ', t)
    t = re.sub(r'[#,\.\-/0-9]', ' ', t)
    left = [w for w in t.split() if len(w) == 1 and w.isalpha()]
    if left:
        return left[-1]
    m = re.search(r'#\s*([A-Z])\b', u)
    return m.group(1) if m else None


assets = []
for sheet, kind in (('Die Mold', 'DieMold'), ('Trim Die', 'TrimDie')):
    for row in wb[sheet].iter_rows(min_row=2, values_only=True):
        tag, desc, ven, dt = row[0], row[1], row[2], row[3]
        if not tag or not desc:
            continue
        raw = str(desc).strip()
        d = DESC_FIX.get(str(tag).strip(), raw)
        k = 'TrimDie' if 'trim' in d.lower() else kind
        assets.append(dict(tag=tag, desc=d, raw=raw, kind=k,
                           restated=d != raw,
                           vendor=VENDOR_FIX.get(str(ven or '').strip().lower(),
                                                 str(ven or '').strip()),
                           acquired=dt.date().isoformat() if hasattr(dt, 'date') else '',
                           families=families(d), component=component(d),
                           dieletter=None if k == 'TrimDie' else dieletter(d),
                           variant=variant(d)))

# ------------------------------------------------------------ the join
byfcd = defaultdict(list)
for i, d in enumerate(dies):
    byfcd[(d['family'], d['component'], d['dieletter'])].append(i)

def pick(a, cands):
    """Choose which cluster(s) of one (family, component, letter) key belong to
    this asset. Several clusters on one key means MPP runs a die SET -- pick the
    one whose journal positions / cam bank match the asset's description."""
    if len(cands) <= 1:
        return cands
    if a['variant'] and any(dies[i]['variant'] for i in cands):
        v = [i for i in cands if dies[i]['variant'] == a['variant']]
        if v:
            return v
    posed = [i for i in cands if dies[i]['pos']]
    if len(posed) < 2:
        return cands                       # nothing to disambiguate on
    apos, aax = positions(a['desc']), axes(a['desc'])
    if not apos:
        return cands                       # asset names no position -- combo die
    apairs = {(x, p) for x in (aax or {None}) for p in apos}
    best, bestscore = [], 0.0
    for i in cands:
        d = dies[i]
        if aax and d['pairs'] and all(ax for ax, _ in d['pairs']):
            score = len(d['pairs'] & apairs) / float(len(d['pairs']))
        else:
            score = (len(d['pos'] & apos) / float(len(d['pos']))) if d['pos'] else 0.0
        if score > bestscore + 1e-9:
            best, bestscore = [i], score
        elif abs(score - bestscore) < 1e-9 and score > 0:
            best.append(i)
    return best if bestscore >= 0.5 else cands


used = set()
for a in assets:
    a['matches'] = []
    a['ambiguous'] = False
    if not (a['component'] and a['dieletter']):
        continue
    for f in (a['families'] or [None]):
        cands = byfcd.get((f, a['component'], a['dieletter']), [])
        chosen = pick(a, cands)
        if len(cands) > 1 and len(chosen) > 1:
            a['ambiguous'] = True
        for i in chosen:
            if i not in a['matches']:
                a['matches'].append(i)
            used.add(i)

# ------------------------------------------------------------- emit
STATUS = {'C': 'Current', 'B': 'Backup', 'W': 'Waiting for Approval',
          'A': 'Approved', 'O': 'OutSourced'}


def over(d):
    return d['status'] != 'B' and d['good'] > d['life']


recs = []
for a in assets:
    ms = [dies[i] for i in a['matches']]
    if ms:
        cav = sorted({c for m in ms for c in m['cavities']})
        recs.append(dict(
            AssetTag=a['tag'], ToolKind=a['kind'], Description=a['desc'],
            Family='/'.join(a['families']), Component=a['component'] or '',
            DieGeneration=a['dieletter'] or '',
            Status=ms[0]['status'], StatusName=STATUS.get(ms[0]['status'], ''),
            Customer=ms[0]['customer'],
            CavityCount=len(cav),
            Cavities='; '.join('%s %s' % c for c in cav),
            MacolaParts=','.join(sorted({c[0] for c in cav})),
            TotalShots=sum(m['total'] for m in ms),
            GoodShots=sum(m['good'] for m in ms),
            ShotLifePlanned=max(m['life'] for m in ms),
            OverPlannedLife='YES' if any(over(m) for m in ms) else '',
            Restated=a['raw'] if a['restated'] else '',
            Vendor=a['vendor'], Acquired=a['acquired'], Source='asset+report',
            Note=('AMBIGUOUS - could not tell which die of the set; %d entries merged'
                  % len(ms)) if a['ambiguous'] else
                 (('combo die - %d report entries summed' % len(ms)) if len(ms) > 1 else '')))
    else:
        recs.append(dict(
            AssetTag=a['tag'], ToolKind=a['kind'], Description=a['desc'],
            Family='/'.join(a['families']), Component=a['component'] or '',
            DieGeneration=a['dieletter'] or '',
            Status='', StatusName='Not in shots report', Customer='',
            CavityCount='', Cavities='', MacolaParts='',
            TotalShots='', GoodShots='', ShotLifePlanned='', OverPlannedLife='',
            Restated=a['raw'] if a['restated'] else '',
            Vendor=a['vendor'], Acquired=a['acquired'], Source='asset only',
            Note=('trim die - the shots report covers die-cast dies only'
                  if a['kind'] == 'TrimDie'
                  else 'no matching die in the shots report (retired, or naming mismatch)')))

for i, d in enumerate(dies):
    if i in used:
        continue
    recs.append(dict(
        AssetTag='', ToolKind='DieMold',
        Description='%s -- die %s' % (
            d['cavities'][0][1] if d['cavities'] else (d['component'] or 'unknown'),
            d['dieletter']),
        Family=d['family'] or '', Component=d['component'] or '',
        DieGeneration=d['dieletter'], Status=d['status'],
        StatusName=STATUS.get(d['status'], ''), Customer=d['customer'],
        CavityCount=len(d['cavities']),
        Cavities='; '.join('%s %s' % c for c in d['cavities']),
        MacolaParts=','.join(sorted({c[0] for c in d['cavities']})),
        TotalShots=d['total'], GoodShots=d['good'], ShotLifePlanned=d['life'],
        OverPlannedLife='YES' if over(d) else '',
        Restated='', Vendor='', Acquired='', Source='report only',
        Note='NO ASSET NUMBER - customer-owned/consigned, or pre-2019'))

cols = ['AssetTag', 'ToolKind', 'Status', 'StatusName', 'Description', 'Family',
        'Component', 'DieGeneration', 'Customer', 'CavityCount', 'MacolaParts',
        'Cavities', 'TotalShots', 'GoodShots', 'ShotLifePlanned', 'OverPlannedLife',
        'Restated', 'Vendor', 'Acquired', 'Source', 'Note']
with open(os.path.join(OUT, 'die_roster.csv'), 'w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=cols)
    w.writeheader()
    w.writerows(recs)

cavrows = []
for r in recs:
    if not r['Cavities']:
        continue
    for n, c in enumerate(r['Cavities'].split('; ')):
        mm = re.match(r'(\d+-090)\s+(.*)$', c)
        cavrows.append(dict(AssetTag=r['AssetTag'], Description=r['Description'],
                            Status=r['Status'], CavityCode=chr(ord('a') + n),
                            MacolaPart=mm.group(1) if mm else '',
                            PartName=mm.group(2) if mm else c))
with open(os.path.join(OUT, 'die_cavities.csv'), 'w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=['AssetTag', 'Description', 'Status', 'CavityCode',
                                      'MacolaPart', 'PartName'])
    w.writeheader()
    w.writerows(cavrows)

print('physical dies clustered from report : %d' % len(dies))
print('asset rows                          : %d' % len(assets))
print('roster rows                         : %d' % len(recs))
print('  asset+report : %d' % sum(1 for r in recs if r['Source'] == 'asset+report'))
print('  asset only   : %d' % sum(1 for r in recs if r['Source'] == 'asset only'))
print('  report only  : %d' % sum(1 for r in recs if r['Source'] == 'report only'))
print('cavity rows                         : %d' % len(cavrows))
print()
print('by status:', Counter(r['StatusName'] for r in recs).most_common())
print('cavity counts:', Counter(r['CavityCount'] for r in recs if r['CavityCount']).most_common())
