# Data model doc ↔ database drift — 2026-09-03

Found while building `sql/scripts/gen_extended_properties.js`, which lifts the
table and column descriptions out of `MPP_MES_DATA_MODEL.md` into
`sys.extended_properties`. Parsing the document against the live `MPP_MES_Dev`
schema turns the doc into something verifiable for the first time, and three
kinds of gap fell out.

None of these block anything. They are recorded so they become follow-ups
rather than a footnote in a session that nobody re-reads.

## Baseline

| | |
|---|---|
| `### ` table sections in the doc | 90 |
| …carrying a prose description | 67 |
| Column rows in the doc | 752 |
| …carrying a non-empty description | 299 |
| Tables in `MPP_MES_Dev` (excl. `test`, `dbo.SchemaVersion`) | 101 |
| Properties that landed | 66 table, 257 column |

The gap between generated (67/299) and landed (66/257) is entirely the
existence guards doing their job on objects the document describes but the
schema does not carry.

## 1. In the database, absent from the doc (13)

These have no `### ` section in `MPP_MES_DATA_MODEL.md`, so they will never
carry a description and they are invisible to anyone reading the doc rather
than the schema. Several are load-bearing.

- `Audit.PartitionRetention`
- `Location.PlcDeviceType`
- `Location.PrinterFgAssignment`
- `Location.SessionPolicy`
- `Location.TerminalPlcDevice`
- `Lots.ContainerSerialHistory`
- `Lots.LabelTemplate`
- `Lots.LotEventLog`
- `Lots.LotGenealogyClosure`
- `Oee.ShiftOverride`
- `Parts.ClosureMethodCode`
- `Parts.DataCollectionFieldDataType`
- `Quality.ChargeToParty`

`Lots.LotGenealogyClosure` and `Audit.PartitionRetention` are the two worth
documenting first: the closure table is the B4 decision from the OI-35
architecture gate, and `PartitionRetention` is the B2 sliding-window mechanism.
Both are described in prose elsewhere (CLAUDE.md, the Phase 1 design spec) but
have no row-level definition in the data model reference.

`Oee.ShiftOverride` and `Lots.ContainerSerialHistory` also carry recent design
decisions that only exist in migration headers today.

## 2. In the doc, absent from the database (2)

- **`Quality.NonConformance`** — described in §5 but never built. Either
  FUTURE-scoped and should be tagged as such, or an omission.
- **`OEE.OeeSnapshot`** — same.

Both are skipped harmlessly by the generated migration's `IF OBJECT_ID(...)
IS NOT NULL` guard, so this costs nothing at deploy time. It is a
documentation-accuracy question, not a build one.

## 3. Documented tables with no prose description (22)

These have a `### ` heading and a column table but no paragraph between them,
so they get column descriptions but no table-level one. Most are code tables
where the name genuinely says everything (`Lots.PrintReasonCode`,
`Quality.DispositionCode`), and that is a fair editorial choice.

Three are not code tables and the omission is more noticeable:
`Parts.Item`, `Quality.QualitySpec`, `Quality.QualitySample`.

Full list: `Parts.ItemType`, `Parts.Uom`, `Parts.Item`, `Lots.LotOriginType`,
`Lots.GenealogyRelationshipType`, `Lots.PrintReasonCode`, `Lots.LabelTypeCode`,
`Lots.ContainerStatusCode`, `Workorder.WorkOrderStatus`,
`Workorder.OperationStatus`, `Quality.QualitySpec`, `Quality.QualitySpecVersion`,
`Quality.QualitySpecAttribute`, `Quality.QualitySample`, `Quality.QualityResult`,
`Quality.QualityAttachment`, `Quality.InspectionResultCode`,
`Quality.SampleTriggerCode`, `Quality.HoldTypeCode`, `Quality.DispositionCode`,
`OEE.DowntimeSourceCode`, `Audit.LogSeverity`.

## 4. Heading-case mismatch — `OEE` vs `Oee`

The doc writes `## 6. OEE Schema`; the database schema is `Oee`. The generator
matches case-insensitively and SQL Server resolves `[OEE].[Shift]` fine under
the default collation, so nothing breaks. Worth fixing at the source anyway,
because every other schema heading matches its database name exactly and this
one silently does not.

## Re-running this check

```bash
node sql/scripts/gen_extended_properties.js --stats
```

The `--stats` mode reports section and description counts plus any table with
neither a description nor any described column. The full drift comparison
against a live database is the query in this note's git history; folding it
into the script as a `--check` mode is the obvious next step if this becomes a
recurring check rather than a one-off.
