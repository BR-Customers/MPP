# Ignition 8.3 Context Pack

A portable knowledge pack for working with Ignition 8.3 file-based Perspective projects — distilled from real production work and DevTools-verified observations. Drop it in a repo where engineers (and AI coding agents) need shared grounding on how Ignition projects are structured, what conventions to follow, and what gotchas to watch for.

The content is technology-specific (Ignition 8.3 file-based projects, Perspective module) but vendor-neutral — it does not assume a particular integrator package name, project domain, database backend, or theming system.

## What's inside

| File | Topic |
|---|---|
| `01_project_layout.md` | Filesystem shape of a file-based 8.3 project. `resource.json` metadata model, scope codes, project inheritance. |
| `02_perspective_views.md` | `view.json` structure: top-level keys, component tree, bindings, events, style classes, page-config router, session props, common idioms. |
| `03_script_python.md` | `script-python` package layout, standard CRUD module shape, `Common.Db` / `Common.Ui` / `Common.Util` / `Common.Notify` helper implementations (`execList`, `execOne`, `execMutation`, `notifyResult`, `toast`, `log`, `_currentAppUserId`, `extractQualifiedValues`, `convertWrapperObjectToJson`), data-shape conventions for UI bindings. |
| `04_named_queries.md` | Named-query layout (`version: 2` schema; Designer-canonical `sqlType` codes), thin `EXEC` wrapper convention, dataset → `list[dict]` consumption, default status-row mutation pattern (BIT `@Status` 1/0). |
| `05_lifecycle_and_timers.md` | Project lifecycle scripts (`startup`, `shutdown`, `update`) and timer-script structure. |
| `06_component_quirks.md` | DevTools-verified specifics: actual DOM class names, format-token differences between components, table-component virtualized DOM, value type quirks. |
| `07_conventions_and_antipatterns.md` | View authoring rules ("root" container, no `psc-` prefix, `position.display` for conditional flex visibility, underscore folder convention, no drag-and-drop). Save semantics (`editDraft` + explicit Save, no auto-save, no nav guard, dirty indicator). Versioned-entity workflow (Draft / Published / Deprecated, optimistic locking via `RowVersion`, `EffectiveFrom` scheduled-publish). Audit user attribution via `session.custom.appUserId`. Mutation feedback via `notifyResult`. Anti-patterns to flag rather than silently propagate. |
| `08_custom_icon_libraries.md` | Custom icon library setup (8.3 path moved from 8.1's `data/modules/...`); SVG sprite format; viewBox + no-fill-on-path rules; recolor mechanism; Material Symbols GitHub source URL pattern for non-default axes. |
| `09_repo_gateway_sync.md` | Repo-as-source-of-truth dev workflow: Gateway project folders as directory junctions into the repo working tree, the scan-to-register loop (`POST /data/api/v1/scan/projects`), the one-time elevated link setup (incl. converting Designer-created real folders), and the deploy-box `pull.ps1` mechanism. |

Read in order if you're new to Ignition projects. Skim by topic if you're solving a specific problem.

## How to prompt with this pack

Ignition is unusual enough — file-based project layout, Jython scripts, a custom expression language, virtualized DOM components — that AI agents do not have reliable training on it and tend to hallucinate plausible-looking things that don't actually work. Feeding this pack into the agent's context closes a lot of those gaps.

Three integration patterns, pick whichever fits your team's setup:

### Pattern 1 — Reference from `CLAUDE.md` / `AGENTS.md`

Add a short section to your repo's agent-instructions file pointing at this pack:

```markdown
## Ignition development reference

When writing or editing anything under `ignition/projects/`, read the
`ignition-context-pack/` files at the relevant level of detail:

- Project structure questions       → 01_project_layout.md
- Perspective view authoring        → 02_perspective_views.md + 06_component_quirks.md
- Jython script modules             → 03_script_python.md
- Named queries / DB access         → 04_named_queries.md
- Project lifecycle / timers        → 05_lifecycle_and_timers.md
- Custom icon libraries             → 08_custom_icon_libraries.md
- Repo ↔ Gateway sync / linking      → 09_repo_gateway_sync.md
- All view authoring (always read)  → 07_conventions_and_antipatterns.md
```

The agent will fetch them on demand. This is the lowest-overhead integration — no setup beyond placing the files in the repo.

### Pattern 2 — Inject into long-lived agent memory

If your tooling supports persistent agent memory (Claude Code's auto-memory, Cursor rules, Cline custom instructions, etc.), copy the pack contents into one or more memory entries. The agent will carry the knowledge across sessions without re-reading the files each time.

Suggested memory split if your tool has size limits per entry:

- One entry per topic file (six entries) — clean per-topic loading
- Or one big entry combining files 01–07 (~25 KB) — single load, denser

### Pattern 3 — Paste relevant sections at task start

For one-off prompts in a chat-style interface, paste the specific section you need into the conversation along with your task. Most useful for ad-hoc work where setting up persistent memory is overkill.

## Per-task prompting tips

When asking an agent to do Ignition work, name the relevant files explicitly. The agent will infer how to apply them, but stating the rule prevents drift:

- **"Build a new Perspective view"** — "follow the `view.json` structure in `02_perspective_views.md` and the conventions in `07_conventions_and_antipatterns.md`. Top-level component keeps `meta.name: "root"`. Reference style classes by suffix only (no `psc-` prefix). Use `position.display` for conditional flex visibility. Form inputs bind bidirectionally to `view.custom.editDraft.*` — never auto-save on writeback."
- **"Add a CRUD module"** — "follow the standard module shape in `03_script_python.md`. Mirror the `getAll` / `getOne` / `add` / `update` / `deprecate` surface. Entity scripts call `<integrator>.Common.Db.*` helpers, never `system.db.*` directly. Pass `@AppUserId` via `Common.Util._currentAppUserId()`. Pass `@RowVersion` on Update / Deprecate for optimistic locking."
- **"Add a named query"** — "thin `EXEC` wrapper per `04_named_queries.md`. Mutations follow the status-row pattern (`SELECT @Status, @Message, @NewId`) and are consumed via `Common.Db.execMutation`. No OUTPUT params."
- **"Wire up a Save button"** — "follow Save semantics in `07_conventions_and_antipatterns.md`: Save is an explicit user click that reads `view.custom.editDraft`, calls the entity script's `update` / `add`, routes the result through `Common.Ui.notifyResult`, commits `selected = editDraft` on success, sends `refreshTrigger`. No auto-save on bindings, no nav guard, dirty indicator via expression."
- **"Fix table styling"** — "table component DOM is virtualized — consult `06_component_quirks.md` for actual class names before writing CSS selectors."

## Versioning + portability

Each file is self-contained — no cross-file imports, no `<<include>>` directives. Topics overlap intentionally where understanding requires context (e.g., scope codes appear in `01_project_layout.md` and are referenced from `02_perspective_views.md`). Add or correct as your team learns more about Ignition; the goal is a living document, not a frozen reference.

When you genuinely verify something through DevTools or running code, capture it in the pack with a short "verified via …" note. When something is theoretical or extrapolated, mark it as such — agents will run with whatever you write, so be explicit about confidence level.

## Out of scope

This pack focuses on **file-based Perspective projects in Ignition 8.3**. It does not cover:

- Vision module (legacy)
- Tag Historian configuration, alarm pipelines, OPC-UA server config
- UDT design and parameterization beyond the basics
- Gateway-level configuration (DB connections, identity providers, modules)
- Edge / SCADA integration patterns

Refer to Inductive Automation's official documentation for those.

## Feedback

If you find a section that is wrong, incomplete, or has drifted out of date relative to your Ignition version, edit it in place. The pack lives or dies by being current; stale guidance is worse than no guidance.
