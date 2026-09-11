# Packaging project resources for Designer import

How to turn files in a version-controlled Ignition 8.3 file-based project into a `.zip` a human can import through the Designer. This is the sibling of `09_repo_gateway_sync.md`: that file covers the **dev** loop (junction + project scan, no archive), this one covers **shipping a change to a Gateway you do not have a junction into** — typically production.

> **When you do NOT need this.** If the target Gateway junctions into the repo, do not build an archive. Write the files and run a project scan. Exports exist for Gateways that own their own project store.

---

## The archive shape

Verified against a genuine Designer-produced export, 2026-09-10. Fifteen entries covering one of each resource type:

```
project.json                                                   <- at the ZIP ROOT
com.inductiveautomation.perspective/page-config/resource.json + config.json
com.inductiveautomation.perspective/session-props/resource.json + props.json
com.inductiveautomation.perspective/stylesheet/resource.json + stylesheet.css
com.inductiveautomation.perspective/views/<Path>/resource.json + view.json
ignition/global-props/resource.json + data.bin
ignition/named-query/<folder>/<Name>/resource.json + query.sql
ignition/script-python/<Pkg>/<Module>/resource.json + code.py
```

Four rules, each of which has broken a real deployment:

| Rule | What happens when you get it wrong |
|---|---|
| `project.json` sits at the **zip root**, not under a project-named folder | Import does not recognise the archive |
| Entry separators are **forward slashes** | `Compress-Archive` on PS 5.1 writes backslashes; Java-side consumers read the whole path as one long filename |
| Every file a `resource.json` declares in `files[]` **is in the archive** | The Gateway builds the resource from that manifest. A promised-but-absent file stops the *entire project* resolving — Perspective keeps serving already-loaded resources while the Designer dies on connect with `NullPointerException: Cannot invoke ResourceCollection.getInheritanceStructure() because "project" is null` |
| A `script-python` resource folder contains **only** `code.py` + `resource.json` | Give it a child folder (e.g. `__pycache__`) and the Gateway renders it as a *folder, not a module*. `BlueRidge.Common.Util` then stops resolving and Jython silently falls through to a same-named Java package: `AttributeError: 'com.inductiveautomation…' object has no attribute 'Util'` |

### A resource is a FOLDER, not a file

This is the single most common mistake. If `view.json` changed, the archive must also carry that folder's `resource.json`. Shipping the payload without its manifest — or the manifest without its payload — is how you get "View Not Found" or the Designer NPE above.

### Excluded files, and the manifest consequence

Never ship: `thumbnail.png` (Gateway-regenerated, gitignored), `__pycache__/`, `*.pyc`, `.gitkeep`, `pull.log`, `Thumbs.db`, `desktop.ini`.

**Excluding a file is only half the job.** If a `resource.json` still declares `thumbnail.png` in its `files[]`, you have just created a promised-but-absent file. Either ship it or **rewrite the manifest inside the archive** to stop naming it. The on-disk file stays as it is; only the copy in the zip changes.

Rewriting has its own trap: PowerShell 5.1's `ConvertTo-Json` **collapses a one-element array to a scalar**, emitting `"files": "view.json"` and breaking the schema a second way. Emit the array by hand through a placeholder:

```powershell
$obj.files = @('__FILES__')
$json = $obj | ConvertTo-Json -Depth 20
$arr  = '[' + (($kept | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']'
$json = $json -replace '"files":\s*\[\s*"__FILES__"\s*\]', ('"files": ' + $arr)
$json = $json -replace '"files":\s*"__FILES__"',           ('"files": ' + $arr)
```

### What differs between a repo `resource.json` and a Designer-exported one

Only the modification metadata:

```jsonc
// Designer export                          // repo
"lastModificationSignature": "0a4c30b8…",   "lastModificationSignature": "",
"lastModification": {                       "lastModification": {
  "actor": "external",                        "actor": "claude",
  "timestamp": "2026-09-10T12:24:25Z" }       "timestamp": "2026-06-17T12:00:00Z" }
```

`project.json` is byte-identical. Whether the Gateway **validates** `lastModificationSignature` on import is **not established** — repo files carry `""` and work fine through the junction+scan path, which is a different code path from import. Treat an empty signature as the open question to watch on a first import, not as known-good.

---

## Two kinds of archive

**Full project** — every resource. Use for standing up a new Gateway. In this repo: `build-project-exports.ps1`.

**Scoped change** — only the resources a commit range touched. Use for shipping a fix to a **live** Gateway: a full-project import replaces far more than the thing you are shipping, and every unrelated resource in it is a chance to clobber something a person changed on the Gateway. In this repo: `tools/Build-ChangeExport.ps1`.

```bash
# everything changed since a commit, one archive per project
.\tools\Build-ChangeExport.ps1 -Since <commit> -Label <change-name>
```

It maps each changed file to its owning resource folder (nearest ancestor containing a `resource.json`), ships that folder's manifest plus every file the manifest declares, rewrites manifests that name an excluded file, and then **re-opens the archive it just wrote** to verify: root `project.json`, zero backslash entries, zero thumbnails or bytecode, and every manifest promise kept.

It builds from **git at `-Until`, not the working tree** (`git archive` into a temp folder). The working tree is junctioned into the dev Gateway, which rewrites manifests on scan, and concurrent sessions leave uncommitted edits there — an archive must be exactly what is committed. Two consequences, both learned on the 2026-09-10 prod release:

- **Run `git archive` with `-c core.autocrlf=false`.** On a Windows checkout with `autocrlf=true`, `git archive` emits CRLF, so every `view.json` / `code.py` / `query.sql` in the zip differs from the committed blob. Harmless to parse, but it defeats a byte-for-byte check against HEAD — which is the check that proves the archive is what was reviewed.
- **Manifest-only churn is skipped.** A resource whose only change in the range is its `resource.json` dropping `thumbnail.png` is left out; the target already has that shape (the export rewrites manifests the same way), and shipping it would re-import an unchanged `view.json` over whatever is on the Gateway.

It also writes a `<label>_<stamp>_CONTENTS.txt` beside the zips — every resource, NEW/MOD, and the commits that touched it — as the import checklist, and lists any **deleted** resources loudly (an import cannot remove them; delete by hand in the Designer).

**Import through Designer → File → Import**, not the Gateway web page's project import: a scoped archive is a partial project.

---

## Import order

**Core FIRST.** Child projects declare `"parent": "Core"` and will not resolve inherited resources without it. Then the children in any order.

**And deploy the SQL first.** Views and named queries call procedures and read columns that must already exist. A Gateway serving new views against an old schema fails in the worst way available — a blank field with no error, rather than a stack trace.

---

## Verify before you hand it over

Do not trust a builder's own success message; re-open the archive:

```python
import zipfile, json
z = zipfile.ZipFile(path); names = z.namelist()
assert 'project.json' in names                                   # root manifest
assert not [n for n in names if chr(92) in n]                    # forward slashes only
assert not [n for n in names if 'thumbnail' in n or '__pycache__' in n]
for n in names:                                                  # manifest promises kept
    if n.endswith('resource.json'):
        d = json.loads(z.read(n).decode('utf-8'))
        assert isinstance(d.get('files', []), list)              # not collapsed to a scalar
        for f in d.get('files', []):
            assert n.rsplit('/', 1)[0] + '/' + f in names, (n, f)
```

**Structural validity is not an import test.** This repo shipped two archives that passed every structural check and still broke the Designer, because nobody had actually imported one. Import into a throwaway project on a dev Gateway once and confirm a `script-python` resource shows as a **script, not a folder** — that single check catches the `__pycache__` class of failure, which no amount of file-listing will.

---

## Reference incidents

Both from this repo, both shipped, both caught only after the fact:

1. **142 manifests named a `thumbnail.png` that was not in the archive** — the builder excluded the file but left the manifest declaring it. Project failed to load; Designer died with the `"project" is null` NPE.
2. **18 `__pycache__` folders shipped inside script-module folders** — invisible to review because `.gitignore` covers them, so they never appeared in `git status`. The builder walks the *filesystem*, and `.gitignore` has no say in what it finds.

The lesson generalises: **a filesystem-walking builder ships whatever is on disk.** Any file git deliberately ignores is a candidate to leak into an archive. Report anything being included that git ignores, loudly, before it can ship.
