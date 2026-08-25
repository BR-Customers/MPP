# Report build tooling

Ignition Reporting Module reports are committed as `data.bin` — a gzipped binary
object graph. **The binary is an output. Do not hand-edit it.**

Source of truth for the Lot Detail report:

| File | What |
|---|---|
| `lot_detail/layout.xml` | ReportMill page layout (points, 612x792 letter) |
| `lot_detail/queries.py` | Parameters + data sources (SQL, tokens, nesting) |
| `build_lot_detail_report.py` | Assembles them onto the donor envelope |
| `verify_lot_detail_report.py` | Parses a built `data.bin` and prints its structure |
| `nesting_builder.py` | Adds nested-child-query support to the skill's builder |

Regenerate and deploy:

```
python tools/reports/build_lot_detail_report.py
.\scan.ps1
```

`scan.ps1` DOES reload a changed report `data.bin` — no gateway restart.

Three things that fail silently and cost hours:

- A report resolves by its internal `setTitle`, NOT its folder name. Folder name,
  `setTitle`, and the `BlueRidge.Reports` registry `reportPath` must all match.
- A raw `&` / `<` / `>` in a layout literal throws `RMException` at render time,
  shown as a generic "invalid report". The generator XML-parses the layout first.
- Unresolved `@tokens@` and bad layout render BLANK and log nothing. Always render
  and look at the output; a clean load proves nothing.

The generic mechanics (binary format, codec, ReportMill vocabulary) live in the
global `ignition-reporting` skill; MPP-specific notes are in
`ignition-context-pack/10_reporting_module.md`.
