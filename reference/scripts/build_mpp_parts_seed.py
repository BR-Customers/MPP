#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
build_mpp_parts_seed.py
=======================
Emits sql/scratch/seed_mpp_parts.sql from the REVIEWED workbook
reference/MPP_Seed_Layout_Proposal.xlsx (itself built by
build_seed_layout_proposal.py from the customer's MPP_Part_Data_Final.xlsx).

The workbook is the single source of truth: edit it (or the upstream builder)
and re-run this, never hand-edit the emitted SQL.

Emitted SQL follows sql/seeds/020_seed_items.sql + 029_seed_item_routes.sql:
  * idempotent - IF NOT EXISTS / NOT EXISTS on natural keys (PartNumber, Code),
    never a hardcoded Id, so it is safe to re-run over MPP_MES_Dev in place.
  * ASCII-only string literals (sqlcmd reads .sql in the Windows codepage, so a
    non-ASCII byte lands in the DB as mojibake). Asserted below, not assumed.
  * set-based via table variables, so no per-entity GO/DECLARE churn.
  * routes resolve the OperationTemplate BY OperationType ROLE, matching 029.
"""
import os
import sys
import warnings

warnings.filterwarnings('ignore')
import openpyxl

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'reference', 'MPP_Seed_Layout_Proposal.xlsx')
OUT = os.path.join(ROOT, 'sql', 'scratch', 'seed_mpp_parts.sql')

wb = openpyxl.load_workbook(SRC, data_only=True)


def tab(name):
    ws, rows = wb[name], []
    for r in ws.iter_rows(min_row=2, values_only=True):
        if any(x is not None and str(x).strip() for x in r):
            rows.append(['' if x is None else str(x).strip() for x in r])
    return rows


ITEMS, ELIG, ROUTES, BOMS, PACK = (tab('Items'), tab('Eligibility'), tab('Routes'),
                                   tab('BOMs'), tab('Packaging'))

BAD = []


def q(s):
    """Single-quoted SQL literal, ASCII-verified."""
    s = '' if s is None else str(s)
    try:
        s.encode('ascii')
    except UnicodeEncodeError:
        BAD.append(s)
    return "N'" + s.replace("'", "''") + "'"


def num(s):
    s = ('' if s is None else str(s)).strip()
    if not s or s.upper() in ('N/A', 'NA', '-', 'NONE'):
        return 'NULL'
    try:
        f = float(s)
    except ValueError:
        return 'NULL'
    return str(int(f)) if f == int(f) else repr(f)


L = []
A = L.append

A("""-- ============================================================
-- Seed:        seed_mpp_parts.sql   (GENERATED - edit reference/scripts/build_mpp_parts_seed.py)
-- Author:      Blue Ridge Automation
-- Date:        2026-08-12
-- Description: The REAL MPP part list, transformed from the customer-returned
--              reference/MPP_Part_Data_Final.xlsx via
--              reference/MPP_Seed_Layout_Proposal.xlsx (the reviewed layout).
--
--              Lives in sql/scratch/ (NOT sql/seeds/) for now: it is a first
--              load pending MPP's answers to the HIGH-severity items on the
--              workbook's DataIssues tab, and dropping 150+ items into every
--              Reset-DevDatabase / test-DB build before then would destabilise
--              the suite. Promote to sql/seeds/032_* once the data is settled.
--
--              Fully idempotent - re-running inserts nothing twice. Part numbers
--              already present from 020_seed_items.sql (the 13-part demo matrix)
--              are LEFT ALONE, not overwritten.
--
--              Dependencies: 011 (plant Location tree), 004 (ItemType/Uom),
--              022/024/026/027 (one active OperationTemplate per role).
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
IF @Dev IS NULL
BEGIN
    RAISERROR(N'seed_mpp_parts: no AppUser with Initials DEV - run 020_seed_items.sql first.', 16, 1);
    RETURN;
END
""")

# ---------------- Items ----------------
# Items columns: 0 PN, 1 Desc, 2 ProposedType, 3 MPPType, 4 ProcClass, 5 Program,
#                6 Uom, 7 UnitWeight, 8 WeightUom, 9 MaxLotSize, 10 SubLotQty,
#                11 Macola, 12 Src, 13 Active, 14 Lines, 15 Status, 16 Notes
A("""
-- ============================================================
-- Parts.Item
-- ============================================================
DECLARE @I TABLE (Pn NVARCHAR(50), Descr NVARCHAR(500), TypeCode NVARCHAR(30),
                  UomCode NVARCHAR(10), MaxLot INT, SubLot INT, Macola NVARCHAR(50));
INSERT INTO @I (Pn, Descr, TypeCode, UomCode, MaxLot, SubLot, Macola) VALUES""")
vals = []
for r in ITEMS:
    vals.append(' (%s, %s, %s, %s, %s, %s, %s)' % (
        q(r[0]), q(r[1]), q(r[2]), q(r[6] or 'EA'), num(r[9]), num(r[10]),
        q(r[11]) if r[11] else 'NULL'))
A(',\n'.join(vals) + ';')
A("""
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber,
                        DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
SELECT t.Id, i.Pn, i.Descr, i.Macola, i.SubLot, i.MaxLot, u.Id, SYSUTCDATETIME(), @Dev
FROM @I i
JOIN Parts.ItemType t ON t.Code = i.TypeCode
JOIN Parts.Uom      u ON u.Code = i.UomCode
WHERE NOT EXISTS (SELECT 1 FROM Parts.Item x WHERE x.PartNumber = i.Pn);
PRINT 'seed_mpp_parts: Parts.Item  -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';
GO
""")

# ---------------- ContainerConfig ----------------
# Packaging cols: 0 PN,1 Desc,2 Trays,3 PerTray,4 Ser,5 Closure,6 TgtWt,7 Dunnage,8 Cust,9 raw
A("""DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
-- ============================================================
-- Parts.ContainerConfig -- one active config per finished good.
-- ============================================================
DECLARE @C TABLE (Pn NVARCHAR(50), Trays INT, PerTray INT, Ser BIT,
                  Closure NVARCHAR(20), TgtWt DECIMAL(10,4),
                  Dunnage NVARCHAR(50), Cust NVARCHAR(50));
INSERT INTO @C (Pn, Trays, PerTray, Ser, Closure, TgtWt, Dunnage, Cust) VALUES""")
vals = []
for r in PACK:
    vals.append(' (%s, %s, %s, %s, %s, %s, %s, %s)' % (
        q(r[0]), num(r[2]), num(r[3]), num(r[4]) if r[4] != '' else '0',
        q(r[5]) if r[5] else 'NULL', num(r[6]),
        q(r[7]) if r[7] else 'NULL', q(r[8]) if r[8] else 'NULL'))
A(',\n'.join(vals) + ';')
A("""
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
                                   DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
SELECT i.Id, c.Trays, c.PerTray, c.Ser, c.Dunnage, c.Cust, c.Closure, c.TgtWt, SYSUTCDATETIME()
FROM @C c
JOIN Parts.Item i ON i.PartNumber = c.Pn
WHERE NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig x
                  WHERE x.ItemId = i.Id AND x.DeprecatedAt IS NULL);
PRINT 'seed_mpp_parts: ContainerConfig -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';
GO
""")

# ---------------- BOM ----------------
# BOMs cols: 0 Parent,1 PDesc,2 Child,3 CDesc,4 Qty,5 Sort,6 Origin,7 Note
A("""DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
-- ============================================================
-- Parts.Bom + Parts.BomLine -- published v1 per assembled parent.
-- ============================================================
DECLARE @B TABLE (Parent NVARCHAR(50), Child NVARCHAR(50), Qty DECIMAL(18,4), Sort INT);
INSERT INTO @B (Parent, Child, Qty, Sort) VALUES""")
vals = []
for r in BOMS:
    vals.append(' (%s, %s, %s, %s)' % (q(r[0]), q(r[2]), num(r[4]) if num(r[4]) != 'NULL' else '1', num(r[5])))
A(',\n'.join(vals) + ';')
A("""
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
SELECT DISTINCT i.Id, 1, '2026-01-15', '2026-01-14', @Dev, SYSUTCDATETIME()
FROM @B b
JOIN Parts.Item i ON i.PartNumber = b.Parent
WHERE NOT EXISTS (SELECT 1 FROM Parts.Bom x WHERE x.ParentItemId = i.Id AND x.VersionNumber = 1);
PRINT 'seed_mpp_parts: Parts.Bom   -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';

INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
SELECT bm.Id, c.Id, b.Qty, c.UomId, b.Sort
FROM @B b
JOIN Parts.Item p  ON p.PartNumber = b.Parent
JOIN Parts.Bom  bm ON bm.ParentItemId = p.Id AND bm.VersionNumber = 1
JOIN Parts.Item c  ON c.PartNumber = b.Child
WHERE NOT EXISTS (SELECT 1 FROM Parts.BomLine x WHERE x.BomId = bm.Id AND x.ChildItemId = c.Id);
PRINT 'seed_mpp_parts: BomLine     -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';
GO
""")

# ---------------- Eligibility ----------------
# Elig cols: 0 PN,1 LocCode,2 LocName,3 Tier,4 IsConsumptionPoint,5 Why
A("""-- ============================================================
-- Parts.ItemLocation -- eligibility. A LocationCode that resolves to no row is
-- silently skipped (the JOIN yields nothing), matching 020_seed_items.sql.
-- ============================================================
DECLARE @L TABLE (Pn NVARCHAR(50), Lc NVARCHAR(50), Cp BIT);
INSERT INTO @L (Pn, Lc, Cp) VALUES""")
vals = []
seen = set()
for r in ELIG:
    k = (r[0], r[1])
    if k in seen:
        continue
    seen.add(k)
    vals.append(' (%s, %s, %s)' % (q(r[0]), q(r[1]), num(r[4]) if r[4] != '' else '0'))
A(',\n'.join(vals) + ';')
A("""
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT i.Id, l.Id, e.Cp, SYSUTCDATETIME()
FROM @L e
JOIN Parts.Item i        ON i.PartNumber = e.Pn
JOIN Location.Location l ON l.Code = e.Lc
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation x
                  WHERE x.ItemId = i.Id AND x.LocationId = l.Id AND x.DeprecatedAt IS NULL);
PRINT 'seed_mpp_parts: ItemLocation-> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';
GO
""")

# ---------------- Routes ----------------
# Routes cols: 0 PN,1 RouteName,2 Seq,3 Role,4 StepDesc,5 Mints
A("""DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
-- ============================================================
-- Parts.RouteTemplate + Parts.RouteStep -- published v1.
-- Steps bind the OperationTemplate BY OperationType ROLE (never by template
-- code), exactly as 029_seed_item_routes.sql does.
-- ============================================================
DECLARE @S TABLE (Pn NVARCHAR(50), Nm NVARCHAR(120), Seq INT, Role NVARCHAR(30), Descr NVARCHAR(120));
INSERT INTO @S (Pn, Nm, Seq, Role, Descr) VALUES""")
vals = []
for r in ROUTES:
    vals.append(' (%s, %s, %s, %s, %s)' % (q(r[0]), q(r[1][:120]), num(r[2]), q(r[3]), q(r[4][:120])))
A(',\n'.join(vals) + ';')
A("""
INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt,
                                 DeprecatedAt, CreatedByUserId, CreatedAt)
SELECT DISTINCT i.Id, 1, s.Nm, '2026-01-15', '2026-01-14', NULL, @Dev, SYSUTCDATETIME()
FROM @S s
JOIN Parts.Item i ON i.PartNumber = s.Pn
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt WHERE rt.ItemId = i.Id AND rt.VersionNumber = 1);
PRINT 'seed_mpp_parts: RouteTemplate -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';

INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
SELECT rt.Id, op.Id, s.Seq, 1, s.Descr
FROM @S s
JOIN Parts.Item i          ON i.PartNumber = s.Pn
JOIN Parts.RouteTemplate rt ON rt.ItemId = i.Id AND rt.VersionNumber = 1
CROSS APPLY (
    SELECT TOP 1 o.Id
    FROM Parts.OperationTemplate o
    JOIN Parts.OperationType oty ON oty.Id = o.OperationTypeId
    WHERE oty.Code = s.Role AND o.DeprecatedAt IS NULL
    ORDER BY o.Id
) op
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteStep x
                  WHERE x.RouteTemplateId = rt.Id AND x.SequenceNumber = s.Seq);
PRINT 'seed_mpp_parts: RouteStep     -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';
GO

PRINT 'seed_mpp_parts: done.';
GO
""")

if BAD:
    sys.exit('ABORT: %d non-ASCII literal(s), first: %r' % (len(BAD), BAD[0]))

sql = '\n'.join(L)
sql.encode('ascii')                       # hard gate: the whole file must be ASCII
with open(OUT, 'wb') as fh:               # bytes, so no BOM and no CRLF surprises
    fh.write(sql.replace('\r\n', '\n').encode('ascii'))
print('Wrote %s (%d bytes)' % (OUT, len(sql)))
print('  items=%d containerConfigs=%d bomLines=%d eligibility=%d routeSteps=%d'
      % (len(ITEMS), len(PACK), len(BOMS), len(seen), len(ROUTES)))
