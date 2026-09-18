# Release handoff — mutation attribution (the DEV-user fallback removed)

**For:** the agent preparing the prod release. Read `prod-release-context-pack/` first
(`01` → `07`); this note is the scoping input for `02_scoping_a_release.md`, not a runbook.
**Fix commit:** `df99b8d5` on `jacques/working` (on top of `8e501753`).
**Status on 2026-09-18:** merged to `jacques/working`, Dev gateway scanned (no script or
view load errors), new proc applied to `MPP_MES_Dev`. **Runtime smoke test NOT yet done**
(see § 6, gate G0).

---

## 1. The defect, in one paragraph

`BlueRidge.Common.Util._currentAppUserId()` read `system.perspective.getSessionInfo()["custom"]`.
That API returns a **list of every session on the gateway**, so the index threw, a bare
`except` swallowed it, and every call returned the constant `_DEV_APP_USER_ID = 2`. Every
mutation whose caller did not pass `appUserId` itself was audited as AppUser 2. On prod that
row is the seeded **`DEV` / "Dev User"** (created 2026-08-17 alongside SYS). Jacques ran this
against prod on 2026-09-18: **538 `Audit.ConfigLog` rows, 211 `Audit.OperationLog` rows and 91
`Lots.LotMovement` rows** carry `UserId = 2`. Nothing failed and no real person was credited
wrongly; the author is simply lost. Affected: every Config Tool save, the normal Movement Scan
move, ~20 other plant-floor actions, and both gateway timers (shift boundary, partition
maintenance).

The historical rows are **out of scope** for this release. A backfill would be a separate
one-off remediation (`09_one_off_remediation.md`) and Jacques has not asked for one.

## 2. What the fix does

- **No fallback anywhere.** A project-library script cannot identify the calling session, so
  the caller always supplies the user.
- **`Common.Session.currentAppUserId(session)`** (new). Returns `session.custom.appUserId`
  (plant-floor PIN sign-in; the supervisor during an elevation window). Otherwise it resolves
  the **AD login** (`session.props.auth.user.userName`) through the new
  **`Location.AppUser_GetActiveByAdAccount`** proc, on every call (never cached). When neither
  resolves it shows an error toast saying why and returns None.
- **`Common.Util.requireAppUserId(appUserId)`** replaces `_currentAppUserId()` at every
  entity-function site. It passes the id through, and when the id is missing it logs an ERROR
  naming the function. The proc's own required-parameter guard then refuses the write.
- ~70 Config Tool entity functions gained an `appUserId=None` argument. **47 views** now pass
  `appUserId=BlueRidge.Common.Session.currentAppUserId(self.session)` (Location handlers
  take `userId=`).
- Movement Scan also passes `terminalLocationId`.
- Wrappers that used to drop the id now forward it: `RouteTemplate.publishWithSave`,
  `QualitySpec.publish`, `Assembly.handleTrayComplete`.
- Gateway scope: the `PartitionMaintenance` timer and `Oee.Shift.tickShiftBoundary` pass
  `Common.Util.systemAppUserId()` (AppUser 1, SYS).
- Removed: `Util._currentAppUserId`, `Util._DEV_APP_USER_ID`,
  `Session.getCurrentUserId` (no callers), `Oee.Downtime._uid`.
- Docs: `CLAUDE.md` § "Mutation attribution"; `ignition-context-pack/03` + `07` (they taught
  the broken pattern as canonical).

## 3. What ships (from `df99b8d5` alone)

| Pile | Items |
|---|---|
| Versioned migrations | **none** |
| Repeatables | `R__Location_AppUser_GetActiveByAdAccount.sql` — **NEW**, read-only, no schema change |
| Core | 45 script modules (MOD) + NQ `location/AppUser_GetActiveByAdAccount` (**NEW**) |
| MPP | 18 views (MOD) + timer `PartitionMaintenance` (MOD) |
| MPP_Config | 29 views (MOD) |
| Ships nothing | `CLAUDE.md`, `ignition-context-pack/*`, `sql/tests/03_appuser/031_*`, this note |

Exact list: `git diff --name-status 8e501753 df99b8d5`.

## 4. ⚠ The release cannot be scoped to this commit alone — decide first

Prod's last release was `192c77c1` (migration `0089`, SQL only, executed 2026-09-17). Its
last **Ignition** import was the `aec53015` release (2026-09-16); four `ignition/` commits sit
between the two. Confirm prod's actual state in the preview before trusting either. After
`192c77c1` about 80 commits touching `ignition/` or `sql/` are undeployed, including migrations
**`0090` (location IsOeeEnabled), `0091` (line inventory sidebar), `0093`, `0094` (retire
LowInventoryHorizon)**. There is no `0092` in the repo; confirm with Jacques that the gap is
deliberate before the contiguity gate asks. Most of that work has its own handoff in
`notes/2026-09-17_*handoff*` and `notes/2026-09-18_prod-release-handoff-diecast-shift-confirm.md`.

**14 of the 97 files in this fix were also changed by undeployed commits** (the same 14
whether the baseline is `aec53015` or `192c77c1`). An export ships each file's *whole* content
at `-Until`, so a narrow range (`-Since 8e501753 -Until df99b8d5`) does **not** avoid this:
those 14 files carry the other features with them.

| File | Undeployed commits also in it | Feature |
|---|---|---|
| Core `Lots/Lot` | 9: `ca1d7424` `f89525fa` `98df849e` `2cb476cc` `c1121e35` `83e58617` `67947b9d` `079ea185` `9e4125c5` | Line inventory rev 2 |
| Core `Parts/Item` | 6: `bca73704` (0094) `9a9f2311` `ca1d7424` `f706a052` `45c18b95` `1da26dfb` | Line inventory; cutover location-first |
| Core `Parts/ItemLocation` | 4: `2cb476cc` `0a473bcf` `1905f730` `67947b9d` | Line inventory Tolerances |
| MPP_Config `Views/Location/PlantHierarchy` | 3: `667875e8` `b68519c7` `59317a43` | OEE flag (**needs 0090**) |
| Core `Location/Location` | 2: `36bbb744` `1da26dfb` | OEE flag (0090); cutover |
| Core `Oee/Downtime`, `Oee/ShiftOverride` | `412d0914`, `36bbb744` | OEE / downtime manager |
| Core `Parts/Tool`; MPP_Config `Views/Parts/Tools` | `ea5756fe`; `ffeb7c18` | Tool shot count |
| Core `Lots/Shipping`, `Lots/Container`; MPP `AssemblySerialized`, `AssemblyNonSerialized` | `675e000e` | Assembly OUT reprint |
| Core `Oee/Shift` | `8e501753` | Die-cast shift confirm (only adds `labelFor`, read-only) |

Recompute before building: for each file in `git diff --name-only 8e501753 df99b8d5`, run
`git log --oneline <baseline>..8e501753 -- <file>`.

**The reverse also holds.** Each of those other handoffs, shipped from HEAD, would carry this
fix inside the shared files. The die-cast handoff already says so for `Oee/Shift`: a
`Shift/code.py` from HEAD calls `Util.requireAppUserId`, which prod does not have. Any
release built with `-Until` at or after `df99b8d5` must ship **all** of `df99b8d5`, because
the Core helpers, the entity signatures and the view keyword arguments only work together
(§ 5 Test 4).

**Options to put to Jacques, and he decides:**
1. **Ship the whole pending range up to `df99b8d5`** as one release: 0090–0094, OEE
   flagging, line inventory rev 2, Tolerances, tool shot count, cutover location-first,
   Assembly OUT reprint, die-cast shift confirm, and this fix. This is the honest option, but
   it is a much bigger release, and it absorbs the other handoffs, so it needs its own scoping
   and rehearsal. `Build-ChangeExport.ps1 -Since <confirmed Ignition baseline>` gives the
   Ignition side; the preview gives the SQL.
2. **Hold this fix** until the rest of the pending range is ready, then ship together.
3. **Carve out** by back-porting the fix onto a branch cut at `aec53015`. It is mechanical
   (`requireAppUserId` + the view kwargs), but the 14 entangled files would need hand
   re-application, and it forks history. Not recommended.

Every risk and gate below applies to this fix whichever option is chosen.

## 5. Risk, in the four tests of `02_scoping_a_release.md` § 4

**Test 1 — now refuses what it used to allow. YES, deliberately:**
- **Config Tool:** every save now needs an active `Location.AppUser` whose `AdAccount`
  equals the AD login name **exactly**. Anyone without one is refused on every save with the
  toast *"Signed in as 'x', which is not an active MES user…"*. Gate G1.
- **Config Tool login:** if MPP_Config is not requiring login on prod, `auth.authenticated`
  is false, so **every Config save is refused** ("No one is signed in"). Gate G2.
- **Plant floor:** an action taken with no operator signed in (`session.custom.appUserId`
  null) is now refused with a toast. Before, it was written as DEV. The PIN overlay should
  make this rare; verify on the floor (§ 7).

**Test 2 — shared code. YES:** `Common.Util` and `Common.Session` changed, and so did nearly
every entity module. Post-deploy verification must prove a surface outside attribution
still works: one elevated action (e.g. Sort Cage migrate) and one ordinary save toast.

**Test 3 — schema.** None. One new read-only proc.

**Test 4 — does old Ignition work against new SQL?** Yes, since nothing old calls the new
proc, so the SQL step is independent. **But the three Ignition imports are one atomic unit:**
- New Core with old views: every Config save and the fixed plant-floor actions are refused
  (no appUserId passed). A refusal, not corruption.
- New views with old Core: `TypeError: unexpected keyword argument 'appUserId'` on Config
  saves.

Import Core → MPP → MPP_Config back-to-back in a quiet window, then F5 every terminal.

## 6. Pre-flight gates for the runbook

| Gate | Check | Pass |
|---|---|---|
| **G0** | Dev smoke test (not yet done): Config Tool save as a real AD user; PIN sign-in + one Movement Scan | `Audit.ConfigLog` newest row `UserId` = that person (Jacques = 22 on Dev); `LotMovement` row has `MovedByUserId` = operator and a non-null `TerminalLocationId` |
| **G1** | On prod: `SELECT Id, Initials, DisplayName, AdAccount, DeprecatedAt FROM Location.AppUser WHERE AdAccount IS NOT NULL;` compared with the people who use the Config Tool (ask Jacques) | every Config Tool user has an active row with the exact login name |
| **G2** | Prod MPP_Config requires login through the AD identity provider | see below |
| **G3** | `SELECT Id, Initials, DeprecatedAt FROM Location.AppUser WHERE Id = 1;` | SYS present and active (Jacques's screenshot shows it is) |
| **G4** | `SELECT OBJECT_ID('Location.AppUser_GetActiveByAdAccount')` before the SQL step | NULL (repeatable marked NEW) |

**G2 detail.** On Dev, Jacques enabled MPP_Config authentication on 2026-09-18. Those
settings are **uncommitted** in his main checkout: `MPP_Config/ignition/global-props/*`
(identity provider "Active Directory") and a new
`MPP_Config/com.inductiveautomation.perspective/session-permissions/`. **Do not ship Dev's
`global-props` to prod:** it carries gateway-specific names (identity provider, datasource).
The runbook should instead set prod's MPP_Config project properties by hand in the Designer:
identity provider, plus session permissions requiring authentication. Confirm with Jacques
that the prod gateway has an IdP backed by the AD user source. Elevation already validates
against a user source named **"Active Directory"** (`Location.AppUser._ELEVATION_USER_SOURCE`).

Also check the working tree for Designer-pickled values before building (context pack § 3).
Jacques's checkout has an uncommitted MPP `session-props/props.json` whose `terminal` default
carries live Dev values (`DC1-T1`, id 15). It is not part of this fix and must not ship.

## 7. Post-deploy verification (prod)

```sql
-- Config Tool: newest config rows carry a real person, not 2
SELECT TOP 10 LoggedAt, UserId, LEFT(Description, 80) AS D FROM Audit.ConfigLog ORDER BY LoggedAt DESC;
-- Plant floor: newest moves carry the operator and the terminal
SELECT TOP 10 MovedAt, MovedByUserId, TerminalLocationId FROM Lots.LotMovement ORDER BY MovedAt DESC;
-- After the next shift boundary: shift rows are SYS (1), not DEV (2)
SELECT TOP 4 LoggedAt, UserId, LEFT(Description, 80) AS D FROM Audit.OperationLog
WHERE Description LIKE N'%Shift%Started%' OR Description LIKE N'%Shift%Ended%' ORDER BY LoggedAt DESC;
-- Nothing new is attributed to DEV from here on
SELECT COUNT(*) FROM Audit.ConfigLog WHERE UserId = 2 AND LoggedAt > '<window end, UTC>';
```

Gateway log: search for **`called with no appUserId`**. Each line names the entity function
a caller forgot to supply an id to. Any hit is a missed call site: fix it in the calling view,
never with a fallback.

## 8. Rollback

- **SQL:** nothing to roll back. The proc is additive and harmless if left in place.
- **Ignition:** re-import the previous versions of the same resources. Build that archive
  **before** the window from the prod baseline (`aec53015`, or whichever commit the release
  is scoped from). **Rolling back restores the DEV-attribution bug.**

## 9. Evidence already gathered (Dev, 2026-09-18)

- `sql/tests` `03_appuser` **82/82**, including the new `031_AppUser_GetActiveByAdAccount.sql`
  (active resolves; unknown, deprecated and NULL do not).
- All 96 changed view scripts parse, and each reconstructs byte-for-byte from the original
  once the inserted argument is removed.
- A signature check of every `BlueRidge.*` call in every view and script against its target
  function (unknown keyword, duplicate argument, too many positional): **0 issues** after the
  rebase. The checker catches all three kinds when they are planted.
- No `_currentAppUserId` / `getCurrentUserId` reference left anywhere.
- Gateway log after the scan: no script or view load errors.
- Known false positive: `DieCastBody` passes `appUserId` inside the data dict to
  `Lot.openDieCast` / `releaseDieCast`, which a keyword-only scan flags. It is correct.

## 10. Open follow-ups (not in this release)

- About 7 procs do not reject a NULL `@AppUserId`: `PrinterFgAssignment_SaveAll`,
  `Container_Complete`, `ContainerTray_Close`, `ContainerSerial_Add`, `DowntimeEvent_Start`,
  `AimShipperIdPool_Claim`, `Partition_MaintainWindow`. Every caller now supplies one; a SQL
  guard would close the gap for good.
- `Lots.LotLabel._sessionPrinter` and `Lots.ShippingDispatcher._sessionPrinter` still use the
  same broken `getSessionInfo()["custom"]` read. Impact not investigated.
- Optional backfill of the historical DEV-attributed rows (§ 1). For the 91 moves, first
  check whether prod stored a `TerminalLocationId`; without one, matching a move to a sign-in
  is guesswork.
