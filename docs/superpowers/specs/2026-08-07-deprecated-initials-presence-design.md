# Deprecated initials blocked at presence sign-in — design (FAT-USR-090)

**Date:** 2026-08-07
**FAT row:** FAT-USR-090 (FDS-04-005)
**Brief:** `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief E
**Source triage:** `notes/2026-08-07_fat-failure-remediation-brief.md` § Spec E
**Status:** design for approval

---

## 1. Problem

FDS-04-005 (and the FAT acceptance) requires that shop-floor initials which are **unknown
_or deprecated_** are rejected at presence sign-in; the system SHALL NOT auto-create users from
unknown initials. Today **unknown** initials are blocked but **deprecated** initials are not — a
retired operator can still sign in and stamp mutations, corrupting Honda genealogy attribution.

### Evidence

- `sql/migrations/repeatable/R__Location_AppUser_GetByInitials.sql:36-45` returns the matching row
  with **no `DeprecatedAt` filter** — by design (see §2 contract).
- `ignition/projects/Core/.../BlueRidge/Location/AppUser/code.py:154-179` `resolveForPresence` marks
  **any** found row `valid=True` — no deprecated check. Consumed by the per-mutation `InitialsField`
  (`.../PlantFloor/InitialsField/view.json:58`).
- `ignition/projects/MPP/.../Popups/InitialsEntry/view.json:229` `submitInitials` calls
  `getByInitials` **directly**, then `loginAs(...)` on any non-null row — the **shift-start sign-in**
  path, a second surface the brief did not enumerate. A deprecated operator can sign in here.

### The contract that must be preserved

`AppUser_GetByInitials` **intentionally** returns deprecated rows. This is a documented,
tested attribution-history contract, not a bug:

- Proc header comment: *"Initials are unique across the full row set (active + deprecated), so this
  returns deprecated rows as well. Callers that want active-only should filter … on the result."*
- `sql/tests/03_appuser/040_AppUser_GetByInitials.sql:78-126` **Test 3** asserts a deprecated user
  is still returned with `DeprecatedAt` set, rationale: *"historical events stamped with a retired
  operator's initials still resolve."*

Therefore we **must not** add a `DeprecatedAt` filter to `AppUser_GetByInitials`. The presence rule
must live in a separate, active-only resolver.

---

## 2. Approach

Add a **dedicated active-only presence resolver in SQL** (business rule in SQL, per CLAUDE.md), and
route **both** presence entry points through it. The history lookup proc is left untouched.

| Layer | Change |
|---|---|
| SQL | **New** `Location.AppUser_GetActiveByInitials` — same columns as `AppUser_GetByInitials`, but `WHERE Initials=@Initials AND DeprecatedAt IS NULL`. Read-only, no audit, no OUTPUT params, empty set = not eligible. |
| NQ | **New** `location/AppUser_GetActiveByInitials` — `type:"Query"`, `EXEC Location.AppUser_GetActiveByInitials :initials`. |
| Python | `AppUser/code.py`: **add** `getActiveByInitials(initials)` (wraps the new NQ). **Repoint** `resolveForPresence` from `getByInitials` → `getActiveByInitials`. `getByInitials` is **kept** (history + deprecated-detection). |
| View | `InitialsEntry/view.json` `submitInitials`: resolve via `getActiveByInitials`; if a row → `loginAs`. If none → call `getByInitials` to distinguish a **deprecated** hit (show a "deactivated — see a supervisor" message via the existing `view.custom.error`, no register popup) from a **genuine unknown** (existing `UnknownInitials` register popup, unchanged). |
| Tests | **New** `sql/tests/03_appuser/045_AppUser_GetActiveByInitials.sql`: active→1 row, deprecated→0 rows, unknown→0 rows. Existing `040`/`0020_.../020` untouched (they test the history proc) and stay green. |

**No versioned migration** — repeatable proc only (matches the brief: E needs no new migration).

### Why a new proc rather than a `@ActiveOnly` param on the existing proc

A new single-purpose proc keeps the history proc's tested behaviour byte-for-byte, avoids any
INSERT-EXEC result-shape ambiguity, and is self-documenting at each call site. Matches the project's
focused-proc convention.

### Why both paths (per "all of it")

`resolveForPresence` covers the per-mutation `InitialsField` (the literal FAT surface).
`InitialsEntry` is the shift-start sign-in that sets `session.custom.user` — the identity every
subsequent mutation is attributed to. Leaving it open would let a deprecated operator establish a
deprecated session identity, defeating the genealogy-integrity goal. Both are gated.

---

## 3. Behaviour after the change

**Per-mutation field (`resolveForPresence`):**
- Active initials → `valid=True` (unchanged).
- Deprecated initials → `valid=False` → mutation blocked (same as unknown today). ✔ FAT-USR-090.
- Unknown initials → `valid=False` (unchanged).

**Shift-start sign-in (`InitialsEntry.submitInitials`):**
- Active initials → `loginAs` (unchanged).
- Deprecated initials → `view.custom.error` shows *"Operator {XX} is deactivated. See a
  supervisor."*; **no** login, **no** register popup.
- Unknown initials → existing `UnknownInitials` register popup (unchanged).

**Safety of the deprecated path:** a deprecated operator cannot self-register around the block —
`AppUser_Create` enforces global initials uniqueness across active+deprecated
(`R__Location_AppUser_Create.sql:100-104`, *"An AppUser with these Initials already exists."*).
Reactivation is a supervisor/config action, out of scope here.

---

## 4. Out of scope

- Reactivation UI/flow for deprecated operators.
- FAT-USR-070 / FAT-USR-160 (closed — handled by Ignition built-in project auth).
- Any change to the history proc `AppUser_GetByInitials` or its tests.
- Enriching the per-mutation `InitialsField` message to distinguish deprecated-vs-unknown (the field
  already blocks both; a distinct message there is a nicety, not required).

---

## 5. Files

- **New** `sql/migrations/repeatable/R__Location_AppUser_GetActiveByInitials.sql`
- **New** `ignition/projects/Core/ignition/named-query/location/AppUser_GetActiveByInitials/{query.sql,resource.json}`
- **Edit** `ignition/projects/Core/ignition/script-python/BlueRidge/Location/AppUser/code.py`
- **Edit** `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/InitialsEntry/view.json`
- **New** `sql/tests/03_appuser/045_AppUser_GetActiveByInitials.sql`

## 6. Test plan

1. **TDD SQL:** write `045` first (active→1, deprecated→0, unknown→0), watch it fail (proc absent),
   implement the proc, watch it pass. Validate on a throwaway DB (`MPP_MES_UsrPresence`) — never
   `MPP_MES_Dev`.
2. **Regression:** re-run `03_appuser/040` and `0020_PlantFloor_Foundation/020` — both stay green
   (history proc unchanged).
3. **Ignition:** `.\scan.ps1` after the NQ + view + code.py changes; confirm no scan errors.
4. **Manual smoke (documented, not automated):** deprecated initials at both the per-mutation field
   and the sign-in popup are blocked with the expected messaging; active initials still work.
