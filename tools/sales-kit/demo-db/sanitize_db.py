"""Rewrite customer-identifying text in MPP_MES_Demo using ../substitutions.json.

Usage: python -I sanitize_db.py [--server localhost]

Finds every text column holding a value the substitution rules change (via dump_text.py), reads
those columns' exact values (FOR JSON keeps line breaks, which ZPL label bodies contain), and
issues UPDATE ... WHERE <column> = <exact old value> per changed value. Word-boundary regexes, so
"AIM" is replaced and "claimed" is not -- the reason this is not a T-SQL REPLACE.
The icon-library path column is configuration, not displayed text, and is left alone.
"""
import argparse, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP_COLUMNS = {"Location.LocationTypeDefinition.Icon"}
DB = "MPP_MES_Demo"

ap = argparse.ArgumentParser()
ap.add_argument("--server", default="localhost")
a = ap.parse_args()

rules = [(re.compile(p), r) for p, r in json.load(open(os.path.join(HERE, "..", "substitutions.json"), encoding="utf-8"))["rules"]]


def apply(text):
    for p, r in rules:
        text = p.sub(r, text)
    return text


def sqlcmd(args):
    r = subprocess.run(["sqlcmd", "-S", a.server, "-E", "-C", "-I", "-b", "-d", DB, "-f", "65001"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("sqlcmd failed: " + r.stdout + r.stderr)
    return r


def lit(s):
    return "N'" + s.replace("'", "''") + "'"


with tempfile.TemporaryDirectory() as tmp:
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "dump_text.py"), "--db", DB, "--out", tmp, "--server", a.server], check=True, capture_output=True)
    cols = set()
    for line in open(os.path.join(tmp, "db_text.txt"), encoding="utf-8-sig"):
        col, _, val = line.rstrip("\n").partition("\t")
        if col not in SKIP_COLUMNS and apply(val) != val:
            cols.add(col)

    updates = []
    for col in sorted(cols):
        s, t, c = col.split(".")
        q = os.path.join(tmp, "q.sql")
        open(q, "w", encoding="utf-8").write(
            f"SET NOCOUNT ON; SELECT (SELECT DISTINCT CAST([{c}] AS NVARCHAR(MAX)) AS v FROM [{s}].[{t}] WHERE [{c}] IS NOT NULL FOR JSON PATH);")
        o = os.path.join(tmp, "q.out")
        sqlcmd(["-y", "0", "-i", q, "-o", o])   # -y 0: no 256-char column truncation
        raw = "".join(ln.strip("\r\n") for ln in open(o, encoding="utf-8-sig")
                      if ln.strip() and set(ln.strip()) != {"-"})
        for row in json.loads(raw or "[]"):
            old = row["v"]
            new = apply(old)
            if new != old:
                updates.append(f"UPDATE [{s}].[{t}] SET [{c}] = {lit(new)} WHERE CAST([{c}] AS NVARCHAR(MAX)) = {lit(old)};")

    if updates:
        u = os.path.join(tmp, "updates.sql")
        # newline="": the exact-match literals must keep the column's own line breaks (ZPL bodies use
        # bare LF); Windows text mode would turn them into CRLF and the WHERE would match nothing.
        open(u, "w", encoding="utf-8", newline="").write("SET NOCOUNT ON;\nSET XACT_ABORT ON;\nBEGIN TRANSACTION;\n" + "\n".join(updates) + "\nCOMMIT;\n")
        sqlcmd(["-i", u])
print(f"sanitize_db: {len(cols)} column(s), {len(updates)} value(s) rewritten")
