# -*- coding: utf-8 -*-
"""Make every resource.json files[] match what is actually on disk.

THE FAILURE THIS FIXES. A resource.json files[] is a MANIFEST: the Gateway
builds the resource from it. Name a file that is not there and the Gateway
logs

    ResourceCollectionFileTree: Error creating dataFile for
      resourceManifest=...\\resource.json, file=thumbnail.png
    java.nio.file.NoSuchFileException: ...

per resource, the project fails to resolve, and the Designer dies on startup:

    NullPointerException: Cannot invoke
      ResourceCollection.getInheritanceStructure() because "project" is null

The Gateway keeps serving already-loaded resources, so the symptom is the
confusing one: the projects RUN but will not OPEN in the Designer.

WHY THE TREE DRIFTS. thumbnail.png is Gateway-regenerated and gitignored, so
a manifest that names one is right on the machine that generated it and wrong
on every clean checkout. build-project-exports.ps1 already rewrites manifests
on the way into a zip (that was the 2026-09-09 fix); this applies the same
rule to the working tree the Gateway junctions into, which the export fix
never touched.

Dropping the entry rather than fabricating the file is the right direction:
the thumbnail is a preview the Designer regenerates and re-declares the next
time the view is saved, at which point manifest and payload agree again.

    python tools/fix_resource_manifests.py --check    # report, write nothing
    python tools/fix_resource_manifests.py            # rewrite
"""
import io
import json
import os
import sys

ROOT = os.path.join('ignition', 'projects')


def main(argv):
    check_only = '--check' in argv
    targets = [a for a in argv if not a.startswith('--')] or [
        os.path.join(ROOT, d) for d in sorted(os.listdir(ROOT))
        if os.path.isdir(os.path.join(ROOT, d))]

    total = 0
    for base in targets:
        fixed = []
        for dp, dn, fn in os.walk(base):
            if 'resource.json' not in fn:
                continue
            path = os.path.join(dp, 'resource.json')
            raw = io.open(path, encoding='utf-8-sig').read()
            try:
                obj = json.loads(raw)
            except Exception as e:
                print('  !! %s unreadable (%s)' % (path, e))
                continue
            files = obj.get('files')
            if not isinstance(files, list):
                continue
            kept = [f for f in files if os.path.isfile(os.path.join(dp, f))]
            if len(kept) == len(files):
                continue
            dropped = [f for f in files if f not in kept]
            fixed.append((path, dropped))
            if not check_only:
                obj['files'] = kept          # stays a LIST even at length 1
                out = json.dumps(obj, indent=2, ensure_ascii=False)
                # Match the trailing-newline convention of the file replaced.
                if raw.endswith('\n'):
                    out += '\n'
                io.open(path, 'w', encoding='utf-8', newline='').write(out)

        name = os.path.basename(base.rstrip('/\\'))
        total += len(fixed)
        verb = 'would rewrite' if check_only else 'rewrote'
        if fixed:
            print('%-12s %s %d manifest(s)' % (name, verb, len(fixed)))
            for p, d in fixed[:3]:
                print('             - %s  (dropped %s)'
                      % (p.replace(os.sep, '/'), ', '.join(d)))
            if len(fixed) > 3:
                print('             ... and %d more' % (len(fixed) - 3))
        else:
            print('%-12s clean' % name)
    return 0 if total == 0 or not check_only else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
