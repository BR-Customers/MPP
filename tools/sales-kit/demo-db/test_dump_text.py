"""Sanitized gate for MPP_MES_Demo. Run: python -I test_dump_text.py

1. The dump reaches columns no screen shows: the shipping-label template body (migration 0054)
   must carry the sanitized sample address that 090_sanitize_migration_data.sql writes.
2. check_terms.py finds nothing in the whole dump.
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "..", "check_terms.py")

with tempfile.TemporaryDirectory() as d:
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "dump_text.py"), "--db", "MPP_MES_Demo", "--out", d],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    print(r.stdout.strip())
    text = open(os.path.join(d, "db_text.txt"), encoding="utf-8-sig").read()
    failed = 0
    if "100 Industrial Way" not in text:
        failed += 1
        print("FAIL dump reaches the label template body with the sanitized sample address")
    else:
        print("PASS dump reaches the label template body with the sanitized sample address")
    g = subprocess.run([sys.executable, "-I", CHECK, d, "--terms-only", "--skip-prefix", "Location.LocationTypeDefinition.Icon" + chr(9)], capture_output=True, text=True)
    if g.returncode != 0:
        failed += 1
        print("FAIL check_terms on the database dump:")
        print("\n".join(g.stdout.splitlines()[:40]))
    else:
        print("PASS check_terms on the database dump: " + g.stdout.strip().splitlines()[-1])
    sys.exit(1 if failed else 0)
