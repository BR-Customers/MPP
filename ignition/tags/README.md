# PLC UDT tag artifacts (`ignition/tags/`)

Ignition **Gateway tags live outside the project export** that `scan.ps1` syncs, so
these are plain tracked files that get **imported at deploy** (not picked up by a
project scan). Spec: `docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md`
(Sec 3 + Sec 8). Plan 2: `docs/superpowers/plans/2026-07-13-plc-integration-plan2-ignition-udts-sim.md`.

## What's here

| Path | What |
|------|------|
| `generate_tags.py` | **Source of truth.** One member catalog + the device manifest -> all three artifacts below, so real UDTs and the sim can't drift (spec Sec 8). |
| `udt/*.json` | 4 UDT **definitions** — ScaleStation, SerializedMipStation, NonSerializedMipStation, TrayInspectionStation. |
| `instances/PlcDevices.json` | 22 UDT **instances** (a Folder), one per active device, all pointed at `MPP_Sim`. |
| `sim/MPP_Sim_program.csv` | The **Programmable Device Simulator** program — one writeable row per OPC member per device. |

## Regenerating

```
python ignition/tags/generate_tags.py      # from the repo root
```

Edit the member catalog / datatype maps **in `generate_tags.py` only**, then rerun.
The device list is read from
`reference/legacy_mes_extract/emmd_automation/integration_manifest.csv`.

## Importing into the Gateway (Designer)

Order matters — definitions before instances:

1. **UDT definitions** — Tag Browser -> Import -> select each `udt/*.json`. Place them
   at the root of the `MPP` provider's `_types_` folder (so an instance's `typeId`
   resolves to the bare type name, e.g. `SerializedMipStation`).
2. **Instances** — Tag Browser -> Import `instances/PlcDevices.json` into the `MPP`
   provider root (creates the `PlcDevices/` folder with the 22 instances).
3. **Simulator device** — Config -> OPC Client / Devices -> add a **Programmable
   Device Simulator** named `MPP_Sim` on the **Ignition OPC UA Server**; load
   `sim/MPP_Sim_program.csv` as its program.

Then confirm an instance member reads **Good**: write a value to a `MPP_Sim` tag and
watch e.g. `[MPP]PlcDevices/5G0_A1/DataReady` reflect it.

## Addressing scheme (READ THIS before commissioning)

The OPC member item path is `ns=1;s=[{Device}]{BasePath}<Member>` — the member name
is appended **directly** to `{BasePath}` (exactly the reference `SampleUDT.json`
pattern `[{Device}]{BasePath}0`). **The address separator lives in `{BasePath}`**,
swapped per instance / environment:

- **dev / sim:** `{BasePath} = "<device>/"` (trailing slash) -> resolves to
  `[MPP_Sim]<device>/<member>`, matching the simulator's `<device>/<member>` browse
  paths in the CSV.
- **prod:** set `{BasePath}` per instance to the real device base **including its
  trailing separator**, e.g. `5G0_A1.5G0_A1.` (TopServer/Mitsubishi dotted path).
  Also set `{OpcServer}` (`TopServer` / `OmniServer` / `Ignition OPC UA Server`) and
  `{Device}` to the real connection + device name (see the manifest). **Nothing in
  the definition changes** — only the three instance parameters.

> The spec writes `.<Member>` in Sec 3.4 but a `/` browse path in Sec 7.1, and Sec 6.1
> calls the exact namespace string "a trivial commissioning fill-in". This build
> resolves that to the sample-faithful separator-in-`BasePath` form above.

## Provider name

`BlueRidge.Sim` (the Sim Panel script) and the DB `TerminalPlcDevice.UdtInstancePath`
values reference instances as `[MPP]PlcDevices/<device>`. If the tag provider is not
named `MPP` at commissioning, change `PROVIDER` in
`ignition/projects/Core/ignition/script-python/BlueRidge/Sim/code.py` and re-seed the
`TerminalPlcDevice` mapping paths to match.

## Note on `=` in the JSON

`generate_tags.py` writes literal `=` in the `opcItemPath` bindings (valid JSON,
imports fine). Designer's tag export HTML-escapes it to `=` — so if you re-export
after import you'll see that cosmetic churn; regenerate from the script to normalize.
