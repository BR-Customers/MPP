# EMMD automation-config extract — data grids (2026-07-10)

The **data** behind the legacy Flexware **EMMD** (`em` schema) OPC/handshake engine on
`EXCSRV05`, pulled 2026-07-10 during the UDT-design session. The parent
`../` folder holds the EMMD *schema* catalogs (tables/columns/FKs); **this** folder
holds the actual automation-config **rows** (servers, tags, events, actions, scripts) —
the ground-truth PLC touchpoint wiring the new Ignition UDT build is derived from.

## Provenance & fidelity

Transcribed from the SSMS result grids pasted into the 2026-07-10 chat (the legacy DB is
not reachable from the build environment). **Spot-check against a fresh extract before
using as authoritative seed input.** Stored as **TSV** (tab-separated) to preserve values
that contain commas (script bodies, action descriptions) losslessly.

**Regenerate byte-accurate** (on a host that can reach `EXCSRV05`) via the committed
scripts, then *right-click grid → Save Results As… → CSV*:
- `sql/scratch/emmd_extract_udt_tag_map.sql` → grids `#U1..#U4` (parsed/clustered views)
- `sql/scratch/emmd_extract_automation_config.sql` → grids `#H..#N` (raw + script bodies)

## Files (grid → file)

| Grid | File | Contents |
|------|------|----------|
| #U1 | `opc_servers.tsv` | The 2 OPC servers (TOPServer.V5, OmniServer) + PID |
| #U2 | `tag_catalog.tsv` | **Every tag parsed into BasePath + Member** (Read/Write/Trigger) — the UDT member catalog feed |
| #U3 | `device_rollup.tsv` | One row per (Server, BasePath) device instance + member list — the UDT "type" signatures |
| #U4 | `station_chain.tsv` | Line→Task→Event→Action step order = the handshake **sequence** per station (**representative** — see note) |
| #H | `topology.tsv` | Plant → Line → Task tree (Active flags) |
| #I | `events.tsv` | Each Event: watched OPC item + trigger operation/args |
| #M | `trigger_ops.tsv` | TriggerOperation code table (EQ/NEQ/GT/…/ALL=data-change) |
| — | `integration_manifest.csv` | **The commissioning checkoff sheet.** All 22 devices with legacy source, native driver availability, migration strategy, and two validation columns (`ValidatedConnected`, `ValidatedHandshake`) that flip 0→1 as each device is exercised. Referenced from spec §6.2. |

**`station_chain.tsv` is a representative capture:** the scale + MIP lines
(59B / 5A2 / 5G0 / 5J6 / 5K8 / 5PA) carry their full step sequences; the tray-inspection
lines (6B2 / 6C2 / 6FB / 6MA / RPY / Sort) follow the identical `TrayLocked` →
`InspectionComplete` pattern and are condensed to their distinctive steps. Re-pull #U4 for
the byte-complete chain.

## Not re-transcribed (regenerable)

- **#N (143 VBScript bodies)** — the MES-transaction *logic* (`Flexware.MES.EMInterface.MESCore`
  calls: `ProcessContainerAtEndOfLine`, `ProcessSerializedItemAtEndOfLine`,
  `CompleteSerializedContainer`, `ProcessTrayInspectionComplete`, `GetInProcessContainerSortRecipe`,
  serial-validation, etc.). Not cached as TSV: voluminous VBScript with embedded quotes/commas
  = high transcription-corruption risk. Regenerable via grid #N of
  `emmd_extract_automation_config.sql`; the **logic is distilled** in the design spec §5
  (legacy MESCore call → new stored proc mapping) and §3.3 (datatypes from the `CBool/CInt/CDbl`
  casts).
- **#K (OPC item inventory)** — un-deduped read/write list, already reflected (deduped, with
  directions) in `tag_catalog.tsv` (#U2).
- **#J (actions)** / **#L (action data-wiring / IO)** — lowest-level EMMD step/parameter tables;
  fully regenerable via `emmd_extract_automation_config.sql`; useful content reflected in
  `station_chain.tsv` (#U4) + spec §3.3.

## Key facts this data established (see the design spec for full analysis)

- **4 device types** by member signature: ScaleStation (OmniServer), SerializedMipStation
  (5G0/Mitsubishi), NonSerializedMipStation (5A2/Pro-face), TrayInspectionStation
  (MicroLogix 1400).
- **PartType / PartNumber / VisionPartNumber are line-local INTEGER type-codes** (1/2/3),
  mapped to real part numbers inside the scripts (e.g. `1120A-6C2 -A000 → 1`).
- Tray-inspection events trigger on **data-change** then bail if 0 ⇒ act on the **rising edge**.
- Legacy split = EMMD (OPC choreography) + `MESCore` (MES transaction) → new = Ignition
  gateway watcher + our stored procs.
</content>
