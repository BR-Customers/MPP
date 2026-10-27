"""Tests for sanitize_pdf.py. Run: python -I test_sanitize_pdf.py"""
import os, subprocess, sys, tempfile
import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
SAN = os.path.join(HERE, "sanitize_pdf.py")
sys.path.insert(0, HERE)


def make_pdf(path, lines, author="jpotgieter", image_rect=None):
    doc = pymupdf.open()
    page = doc.new_page(width=612, height=792)
    y = 72
    for text in lines:
        page.insert_text((72, y), text, fontsize=11, fontname="helv")
        y += 20
    if image_rect:   # a "logo": a grey box with the customer name drawn into it
        r = pymupdf.Rect(*image_rect)
        page.draw_rect(r, color=(0.5, 0.5, 0.5), fill=(0.5, 0.5, 0.5))
        page.insert_text((r.x0 + 4, r.y0 + 14), "Madison Precision Products", fontsize=9, fontname="helv", color=(1, 1, 1))
    doc.set_metadata({"title": "Super-lot CR000001 - MPP", "author": author, "producer": "ReportMill", "creationDate": "D:20261027084900"})
    doc.save(path)


def run(src, out, *extra):
    return subprocess.run([sys.executable, "-I", SAN, "--in", src, "--out", out, *extra], capture_output=True, text=True)


def text_of(path):
    with pymupdf.open(path) as d:
        return "".join(p.get_text() for p in d)


def test_replaces_customer_name_and_passes_the_gate():
    with tempfile.TemporaryDirectory() as d:
        src, out = os.path.join(d, "raw.pdf"), os.path.join(d, "clean.pdf")
        make_pdf(src, ["Madison Precision Products", "Super-lot CR000001"])
        p = run(src, out)
        assert p.returncode == 0, p.stdout + p.stderr
        t = text_of(out)
        assert "Sample Components Co." in t, t
        assert "Madison" not in t and "Precision Products" not in t, t
        assert "CR000001" in t, t


def test_drops_the_date_keeps_the_time():
    with tempfile.TemporaryDirectory() as d:
        src, out = os.path.join(d, "raw.pdf"), os.path.join(d, "clean.pdf")
        make_pdf(src, ["Printed 10/27/26 08:49"])
        p = run(src, out)
        assert p.returncode == 0, p.stdout + p.stderr
        t = text_of(out)
        assert "08:49" in t and "10/27" not in t, t


def test_rewrites_metadata():
    with tempfile.TemporaryDirectory() as d:
        src, out = os.path.join(d, "raw.pdf"), os.path.join(d, "clean.pdf")
        make_pdf(src, ["Super-lot CR000001"])
        p = run(src, out)
        assert p.returncode == 0, p.stdout + p.stderr
        with pymupdf.open(out) as doc:
            m = doc.metadata
            assert m["author"] == "" and m["producer"] == "" and m["creationDate"] == "", m
            assert m["title"] == "Super-lot report", m
            assert not doc.get_xml_metadata(), doc.get_xml_metadata()


def test_cover_region_hides_a_logo():
    with tempfile.TemporaryDirectory() as d:
        src, out, png = os.path.join(d, "raw.pdf"), os.path.join(d, "clean.pdf"), os.path.join(d, "p1.png")
        make_pdf(src, ["Super-lot CR000001"], image_rect=(400, 40, 560, 70))
        p = run(src, out, "--png", png, "--cover", "400,40,560,70=Sample Components Co.")
        assert p.returncode == 0, p.stdout + p.stderr
        assert "Madison" not in text_of(out)
        pix = pymupdf.Pixmap(png)   # rendered at 2x: the region's left edge, mid-height, is white
        assert pix.pixel(int(402 * 2), int(55 * 2))[:3] == (255, 255, 255), pix.pixel(int(402 * 2), int(55 * 2))


def test_fails_when_a_banned_term_has_no_rule():
    with tempfile.TemporaryDirectory() as d:
        src, out = os.path.join(d, "raw.pdf"), os.path.join(d, "clean.pdf")
        make_pdf(src, ["Built with Flexware tooling"])
        p = run(src, out)
        assert p.returncode == 1, p.stdout + p.stderr
        assert "flexware" in (p.stdout + p.stderr).lower()


def test_banned_font_name_is_a_problem():
    import sanitize_pdf
    assert sanitize_pdf.font_problems([(5, "ttf", "TrueType", "ABCDEF+MadisonSans", "F1", "")]) == ["font ABCDEF+MadisonSans"]
    assert sanitize_pdf.font_problems([(5, "ttf", "TrueType", "ABCDEF+Helvetica", "F1", "")]) == []


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print("PASS", t.__name__)
        except Exception as e:
            failed += 1
            print("FAIL", t.__name__, "-", type(e).__name__, str(e)[:200])
    print(f"{len(tests) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
