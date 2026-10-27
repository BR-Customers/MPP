"""Tests for sanitize.py. Run: python -I test_sanitize.py"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SAN = os.path.join(HERE, "sanitize.py")

PAGE = ('<html><head></head><body class="psc-root">'
        '<div data-component="ia.display.label" class="psc-mpp-header">MPP MES</div>'
        '<input placeholder="Scan the LTT" value="LTT 810220005">'
        '<span title="Honda audit query surface">Audit</span>'
        '<div style="display:none">Madison Facility</div>'
        '<p>Tom &amp; Jerry</p>'
        '</body></html>')
CSS = '.psc-x::after{content:"MPP MES"} @font-face{font-family:X;src:url(data:font/woff2;base64,AAAA)}'


def run(raw, extra=()):
    shots, caps = os.path.join(raw, "_shots"), os.path.join(raw, "_caps")
    p = subprocess.run([sys.executable, "-I", SAN, "--raw", raw, "--out-screens", shots, "--out-captures", caps, "--no-render", *extra],
                       capture_output=True, text=True)
    return p, caps


def fixture(d, page=PAGE, css=CSS):
    raw = os.path.join(d, "raw")
    os.makedirs(raw)
    json.dump({"w": 1904, "h": 882, "route": "/x", "html": page}, open(os.path.join(raw, "s1.json"), "w", encoding="utf-8"))
    open(os.path.join(raw, "bundle.css"), "w", encoding="utf-8").write(css)
    return raw


def test_replaces_text_attributes_hidden_and_css():
    with tempfile.TemporaryDirectory() as d:
        p, caps = run(fixture(d))
        assert p.returncode == 0, p.stdout + p.stderr
        html = json.load(open(os.path.join(caps, "s1.json"), encoding="utf-8"))["html"]
        css = open(os.path.join(caps, "bundle.css"), encoding="utf-8").read()
        assert "MES Track &amp; Trace" in html, html            # text node, HTML-escaped
        assert 'placeholder="Scan the LOT ticket"' in html, html
        assert 'value="LOT ticket 810220005"' in html, html
        assert 'title="customer audit query surface"' in html, html
        assert "Sample Components Plant" in html, html           # inside a hidden element
        assert "Tom &amp; Jerry" in html, html                   # existing entities untouched
        assert 'content:"MES Track & Trace"' in css, css


def test_renames_project_token_in_classes_and_css_consistently():
    with tempfile.TemporaryDirectory() as d:
        css = CSS + ' .psc-mpp-header{color:red} .psc-MPP\\/Card{margin:0}'
        page = PAGE.replace('<p>', '<div class="psc-MPP/Card x">c</div><div id="popup-mpp-elevation-modal">m</div><p>')
        p, caps = run(fixture(d, page=page, css=css))
        assert p.returncode == 0, p.stdout + p.stderr
        html = json.load(open(os.path.join(caps, "s1.json"), encoding="utf-8"))["html"]
        out_css = open(os.path.join(caps, "bundle.css"), encoding="utf-8").read()
        assert 'class="psc-app-header"' in html, html
        assert 'class="psc-APP/Card x"' in html, html
        assert 'id="popup-app-elevation-modal"' in html, html
        assert ".psc-app-header{color:red}" in out_css, out_css
        assert ".psc-APP\\/Card{margin:0}" in out_css, out_css
        assert 'data-component="ia.display.label"' in html, html


def test_popup_component_paths_renamed():
    with tempfile.TemporaryDirectory() as d:
        page = PAGE.replace('<p>', '<div data-component-path="Pmpp-initials.0:0">x</div><div data-component-path="C$0:1[0].0">y</div><p>')
        p, caps = run(fixture(d, page=page))
        assert p.returncode == 0, p.stdout + p.stderr
        html = json.load(open(os.path.join(caps, "s1.json"), encoding="utf-8"))["html"]
        assert 'data-component-path="Papp-initials.0:0"' in html, html
        assert 'data-component-path="C$0:1[0].0"' in html, html


def test_style_attribute_variables_renamed_like_the_css():
    with tempfile.TemporaryDirectory() as d:
        css = CSS + ' :root{--mpp-text-primary:#fff}'
        page = PAGE.replace('<p>', '<div style="color: var(--mpp-text-primary)">x</div><p>')
        p, caps = run(fixture(d, page=page, css=css))
        assert p.returncode == 0, p.stdout + p.stderr
        html = json.load(open(os.path.join(caps, "s1.json"), encoding="utf-8"))["html"]
        out_css = open(os.path.join(caps, "bundle.css"), encoding="utf-8").read()
        assert 'style="color: var(--app-text-primary)"' in html, html
        assert "--app-text-primary:#fff" in out_css, out_css


def test_session_panel_gateway_url_and_component_paths():
    with tempfile.TemporaryDirectory() as d:
        page = PAGE.replace('<p>', '<div class="detail-data">http://localhost:8088</div>'
                                   '<div data-component-path="C$0:0$0:1">y</div><p>')
        p, caps = run(fixture(d, page=page))
        assert p.returncode == 0, p.stdout + p.stderr
        html = json.load(open(os.path.join(caps, "s1.json"), encoding="utf-8"))["html"]
        assert "localhost" not in html, html
        assert 'data-component-path="C$0:0$0:1"' in html, html


def test_strips_css_comments():
    with tempfile.TemporaryDirectory() as d:
        css = CSS + ' /* trimmed 2026-09-15 for the plant */ .a{color:red}'
        p, caps = run(fixture(d, css=css))
        assert p.returncode == 0, p.stdout + p.stderr
        out_css = open(os.path.join(caps, "bundle.css"), encoding="utf-8").read()
        assert "2026" not in out_css and ".a{color:red}" in out_css, out_css

def test_drops_perspective_client_chrome():
    with tempfile.TemporaryDirectory() as d:
        page = PAGE.replace('<p>', '<div class="connection-banner banner-inactive"><div class="connection-message">No Connection</div></div>'
                                   '<div class="app-modal-wrapper no-print"><div><div>Session ID 98a2</div></div></div>'
                                   '<div class="center view-parent"><div>KEEP-ME</div></div><p>')
        p, caps = run(fixture(d, page=page))
        assert p.returncode == 0, p.stdout + p.stderr
        html = json.load(open(os.path.join(caps, "s1.json"), encoding="utf-8"))["html"]
        assert "No Connection" not in html and "Session ID" not in html, html
        assert "KEEP-ME" in html and "<p>Tom" in html, html


def test_strips_capture_dates_keeps_times_and_counts():
    with tempfile.TemporaryDirectory() as d:
        page = PAGE.replace("<p>", "<p>Tue Oct 27   8:52:18 AM</p><p>10/27/26 08:49</p><p>9m ago  ·  L. Brooks  ·  10/27 08:49</p>"
                                   "<p>First Shift - 10/27 (current)</p><p>Open boxes: FG-4100 12/48</p><p>")
        p, caps = run(fixture(d, page=page))
        assert p.returncode == 0, p.stdout + p.stderr
        out = json.load(open(os.path.join(caps, "s1.json"), encoding="utf-8"))["html"]
        for gone in ("Oct 27", "10/27"):
            assert gone not in out, out
        for kept in (">8:52:18 AM<", ">08:49<", "L. Brooks  ·  08:49", ">First Shift (current)<", "FG-4100 12/48"):
            assert kept in out, (kept, out)


def test_fails_on_password_value():
    # a login popup still open when a step was saved must never reach the kit with what was typed
    page = '<html><body><input type="text" value="jdoe"><input type="password" value="hunter2"></body></html>'
    with tempfile.TemporaryDirectory() as d:
        p, _ = run(fixture(d, page=page))
        assert p.returncode != 0, p.stdout
        assert "password input" in p.stdout, p.stdout


def test_fails_on_gateway_reference():
    with tempfile.TemporaryDirectory() as d:
        page = PAGE.replace("<p>", '<img src="http://localhost:8088/system/images/x.png"><p>')
        p, _ = run(fixture(d, page=page))
        assert p.returncode != 0, p.stdout
        assert "localhost" in p.stdout + p.stderr


def test_fails_on_leftover_customer_term():
    with tempfile.TemporaryDirectory() as d:
        page = PAGE.replace("<p>", "<p>Ships from Madison IN</p><p>")
        p, _ = run(fixture(d, page=page))
        assert p.returncode != 0, p.stdout
        assert "madison" in (p.stdout + p.stderr).lower()


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print("PASS", t.__name__)
        except AssertionError as e:
            failed += 1
            print("FAIL", t.__name__, "-", str(e)[:300])
    print(f"{len(tests) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
