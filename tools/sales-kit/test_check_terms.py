"""Tests for check_terms.py. Run: python -I test_check_terms.py"""
import os, subprocess, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "check_terms.py")


def run(folder):
    p = subprocess.run([sys.executable, "-I", CHECK, folder], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def write(folder, rel, text):
    path = os.path.join(folder, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def test_clean_folder_passes():
    with tempfile.TemporaryDirectory() as d:
        write(d, "hello.html", "<p>Sample plant</p>")
        code, out = run(d)
        assert code == 0, out


def test_flags_term_in_html():
    with tempfile.TemporaryDirectory() as d:
        write(d, "hello.html", "Ships to Honda")
        code, out = run(d)
        assert code == 1, out
        assert "honda" in out.lower(), out


def test_flags_term_inside_pptx_xml():
    with tempfile.TemporaryDirectory() as d:
        with zipfile.ZipFile(os.path.join(d, "x.pptx"), "w") as z:
            z.writestr("ppt/slides/slide1.xml", "<a:t>Built for MPP</a:t>")
        code, out = run(d)
        assert code == 1, out
        assert "slide1.xml" in out, out


def test_flags_iso_date():
    with tempfile.TemporaryDirectory() as d:
        write(d, "notes.md", "Released 2026-10-26")
        code, out = run(d)
        assert code == 1, out


def test_skips_node_modules():
    with tempfile.TemporaryDirectory() as d:
        write(d, "node_modules/pkg/index.js", "// honda")
        code, out = run(d)
        assert code == 0, out


def test_terms_only_ignores_dates():
    with tempfile.TemporaryDirectory() as d:
        write(d, "notes.md", "Released 2026-10-26")
        p = subprocess.run([sys.executable, "-I", CHECK, d, "--terms-only"], capture_output=True, text=True)
        assert p.returncode == 0, p.stdout
        write(d, "more.md", "Ships to Honda")
        p = subprocess.run([sys.executable, "-I", CHECK, d, "--terms-only"], capture_output=True, text=True)
        assert p.returncode == 1, p.stdout


def test_skip_column_lines():
    with tempfile.TemporaryDirectory() as d:
        write(d, "db_text.txt", "Location.LocationTypeDefinition.Icon\tmpp/account_balance\n")
        p = subprocess.run([sys.executable, "-I", CHECK, d, "--terms-only", "--skip-prefix", "Location.LocationTypeDefinition.Icon\t"], capture_output=True, text=True)
        assert p.returncode == 0, p.stdout


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print("PASS", t.__name__)
        except AssertionError as e:
            failed += 1
            print("FAIL", t.__name__, "-", str(e)[:200])
    print(f"{len(tests) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
