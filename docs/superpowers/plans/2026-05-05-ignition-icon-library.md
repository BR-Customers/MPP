# MPP Material Symbols Icon Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a hand-assembled `ignition/icons/mpp.svg` sprite containing the 35 icons locked in `mockup/icons.csv`, ready to deploy to `<gateway>/data/modules/com.inductiveautomation.perspective/icons/mpp.svg` and consume from Perspective views as `mpp/<material_symbol_name>`.

**Architecture:** Single SVG sprite file per IA's documented format (outer `<svg>` containing 35 inner `<svg viewBox="0 0 48 48" id="<name>">…</svg>` blocks). All paths use `fill="currentColor"` so Perspective theme tokens drive icon color. No build pipeline — the committed `mpp.svg` is the source of truth. Companion `README.md` documents the lock spec, sourcing URL pattern, and deployment steps.

**Tech Stack:** Static SVG. Google Material Symbols (Outlined / wght 300 / grade -25 / fill 0 / opsz 48). PowerShell or Node.js for ad-hoc validation. No runtime dependencies in the deliverable.

**Spec:** `docs/superpowers/specs/2026-05-05-ignition-icon-library-design.md`

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `ignition/icons/mpp.svg` | Create | The deployable sprite — 35 icons, IA wrapped-svg format, `fill="currentColor"`. |
| `ignition/icons/README.md` | Create | Lock spec, source URL pattern, deployment steps, regeneration notes. |
| `mockup/icons.csv` | Read-only | Source of truth for which 35 icons + their Material Symbol names. |

---

## Task 1: Create `ignition/icons/` directory and README skeleton

**Files:**
- Create: `ignition/icons/README.md`

- [ ] **Step 1: Verify the parent directory exists**

Run:
```powershell
Test-Path ignition
```
Expected: `True`

- [ ] **Step 2: Create the `ignition/icons/` directory**

Run:
```powershell
New-Item -ItemType Directory -Path ignition\icons -Force | Out-Null
Test-Path ignition\icons
```
Expected: `True`

- [ ] **Step 3: Create `ignition/icons/README.md` with the full content below**

Write to `ignition/icons/README.md`:

````markdown
# MPP Custom Perspective Icon Library

This directory holds `mpp.svg`, the custom icon library deployed to the Ignition gateway under `data/modules/com.inductiveautomation.perspective/icons/mpp.svg`. Perspective references the icons as `mpp/<icon_name>` (e.g., `mpp/play_arrow`).

## Lock spec

The 35 icons are locked against **Material Symbols Outlined** at the following axis combination (set 2026-05-04 in `mockup/icons.csv`):

| Axis | Value |
|---|---|
| Style | Outlined |
| Weight | 300 |
| Fill | 0 |
| Grade | -25 |
| Optical size | 48 |

The locked set lives in `mockup/icons.csv` — that file is the design contract. `mpp.svg` is its Ignition realization.

## Source URL pattern

Each icon is sourced from Google Fonts' static SVG endpoint at the locked axes:

```
https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/<material_symbol_name>/wght300grad_N25/48px.svg
```

(Example: `https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/play_arrow/wght300grad_N25/48px.svg`.)

Fallback if the URL pattern fails for any icon: open https://fonts.google.com/icons, search the icon, set Weight=300 / Grade=-25 / Optical Size=48 / Fill=0, and download the static SVG.

## Cleanup applied to each fetched SVG

1. Preserve the original `viewBox="0 0 48 48"`.
2. Strip any baked-in `fill="#..."` attribute on the root `<svg>` or on `<path>` elements.
3. Set `fill="currentColor"` on each `<path>` so Perspective theme tokens (`--mpp-icon-color`, `--mpp-icon-color-accent`, etc.) drive color.
4. Wrap in `<svg viewBox="0 0 48 48" id="<material_symbol_name>">…</svg>`.
5. Append to `mpp.svg` in the order from `mockup/icons.csv`, grouped by the `group` column (Navigation, Actions, Sections, Status), with section comments.

## Deployment

1. Copy `ignition/icons/mpp.svg` to `<gateway-install>/data/modules/com.inductiveautomation.perspective/icons/mpp.svg`.
2. Refresh any open Perspective session — Ignition 8.1.x hot-reloads custom icon libraries without a gateway restart.
3. Reference icons from views as `mpp/<material_symbol_name>` (e.g., set an Icon component's `path` to `mpp/play_arrow`).

If a gateway restart is needed (older 8.1.x), restart the Ignition Gateway service.

## Regeneration / adding icons

Workflow when adding icon #36+:

1. Add a row to `mockup/icons.csv`.
2. Fetch the new SVG from the URL pattern above.
3. Apply the cleanup steps.
4. Append a new wrapped `<svg id="<name>">` to `mpp.svg` in the appropriate group section.
5. Redeploy `mpp.svg` to the gateway.
````

- [ ] **Step 4: Commit**

```powershell
git add ignition/icons/README.md
git commit -m "icons(ignition): add README for MPP custom Perspective icon library"
```

---

## Task 2: Fetch and prepare the first icon (`play_arrow`) as a sanity check

**Files:**
- Create: `ignition/icons/mpp.svg` (single-icon initial version)

This task validates the URL pattern works, the cleanup steps produce a well-formed SVG, and Perspective renders the result with `currentColor` propagation. Do this before assembling all 35 to catch pattern errors early.

- [ ] **Step 1: Fetch the `play_arrow` SVG at the locked axes**

Try this URL first via PowerShell:
```powershell
$url = "https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/play_arrow/wght300grad_N25/48px.svg"
$response = Invoke-WebRequest -Uri $url -UseBasicParsing
$response.StatusCode
$response.Content
```
Expected: StatusCode `200`, Content begins with `<svg`.

If StatusCode is 404 or content is HTML (not SVG): the URL pattern doesn't serve this exact axis combo. Fallback: open https://fonts.google.com/icons in a browser, search "play arrow", set the four axes per the lock spec, click the SVG download button, and capture the file content. Note the discovered URL or method in `ignition/icons/README.md` for the remaining 34 fetches.

- [ ] **Step 2: Inspect the raw fetched SVG**

Save the raw fetched content to `ignition/icons/_tmp_play_arrow_raw.svg` for inspection only:
```powershell
$response.Content | Out-File -FilePath ignition\icons\_tmp_play_arrow_raw.svg -Encoding utf8
```

Read the file. Note:
- The root `<svg>` element's `viewBox` attribute (should be `0 0 48 48`).
- Any baked-in `fill="..."` on either the root `<svg>` or inner `<path>` elements.
- The path `d="..."` data — this is the actual glyph shape we keep.

- [ ] **Step 3: Apply the cleanup transforms**

Construct the cleaned single-icon block. The pattern (with `<DPATH>` substituted from the raw `d="..."` value):

```xml
    <!-- play_arrow — Forward / play (mockup key: forward) -->
    <svg viewBox="0 0 48 48" id="play_arrow">
        <path d="<DPATH>" fill="currentColor" />
    </svg>
```

If the raw SVG has multiple `<path>` elements, include each one with `fill="currentColor"`. If the raw root `<svg>` has a non-`0 0 48 48` viewBox, keep what was actually served (the implementation must match the source data — do not synthesize).

- [ ] **Step 4: Write the initial single-icon `mpp.svg`**

Create `ignition/icons/mpp.svg` with:

```xml
<?xml version="1.0" encoding="utf-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
    <!--
        MPP MES — Material Symbols icon library
        Lock date: 2026-05-04 (per mockup/icons.csv)
        Style: Outlined · Weight 300 · Fill 0 · Grade -25 · Optical size 48px
        Source: https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/<name>/wght300grad_N25/48px.svg
    -->

    <!-- ===== Navigation ===== -->

    <!-- play_arrow — Forward / play (mockup key: forward) -->
    <svg viewBox="0 0 48 48" id="play_arrow">
        <path d="<DPATH>" fill="currentColor" />
    </svg>

</svg>
```

- [ ] **Step 5: Validate `mpp.svg` is well-formed XML**

Run:
```powershell
[xml]$doc = Get-Content ignition\icons\mpp.svg -Raw
$doc.svg.svg.Count
$doc.svg.svg.id
```
Expected: count is `1`, id is `play_arrow`. If PowerShell throws an XML parse error, the SVG content is malformed — fix and re-run.

- [ ] **Step 6: Deploy single-icon `mpp.svg` to gateway and verify in Perspective**

Manual step (the engineer running this plan does this):
1. Copy `ignition/icons/mpp.svg` to `<gateway>/data/modules/com.inductiveautomation.perspective/icons/mpp.svg`.
2. In Designer, on any view, drop a Perspective Icon component.
3. Set its `path` property to `mpp/play_arrow`.
4. Confirm the icon renders.
5. Set the component's `style.color` (or its parent container's color) to `#22D3EE` (the `--mpp-accent-cyan` token).
6. Confirm the icon recolors to cyan — this proves `fill="currentColor"` propagation works.

If the icon does not render: check gateway logs for SVG parse errors. If it renders but stays black when colored: the `fill="currentColor"` substitution didn't take effect — recheck Step 3.

- [ ] **Step 7: Clean up the temp file**

Run:
```powershell
Remove-Item ignition\icons\_tmp_play_arrow_raw.svg -ErrorAction SilentlyContinue
```

- [ ] **Step 8: Commit the sanity-check sprite**

```powershell
git add ignition/icons/mpp.svg
git commit -m "icons(ignition): seed mpp.svg with play_arrow sanity check"
```

---

## Task 3: Fetch and append the remaining 34 icons

**Files:**
- Modify: `ignition/icons/mpp.svg` (append 34 wrapped `<svg id>` blocks)

The remaining 34 icons in CSV order, grouped by the CSV's `group` column. The complete ordered list (read from `mockup/icons.csv`):

**Navigation (5 — `play_arrow` already done; 4 remaining):** `home`, `arrow_right_alt`, `expand_less`, `expand_more`

**Actions (8):** `check_circle`, `cancel` (used twice — see note below), `pause_circle`, `search`, `lock`, `add_circle`, `edit`

**Sections (20):** `factory`, `account_balance`, `settings`, `tune`, `inventory_2`, `package_2`, `fact_check`, `analytics`, `manage_history`, `handyman`, `engineering`, `verified`, `local_shipping`, `videocam`, `report`, `calendar_month`, `pending_actions`, `group`, `content_cut`, `qr_code_scanner`

**Status (2):** `warning`, `local_fire_department`

**Note on `cancel`:** rows `close` and `reject` in `icons.csv` both map to Material Symbol `cancel`. Fetch and include `cancel` only **once** — in the sprite, `<svg id="cancel">` appears one time; the two CSV keys both resolve to `mpp/cancel`. The CSV's two rows are documentation aliases, not two distinct icons.

That makes the remaining unique fetches: 4 + 7 + 20 + 2 = **33 fetches**, plus `play_arrow` already done = **34 unique `<svg id="…">` blocks** in the final `mpp.svg`.

- [ ] **Step 1: Confirm the unique icon list**

Read `mockup/icons.csv`. Build the deduplicated list of `material_symbol` values:
- Navigation: home, play_arrow, arrow_right_alt, expand_less, expand_more (5)
- Actions: check_circle, cancel, pause_circle, search, lock, add_circle, edit (7 — `cancel` appears for both `close` and `reject` rows; count once)
- Sections: factory, account_balance, settings, tune, inventory_2, package_2, fact_check, analytics, manage_history, handyman, engineering, verified, local_shipping, videocam, report, calendar_month, pending_actions, group, content_cut, qr_code_scanner (20)
- Status: warning, local_fire_department (2)

Total unique: 34 (one of which — `play_arrow` — is already in `mpp.svg`).

- [ ] **Step 2: Fetch each remaining icon and apply cleanup**

For each `<name>` in the list above (excluding `play_arrow`):

```powershell
$names = @(
    "home","arrow_right_alt","expand_less","expand_more",
    "check_circle","cancel","pause_circle","search","lock","add_circle","edit",
    "factory","account_balance","settings","tune","inventory_2","package_2","fact_check","analytics","manage_history","handyman","engineering","verified","local_shipping","videocam","report","calendar_month","pending_actions","group","content_cut","qr_code_scanner",
    "warning","local_fire_department"
)
New-Item -ItemType Directory -Path ignition\icons\_tmp_raw -Force | Out-Null
foreach ($n in $names) {
    $url = "https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/$n/wght300grad_N25/48px.svg"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing
        if ($r.StatusCode -eq 200 -and $r.Content -like "<svg*") {
            $r.Content | Out-File -FilePath "ignition\icons\_tmp_raw\$n.svg" -Encoding utf8
            Write-Host "OK   $n"
        } else {
            Write-Host "FAIL $n  status=$($r.StatusCode)"
        }
    } catch {
        Write-Host "FAIL $n  $($_.Exception.Message)"
    }
}
```

Expected: 33 lines printed, all `OK`. Any `FAIL` line means the URL pattern doesn't serve that name; for failures, fall back to the manual fonts.google.com download (per Task 2 Step 1 fallback) and save the SVG to `ignition/icons/_tmp_raw/<name>.svg` manually.

- [ ] **Step 3: Build the final `mpp.svg` content**

For each raw SVG in `ignition/icons/_tmp_raw/<name>.svg`:
1. Extract the `<path d="…" />` element(s) only — discard the root `<svg>` wrapper from the raw file.
2. For each extracted path: if it has `fill="…"` or `style="fill:…"`, replace with `fill="currentColor"`. If it has neither, add `fill="currentColor"`.
3. Wrap as `<svg viewBox="0 0 48 48" id="<name>">…paths…</svg>`.

Assemble the **complete final** `mpp.svg` in the structure below. Replace each `<PATH-FOR-name>` placeholder with the cleaned `<path>` element(s) for that icon (a single `<path>` for most; multiple `<path>` for icons with multiple subpaths like `pause_circle`).

```xml
<?xml version="1.0" encoding="utf-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
    <!--
        MPP MES — Material Symbols icon library
        Lock date: 2026-05-04 (per mockup/icons.csv)
        Style: Outlined · Weight 300 · Fill 0 · Grade -25 · Optical size 48px
        Source: https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/<name>/wght300grad_N25/48px.svg
    -->

    <!-- ===== Navigation ===== -->

    <!-- home — Home -->
    <svg viewBox="0 0 48 48" id="home"><PATH-FOR-home /></svg>

    <!-- play_arrow — Forward / play (mockup key: forward) -->
    <svg viewBox="0 0 48 48" id="play_arrow"><PATH-FOR-play_arrow /></svg>

    <!-- arrow_right_alt — Flow / next (mockup key: flow) -->
    <svg viewBox="0 0 48 48" id="arrow_right_alt"><PATH-FOR-arrow_right_alt /></svg>

    <!-- expand_less — Sort ascending (mockup key: sort-up) -->
    <svg viewBox="0 0 48 48" id="expand_less"><PATH-FOR-expand_less /></svg>

    <!-- expand_more — Sort descending (mockup key: sort-down) -->
    <svg viewBox="0 0 48 48" id="expand_more"><PATH-FOR-expand_more /></svg>

    <!-- ===== Actions ===== -->

    <!-- check_circle — Confirm / success (mockup key: check) -->
    <svg viewBox="0 0 48 48" id="check_circle"><PATH-FOR-check_circle /></svg>

    <!-- cancel — Close / dismiss (mockup keys: close, reject) -->
    <svg viewBox="0 0 48 48" id="cancel"><PATH-FOR-cancel /></svg>

    <!-- pause_circle — Pause LOT (mockup key: pause) -->
    <svg viewBox="0 0 48 48" id="pause_circle"><PATH-FOR-pause_circle /></svg>

    <!-- search — Search -->
    <svg viewBox="0 0 48 48" id="search"><PATH-FOR-search /></svg>

    <!-- lock — Auth / lock -->
    <svg viewBox="0 0 48 48" id="lock"><PATH-FOR-lock /></svg>

    <!-- add_circle — Add / create (mockup key: add) -->
    <svg viewBox="0 0 48 48" id="add_circle"><PATH-FOR-add_circle /></svg>

    <!-- edit — Edit -->
    <svg viewBox="0 0 48 48" id="edit"><PATH-FOR-edit /></svg>

    <!-- ===== Sections ===== -->

    <!-- factory — Plant / factory (mockup key: plant) -->
    <svg viewBox="0 0 48 48" id="factory"><PATH-FOR-factory /></svg>

    <!-- account_balance — Enterprise (ISA-95) (mockup key: enterprise) -->
    <svg viewBox="0 0 48 48" id="account_balance"><PATH-FOR-account_balance /></svg>

    <!-- settings — Parts / settings (mockup key: parts) -->
    <svg viewBox="0 0 48 48" id="settings"><PATH-FOR-settings /></svg>

    <!-- tune — System config (mockup key: system) -->
    <svg viewBox="0 0 48 48" id="tune"><PATH-FOR-tune /></svg>

    <!-- inventory_2 — Item Master (mockup key: item) -->
    <svg viewBox="0 0 48 48" id="inventory_2"><PATH-FOR-inventory_2 /></svg>

    <!-- package_2 — Container (mockup key: container) -->
    <svg viewBox="0 0 48 48" id="package_2"><PATH-FOR-package_2 /></svg>

    <!-- fact_check — Operation Templates (mockup key: list) -->
    <svg viewBox="0 0 48 48" id="fact_check"><PATH-FOR-fact_check /></svg>

    <!-- analytics — Reports / trends (mockup key: reports) -->
    <svg viewBox="0 0 48 48" id="analytics"><PATH-FOR-analytics /></svg>

    <!-- manage_history — Audit log (mockup key: audit) -->
    <svg viewBox="0 0 48 48" id="manage_history"><PATH-FOR-manage_history /></svg>

    <!-- handyman — Tools (config) (mockup key: tools) -->
    <svg viewBox="0 0 48 48" id="handyman"><PATH-FOR-handyman /></svg>

    <!-- engineering — Maintenance (FUTURE) (mockup key: maintenance) -->
    <svg viewBox="0 0 48 48" id="engineering"><PATH-FOR-engineering /></svg>

    <!-- verified — Quality (mockup key: quality) -->
    <svg viewBox="0 0 48 48" id="verified"><PATH-FOR-verified /></svg>

    <!-- local_shipping — Shipping (mockup key: shipping) -->
    <svg viewBox="0 0 48 48" id="local_shipping"><PATH-FOR-local_shipping /></svg>

    <!-- videocam — Vision / camera (mockup key: vision) -->
    <svg viewBox="0 0 48 48" id="videocam"><PATH-FOR-videocam /></svg>

    <!-- report — Defect codes (mockup key: defects) -->
    <svg viewBox="0 0 48 48" id="report"><PATH-FOR-report /></svg>

    <!-- calendar_month — Shift schedules (mockup key: schedule) -->
    <svg viewBox="0 0 48 48" id="calendar_month"><PATH-FOR-calendar_month /></svg>

    <!-- pending_actions — Operations / time (mockup key: ops) -->
    <svg viewBox="0 0 48 48" id="pending_actions"><PATH-FOR-pending_actions /></svg>

    <!-- group — Users (mockup key: user) -->
    <svg viewBox="0 0 48 48" id="group"><PATH-FOR-group /></svg>

    <!-- content_cut — Trim shop (mockup key: trim) -->
    <svg viewBox="0 0 48 48" id="content_cut"><PATH-FOR-content_cut /></svg>

    <!-- qr_code_scanner — Barcode / scan (mockup key: qr) -->
    <svg viewBox="0 0 48 48" id="qr_code_scanner"><PATH-FOR-qr_code_scanner /></svg>

    <!-- ===== Status ===== -->

    <!-- warning — Warning -->
    <svg viewBox="0 0 48 48" id="warning"><PATH-FOR-warning /></svg>

    <!-- local_fire_department — Hot / urgent (mockup key: fire) -->
    <svg viewBox="0 0 48 48" id="local_fire_department"><PATH-FOR-local_fire_department /></svg>

</svg>
```

Write the assembled content to `ignition/icons/mpp.svg` (overwriting the single-icon Task 2 version).

- [ ] **Step 4: Validate the assembled `mpp.svg`**

Run:
```powershell
[xml]$doc = Get-Content ignition\icons\mpp.svg -Raw
$ids = $doc.svg.svg | ForEach-Object { $_.id }
Write-Host "Total icons: $($ids.Count)"
$ids | Sort-Object | Out-Host
```
Expected: `Total icons: 34` (34 unique icons; `cancel` appears once though it serves both `close` and `reject` aliases).

Confirm the printed list matches the 34 unique Material Symbol names. If count differs or any name is missing, fix `mpp.svg` and re-run.

- [ ] **Step 5: Visual verification — full library in a Perspective view**

Manual step:
1. Copy `ignition/icons/mpp.svg` to `<gateway>/data/modules/com.inductiveautomation.perspective/icons/mpp.svg`.
2. Refresh Perspective.
3. In a throwaway view, drop 34 Icon components and set each `path` to `mpp/<each-name>`. Or, simpler: open `mockup/icon-explorer.html` in a browser side-by-side and visually compare.
4. Confirm each icon renders at the matching weight 300 / grade -25 character. Any icon that looks heavier, lighter, or filled — its source URL pulled the wrong axis combo. Re-fetch using the manual fonts.google.com fallback for that one icon.

- [ ] **Step 6: Clean up `_tmp_raw/`**

Run:
```powershell
Remove-Item -Recurse -Force ignition\icons\_tmp_raw
```

- [ ] **Step 7: Commit**

```powershell
git add ignition/icons/mpp.svg
git commit -m "icons(ignition): assemble full 34-icon mpp.svg from Material Symbols"
```

---

## Self-review (run after writing this plan, not at execution time)

**Spec coverage:**
- Sprite at `ignition/icons/mpp.svg` with 35 logical icons (34 unique — `cancel` serves two aliases) ✓ Tasks 2 + 3
- IA wrapped-svg format, viewBox 0 0 48 48, fill currentColor ✓ Tasks 2 + 3 (steps showing format)
- Repo path mirrors gateway path ✓ Task 1
- README documenting lock spec, source pattern, deployment, regen ✓ Task 1 Step 3
- First-icon sanity check before mass assembly ✓ Task 2
- Visual verification of full library ✓ Task 3 Step 5
- Naming = Material Symbol names (e.g., `mpp/play_arrow`) ✓ throughout

**Placeholder scan:**
- `<DPATH>` and `<PATH-FOR-name>` are intentional substitution markers, with adjacent instructions for what to substitute. Not "TODOs."
- "Manual step" callouts in Task 2 Step 6 and Task 3 Step 5 are intentional — Perspective rendering can't be unit-tested from the plan-runner; the engineer/agent doing the deploy must verify in Designer.

**Type / name consistency:**
- `mpp` library name consistent across spec, README, and references throughout.
- 34 unique icons / 35 CSV rows (`cancel` dedup) is called out explicitly in Task 3 preamble and validated in Task 3 Step 4. The Step 4 expected count is 34, matching the assembly structure in Step 3.
- All 34 Material Symbol names listed in the Step 2 PowerShell array exactly match the `<svg id="…">` entries in the Step 3 final-content template.

No gaps detected.
