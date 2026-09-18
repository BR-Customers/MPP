"""Port Jacques's prod-gateway Designer edits (prod export 2026-09-18 11:00) into HEAD views.
  * AssemblyNonSerialized: CameraPane subtree replaced wholesale by prod's (IFrame ia.display.iframe).
  * Tools: collapsible summary header (Icon + custom.DisplayDetails + row display bindings);
           FieldRowShotLimit keeps HEAD's Die-only rule AND the collapse.
  * OperatorEditor: defaultSize.height 500."""
import json, zipfile, sys, copy
sys.path.insert(0, 'tools'); from edit_tools_view_shot_count import dump
MPPZ = zipfile.ZipFile('reference/MPP_20260918110048.zip'); CFGZ = zipfile.ZipFile('reference/MPP_Config_20260918110052.zip')
PV = 'com.inductiveautomation.perspective/views/BlueRidge/'
def find(n, name):
    if isinstance(n, dict):
        if isinstance(n.get('meta'), dict) and n['meta'].get('name') == name: return n
        for v in n.values():
            h = find(v, name)
            if h is not None: return h
    elif isinstance(n, list):
        for v in n:
            h = find(v, name)
            if h is not None: return h
def write(p, raw, crlf):
    if crlf: raw = raw.replace('\r\n', '\n').replace('\n', '\r\n')
    open(p, 'wb').write(raw.encode('utf-8'))

# ---------- AssemblyNonSerialized: raw-text splice of the CameraPane object ----------
rel = PV + 'Views/ShopFloor/AssemblyNonSerialized/view.json'; p = 'ignition/projects/MPP/' + rel
raw = open(p, 'rb').read().decode('utf-8'); crlf = '\r\n' in raw; raw = raw.replace('\r\n', '\n')
key = '"name": "CameraPane"'; assert raw.count(key) == 1
k = raw.index(key)
def obj_start(s, pos):          # walk back to the '{' opening the node that contains "meta"
    depth = 0; i = s.rfind('"meta"', 0, pos)
    j = i
    while True:
        j -= 1
        c = s[j]
        if c == '}': depth += 1
        elif c == '{':
            if depth == 0: return j
            depth -= 1
def obj_end(s, start):
    depth, i, instr = 0, start, False
    while True:
        c = s[i]
        if instr:
            if c == chr(92): i += 2; continue
            if c == '"': instr = False
        elif c == '"': instr = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i + 1
        i += 1
a = obj_start(raw, k); b = obj_end(raw, a)
old = json.loads(raw[a:b]); assert old['meta']['name'] == 'CameraPane'
prodCP = find(json.loads(MPPZ.read(rel)), 'CameraPane')
indent = a - raw.rfind('\n', 0, a) - 1
new = dump(prodCP).replace('\n', '\n' + ' ' * indent)
raw2 = raw[:a] + new + raw[b:]
after = json.loads(raw2); assert find(after, 'CameraPane') == prodCP
bj = json.loads(raw); find(bj, 'CameraPane').clear(); find_a = json.loads(raw2); find(find_a, 'CameraPane').clear()
assert bj == find_a, 'something outside CameraPane changed'
write(p, raw2, crlf); print('AssemblyNonSerialized: CameraPane <- prod', [c['meta']['name'] for c in prodCP['children']])

# ---------- Tools ----------
rel = PV + 'Views/Parts/Tools/view.json'; p = 'ignition/projects/MPP_Config/' + rel
raw = open(p, 'rb').read().decode('utf-8'); crlf = '\r\n' in raw
v = json.loads(raw); prod = json.loads(CFGZ.read(rel))
v['propConfig']['custom.DisplayDetails'] = copy.deepcopy(prod['propConfig']['custom.DisplayDetails'])
v['custom']['DisplayDetails'] = True
sr = find(v, 'SummaryRow'); assert find(sr, 'Icon') is None
sr['children'].insert(0, copy.deepcopy(find(prod, 'Icon')))
for nm in ('FieldRowIdentity', 'FieldRowDescription'):
    find(v, nm).setdefault('propConfig', {})['position.display'] = copy.deepcopy(find(prod, nm)['propConfig']['position.display'])
lim = find(v, 'FieldRowShotLimit')['propConfig']['position.display']['binding']['config']
assert lim == {'expression': "{view.custom.editDraft.meta.ToolTypeCode} = 'Die'"}, lim
lim['expression'] = "{view.custom.DisplayDetails} && {view.custom.editDraft.meta.ToolTypeCode} = 'Die'"
write(p, dump(v) + '\n', crlf); print('Tools: summary header ported; ShotLimit =', lim['expression'])

# ---------- OperatorEditor ----------
rel = PV + 'Components/Popups/OperatorEditor/view.json'; p = 'ignition/projects/MPP_Config/' + rel
raw = open(p, 'rb').read().decode('utf-8'); crlf = '\r\n' in raw
v = json.loads(raw); assert v['props']['defaultSize']['height'] == 300
v['props']['defaultSize']['height'] = 500
write(p, dump(v) + '\n', crlf); print('OperatorEditor: height 500')
