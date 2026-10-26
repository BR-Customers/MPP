"""Dump every text value in a database, for the sales-kit sanitized gate.

Usage: python -I dump_text.py --db MPP_MES_Demo --out <folder> [--server localhost]

Lists every char / varchar / nchar / nvarchar / text / ntext column of every user table and writes
one line per distinct non-null value:  schema.table.column<TAB>value  (newlines folded to spaces)
to <folder>/db_text.txt. Then run check_terms.py on <folder>.
"""
import argparse, os, subprocess, sys, tempfile

ap = argparse.ArgumentParser()
ap.add_argument("--db", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--server", default="localhost")
a = ap.parse_args()
if a.db != "MPP_MES_Demo":
    sys.exit("dump_text: only dumps MPP_MES_Demo")


def sqlcmd(query_file, out_file):
    r = subprocess.run(["sqlcmd", "-S", a.server, "-E", "-C", "-I", "-b", "-d", a.db, "-y", "0",
                        "-f", "65001", "-i", query_file, "-o", out_file], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("sqlcmd failed: " + r.stdout + r.stderr)


os.makedirs(a.out, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    list_sql = os.path.join(tmp, "cols.sql")
    with open(list_sql, "w", encoding="utf-8") as f:
        f.write("SET NOCOUNT ON;\n"
                "SELECT c.TABLE_SCHEMA + '|' + c.TABLE_NAME + '|' + c.COLUMN_NAME\n"
                "FROM INFORMATION_SCHEMA.COLUMNS c JOIN INFORMATION_SCHEMA.TABLES t\n"
                "  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_TYPE = 'BASE TABLE'\n"
                "WHERE c.DATA_TYPE IN ('char','varchar','nchar','nvarchar','text','ntext')\n"
                "ORDER BY 1;\n")
    cols_out = os.path.join(tmp, "cols.txt")
    sqlcmd(list_sql, cols_out)
    cols = [ln.strip().split("|") for ln in open(cols_out, encoding="utf-8-sig") if ln.strip().count("|") == 2]

    dump_sql = os.path.join(tmp, "dump.sql")
    with open(dump_sql, "w", encoding="utf-8") as f:
        f.write("SET NOCOUNT ON;\n")
        for s, t, c in cols:
            label = f"{s}.{t}.{c}".replace("'", "''")
            f.write(f"SELECT DISTINCT N'{label}' + NCHAR(9) + REPLACE(REPLACE(CAST([{c}] AS NVARCHAR(MAX)), NCHAR(13), N' '), NCHAR(10), N' ') "
                    f"FROM [{s}].[{t}] WHERE [{c}] IS NOT NULL;\n")
    out_file = os.path.join(a.out, "db_text.txt")
    sqlcmd(dump_sql, out_file)

# -y 0 keeps long values whole but prints a blank header and a dash rule per result set: drop them.
lines = [ln for ln in open(out_file, encoding="utf-8-sig").read().splitlines() if ln.strip() and set(ln.strip()) != {"-"}]
open(out_file, "w", encoding="utf-8").write("\n".join(lines) + "\n")
n = len(lines)
print(f"{len(cols)} text column(s), {n} value line(s) -> {out_file}")
