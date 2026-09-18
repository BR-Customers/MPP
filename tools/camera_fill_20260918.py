"""Assembly OUT camera: correct component + fill the available space (Jacques, 2026-09-18).

  * AssemblyNonSerialized: prod's sizing around the (already ported) CameraPane --
    TrayClosePanel grow 1 + gap 4px; TrayBody grow 1, no gap. These were the prod
    Designer edits that make the camera expand.
  * AssemblySerialized: VisionEmbed ia.display.inline-frame (props.url) ->
    ia.display.iframe (props.src), the same fix Jacques made on prod for the
    non-serialized screen; VisionEmbed and TrayPanel grow to fill the Body column.

Only the named subtrees are re-serialised (Designer/GSON escapes); asserts that
nothing outside them changes. One-off; re-running is a no-op check."""
import json, sys, copy
sys.path.insert(0, 'tools'); from edit_tools_view_shot_count import dump
BS = chr(92)
V = 'ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/'

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

def span(raw, name):
    key = '"name": "%s"' % name; assert raw.count(key) == 1, (name, raw.count(key))
    k = raw.index(key); i = raw.rfind('"meta"', 0, k); depth = 0; j = i
    while True:
        j -= 1
        if raw[j] == '}': depth += 1
        elif raw[j] == '{':
            if depth == 0: break
            depth -= 1
    a = j; depth = 0; i = a; instr = False
    while True:
        c = raw[i]
        if instr:
            if c == BS: i += 2; continue
            if c == '"': instr = False
        elif c == '"': instr = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return a, i + 1
        i += 1

def splice(path, name, mutate):
    raw = open(path, 'rb').read().decode('utf-8'); crlf = '\r\n' in raw; raw = raw.replace('\r\n', '\n')
    a, b = span(raw, name); node = json.loads(raw[a:b]); before = copy.deepcopy(node)
    mutate(node)
    if node == before: print('  %s: already applied' % name); return
    ind = a - raw.rfind('\n', 0, a) - 1
    out = raw[:a] + dump(node).replace('\n', '\n' + ' ' * ind) + raw[b:]
    x, y = json.loads(raw), json.loads(out); find(x, name).clear(); find(y, name).clear()
    assert x == y, 'change leaked outside ' + name
    if crlf: out = out.replace('\n', '\r\n')
    open(path, 'wb').write(out.encode('utf-8')); print('  %s: updated' % name)

def ans(tcp):
    tcp.setdefault('position', {})['grow'] = 1
    tcp['props']['style']['gap'] = '4px'
    tb = find(tcp, 'TrayBody')
    tb['position'] = {'grow': 1}
    tb['props'].get('style', {}).pop('gap', None)

def ser(tp):
    tp['position'] = {'grow': 1}
    ve = find(tp, 'VisionEmbed')
    assert ve['type'] in ('ia.display.inline-frame', 'ia.display.iframe')
    ve['type'] = 'ia.display.iframe'
    pc = ve.setdefault('propConfig', {})
    if 'props.url' in pc: pc['props.src'] = pc.pop('props.url')
    ve['position'] = {'basis': '360px', 'grow': 1}

print('AssemblyNonSerialized'); splice(V + 'AssemblyNonSerialized/view.json', 'TrayClosePanel', ans)
print('AssemblySerialized');    splice(V + 'AssemblySerialized/view.json', 'TrayPanel', ser)
