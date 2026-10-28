# Super-lot gateway walk -- bug log (sales-kit module 4 capture session)

The first time the super-lot screens were driven on a gateway. Written during the capture session
of `docs/superpowers/plans/2026-10-27-mes-sales-kit-module-4-quality.md` (Task 6) so another agent
can pick each bug up cold. **Nothing here was fixed in the session**: the application was not
changed. Each entry: screen and route; steps from a named state; expected; actual; `wrapper.log`
excerpt; screenshot (`tools/sales-kit/captures/m4/raw/<step>.png`, gitignored); likely proc / view.

## Scenario state

`MPP_MES_Demo` built with `tools\sales-kit\demo-db\Build-DemoDatabase.ps1 -WithQualityScenario`
(`sql/seeds_demo/opt/060_demo_quality_scenario.sql`): casting `520100004` on a hard Hold; super-lot
`CR000001` open with "keep adding new production" on for HSG-410; members as listed in the seed
header; results recorded for `520100006` only. The sample Quality user `EN` (E. Novak) has its
`AdAccount` set to the presenter's login with `Set-QualityAdAccount.ps1`.

## How elevation authenticates (checked before the session)

`BlueRidge.Location.AppUser.elevate` (Core) checks the password with
`system.security.validateUser(account, password, "Active Directory")` -- the user source named
`_ELEVATION_USER_SOURCE` -- then resolves the account through `Location.AppUser_AuthenticateAd`,
which needs an ACTIVE `AppUser` whose `AdAccount` equals the typed account. Signing (release,
deviation) additionally needs `Quality.ufn_SignatureAllowed`: any active user with a non-empty
`AdAccount`. So on this gateway an "Active Directory" user source must exist, and the account name
typed at sign-in must match what `Set-QualityAdAccount.ps1` stored, character for character.

## Bugs

(none yet)

## Walked and worked

## Could not reach
