# Ignition UDT + Programmable Device Simulator — format reference samples

Provided by Jacques 2026-07-13 as ground-truth for the exact Ignition 8.3 tag JSON /
simulator CSV format the PLC-UDT build must match. Referenced by the design spec
`docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md` §3.4.

| File | What it demonstrates |
|------|----------------------|
| `SampleUDT.json` | A UDT **definition**: `parameters` block; members with `valueSource` = `opc` / `memory` / `expr` / `reference`; OPC members using `opcServer` + `opcItemPath.bindType:"parameter"` with `ns=1;s=[{Device}]{BasePath}N`; an expression member referencing siblings via `{[.]Tag}`; an `eventScripts` `valueChanged` handler (tab-indented Jython). |
| `SampleUDTInstance.json` | A UDT **instance**: `tagType:"UdtInstance"`, `typeId`, parameter overrides only, member value overrides. |
| `ProgrammableDeviceSimulator_sample.csv` | The Inductive Automation **Programmable Device Simulator** program format: `Time Interval, Browse Path, Value Source, Data Type`. `Value Source` examples: `ramp(...)`, `random(...)`, `sine(...)`, `readonly(x)`, and plain literals (`false`/`0`/`""`) = **writeable** tags. Our sim uses the writeable-literal pattern (one row per member per device). |

**How these map to our design:**
- Our 4 UDT definitions follow `SampleUDT.json`, parameterized by `{OpcServer}` / `{Device}` / `{BasePath}`.
- Our `MPP_Sim` simulator program CSV follows `ProgrammableDeviceSimulator_sample.csv`, all rows writeable.
- Instances follow `SampleUDTInstance.json`, with `{OpcServer}=Ignition OPC UA Server`, `{Device}=MPP_Sim` in dev.
