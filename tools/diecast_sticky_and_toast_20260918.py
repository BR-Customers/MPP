"""Die cast 'sticky' state + duplicate toasts (Jacques, 2026-09-18). One-off; re-runnable.

1. DieCastBody: the per-press reset that only the press dropdown ran (applyCell)
   is extracted into customMethod resetForPress(), and a new custom.watchedCellId
   (bound to session.custom.cell.locationId) runs it from its onChange whenever
   the session's cell changes by ANY route. Perspective can hand back this view's
   previous state when an operator returns to the page (startup() does not run
   again), and other pages set session.custom.cell; the old press's rows,
   entries and reporting shift survived both.
2. DieCastBody + AimPoolConfig: remove their own 'mpp-toast' session handler.
   The shared bottom dock NotifyHost already handles every toast, so on these
   two screens every toast opened twice (prod too, since 06-17)."""
import json, sys
sys.path.insert(0, 'tools'); from edit_tools_view_shot_count import dump
BS = chr(92)
V = 'ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/'

def ordered_insert(d, key, val):
    items = list(d.items()); d.clear()
    placed = False
    for k, v in items:
        if not placed and k > key:
            d[key] = val; placed = True
        d[k] = v
    if not placed: d[key] = val

# ---------------- DieCastBody (round-trips byte-exact) ----------------
p = V + 'DieCastBody/view.json'
raw = open(p, 'rb').read().decode('utf-8'); crlf = '\r\n' in raw
v = json.loads(raw)
root = v['root']; methods = root['scripts']['customMethods']; handlers = root['scripts']['messageHandlers']
names = [m['name'] for m in methods]

MARK = '\tself.session.custom.cell = {"locationId": row.get("value"), "code": row.get("code") or "", "name": row.get("name") or ""}\n'
if 'resetForPress' not in names:
    ac = [m for m in methods if m['name'] == 'applyCell'][0]
    s = ac['script']; assert s.count(MARK) == 1
    head, tail = s.split(MARK)
    assert tail.strip().endswith('self.recomputeTotals()'), tail[-80:]
    ac['script'] = head + MARK + ('\t# The per-press reset lives in resetForPress(); custom.watchedCellId also\n'
                                  '\t# runs it when the cell changes by any other route.\n'
                                  '\tself.resetForPress()')
    reset = ('\t# Everything imperative on this screen belongs to ONE press. Called by\n'
             '\t# applyCell (press dropdown) and by custom.watchedCellId\'s onChange, which\n'
             '\t# fires whenever session.custom.cell changes by ANY route -- another page\n'
             '\t# setting its own cell, or Perspective handing this view back with its old\n'
             '\t# state when an operator returns (startup() does not run again then).\n'
             '\t# Idempotent: running it twice for one change is harmless.\n') + tail.lstrip('\n')
    methods.insert(names.index('applyCell') + 1, {'name': 'resetForPress', 'params': [], 'script': reset})
    print('DieCastBody: resetForPress extracted from applyCell')

if 'watchedCellId' not in v['custom']:
    ordered_insert(v['custom'], 'watchedCellId', None)
    ordered_insert(v['propConfig'], 'custom.watchedCellId', {
        'binding': {'config': {'path': 'session.custom.cell.locationId'}, 'type': 'property'},
        'onChange': {'enabled': True, 'script': (
            '\t# The session\'s cell changed (press dropdown, another page, or this view\n'
            '\t# being handed back on return). Start clean for the new press -- see\n'
            '\t# resetForPress. Skip the no-op evaluation where nothing changed.\n'
            '\tprev = previousValue.value if previousValue is not None else None\n'
            '\tcur = currentValue.value if currentValue is not None else None\n'
            '\tif prev == cur:\n'
            '\t\treturn\n'
            '\tself.rootContainer.resetForPress()')}})
    print('DieCastBody: custom.watchedCellId + onChange added')

before = len(handlers)
root['scripts']['messageHandlers'] = [h for h in handlers if h['messageType'] != 'mpp-toast']
print('DieCastBody: mpp-toast handlers removed:', before - len(root['scripts']['messageHandlers']))
out = dump(v) + '\n'
if crlf: out = out.replace('\n', '\r\n')
open(p, 'wb').write(out.encode('utf-8'))

# ---------------- AimPoolConfig: raw removal of the handler object ----------------
p = V + 'AimPoolConfig/view.json'
raw = open(p, 'rb').read().decode('utf-8'); crlf = '\r\n' in raw; s = raw.replace('\r\n', '\n')
key = '"messageType": "mpp-toast"'
if key in s:
    assert s.count(key) == 1
    k = s.index(key); a = s.rfind('{', 0, k)
    depth, i, instr = 0, a, False
    while True:
        c = s[i]
        if instr:
            if c == BS: i += 2; continue
            if c == '"': instr = False
        elif c == '"': instr = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: b = i + 1; break
        i += 1
    obj = json.loads(s[a:b]); assert obj['messageType'] == 'mpp-toast' and 'Notify._handle' in obj['script']
    before_j = json.loads(s)
    # take the separating comma with it (before if not first element, else after)
    pre = s[:a].rstrip(); post = s[b:]
    if pre.endswith(','):
        s2 = pre[:-1] + s[a - (len(s[:a]) - len(pre)) - 0:a][:0] + post
        s2 = s[:len(pre) - 1] + post
    else:
        post2 = post.lstrip()
        assert post2.startswith(','), 'unexpected layout'
        s2 = s[:a] + post2[1:].lstrip(' ')
    after_j = json.loads(s2)
    bh = before_j['root']['scripts']['messageHandlers']; ah = after_j['root']['scripts']['messageHandlers']
    assert [h for h in bh if h['messageType'] != 'mpp-toast'] == ah
    before_j['root']['scripts']['messageHandlers'] = ah; assert before_j == after_j
    if crlf: s2 = s2.replace('\n', '\r\n')
    open(p, 'wb').write(s2.encode('utf-8')); print('AimPoolConfig: mpp-toast handler removed')
else:
    print('AimPoolConfig: already removed')
