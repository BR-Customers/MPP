# SDD progress — Assembly-out printer-card FG routing
Plan: docs/superpowers/plans/2026-08-06-assembly-out-printer-fg-routing.md
Spec: docs/superpowers/specs/2026-08-06-assembly-out-printer-fg-routing-design.md
Branch: jacques/working (SHARED tree — a CONCURRENT SDD session (Trim scrap #2) is also active; my work is disjoint. Stage explicit paths only; no -A/-u; no git checkout.)
Validation DB: MPP_MES_PrinterCards (throwaway; NEVER MPP_MES_Dev). Repeatables applied additively to MPP_MES_Dev.
Migration: 0052 ; test dir 0029_AssemblyPrinterCards. Review diffs PATH-SCOPED (interleaved commits from the other session).

Plan start BASE: 5813a3c5

Task 1 BASE: 5813a3c5
Task 1: complete (commit 10a1d977; controller review clean; spec ✅ quality Approved)
  - Implementer fixed 2 real plan bugs: GETUTCDATETIME() -> SYSUTCDATETIME() (CLAUDE.md typo; not a real SQL Server fn); Audit.LogEntityType.Id not IDENTITY -> explicit-Id SELECT ISNULL(MAX(Id),0)+1 pattern (per 0049). Both codebase-verified.
  - FLAG to user: CLAUDE.md says GETUTCDATETIME() but the codebase uses SYSUTCDATETIME(); doc typo worth fixing.

Task 2 BASE: 10a1d977
Task 2: complete (commit f5863fa3; controller review clean; spec ✅ quality Approved)
  - Printer_GetById proc (guards DefId 16 + not-deprecated) + NQ (Query, sqlType 3) + getById script.
  - Implementer fixed a test bug: `EXEC proc @Param = (SELECT ...)` inline subquery is illegal (EXEC args = literal/@var). Same pattern is in Task 3's + Task 4's test SQL — WARN those implementers.

Task 3 BASE: f5863fa3
Task 3: complete (commit 2c166182; controller review clean; spec ✅ quality Approved)
  - ListForStation proc (LEFT JOIN assignment+Item, child-printer filter, ORDER BY ISNULL(pfa.SortOrder,p.SortOrder)) + NQ + NEW PrinterFgAssignment script module. EXEC-param subquery bug fixed. 6 files, disjoint.

Task 4 BASE: 2c166182
Task 4: complete (commits 5602a9fd + fix 25a9b027; reviewer sonnet spec ✅; fix verified; spec ✅ quality Approved)
  - Full-replace SaveAll: 3 validations before BEGIN TRAN, DELETE scoped to station child printers, Audit_LogConfigChange (corrected Audit_LogFailure 7-param). Fixed another test inline-EXEC-CAST bug.
  - Review found 4 (3 Important): audit @NewValue bare IDs; @OldValue NULL; validations 1&2 untested; dead RowIndex. FIX 25a9b027: resolved-name FOR JSON old+new, +2 validation tests, RowIndex removed. 75/75 in 0029.

Task 5 BASE: 25a9b027
Task 5: complete (commit a1904bb0; controller review clean; spec ✅ quality Approved)
  - dispatch(aimShipperId, terminalLocationId, printerLocationId=None): override resolves endpoint via Printer.getById; else-branch unchanged (session+terminal fallback). Gateway-verified DIAGDO getById(-999)={}. Temp timer removed. 1 file.

Task 6 BASE: a1904bb0
Task 6: complete (commit 8eb781d8; controller review clean; spec ✅ quality Approved)
  - Assembly.completeBoxToPrinter(containerId, terminalLocationId, printerLocationId): Container.complete -> ShippingDispatcher.dispatch(printerLocationId override). Completed-but-unprinted = Status 1 (re-dispatchable). ast-parse + scan clean. 1 file.

BACKEND COMPLETE (Tasks 1-6): commits 10a1d977, f5863fa3, 2c166182, 5602a9fd, 25a9b027, a1904bb0, 8eb781d8. All TDD'd/verified.
Task 7 (view panel + manual smoke) PAUSED at Designer-coordination gate — needs human: (a) confirm Designer CLOSED (concurrent Trim view session may have it open), (b) manual smoke needs 2 printers added via config app + live session on that terminal.
Task 7 (view): PARTIAL — committed PrinterCard component + listCardsForStation merge helper (commit after 8eb781d8). Step 2 (getEligibleFinishedGoodsForDropdown) already existed in Workorder.Assembly — no-op.
  REMAINING: wire PrinterCard into AssemblyNonSerialized (customs printerCards/usePrinterCards + listCardsForStation binding; gate existing CloseForm+CompletionPanel on !usePrinterCards; flex-repeater panel; 3 page-scoped handlers printerCardsRefresh/printerCardAssign/printerCardReorder + customMethods doing immediate SaveAll; no separate Save button). Existing-view edit = DESIGNER work (file-edit boundary). Then manual smoke (2 printers via config app + live session).
  Backend final review: running (background).
Backend final review (sonnet, background afc6744c): Changes-needed (close). No arch/security; cross-task wiring correct.
  Important: (1) SaveAll JSON_VALUE bare cast for PrinterLocationId/ItemId no TRY_CAST -> malformed throws before BEGIN TRY (bypasses Status=0 contract); (2) 040 test never queries Audit.ConfigLog (resolved-name JSON untested); (3) reorder-only-SortOrder + ListForStation ordering unasserted.
  Minor: audit Desc raw terminal Id; LastEditedAt never set (delete+insert); empty JSON+bad station -> Status=1; dispatch no-endpoint msg text changed for all callers; no explicit dup-PrinterLocationId reject.
  Full: .superpowers/sdd/pc-backend-review-result.md
Backend review fixes: commit d24e301a (TRY_CAST guard + malformed-null reject + audit-JSON/ordering/reorder/malformed tests). 0029 = 80/80. Backend merge-clean.
Task 7: CODE-COMPLETE (commits: PrinterCard+helper, f876455e wiring). AssemblyNonSerialized JSON valid + gateway-accepted (no deserialize errors). Immediate-SaveAll model (no separate Save button). Step 2 wrapper pre-existed.
  PENDING: manual smoke (2 printers via config app + live session on that terminal). Designer polish: gate legacy single-FG form on !usePrinterCards (currently both show when >1 printer).
FEATURE CODE-COMPLETE. Commits: 10a1d977 f5863fa3 2c166182 5602a9fd 25a9b027 a1904bb0 8eb781d8 d24e301a (backend) + PrinterCard/helper + f876455e (view).

Designer-polish gate: commit added (MainCol position.display=!usePrinterCards). Task 7 fully code-complete.
