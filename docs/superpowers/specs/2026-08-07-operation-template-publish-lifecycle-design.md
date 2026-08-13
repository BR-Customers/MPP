# Operation Template Draft/Published lifecycle — design (FAT-OQ-030)

**Date:** 2026-08-07
**Brief:** `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief A
**FAT row:** FAT-OQ-030
**Migration:** `0053`
**Branch:** `jacques/working`

## Problem

`Parts.OperationTemplate` never received the Draft/Published/Deprecated retrofit that
`Parts.RouteTemplate` and `Parts.Bom` got in `0007_bom_and_route_publish.sql`. Its only
lifecycle columns are `VersionNumber` + `DeprecatedAt`, so:

- `OperationTemplate_CreateNewVersion` clones the parent into `Version+1` **immediately live** —
  there is no editable Draft stage; the moment a new version is cloned it can resolve into
  execution.
- The entity `getVersionsForCode` marks the highest non-deprecated version "active" with **no
  Published gate**.
- The editor has no Publish button and no Draft/Published badge.

FAT-OQ-030 requires: *creating a new template version follows the Draft/Published/Deprecated
lifecycle; the prior version is retained.*

## Approach

Mirror the shipped `RouteTemplate` publish pattern exactly. The `RouteTemplate_Publish` /
`RouteTemplate_DiscardDraft` procs, the `PublishedAt` column semantics (NULL = Draft, set =
Published), and the atomic single-Published invariant are the reference of record.

### Current `Parts.OperationTemplate` shape (post-0006/0027/0032/0033)

`Id, Code, VersionNumber, Name, OperationTypeId (NOT NULL FK), Description,
RequiresSubLotSplit, CreatedAt, DeprecatedAt`. **No `PublishedAt`. No `CreatedByUserId`**
(unlike RouteTemplate/Bom — so the Publish proc audits with `@AppUserId` only, and no
`CreatedByUserId` is emitted in audit JSON).

### 1. Migration `0053` — add + backfill `PublishedAt`

```sql
ALTER TABLE Parts.OperationTemplate ADD PublishedAt DATETIME2(3) NULL;   -- NULL = Draft
-- Backfill: every existing non-deprecated row becomes Published as-of its CreatedAt so
-- current routes keep resolving (mirrors 0007's RouteTemplate retrofit intent).
UPDATE Parts.OperationTemplate SET PublishedAt = CreatedAt WHERE DeprecatedAt IS NULL;
```

Idempotent guards (`COL_LENGTH ... IS NULL`) around the ALTER, per the 0032/0033 style. The
backfill runs once inside the same versioned migration. Deprecated rows are intentionally left
`PublishedAt = NULL` (they never resolve anyway; leaving them Draft-shaped is harmless and
avoids fabricating a publish timestamp for a retired row).

### 2. `Parts.OperationTemplate_Publish` (new repeatable proc)

Clone of `R__Parts_RouteTemplate_Publish.sql`, adapted:

- Params: `@Id BIGINT, @AppUserId BIGINT`. (No `@EffectiveFrom`/`@Name` overrides — OperationTemplate
  has no `EffectiveFrom`, and Name is edited via `_Update` on the Draft before publish. Keeping the
  surface minimal.)
- Pre-transaction rejections (each SELECTs the status row + `RETURN`s, no open txn — INSERT-EXEC /
  Msg-3915 rule): required-param missing; row not found; already deprecated; already published.
  **No zero-steps guard** (that is a route concept; an OperationTemplate with zero fields is
  legitimate).
- Atomic single-Published invariant: in the transaction, deprecate any **other** row of the same
  `Code` that is currently Published-and-not-Deprecated (`DeprecatedAt = SYSUTCDATETIME()` WHERE
  `Code = @Code AND Id <> @Id AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL`), capturing
  their `VersionNumber`s via `OUTPUT` for the audit narrative + success message. This enforces
  "at most one Published-and-not-Deprecated version per Code" and auto-retires the prior published
  version on publish — same model as `RouteTemplate_Publish` v3.2 / `Bom_Publish` v4.0.
- Flip `PublishedAt = SYSUTCDATETIME()` on `@Id`.
- Audit: `Audit.Audit_LogConfigChange`, `@LogEntityTypeCode = N'OperationTemplate'`,
  `@LogEventTypeCode = N'Updated'`. Description shape `<SUBJECT> · <CATEGORY> · <ACTION>` where
  SUBJECT = `Code vN`, e.g. `M-Out-A v2 · Operation Template · Published (deprecated v1)`.
  `OldValue`/`NewValue` = resolved-FK JSON snapshots of the row (header + `OperationType` resolved
  sub-object). `Audit.ufn_TruncateActivity`, `Audit.ufn_MidDot()`.
- End with `SELECT @Status AS Status, @Message AS Message;` (no `@NewId` — publish mutates in
  place). CATCH: `ROLLBACK` + best-effort `Audit_LogFailure` + `RAISERROR`.

### 3. `Parts.OperationTemplate_DiscardDraft` (new repeatable proc)

Clone of `R__Parts_RouteTemplate_DiscardDraft.sql`, adapted: hard-delete an unpublished Draft
row plus its `OperationTemplateField` children. Rejects if `PublishedAt IS NOT NULL` ("Use
Deprecate instead") or `DeprecatedAt IS NOT NULL`. Pre-state JSON snapshot into audit `OldValue`;
`@LogEventTypeCode = N'Deleted'`. Included for parity — `CreateNewVersion` now produces Drafts that
engineering may want to abandon without burning a permanent deprecated row. Same INSERT-EXEC /
Msg-3915 discipline (validations before `BEGIN TRANSACTION`).

### 4. `CreateNewVersion` + `Create` leave the clone a **Draft**

`OperationTemplate_CreateNewVersion` already inserts without a `PublishedAt` column, so once the
column exists (default NULL) the clone is **born a Draft** with **no code change** — the prior
published version stays active until the new Draft is published. `OperationTemplate_Create`
(new-Code family, version 1) likewise inserts no `PublishedAt`, so a brand-new template is also
born a Draft and must be Published before it resolves. This is the intended lifecycle and matches
RouteTemplate/Bom (both Create-as-Draft). No signature change to either proc; only their header
change-logs get a note. The backfill (§1) protects every pre-existing row.

### 5. Surface `PublishedAt` in reads + gate "active" on it

- `OperationTemplate_Get` and `OperationTemplate_List`: add `ot.PublishedAt` to the SELECT list
  (append after `CreatedAt`). NQs are proc pass-throughs, so no NQ file change is needed for these
  two — the new column flows automatically. Test temp-table shapes that `INSERT ... EXEC` these
  procs must add the trailing `PublishedAt DATETIME2(3)` column.
- Resolver NQ `parts/OperationTemplate_GetForRouteRole/query.sql`: add
  `AND ot.PublishedAt IS NOT NULL` so a Draft template referenced by a route step can **never**
  resolve into execution.
- Entity `getVersionsForCode`: compute "IsActive" as the highest-version row that is **both**
  `DeprecatedAt IS NULL` **and** `PublishedAt IS NOT NULL`, and add a per-version `Published`
  bool to the returned dicts so the UI can render a Draft state. (Requires the `List` proc to
  return `PublishedAt`, done above.)

### 6. Editor — Publish button + Draft/Published badge

View `BlueRidge/Views/Parts/OperationTemplates/view.json`:

- **State badge** next to the existing version badge (`SummaryBadgeVersion`) + deprecated badge
  (`SummaryBadgeDeprecated`). Two new sibling labels bound on `view.custom.editDraft.meta`:
  - `Draft` (class `badge badge-draft` or reuse an existing neutral badge class) — visible when
    `{...PublishedAt} = null && {...DeprecatedAt} = null`.
  - `Published` (class `badge badge-published`/reuse) — visible when
    `{...PublishedAt} != null && {...DeprecatedAt} = null`.
  (The existing `Deprecated` badge already covers the deprecated state.) Expression language is
  C-style (`=`, `!=`, `&&`), not Python — per `feedback_ignition_expression_language_operators`.
- **Publish button** in the detail action row (alongside Save / New Version / Deprecate). Visible
  only for a Draft (`PublishedAt = null && DeprecatedAt = null`). On click → entity
  `OperationTemplate.publish(id)` → on Status=1, reload the selected template + `templateListRefresh`
  page message (mirror the New Version button's refresh handler).
- Version-dropdown label transform (inline `code` transform at ~line 922 / entity
  `formatVersionDropdownOptions`): render `(Draft)` when the version is unpublished-and-not-deprecated,
  keeping `(Active)` / `(Deprecated)`.
- The `getOne`-fed `editDraft.meta` will carry `PublishedAt` once `OperationTemplate_Get` returns
  it — the badge/button bindings read it directly. No new custom prop needs pre-declaring beyond
  the badge/button bindings (meta already exists, fully shaped, from `_loadTemplate`).

### 7. Entity `publish` method + `parts/OperationTemplate_Publish` NQ

- Entity `BlueRidge.Parts.OperationTemplate.publish(operationTemplateId)` → `execMutation`
  `parts/OperationTemplate_Publish` with `{id, appUserId}` (mirror `deprecate`). Optional
  `discardDraft(id)` → `parts/OperationTemplate_DiscardDraft`.
- New NQ `parts/OperationTemplate_Publish` (`query.sql` = `EXEC Parts.OperationTemplate_Publish
  @Id=:id, @AppUserId=:appUserId`; `resource.json` mirrors `RouteTemplate_Publish`'s —
  `type: "Query"`, `database: "MPP"`, params `id`/`appUserId` sqlType 3=BIGINT, `scope: "DG"`).
  Optional matching `parts/OperationTemplate_DiscardDraft` NQ.

## Testing (extend `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`)

TDD — add before/with the build:

1. **Create-is-Draft:** a freshly `Create`d template has `PublishedAt IS NULL`.
2. **Publish happy path:** `Publish` a Draft → Status 1, `PublishedAt` now set.
3. **Publish idempotence rejection:** publishing an already-Published row → Status 0.
4. **Publish deprecated rejection:** deprecate then publish → Status 0.
5. **New-version-is-Draft + prior-retained-and-still-active:** publish v1, `CreateNewVersion` →
   v2 has `PublishedAt IS NULL`; v1 remains Published-and-not-Deprecated (prior version retained
   and still the resolving one).
6. **Single-Published invariant:** publish v2 → v1 auto-deprecated (`DeprecatedAt` set); exactly
   one Published-and-not-Deprecated row for the Code.
7. **Resolver ignores a Draft:** a route step pointing at a Draft OperationTemplate →
   `OperationTemplate_GetForRouteRole` returns no row for that role; pointing at the Published
   version → returns it. (Build a minimal Item→RouteTemplate→RouteStep fixture like Test 16.)
8. **DiscardDraft happy + published-rejection:** discard a Draft → Status 1, row gone; discard a
   Published row → Status 0.
9. Update existing `#Get1` / `#ListAll` / `#ListByType` temp tables with the trailing
   `PublishedAt` column so the `INSERT ... EXEC` shape still matches.

Validation DB: a throwaway `MPP_MES_OpTemplatePublish` (reset flow per
`sql_version_control_guide.md`); **never** reset `MPP_MES_Dev`.

## Out of scope (per brief)

- `Parts.ufn_OperationTemplateForLotRole` resolver convergence.
- The two Assembly latent bugs (AssemblyIn no checkpoint / AssemblyOut no template).

Config-side only.

## Files

- Migration: `sql/migrations/versioned/0053_operation_template_publish.sql`
- Repeatables: `R__Parts_OperationTemplate_Publish.sql`, `R__Parts_OperationTemplate_DiscardDraft.sql`
  (new); `R__Parts_OperationTemplate_Get.sql`, `R__Parts_OperationTemplate_List.sql` (add
  `PublishedAt`); `R__Parts_OperationTemplate_CreateNewVersion.sql`, `_Create.sql` (change-log
  note only).
- NQ: `parts/OperationTemplate_Publish` (+ `_DiscardDraft`) new; `parts/OperationTemplate_GetForRouteRole/query.sql`
  (add publish gate).
- Entity: `ignition/projects/Core/.../BlueRidge/Parts/OperationTemplate/code.py` (`publish`,
  `discardDraft`, `getVersionsForCode` gate + `Published` flag, `formatVersionDropdownOptions` Draft label).
- View: `BlueRidge/Views/Parts/OperationTemplates/view.json` (badge + Publish button + dropdown label).
- Test: `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`.

## Risks / notes

- **View file-edit reliability.** Editing the 1501-line existing `view.json` on disk risks the
  Designer GSON `=` escape / cache-race issues (`feedback_ignition_designer_unicode_escapes`,
  `feedback_ignition_view_edit_boundary`). Mitigation: anchor edits on escape-free text, keep
  Designer closed during the edit, run `.\scan.ps1` after, verify in the running gateway. The
  view.json + scan lane is single-lane across Briefs A/C/D/F — coordinate (run scan once, check
  `git status` first).
- **Behavior change:** after this lands, newly-created templates (via `Create` **or**
  `CreateNewVersion`) are Drafts and must be Published before routes resolve them. Existing rows are
  backfilled so nothing in production stops resolving. This is the intended FAT-OQ-030 behavior.
