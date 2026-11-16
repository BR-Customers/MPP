# Review report: c_LocAud_00 (Location schema, 43 procs)

All 43 files read (header comment blocks skimmed on the long mutation procs; all executable code read in full).

Supporting facts verified (not guessed):
- `Location.AppUser` carries `UQ_AppUser_Initials` (0012:73), `UQ_AppUser_Pin` (0069:88) and filtered `UQ_AppUser_AdAccount_Active ... WHERE AdAccount IS NOT NULL` (0012:90-93). Every PIN / initials / AD-account lookup is therefore an index seek on a tiny table (tens of rows).
- `Location.Location` has `UQ_Location_Code`, `IX_Location_ParentLocationId`, `IX_Location_LocationTypeDefinitionId` (0002:78-85). `LocationTypeDefinition` has `UQ_LocationTypeDefinition_Code`. `LocationAttribute` has `UX_LocationAttribute_Location_Definition` (0002:101). `LocationAttributeDefinition` has `UX_LocationAttributeDefinition_ActiveName` (0014:44). So every check-then-insert in this batch is backstopped by a unique index and a lost race ends in the CATCH block, not in duplicate data.
- None of these procs touches `Lots.*`, `Workorder.*`, or any event/log table other than the `Audit.Audit_Log*` writers (small writes inside the mutation transaction). No cursors, no WHILE loops, no multi-statement TVFs in the batch, no SELECT *.
- Callers (grep of `ignition/`): the AppUser read procs run at PIN sign-in / per-mutation AD resolution (`BlueRidge.Common.Session.currentAppUserId` calls `AppUser_GetActiveByAdAccount` once per Config Tool mutation, never cached, by design). That is a single-row unique-index seek per call, not a poll. `Location_ListByTier` is called from dropdown option scripts (`Lots/Lot/code.py` getLocationOptions/getMachineOptions, DieCastSupervisor) on screen load, not on a timer. `Location_GetAncestors` and `Location_GetDescendantsOfType` have no caller in `ignition/`. `Location_GetTree` backs the Plant Hierarchy config screen. The Cutover procs back the temporary inventory-cutover scan screen.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| Location.AppUser_AuthenticateAd | OK | L | read; nothing to change (unique-index seek by AdAccount, audit writes only) | n/a |
| Location.AppUser_Create | OK | L | read; nothing to change (EXISTS-then-INSERT races are backstopped by UQ_AppUser_Initials / UQ_AppUser_Pin / filtered AdAccount; a loser lands in CATCH) | n/a |
| Location.AppUser_Deprecate | OK | L | read; nothing to change | n/a |
| Location.AppUser_Get | OK | L | read; nothing to change (PK seek) | n/a |
| Location.AppUser_GetActiveByAdAccount | OK | L | read; nothing to change (seek on filtered unique AdAccount index; per-mutation call, one row) | n/a |
| Location.AppUser_GetActiveByInitials | OK | L | read; nothing to change (seek on UQ_AppUser_Initials) | n/a |
| Location.AppUser_GetActiveByPin | OK | L | read; nothing to change (seek on UQ_AppUser_Pin, NVARCHAR(5) matches param type, no implicit conversion, leading zeros safe) | n/a |
| Location.AppUser_GetByAdAccount | OK | L | read; nothing to change | n/a |
| Location.AppUser_GetByInitials | OK | L | read; nothing to change | n/a |
| Location.AppUser_GetByPin | OK | L | read; nothing to change | n/a |
| Location.AppUser_GetRoles | OK | L | read; nothing to change (PK seek) | n/a |
| Location.AppUser_List | OK | L | read; nothing to change (leading-wildcard LIKE on a tiny admin table, not worth touching) | n/a |
| Location.AppUser_Update | OK | L | read; nothing to change (same unique-index backstop as Create) | n/a |
| Location.LocationAttributeDefinition_Create | OK | L | read; nothing to change (MAX(SortOrder)+1 outside the txn can duplicate a SortOrder under a concurrent admin create; harmless, no unique index on SortOrder, admin screen) | n/a |
| Location.LocationAttributeDefinition_Deprecate | OK | L | read; nothing to change | n/a |
| Location.LocationAttributeDefinition_Get | OK | L | read; nothing to change | n/a |
| Location.LocationAttributeDefinition_ListByDefinition | OK | L | read; nothing to change (IX on LocationTypeDefinitionId serves it) | n/a |
| Location.LocationAttributeDefinition_MoveDown | OK | L | read; nothing to change (reads sibling sort outside txn; admin arrow button, worst case a stale swap) | n/a |
| Location.LocationAttributeDefinition_MoveUp | OK | L | read; nothing to change (same as MoveDown) | n/a |
| Location.LocationAttributeDefinition_Update | OK | L | read; nothing to change | n/a |
| Location.LocationAttribute_Clear | OK | L | read; nothing to change | n/a |
| Location.LocationAttribute_GetByLocation | OK | L | read; nothing to change (seek on definition index, LEFT JOIN on unique (LocationId, DefinitionId)) | n/a |
| Location.LocationAttribute_Set | OK | L | read; nothing to change (read-then-upsert is backstopped by UX_LocationAttribute_Location_Definition) | n/a |
| Location.LocationTypeDefinition_Deprecate | OK | L | read; nothing to change | n/a |
| Location.LocationTypeDefinition_Get | OK | L | read; nothing to change | n/a |
| Location.LocationTypeDefinition_GetOeeEligibility | OK | L | read; nothing to change (scalar UDF but single row by PK) | n/a |
| Location.LocationTypeDefinition_List | OK | L | read; nothing to change (code-table sized) | n/a |
| Location.LocationTypeDefinition_SaveAll | OK | L | read; nothing to change (single txn, OPENJSON into table variable once, unique-index safety net documented in header; admin only) | n/a |
| Location.LocationType_Get | OK | L | read; nothing to change | n/a |
| Location.LocationType_List | OK | L | read; nothing to change | n/a |
| Location.Location_Create | OK | L | read; nothing to change (Code check backstopped by UQ_Location_Code; MAX(SortOrder)+1 outside txn can duplicate a sort value, admin-only, harmless) | n/a |
| Location.Location_Deprecate | OK | L | read; nothing to change (active-child check then UPDATE without lock could race a concurrent Create under the same parent; admin-only, not a perf or plant-floor concern) | n/a |
| Location.Location_Get | OK | L | read; nothing to change | n/a |
| Location.Location_GetAncestors | OK | L | read; nothing to change (recursive CTE, depth <= ~5, PK seeks; no caller found in ignition/) | n/a |
| Location.Location_GetDescendantsOfType | OK | L | read; nothing to change (recursive CTE over IX_Location_ParentLocationId; no caller found in ignition/) | n/a |
| Location.Location_GetStockDestination | OK | L | read; nothing to change (PK seeks, self-join) | n/a |
| Location.Location_GetTree | OK | L | read; nothing to change (recursive CTE with string path; config-screen load, hundreds of rows at most) | n/a |
| Location.Location_List | OK | L | read; nothing to change (catch-all OR predicates, but Location is a few hundred rows and this feeds the admin Plant Hierarchy screen / search box) | n/a |
| Location.Location_ListByTier | OK | L | read; nothing to change (dropdown option source, called on screen load, small table) | n/a |
| Location.Location_ListCellsForArea | OK | L | read; nothing to change (recursive CTE with MAXRECURSION 8) | n/a |
| Location.Location_ListCutoverDestinationsForLine | OK | L | read; nothing to change (per-store EXISTS over Parts.v_EffectiveItemLocation and ufn_AncestorLocationIds, but only TOP 1 over the 3 flagged stores, cutover-scan screen only, not polled) | n/a |
| Location.Location_ListCutoverSources | OK | L | read; nothing to change | n/a |
| Location.Location_ListDieCastMachinesForItem | OK | L | read; nothing to change (fallback decided once into @EligibleCount, then EXISTS probe per machine; ~11 machines) | n/a |

No WATCH or CANDIDATE sections: nothing in this batch is worth its own change.

Note for the PIN / AD sign-in question specifically: all three presence lookups (`AppUser_GetActiveByPin`, `_GetActiveByInitials`, `_GetActiveByAdAccount`) predicate on a column that has its own unique index and select a handful of columns from a small table, so they cannot scan anything that grows and take no locks beyond a transient shared key lock on a table that is only written by admin-driven Create / Update / Deprecate. `Location.Terminal_*` context reads (the likely hot terminal-refresh path) are not in this batch.

COUNTS: OK=43 WATCH=0 CANDIDATE=0
