# IND570 Scale over Modbus TCP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the OmniServer ASCII scale link on the seven Machining/Assembly checkweigh scales with a native Ignition Modbus TCP connection to their METTLER TOLEDO IND570 terminals.

**Architecture:** The existing `ScaleStation` UDT keeps its name, parameters and 22 instance paths — only its member set changes, from the legacy `NET_*`/`TRG_*` names to folder-grouped members addressing IND570 holding registers. Two message slots: slot 1 permanently parked reporting net weight, slot 2 a command scratchpad for setpoint loads. The operator button reads live tags through a gate and calls the existing `Assembly.plcCompleteTray` path; nothing is latched in tags.

**Tech Stack:** SQL Server 2022 · Ignition 8.3 (Perspective, Jython 2.7, Modbus TCP driver) · Python 3 for the tag generator.

**Spec:** `docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md`

## Global Constraints

- **Branch:** `jacques/working`. Never commit to `main`.
- **Git staging:** stage explicit paths only. Never `git add -u` or `git add -A` — a concurrent user git operation will sweep unrelated files into the commit.
- **Commit trailer:** omit `Co-Authored-By: Claude`.
- **SQL conventions:** `UpperCamelCase` tables/columns, `DECIMAL` not `FLOAT`, `NVARCHAR` not `VARCHAR`, `DATETIME2(3)`. Follow `sql/scripts/_TEMPLATE_stored_procedure.sql`.
- **JDBC (FDS-11-011):** stored procedures SHALL NOT use `OUTPUT` parameters. Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message;`. One result set per proc.
- **Existing Ignition views are edited in the Designer, not on disk.** Designer's GSON serialization writes `=` `'` `<` `>` as 6-char unicode escapes and its in-memory model conflicts with on-disk changes. File edits are safe only for NEW views, Python scripts, named queries, SQL, and the tag JSON generator. Tasks 6 and 7 are therefore Designer tasks with written instructions, not file-edit tasks.
- **UDT JSON is generated, never hand-edited.** `ignition/tags/generate_tags.py` is the single source of truth for `udt/*.json`, `instances/PlcDevices.json` and `sim/MPP_Sim_program.csv`. Edit the generator and re-run it.
- **No business logic in Python.** Domain rules live in SQL. Protocol decode and command sequencing are not domain rules and correctly live in Jython.
- **Test DB:** `MPP_MES_Test` (throwaway). Never destructively reset `MPP_MES_Dev` — it holds Jacques's manually-created parts.
- **ASCII-only** in SQL seed/string values. `sqlcmd` reads `.sql` in the Windows codepage; em-dash and middle-dot become mojibake.

---

## Deviations from the spec — read before starting

Two, both discovered while mapping the spec onto the existing code. Confirm with Jacques before Task 3.

1. **The UDT keeps the name `ScaleStation`, not `IND570_Scale`.** The spec named it fresh, unaware that `ignition/tags/udt/ScaleStation.json` already exists with 7 scale instances inside `instances/PlcDevices.json` and matching `TerminalPlcDevice.UdtInstancePath` rows in the database (`[MPP]PlcDevices/<device>`). Renaming would require re-seeding those mappings for no benefit — the type name is protocol-agnostic. Members change; name, parameters and instance paths do not.

2. **Parameter names reuse the existing ones.** The spec proposed `DeviceName`; the type already has `Device`, `BasePath` and `OpcServer`, which serve the same purpose and are already set per instance. Only `WeightUom` is new.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `sql/migrations/versioned/0068_containerconfig_tolerance_weight.sql` | Adds `Parts.ContainerConfig.ToleranceWeight` | 1 |
| `sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql` | + `@ToleranceWeight` param | 1 |
| `sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql` | + `@ToleranceWeight` param | 1 |
| `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItem.sql` | + `ToleranceWeight` in SELECT | 1 |
| `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItemAndMethod.sql` | + `ToleranceWeight` in SELECT | 1 |
| `sql/tests/0008_Parts_Item/028_ContainerConfig_tolerance.sql` | Tests for the above | 1 |
| `ignition/tags/generate_tags.py` | Address-decoupled members + folder emission + `ScaleStation` rewrite | 2, 3 |
| `ignition/tags/udt/ScaleStation.json` | **Generated** | 3 |
| `ignition/tags/instances/PlcDevices.json` | **Generated** | 3 |
| `ignition/tags/sim/MPP_Sim_program.csv` | **Generated** | 3 |
| `.../BlueRidge/Workorder/Ind570/code.py` | **New.** Protocol layer: decode, command sequencer | 4 |
| `.../BlueRidge/Workorder/ScaleWatcher/code.py` | Rewritten: capture gate + tray close; edge handler removed | 5 |
| `.../ShopFloor/AssemblyNonSerialized/view.json` | **Designer only.** Capture button + setpoint push | 6, 7 |
| `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` | `@WeightValue` / `@WeightUomId` passthrough | 9 |
| `MPP_MES_DATA_MODEL.md`, `MPP_MES_FDS.md`, `MPP_MES_Open_Issues_Register.md` | Doc reconciliation | 8 |

Ignition script paths are under `ignition/projects/Core/ignition/script-python/`.

---

### Task 1: `ContainerConfig.ToleranceWeight` — column, procs, tests

The checkweigh window's half-width. FDS-06-014 describes `ByWeight` closure as "`TargetWeight` per tray (+ optional tolerance)" but the tolerance never reached the schema; legacy SparkMES carried it as `GroupTargetWeightTolerance`. Symmetric by decision — pushed to the terminal as both the + and the − tolerance.

**Files:**
- Create: `sql/migrations/versioned/0068_containerconfig_tolerance_weight.sql`
- Create: `sql/tests/0008_Parts_Item/028_ContainerConfig_tolerance.sql`
- Modify: `sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql`
- Modify: `sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql`
- Modify: `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItem.sql`
- Modify: `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItemAndMethod.sql`

**Interfaces:**
- Produces: `Parts.ContainerConfig.ToleranceWeight DECIMAL(10,4) NULL`; `@ToleranceWeight DECIMAL(10,4) = NULL` on `ContainerConfig_Create` and `ContainerConfig_Update`, positioned immediately after `@TargetWeight`; `ToleranceWeight` column in both read procs' result sets. Task 5 consumes it via `ContainerConfig_GetByItemAndMethod`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0008_Parts_Item/028_ContainerConfig_tolerance.sql`:

```sql
-- =============================================
-- File:         0008_Parts_Item/028_ContainerConfig_tolerance.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-27
-- Description:
--   Tests Parts.ContainerConfig.ToleranceWeight (migration 0068).
--   Covers: Create round-trips the value, Update mutates it, NULL is
--   allowed (tolerance optional), and both read procs project it.
--   Spec: docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md Sec 7.1
-- =============================================

EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/028_ContainerConfig_tolerance.sql';
GO

DECLARE @S BIT, @M NVARCHAR(500), @ItemId BIGINT, @ConfigId BIGINT;

CREATE TABLE #r (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #r EXEC Parts.Item_Create
    @ItemNumber = N'TOLTEST-001', @Description = N'Tolerance test part',
    @ItemTypeId = 5, @UomId = 1, @AppUserId = 1;
SELECT @ItemId = NewId FROM #r;
DELETE FROM #r;

-- Create with a tolerance round-trips it.
INSERT INTO #r EXEC Parts.ContainerConfig_Create
    @ItemId = @ItemId, @TraysPerContainer = 4, @PartsPerTray = 60,
    @ClosureMethod = N'ByWeight', @TargetWeight = 4.2000,
    @ToleranceWeight = 0.0500, @AppUserId = 1;
SELECT @S = Status, @M = Message, @ConfigId = NewId FROM #r;
DELETE FROM #r;

EXEC test.AssertEqual @Expected = N'1', @Actual = @S,
     @TestName = N'ContainerConfig_Create with ToleranceWeight succeeds';

CREATE TABLE #cfg (Id BIGINT, ItemId BIGINT, TraysPerContainer INT, PartsPerTray INT,
                   IsSerialized BIT, ClosureMethod NVARCHAR(20),
                   TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4),
                   DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50));

INSERT INTO #cfg EXEC Parts.ContainerConfig_GetByItemAndMethod
    @ItemId = @ItemId, @ClosureMethod = N'ByWeight';

EXEC test.AssertEqual @Expected = N'0.0500',
     @Actual = (SELECT CAST(ToleranceWeight AS NVARCHAR(20)) FROM #cfg),
     @TestName = N'GetByItemAndMethod projects ToleranceWeight';

-- Update mutates it.
INSERT INTO #r EXEC Parts.ContainerConfig_Update
    @Id = @ConfigId, @TraysPerContainer = 4, @PartsPerTray = 60,
    @ClosureMethod = N'ByWeight', @TargetWeight = 4.2000,
    @ToleranceWeight = 0.0750, @AppUserId = 1;
SELECT @S = Status FROM #r;
DELETE FROM #r;

EXEC test.AssertEqual @Expected = N'1', @Actual = @S,
     @TestName = N'ContainerConfig_Update with ToleranceWeight succeeds';

EXEC test.AssertEqual @Expected = N'0.0750',
     @Actual = (SELECT CAST(ToleranceWeight AS NVARCHAR(20))
                FROM Parts.ContainerConfig WHERE Id = @ConfigId),
     @TestName = N'ContainerConfig_Update persists ToleranceWeight';

-- NULL tolerance is allowed (optional per FDS-06-014).
EXEC Parts.ContainerConfig_Deprecate @Id = @ConfigId, @AppUserId = 1;

INSERT INTO #r EXEC Parts.ContainerConfig_Create
    @ItemId = @ItemId, @TraysPerContainer = 4, @PartsPerTray = 60,
    @ClosureMethod = N'ByWeight', @TargetWeight = 4.2000, @AppUserId = 1;
SELECT @S = Status FROM #r;

EXEC test.AssertEqual @Expected = N'1', @Actual = @S,
     @TestName = N'ContainerConfig_Create omitting ToleranceWeight succeeds';

DROP TABLE #r; DROP TABLE #cfg;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "028_ContainerConfig_tolerance"
```

Expected: FAIL — `Invalid column name 'ToleranceWeight'` and `@ToleranceWeight is not a parameter for procedure ContainerConfig_Create`.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0068_containerconfig_tolerance_weight.sql`:

```sql
-- ============================================================
-- Migration:   0068_containerconfig_tolerance_weight.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-27
-- Description: Parts.ContainerConfig.ToleranceWeight -- the checkweigh
--              window half-width for ByWeight tray closure.
--
--              FDS-06-014 describes ByWeight closure as "TargetWeight per
--              tray (+ optional tolerance)" but only TargetWeight reached
--              the schema. Legacy SparkMES carried the tolerance as
--              GroupTargetWeightTolerance, listed in the FDS legacy-column
--              crosswalk as "subsumed by OI-02 resolution when that closes"
--              -- it was not. This closes that gap.
--
--              SYMMETRIC by decision: one value, pushed to the IND570 as
--              both the (+) and (-) tolerance (commands 131 and 112). The
--              device supports an asymmetric window; the schema
--              deliberately does not. Revisit only if MPP asks for it.
--
--              Unit-less, like TargetWeight. Units live on the scale UDT's
--              WeightUom parameter (default lb) and are verified against
--              the terminal at commissioning via command 30.
--
-- Spec:        docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md Sec 7.1
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Parts.ContainerConfig')
                 AND name = N'ToleranceWeight')
BEGIN
    ALTER TABLE Parts.ContainerConfig
        ADD ToleranceWeight DECIMAL(10,4) NULL;
END
GO

EXEC sys.sp_addextendedproperty
     @name = N'MS_Description',
     @value = N'Symmetric tolerance about TargetWeight for ByWeight closure. Pushed to the scale as both the + and - tolerance. Required when ClosureMethod = ByWeight; ignored otherwise.',
     @level0type = N'SCHEMA', @level0name = N'Parts',
     @level1type = N'TABLE',  @level1name = N'ContainerConfig',
     @level2type = N'COLUMN', @level2name = N'ToleranceWeight';
GO

INSERT INTO dbo.SchemaVersion (VersionNumber, Description, AppliedAt)
VALUES (68, N'ContainerConfig.ToleranceWeight for ByWeight checkweigh window', SYSUTCDATETIME());
GO
```

> Before running: open `sql/migrations/versioned/0067_reject_chargeto_and_location.sql` and copy its exact `SchemaVersion` insert form — column names and whether it uses `GETUTCDATE()` or `SYSUTCDATETIME()`. Match it rather than the shape above if they differ.

- [ ] **Step 4: Add the parameter to the two mutation procs**

In both `R__Parts_ContainerConfig_Create.sql` and `R__Parts_ContainerConfig_Update.sql`:

Add the parameter immediately after `@TargetWeight`:

```sql
    @TargetWeight      DECIMAL(10,4)  = NULL,
    @ToleranceWeight   DECIMAL(10,4)  = NULL,
```

Add `ToleranceWeight` to the `INSERT` column list and `VALUES` (Create), or to the `SET` clause (Update). Add to the header comment block's parameter list:

```sql
--   @ToleranceWeight DECIMAL(10,4) NULL  -- symmetric checkweigh window
```

Add a revision-history line to each header, matching the existing dated format:

```sql
--   2026-08-27 - 2.5 - @ToleranceWeight added (IND570 checkweigh, spec 2026-08-27)
```

Both procs write `Audit.ConfigLog` — add `ToleranceWeight` to the `OldValue`/`NewValue` JSON alongside `TargetWeight` so the audit trail stays complete. Follow the existing JSON construction in each proc verbatim; do not restructure it.

- [ ] **Step 5: Add the column to the two read procs**

In `R__Parts_ContainerConfig_GetByItem.sql` and `R__Parts_ContainerConfig_GetByItemAndMethod.sql`, add `ToleranceWeight` to the `SELECT` list immediately after `TargetWeight`. Column order matters — the test's `#cfg` temp table depends on it.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "0008_Parts_Item"
```

Expected: PASS, and the whole `0008_Parts_Item` directory still green (020, 026, 027 must not regress — they call the same procs without the new parameter, which is why it has a default).

- [ ] **Step 7: Run the full suite**

```bash
cd sql/tests && powershell -File Run-Tests.ps1
```

Expected: 0 failures. Exit code 1 with 0 reported failures means a test's `sqlcmd` errored — usually an FK violation during cleanup. Investigate rather than ignoring the exit code.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/versioned/0068_containerconfig_tolerance_weight.sql sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItem.sql sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItemAndMethod.sql sql/tests/0008_Parts_Item/028_ContainerConfig_tolerance.sql
git commit -m "feat(parts): ContainerConfig.ToleranceWeight for ByWeight checkweigh window"
```

---

### Task 2: Teach the tag generator address-decoupled members and folders

Today `generate_tags.py` derives each member's OPC address from its tag name (`opcItemPath = "{BasePath}" + name`) and emits a flat list of `AtomicTag`s. The IND570 UDT needs friendly names (`Weight/Net`) pointing at register addresses (`HRF2`), grouped in folders, plus memory and expression members. This task adds that capability **without changing any existing output** — the three MIP/tray types must regenerate byte-identical.

**Files:**
- Modify: `ignition/tags/generate_tags.py`

**Interfaces:**
- Produces: `opc_member(name, kind, address=None)` — when `address` is `None`, behaviour is unchanged (address derived from `name`); when given, the address is used and the name is free. `memory_member(name, kind, default)`, `expr_member(name, kind, expression)`, `folder(name, members)`. Task 3 consumes all four.

- [ ] **Step 1: Extend `opc_member` to accept an explicit address**

Replace the existing `opc_member` in `ignition/tags/generate_tags.py`:

```python
def opc_member(name, kind, address=None):
    """One OPC AtomicTag member -- opcServer + opcItemPath are parameter binds.

    address=None  -> the member NAME is the address, appended directly to
                     {BasePath} (the original scheme; MIP + tray types).
    address given -> the tag name and the OPC address are decoupled, so a
                     UDT can present friendly names over raw register
                     addresses (the IND570 scale over Modbus TCP).
    """
    return {
        "name": name,
        "dataType": TAG_DTYPE[kind],
        "valueSource": "opc",
        "opcServer": {"bindType": "parameter", "binding": "{OpcServer}"},
        "opcItemPath": {"bindType": "parameter",
                        "binding": "ns=1;s=[{Device}]{BasePath}" + (address or name)},
        "tagType": "AtomicTag",
    }
```

- [ ] **Step 2: Add the three new member builders**

Insert directly after `opc_member`:

```python
def memory_member(name, kind, default):
    """A memory tag -- MES-side state the device neither reads nor writes."""
    return {
        "name": name,
        "dataType": TAG_DTYPE[kind],
        "valueSource": "memory",
        "defaultValue": default,
        "tagType": "AtomicTag",
    }


def expr_member(name, kind, expression):
    """A derived tag -- protocol decode over a raw register word. Expression
    syntax is C-style (=, &&, !), NOT Python keywords, which fail silently
    as falsy."""
    return {
        "name": name,
        "dataType": TAG_DTYPE[kind],
        "valueSource": "expr",
        "expression": expression,
        "tagType": "AtomicTag",
    }


def folder(name, members):
    """A UDT folder member -- groups children by audience, not by address."""
    return {"name": name, "tagType": "Folder", "tags": members}
```

- [ ] **Step 3: Verify existing output is unchanged**

```bash
git stash && python ignition/tags/generate_tags.py && cp ignition/tags/udt/SerializedMipStation.json /tmp/before.json && git stash pop && python ignition/tags/generate_tags.py && diff /tmp/before.json ignition/tags/udt/SerializedMipStation.json && echo "IDENTICAL"
```

Expected: `IDENTICAL`. If it differs, `opc_member`'s default path changed behaviour — fix before continuing.

- [ ] **Step 4: Commit**

```bash
git add ignition/tags/generate_tags.py
git commit -m "refactor(tags): decouple UDT member names from OPC addresses; add folder/memory/expr builders"
```

---

### Task 3: Rewrite the `ScaleStation` member set for Modbus TCP

**Files:**
- Modify: `ignition/tags/generate_tags.py`
- Regenerate: `ignition/tags/udt/ScaleStation.json`, `ignition/tags/instances/PlcDevices.json`, `ignition/tags/sim/MPP_Sim_program.csv`

**Interfaces:**
- Consumes: `opc_member(name, kind, address)`, `memory_member`, `expr_member`, `folder` from Task 2.
- Produces: UDT member paths consumed by Tasks 4 and 5 — `Weight/Net`, `Weight/InMotion`, `Weight/IsValid`, `Weight/SourceIsNet`, `Weight/Uom`, `Verdict/Under`, `Verdict/Ok`, `Verdict/Over`, `Setpoint/Target`, `Setpoint/Tolerance`, `Setpoint/Apply`, `Setpoint/ActiveTarget`, `Setpoint/State`, `Protocol/Live/Command`, `Protocol/Live/CommandResponse`, `Protocol/Live/FpIndicator`, `Protocol/Live/Status`, `Protocol/Live/Integrity1`, `Protocol/Live/Integrity2`, `Protocol/Command/Command`, `Protocol/Command/LoadValue`, `Protocol/Command/CommandResponse`, `Protocol/Command/FpIndicator`, `Protocol/Command/CommandAck`, `Protocol/Command/EchoValue`.

- [ ] **Step 1: Replace the `SCALE` catalog entry**

Replace the `SCALE = [...]` list in `generate_tags.py` with a builder function. Delete the old list entirely — the `NET_*` / `TRG_*` members are gone.

```python
# ---- IND570 scale over Modbus TCP -------------------------------------------
# Register map: PLC Interface Manual (doc 30205335 rev 12) Sec 5.4.4 + Table 5-3,
# Floating Point format. Mettler's 4000xx/4010xx are Modicon DISPLAY convention;
# the real register numbers are 1 and 1025 -- hence HR1 / HR1026, not HR400001.
# Read and write areas share one holding-register space, offset by 1024.
#
#   slot 1 (live, parked on command 11 = report net weight)
#     HR1     Command Response      HR1026   Command        (write)
#     HRF2    FP value (regs 2-3)
#     HR4     Scale Status
#   slot 2 (command scratchpad -- setpoint loads never interrupt the live read)
#     HR5     Command Response      HR1029   Command        (write)
#     HRF6    FP value (regs 6-7)   HRF1030  FP Load Value  (write)
#
# Scale Status bits: 0 Under / 2 OK / 4 Over (over/under target mode),
# 5 always 1, 12 Motion, 13 Net mode, 14 Data Integrity 2, 15 Data OK.
# Command Response bits: 8-12 FP Indicator, 13 Data Integrity 1, 14-15 Cmd Ack.

_LIVE_CR = "{[.]Protocol/Live/CommandResponse}"
_CMD_CR = "{[.]Protocol/Command/CommandResponse}"


def _bitfield(word, lo, hi):
    """Decode an inclusive bit range out of a 16-bit word as an integer.
    getBit(number, position) is zero-indexed with the LSB at position 0,
    which matches Mettler's bit numbering directly."""
    return " + ".join("getBit(%s, %d) * %d" % (word, b, 2 ** i)
                      for i, b in enumerate(range(lo, hi + 1)))


def scale_members():
    return [
        folder("Weight", [
            opc_member("Net",        "real", "HRF2"),
            opc_member("InMotion",   "bool", "HR4.12"),
            opc_member("IsValid",    "bool", "HR4.15"),
            # FP Indicator 1 == net weight. 0 == gross, which is what a
            # power-cycled terminal reports when its command register is 0 --
            # plausible, well-formed, wrong. This is the guard.
            expr_member("SourceIsNet", "bool",
                        "{[.]Protocol/Live/FpIndicator} = 1"),
            memory_member("Uom", "str", "{WeightUom}"),
        ]),
        folder("Verdict", [
            opc_member("Under", "bool", "HR4.0"),
            opc_member("Ok",    "bool", "HR4.2"),
            opc_member("Over",  "bool", "HR4.4"),
            expr_member("State", "str",
                        "if({[.]Verdict/Ok}, 'Ok', "
                        "if({[.]Verdict/Under}, 'Under', "
                        "if({[.]Verdict/Over}, 'Over', 'Unknown')))"),
        ]),
        folder("Setpoint", [
            memory_member("Target",       "real", 0.0),
            memory_member("Tolerance",    "real", 0.0),
            memory_member("Apply",        "bool", False),
            memory_member("ActiveTarget", "real", 0.0),
            memory_member("State",        "str",  "Idle"),
        ]),
        folder("Protocol", [
            folder("Live", [
                opc_member("Command",         "int",  "HR1026"),
                opc_member("CommandResponse", "int",  "HR1"),
                opc_member("Status",          "int",  "HR4"),
                opc_member("Integrity1",      "bool", "HR1.13"),
                opc_member("Integrity2",      "bool", "HR4.14"),
                expr_member("FpIndicator", "int", _bitfield(_LIVE_CR, 8, 12)),
            ]),
            folder("Command", [
                opc_member("Command",         "int",  "HR1029"),
                opc_member("LoadValue",       "real", "HRF1030"),
                opc_member("CommandResponse", "int",  "HR5"),
                opc_member("EchoValue",       "real", "HRF6"),
                expr_member("FpIndicator", "int", _bitfield(_CMD_CR, 8, 12)),
                expr_member("CommandAck",  "int", _bitfield(_CMD_CR, 14, 15)),
            ]),
        ]),
    ]
```

- [ ] **Step 2: Wire it into the catalog and add the `WeightUom` parameter**

The `CATALOG` dict maps type name to `(members, has_write_display)`. `ScaleStation` now supplies a nested structure rather than a flat `(name, kind)` list, so the emitter must branch. Locate the function that builds a UDT definition from `CATALOG` and make it accept an already-built member list for `ScaleStation`:

```python
CATALOG = {
    "ScaleStation":            (scale_members(), False),
    "SerializedMipStation":    (SERIALIZED, True),
    "NonSerializedMipStation": (NONSERIALIZED, True),
    "TrayInspectionStation":   (TRAY, True),
}
```

In the definition emitter, members that are already dicts pass through untouched; `(name, kind)` tuples still go through `opc_member`:

```python
    tags = [m if isinstance(m, dict) else opc_member(m[0], m[1])
            for m in members]
```

Add `WeightUom` to the parameter block for `ScaleStation` only (default `lb` — MPP's terminals are configured in pounds, verified at commissioning via command 30):

```python
    if type_name == "ScaleStation":
        params["WeightUom"] = {"dataType": "String", "value": "lb"}
```

- [ ] **Step 3: Handle folders in the simulator CSV emitter**

The sim CSV writes one row per OPC member. It currently iterates a flat list; it must now recurse into folders and skip non-OPC members (memory and expression tags have no device address). Add a flattener and use it wherever the CSV emitter walks members:

```python
def flatten_opc(members):
    """Yield (address, kind) for every OPC member, recursing into folders.
    Memory and expression members are skipped -- they have no device address.
    Bit-addressed members (HR4.12) collapse onto their containing word (HR4),
    deduped, because the simulator serves whole registers."""
    out = []
    for m in members:
        if m.get("tagType") == "Folder":
            out.extend(flatten_opc(m["tags"]))
        elif m.get("valueSource") == "opc":
            addr = m["opcItemPath"]["binding"].split("}")[-1]
            word = addr.split(".")[0]
            kind = "bool" if m["dataType"] == "Boolean" else (
                   "real" if m["dataType"] == "Float8" else
                   "str" if m["dataType"] == "String" else "int")
            if addr != word:
                kind = "int"   # the containing word, not the bit
            if (word, kind) not in out:
                out.append((word, kind))
    return out
```

- [ ] **Step 4: Regenerate and inspect**

```bash
python ignition/tags/generate_tags.py && python -c "import json;d=json.load(open('ignition/tags/udt/ScaleStation.json'));print(json.dumps(d,indent=1)[:1200])"
```

Expected: `parameters` contains `BasePath`, `Device`, `OpcServer`, `WeightUom`; `tags` contains four folders (`Weight`, `Verdict`, `Setpoint`, `Protocol`); no `NET_*` or `TRG_*` member survives anywhere.

- [ ] **Step 5: Verify the other three types did not drift**

```bash
git diff --stat ignition/tags/
```

Expected: `ScaleStation.json`, `PlcDevices.json` and `MPP_Sim_program.csv` change. `SerializedMipStation.json`, `NonSerializedMipStation.json` and `TrayInspectionStation.json` must show **no** changes. If they do, Task 2 Step 3's guarantee broke.

- [ ] **Step 6: Confirm no legacy member names remain**

```bash
grep -rn "NET_DataReady\|NET_NetWeightValue\|TRG_SendMessage\|TRG_TargetWeightValue" ignition/tags/ || echo "CLEAN"
```

Expected: `CLEAN`.

- [ ] **Step 7: Commit**

```bash
git add ignition/tags/generate_tags.py ignition/tags/udt/ScaleStation.json ignition/tags/instances/PlcDevices.json ignition/tags/sim/MPP_Sim_program.csv
git commit -m "feat(tags): ScaleStation UDT rebuilt for IND570 Modbus TCP register map"
```

---

### Task 4: `BlueRidge.Workorder.Ind570` — protocol layer

The Modbus command sequencer, isolated from any MES concern so it can be reasoned about and exercised on its own. Domain logic stays in SQL; this is protocol decode and handshake, which correctly lives in Jython.

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Ind570/code.py`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Ind570/resource.json`

**Interfaces:**
- Consumes: `BlueRidge.Workorder.PlcWatcher.readMember(udtInstancePath, member)`, `.writeMember(udtInstancePath, member, value)`, `.readMembers(udtInstancePath, members)`, `.logInterface(deviceCode, description, requestPayload=None, responsePayload=None, ok=True, errorDescription=None)`.
- Produces: `CMD` (dict of command-code constants), `parkLiveCommand(instancePath)`, `sendCommand(instancePath, code, value=None, timeoutMs=3000)` returning `{"ok": bool, "message": str, "echo": float|None}`, `applySetpoint(instancePath, target, tolerance)` returning `{"ok": bool, "message": str}`, `captureGate(instancePath)` returning `{"ok": bool, "reason": str|None}`.

- [ ] **Step 1: Create the resource descriptor**

Create `.../BlueRidge/Workorder/Ind570/resource.json`, copying the exact shape of `.../BlueRidge/Workorder/ScaleWatcher/resource.json`:

```bash
cp ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleWatcher/resource.json ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Ind570/resource.json
```

- [ ] **Step 2: Write the module**

Create `.../BlueRidge/Workorder/Ind570/code.py`:

```python
"""BlueRidge.Workorder.Ind570 - METTLER TOLEDO IND570 Modbus TCP protocol layer.

   Spec: docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md
   Manual: reference/IND570_PLC_Interface_Manual.md (doc 30205335 rev 12),
           Appendix B for the command table and status-bit layout.

   Two independent flows, mirroring the legacy OmniServer shape:

     Flow B (capture) has NO protocol step. Slot 1 sits parked on command 11
     and the terminal refreshes net weight every interface update cycle, so
     the value is simply THERE. captureGate() decides whether to trust it.

     Flow A (setpoint) is a 4-command sequence through slot 2. Each command
     waits for the acknowledgement to rotate before the next is sent -- the
     manual is explicit that the client must wait for the ack.

   There is no send-message pulse. For a value-bearing command the FP value
   is written FIRST, then the command; the echoed value coming back equal to
   what was sent IS the acknowledgement (Table B-4 note 6).
"""

import time

# ---- command codes (standard target control; Fill-570 NOT licensed) --------
# With Fill-570 installed these are illegal and become 170/173/174/119.
CMD = {
    "REPORT_NET":       11,
    "SET_TARGET":      110,
    "SET_TOL_PLUS":    131,
    "SET_TOL_MINUS":   112,
    "START_COMPARE":   114,
    "ABORT_COMPARE":   115,
    "TARGET_USE_NET":  117,
    "LATCH_DISABLE":   122,
    "REPORT_UNITS":     30,
}

# FP Indicator values (Table B-2) that carry meaning for us.
FP_GROSS = 0
FP_NET = 1
FP_CMD_OK = 30
FP_INVALID = 31

_POLL_MS = 100


def parkLiveCommand(instancePath):
    """Park 'report net weight' in slot 1. MUST be re-run on every device
       reconnect -- a terminal power cycle clears the command register to 0,
       and command 0 reports GROSS weight (Table B-4 note 1). The failure is
       silent: plausible, well-formed, wrong numbers."""
    W = BlueRidge.Workorder.PlcWatcher
    W.writeMember(instancePath, "Protocol/Live/Command", CMD["REPORT_NET"])


def sendCommand(instancePath, code, value=None, timeoutMs=3000):
    """Send one command through slot 2 and wait for the ack to rotate.

       Returns {"ok": bool, "message": str, "echo": float or None}.
       For value-bearing commands the FP value is written BEFORE the command
       (Table B-6 establishes that ordering) and the echo is verified."""
    W = BlueRidge.Workorder.PlcWatcher
    before = W.readMember(instancePath, "Protocol/Command/CommandAck")

    if value is not None:
        W.writeMember(instancePath, "Protocol/Command/LoadValue", float(value))
    W.writeMember(instancePath, "Protocol/Command/Command", int(code))

    waited = 0
    while waited < timeoutMs:
        time.sleep(_POLL_MS / 1000.0)
        waited += _POLL_MS
        ack = W.readMember(instancePath, "Protocol/Command/CommandAck")
        if ack == before:
            continue

        fp = W.readMember(instancePath, "Protocol/Command/FpIndicator")
        if fp == FP_INVALID:
            return {"ok": False, "echo": None,
                    "message": "Command %s rejected as invalid. If this "
                               "persists the terminal has Fill-570 installed "
                               "and needs commands 170/173/174/119." % code}

        echo = W.readMember(instancePath, "Protocol/Command/EchoValue")
        if value is not None and abs(float(echo) - float(value)) > 0.0001:
            return {"ok": False, "echo": echo,
                    "message": "Echo mismatch on command %s: sent %s, got %s. "
                               "Check terminal Byte Order = Double Word Swap."
                               % (code, value, echo)}
        return {"ok": True, "echo": echo, "message": "OK"}

    return {"ok": False, "echo": None,
            "message": "Command %s timed out after %sms with no acknowledgement."
                       % (code, timeoutMs)}


def applySetpoint(instancePath, target, tolerance):
    """Flow A. Load target + both tolerances, then start target comparison.

       A partial application is worse than no change -- a new target paired
       with stale tolerances silently validates against the wrong window. On
       any step failure this aborts comparison and leaves ActiveTarget at its
       previous value, so Target != ActiveTarget stays visible as the signal
       that the line is on a stale setpoint."""
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]
    W.writeMember(instancePath, "Setpoint/State", "Loading")

    steps = [
        (CMD["SET_TARGET"],    target),
        (CMD["SET_TOL_PLUS"],  tolerance),
        (CMD["SET_TOL_MINUS"], tolerance),
        (CMD["START_COMPARE"], None),
    ]

    for code, value in steps:
        result = sendCommand(instancePath, code, value)
        if not result["ok"]:
            sendCommand(instancePath, CMD["ABORT_COMPARE"])
            W.writeMember(instancePath, "Setpoint/State", "Failed")
            W.logInterface(device, "Setpoint load",
                           requestPayload="target=%s tol=%s" % (target, tolerance),
                           responsePayload=result["message"], ok=False,
                           errorDescription=result["message"])
            return {"ok": False, "message": result["message"]}

    W.writeMember(instancePath, "Setpoint/ActiveTarget", float(target))
    W.writeMember(instancePath, "Setpoint/State", "Active")
    W.logInterface(device, "Setpoint load",
                   requestPayload="target=%s tol=%s" % (target, tolerance),
                   ok=True)
    return {"ok": True, "message": "Setpoint active"}


def captureGate(instancePath):
    """All five conditions must hold before a reading may be trusted.
       Returns {"ok": bool, "reason": str or None}."""
    W = BlueRidge.Workorder.PlcWatcher
    v = W.readMembers(instancePath, [
        "Weight/InMotion", "Weight/IsValid", "Weight/SourceIsNet",
        "Protocol/Live/Integrity1", "Protocol/Live/Integrity2",
        "Setpoint/State",
    ])

    if v.get("Weight/InMotion"):
        return {"ok": False, "reason": "Scale is still in motion."}
    if not v.get("Weight/IsValid"):
        return {"ok": False,
                "reason": "Scale reports data not OK -- in setup, over "
                          "capacity, or under zero."}
    if not v.get("Weight/SourceIsNet"):
        return {"ok": False,
                "reason": "Scale is reporting GROSS weight, not net. The "
                          "command register was cleared -- re-park it."}
    if bool(v.get("Protocol/Live/Integrity1")) != bool(v.get("Protocol/Live/Integrity2")):
        return {"ok": False,
                "reason": "Scale data integrity bits disagree -- reading is "
                          "mid-update."}
    if v.get("Setpoint/State") != "Active":
        return {"ok": False,
                "reason": "No target is active on this scale. Load a setpoint "
                          "before validating a tray."}
    return {"ok": True, "reason": None}
```

- [ ] **Step 3: Deploy to the gateway and confirm it loads**

```bash
powershell -File scan.ps1
```

Then in the Designer, open the script console and run:

```python
print BlueRidge.Workorder.Ind570.CMD["SET_TARGET"]
```

Expected: `110`. A `NameError` or import failure means `resource.json` is wrong or the scan did not pick the folder up.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Ind570/
git commit -m "feat(scale): IND570 Modbus TCP protocol layer - command sequencer and capture gate"
```

---

### Task 5: Rewrite `ScaleWatcher` for the pull model

The legacy watcher was edge-driven: the scale asserted `NET_DataReady` and the watcher reacted. Modbus TCP has no such edge — the operator button drives everything. `handleEdge` therefore disappears and is replaced by a function the button calls.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleWatcher/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/PlcWatcher/code.py` (remove the scale edge route)

**Interfaces:**
- Consumes: `BlueRidge.Workorder.Ind570.captureGate`, `.applySetpoint`, `.parkLiveCommand`; `BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId, closureMethod)`; `BlueRidge.Workorder.PlcWatcher.readMembers`, `.logInterface`, `.notifyAlarm`.
- Produces: `captureAndClose(instancePath, terminalLocationId)` returning `{"Status": int, "Message": str, "ContainerId": int|None}`; `loadSetpointForItem(instancePath, itemId)` returning `{"ok": bool, "message": str}`. Task 6's button calls both.

- [ ] **Step 1: Replace the module body**

Overwrite `.../BlueRidge/Workorder/ScaleWatcher/code.py`:

```python
"""BlueRidge.Workorder.ScaleWatcher - assembly checkweigh scales (IND570 / Modbus TCP).

   Spec: docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md

   REPLACES the OmniServer edge model. The scale no longer pushes: net weight
   is continuously present in the polled register, so there is no NET_DataReady
   edge, no clear-down, and no handleEdge entry point. The operator button is
   the trigger.

   Nothing is latched in tags. captureAndClose reads the live values, gates
   them, and hands them straight to SQL -- the tag tree stays a pure device
   mirror and MES state lives in the database.

   The verdict closes the tray; the weight rides along on the ProductionEvent
   as evidence. FDS-06-014 is explicit that the device's OK bit is
   authoritative, never the running count. Recording the reading is what makes
   scale drift visible -- a verdict-only record reads "fine" until it abruptly
   reads "broken".
"""


def captureAndClose(instancePath, terminalLocationId):
    """Operator pressed the capture button. Gate the live reading, then close
       the tray through the SAME Assembly_CompleteTray path the ByCount button
       uses (identical genealogy).

       Returns {"Status": 1|0, "Message": str, "ContainerId": id or None}."""
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]

    gate = BlueRidge.Workorder.Ind570.captureGate(instancePath)
    if not gate["ok"]:
        W.logInterface(device, "Scale capture refused",
                       responsePayload=gate["reason"], ok=False,
                       errorDescription=gate["reason"])
        return {"Status": 0, "Message": gate["reason"], "ContainerId": None}

    vals = W.readMembers(instancePath,
                         ["Weight/Net", "Weight/Uom", "Verdict/State"])
    weight = vals.get("Weight/Net")
    uom = vals.get("Weight/Uom")
    verdict = vals.get("Verdict/State")

    if verdict != "Ok":
        msg = "Tray is %s target -- not within tolerance." % (verdict or "outside")
        W.logInterface(device, "Scale capture",
                       requestPayload="weight=%s uom=%s verdict=%s"
                                      % (weight, uom, verdict),
                       ok=False, errorDescription=msg)
        return {"Status": 0, "Message": msg, "ContainerId": None}

    result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId,
                                                          "ByWeight")
    ok = bool(result and result.get("Status"))
    W.logInterface(device, "ByWeight tray close",
                   requestPayload="terminal=%s weight=%s uom=%s"
                                  % (terminalLocationId, weight, uom),
                   responsePayload=str(result), ok=ok,
                   errorDescription=None if ok else (result or {}).get("Message"))

    if not ok:
        msg = (result or {}).get("Message") or "Tray close failed"
        W.notifyAlarm(terminalLocationId, "ByWeight tray close failed", msg)
        return {"Status": 0, "Message": msg, "ContainerId": None}

    return {"Status": 1, "Message": "Tray closed",
            "ContainerId": result.get("ContainerId")}


def loadSetpointForItem(instancePath, itemId):
    """Flow A entry point. Reads the ByWeight ContainerConfig for the item now
       running and pushes target + tolerance to the terminal.

       A missing tolerance is a configuration error, not a zero -- a zero-width
       window would reject every tray."""
    cfg = system.db.runNamedQuery("parts/ContainerConfig_GetByItemAndMethod",
                                  {"ItemId": itemId,
                                   "ClosureMethod": "ByWeight"})
    if cfg.getRowCount() == 0:
        return {"ok": False,
                "message": "No ByWeight container config for this item."}

    target = cfg.getValueAt(0, "TargetWeight")
    tolerance = cfg.getValueAt(0, "ToleranceWeight")
    if target is None or tolerance is None:
        return {"ok": False,
                "message": "ByWeight config is missing TargetWeight or "
                           "ToleranceWeight. Set both in Item Master before "
                           "running this part."}

    return BlueRidge.Workorder.Ind570.applySetpoint(instancePath,
                                                    float(target),
                                                    float(tolerance))


def onDeviceReconnect(instancePath):
    """Re-park the live command. A terminal power cycle clears the command
       register to 0, and command 0 reports GROSS weight -- silently. Call
       from the device-connection-state handler and at gateway startup."""
    BlueRidge.Workorder.Ind570.parkLiveCommand(instancePath)
```

- [ ] **Step 2: Remove the scale edge route from the dispatcher**

In `.../BlueRidge/Workorder/PlcWatcher/code.py`, find `_route` (near line 288) and delete the branch that dispatches `ScaleStation` device types to `ScaleWatcher.handleEdge`. Leave the MIP and tray routes untouched. Add a comment where the branch was:

```python
    # ScaleStation has no edge route -- IND570 over Modbus TCP is polled, not
    # pushed. The operator button calls ScaleWatcher.captureAndClose directly.
    # See spec 2026-08-27-ind570-scale-udt-modbus-tcp-design.md Sec 1.1.
```

- [ ] **Step 3: Confirm no caller still references the removed entry point**

```bash
grep -rn "handleEdge\|NET_DataReady\|NET_TargetWeightMetFlag" ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ | grep -i scale || echo "CLEAN"
```

Expected: `CLEAN`. Any hit is a caller that must be updated before proceeding.

- [ ] **Step 4: Deploy and smoke-test against the simulator**

```bash
powershell -File scan.ps1
```

In the Designer script console, with a `ScaleStation` instance selected in the Sim Panel:

```python
p = "[MPP]PlcDevices/5G0_Front_Scale"
print BlueRidge.Workorder.Ind570.captureGate(p)
```

Expected: `{"ok": False, "reason": "No target is active on this scale. ..."}` — the setpoint has not been loaded, so the gate must refuse. A gate that returns `ok: True` against an unconfigured simulator is broken.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleWatcher/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/PlcWatcher/code.py
git commit -m "feat(scale): ScaleWatcher rewritten for the IND570 pull model; edge route removed"
```

---

### Task 6: Capture button on the assembly screen — **Designer task**

> **Do not edit `view.json` on disk.** This modifies an existing view. Designer's GSON serialization writes `=` `'` `<` `>` as 6-char unicode escapes that defeat literal string matching, and its in-memory model can overwrite on-disk changes through the "Files vs Gateway" conflict dialog. Perform these steps in the Designer, then export via `scan.ps1` and commit the resulting diff.

**Files:**
- Modify (in Designer): `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json`

- [ ] **Step 1: Find the existing ByWeight container — do not add a parallel one**

This view already has ByWeight scaffolding. `session.custom.closureMethod` drives display throughout, and at least one container is bound `position.display` to the expression `{session.custom.closureMethod} = "ByWeight"`. The capture button belongs **inside that container**, not beside the ByCount button.

In the Designer, open the view and use the component tree to find the container whose `position.display` binding is that expression. Confirm what it already holds before adding anything — if a weight-related control is already present, extend it rather than duplicating.

```bash
grep -c 'ByWeight' ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json
```

Expected: `7`. If the count differs, the view has moved on since this plan was written — re-inspect before proceeding.

- [ ] **Step 2: Add the button inside that container**

Style it with the plant-floor classes already on its siblings (`psc-pf-*` — inspect a neighbour rather than inventing class names; the canonical stylesheet is the **Core** project's, and the MPP override was deliberately dropped in `4466f32b`).

Label: **Weigh & Close Tray**.

The view's existing tray-close entry point is `Assembly.handleTrayComplete` — read it first so the new handler is consistent with how the ByCount path reports success and failure.

- [ ] **Step 3: Write the `onActionPerformed` handler**

The script body must begin with a tab character — the Designer wraps it in `def runAction(self, event):` and a column-0 body is an `IndentationError`.

```python
	instancePath = self.session.custom.terminal.udtInstancePath
	terminalId = self.session.custom.terminal.locationId

	result = BlueRidge.Workorder.ScaleWatcher.captureAndClose(
		instancePath, terminalId)

	if result["Status"]:
		BlueRidge.Common.Notify.toast(
			"Tray closed", result["Message"], "success", 4000)
	else:
		BlueRidge.Common.Notify.toast(
			"Cannot close tray", result["Message"], "error", 0)
```

Confirm the two `session.custom.terminal` property names against `BlueRidge/Terminal/code.py`'s `applyToSession` before writing them — that function is the authority for what the session carries.

- [ ] **Step 4: Bind the button's enabled state**

The UDT instance differs per terminal, so the path cannot be hard-coded. Use the `tag()` expression function over the session's instance path:

```
!tag({session.custom.terminal.udtInstancePath} + "/Weight/InMotion")
 && tag({session.custom.terminal.udtInstancePath} + "/Weight/IsValid")
 && tag({session.custom.terminal.udtInstancePath} + "/Setpoint/State") = "Active"
```

Expression syntax is C-style — `=` for equality, `&&`, `!`. Python keywords (`and`, `not`) parse but evaluate falsy, silently disabling the button forever.

The handler re-checks all five gate conditions regardless — the binding is a courtesy, `captureGate` is the contract.

- [ ] **Step 5: Export and verify the diff is small**

```bash
powershell -File scan.ps1 && git diff --stat ignition/projects/MPP/
```

Expected: one `view.json` changed, tens of lines. A diff of hundreds of lines means the Designer pickled runtime-populated data into the view's defaults — discard and redo rather than committing it.

- [ ] **Step 6: Commit**

```bash
git add <the view.json path from step 1> <its resource.json>
git commit -m "feat(shop-floor): Weigh & Close Tray capture button on the assembly terminal"
```

---

### Task 7: Setpoint load on part change — **Designer task**

Flow A must fire whenever the item running on the line changes, otherwise the terminal validates against a stale window.

**Files:**
- Modify (in Designer): the same assembly view; the item-selection dropdown's `onActionPerformed`.

- [ ] **Step 1: Extend the item dropdown handler**

Append to the existing item-selection handler (tab-indented). Do not replace what is already there — read it first and add to it:

```python
	setpoint = BlueRidge.Workorder.ScaleWatcher.loadSetpointForItem(
		self.session.custom.terminal.udtInstancePath, itemId)
	if not setpoint["ok"]:
		BlueRidge.Common.Notify.toast(
			"Scale setpoint not loaded", setpoint["message"], "error", 0)
```

`itemId` is whatever the surrounding handler already resolved the selection to — reuse that variable, do not re-derive it.

The error toast uses `ttl=0` so it persists. A silently failed setpoint load is the failure mode this whole design guards against.

- [ ] **Step 2: Verify against the simulator**

In the Sim Panel, select a scale device. In the Designer script console:

```python
p = "[MPP]PlcDevices/5G0_Front_Scale"
print BlueRidge.Workorder.ScaleWatcher.loadSetpointForItem(p, <a ByWeight itemId>)
```

Expected: with no `ToleranceWeight` configured — `{"ok": False, "message": "ByWeight config is missing TargetWeight or ToleranceWeight..."}`. Set both in Item Master, re-run, and expect the sequencer to attempt four commands and time out against the simulator (which does not emulate the ack rotation) with a clear timeout message naming the command.

That timeout is the correct simulator behaviour. A real ack round-trip is a commissioning test, not a simulator one.

- [ ] **Step 3: Export and commit**

```bash
powershell -File scan.ps1 && git diff --stat ignition/projects/MPP/
git add <the view.json path> <its resource.json>
git commit -m "feat(shop-floor): push scale setpoint on assembly item change"
```

---

### Task 8: Documentation reconciliation

Three canonical documents still describe the superseded design.

**Files:**
- Modify: `MPP_MES_DATA_MODEL.md`
- Modify: `MPP_MES_FDS.md`
- Modify: `MPP_MES_Open_Issues_Register.md`

- [ ] **Step 1: Add `ToleranceWeight` to the data model**

In `MPP_MES_DATA_MODEL.md`, in the `ContainerConfig` column table, add immediately after the `TargetWeight` row:

```markdown
| ToleranceWeight | DECIMAL(10,4) | NULL | Symmetric tolerance about `TargetWeight` for `ByWeight` closure — pushed to the scale as both the + and the − tolerance. Required when `ClosureMethod = 'ByWeight'`; ignored otherwise. Unit-less, like `TargetWeight`; units live on the scale UDT's `WeightUom` parameter. Added migration 0068. |
```

Add a Revision History row at the top of the document, matching the existing format and incrementing the version number from the current top row.

- [ ] **Step 2: Rewrite FDS-10-006**

In `MPP_MES_FDS.md`, replace the body of **FDS-10-006 — OmniServer Scale Reads**. The tag pattern `OmniServer/[LineName].[ScaleName].NET_NetWeightValue` is now wrong. Retitle it **Scale Integration (IND570 / Modbus TCP)** and state: the seven Machining/Assembly checkweigh scales are METTLER TOLEDO IND570 terminals connected natively over Modbus TCP with no third-party OPC server; the device computes the Under/OK/Over verdict, which is authoritative for tray closure per FDS-06-014; Trim Shop weight-based estimation (FDS-06-005) remains a manual entry against an unconnected scale. Cross-reference the design spec.

Also update the two OmniServer rows in the interfaces table (near the "Scale/weight integration" and "OmniServer-connected weight scale" entries) and add a Revision History row.

- [ ] **Step 3: Add the OI entry**

In `MPP_MES_Open_Issues_Register.md`, add a **resolved** entry to Part A recording that FDS-06-014's parenthetical "(+ optional tolerance)" never reached the data model despite legacy SparkMES carrying `GroupTargetWeightTolerance`, that the FDS legacy-column crosswalk incorrectly claimed it was "subsumed by OI-02 resolution", and that it is resolved as a single symmetric `ContainerConfig.ToleranceWeight` (migration 0068) — the device supports an asymmetric window but the schema deliberately does not. Use the next free OI number and match the existing entry format exactly.

- [ ] **Step 4: Regenerate the Word versions**

```bash
pandoc MPP_MES_DATA_MODEL.md -o MPP_MES_DATA_MODEL.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_DATA_MODEL.docx
pandoc MPP_MES_FDS.md -o MPP_MES_FDS.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_FDS.docx
pandoc MPP_MES_Open_Issues_Register.md -o MPP_MES_Open_Issues_Register.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_Open_Issues_Register.docx
```

Expected: `Styled: <file>` for each.

- [ ] **Step 5: Commit**

```bash
git add MPP_MES_DATA_MODEL.md MPP_MES_DATA_MODEL.docx MPP_MES_FDS.md MPP_MES_FDS.docx MPP_MES_Open_Issues_Register.md MPP_MES_Open_Issues_Register.docx
git commit -m "docs: reconcile data model, FDS-10-006 and OI register with the IND570 Modbus TCP design"
```

---

### Task 9: Record the weight alongside the verdict

Spec §7.2. The verdict closes the tray; the reading rides along on the `ProductionEvent` as evidence. `WeightValue DECIMAL(12,4)` and `WeightUomId` already exist on `Workorder.ProductionEvent` and FDS-06-004 already carries them as optional on the write path — nothing new to create, only a passthrough to wire.

This is the one **reversible** decision in the plan. A verdict-only record reads "fine" right up until it reads "broken," with no history showing a scale drifting out of calibration. If MPP would rather not retain readings, drop this task entirely; nothing else changes.

Run after Task 5 — it changes a signature that `captureAndClose` calls.

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleWatcher/code.py`
- Modify: `sql/tests/` — the existing `Assembly_CompleteTray` test file (locate in Step 1)

**Interfaces:**
- Consumes: `captureAndClose`'s already-read `weight` and `uom` locals from Task 5.
- Produces: `@WeightValue DECIMAL(12,4) = NULL`, `@WeightUomId BIGINT = NULL` on `Workorder.Assembly_CompleteTray`; `plcCompleteTray(terminalLocationId, closureMethod, weightValue=None, weightUomId=None)`.

- [ ] **Step 1: Locate the proc and its tests**

```bash
ls sql/migrations/repeatable/ | grep -i completetray
grep -rln "Assembly_CompleteTray" sql/tests/
```

Record both paths. Read the proc's parameter list and the `ProductionEvent` INSERT inside it before changing anything.

- [ ] **Step 2: Write the failing test**

Append to the located `Assembly_CompleteTray` test file, matching its existing setup idiom (reuse whatever LOT/Item fixtures it already builds — do not duplicate them):

```sql
-- ByWeight close records the scale reading on the ProductionEvent.
INSERT INTO #r EXEC Workorder.Assembly_CompleteTray
    @TerminalLocationId = @TerminalId, @FinishedGoodItemId = @FgItemId,
    @PieceCount = 60, @ClosureMethod = N'ByWeight',
    @WeightValue = 4.2110, @WeightUomId = 1, @AppUserId = 1;
SELECT @S = Status FROM #r;
DELETE FROM #r;

EXEC test.AssertEqual @Expected = N'1', @Actual = @S,
     @TestName = N'Assembly_CompleteTray accepts @WeightValue';

EXEC test.AssertEqual @Expected = N'4.2110',
     @Actual = (SELECT TOP 1 CAST(WeightValue AS NVARCHAR(20))
                FROM Workorder.ProductionEvent
                ORDER BY Id DESC),
     @TestName = N'ByWeight close persists WeightValue on the ProductionEvent';
```

Match the real parameter names from Step 1 — the names above are the expected shape, not verified signatures.

- [ ] **Step 3: Run it to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "CompleteTray"
```

Expected: FAIL — `@WeightValue is not a parameter for procedure Assembly_CompleteTray`.

- [ ] **Step 4: Add the parameters and wire them into the INSERT**

In `R__Workorder_Assembly_CompleteTray.sql`, add after the existing optional parameters:

```sql
    @WeightValue       DECIMAL(12,4)  = NULL,
    @WeightUomId       BIGINT         = NULL,
```

Add both columns to the `Workorder.ProductionEvent` INSERT column list and `VALUES`. Add a header revision line in the file's existing dated format. Do not restructure anything else in the proc.

- [ ] **Step 5: Pass them through the Python layer**

In `BlueRidge/Workorder/Assembly/code.py`, extend `plcCompleteTray`:

```python
def plcCompleteTray(terminalLocationId, closureMethod,
                    weightValue=None, weightUomId=None):
```

and add both to the proc call's parameter dict. Defaulting to `None` keeps the existing `ByVision` caller working unchanged.

In `BlueRidge/Workorder/ScaleWatcher/code.py`, `captureAndClose` already reads `weight` and `uom` — pass them:

```python
    result = BlueRidge.Workorder.Assembly.plcCompleteTray(
        terminalLocationId, "ByWeight", weightValue=weight,
        weightUomId=BlueRidge.Common.Util.uomIdForCode(uom))
```

If no `uomIdForCode` helper exists, resolve the UOM id in SQL inside the proc from a `@WeightUomCode NVARCHAR` instead — a code-to-id lookup is a domain rule and belongs in SQL, not a Python map.

- [ ] **Step 6: Run the tests**

```bash
cd sql/tests && powershell -File Run-Tests.ps1
```

Expected: 0 failures, including the pre-existing `ByVision` and `ByCount` close tests, which must not regress.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleWatcher/code.py <the test file>
git commit -m "feat(scale): record the checkweigh reading on the ByWeight tray-close ProductionEvent"
```

---

## Deferred to commissioning

Not tasks — they need the physical terminal and are covered by the integration guide's §6 test sequence:

- Addressing-base confirmation (`HR4.5` reads 1; integrity bits toggle together).
- Byte order confirmation against a known weight.
- Whether the combo card serves EtherNet/IP and Modbus TCP concurrently.
- Whether all four message slots can address the same local scale independently.
- Command 30 units verification against the `WeightUom` default of `lb`.
- Instance parameter fill-in: `Device`, `BasePath` (empty for Modbus — registers are the address, unlike the sim's `<device>/`), `OpcServer`, per scale.

## Not in this plan

- Asymmetric tolerance windows.
- Retiring the OmniServer OPC server connection itself — a separate infrastructure change once all seven scales are cut over.
