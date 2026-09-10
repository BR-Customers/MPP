# -*- coding: utf-8 -*-
"""Verify an Ignition 8.3 project-export zip against the invariants the
2026-09-09 export/import incident established.

WHY A SEPARATE CHECKER. build-project-exports.ps1 reports on its own work,
which is exactly the kind of assurance that let two broken export sets reach
a customer Gateway. This reads the finished archive and knows nothing about
how it was produced.

The invariants, and the failure each one prevents:

  1. resource.json files[] must match the payload EXACTLY -- every promised
     file present, and (informationally) every sibling file declared. A
     manifest naming a thumbnail.png that was excluded is defect #1: the
     project will not load and Designer dies on startup with
     "NullPointerException ... because \"project\" is null".

  2. No __pycache__ / *.pyc anywhere. A script-python resource is a LEAF
     folder of code.py + resource.json; a child folder makes the Gateway
     render it as a FOLDER rather than a module, and BlueRidge.Common.Util
     stops resolving -- defect #2.

  3. Every script-python resource folder is a leaf.

  4. Forward-slash separators only, and project.json at the archive root.
     Windows PowerShell has historically written backslashes, which Java-side
     consumers read as one long filename instead of a tree.

  5. Every entry is accounted for: project.json, a resource.json, or a file
     some resource.json in its own directory declares. An orphan is a file
     the Gateway will not load and a sign the tree and the manifests have
     drifted apart.

    python tools/verify_project_exports.py dist/ignition-exports/*.zip
"""
import json
import posixpath
import sys
import zipfile


def verify(path):
    problems = []
    notes = []
    with zipfile.ZipFile(path) as z:
        names = z.namelist()

        # ---- 4. separators + root ----------------------------------------
        if any('\\' in n for n in names):
            problems.append('backslash separators in %d entr(ies)'
                            % sum(1 for n in names if '\\' in n))
        if 'project.json' not in names:
            problems.append('project.json is not at the archive root')

        # ---- 2. bytecode --------------------------------------------------
        junk = [n for n in names if '__pycache__' in n or n.endswith('.pyc')]
        if junk:
            problems.append('%d bytecode entr(ies), e.g. %s' % (len(junk), junk[0]))

        # ---- 1 + 5. manifests vs payload ---------------------------------
        present = set(names)
        declared = set()
        manifests = [n for n in names if posixpath.basename(n) == 'resource.json']
        missing = []
        for m in manifests:
            d = posixpath.dirname(m)
            try:
                obj = json.loads(z.read(m).decode('utf-8-sig'))
            except Exception as e:
                problems.append('%s is not readable JSON (%s)' % (m, e))
                continue
            files = obj.get('files')
            if files is None:
                problems.append('%s has no files[] array' % m)
                continue
            if not isinstance(files, list):
                # PS 5.1 collapses a one-element array to a scalar; that breaks
                # the schema just as surely as a lying manifest does.
                problems.append('%s files[] is %s, not an array'
                                % (m, type(files).__name__))
                continue
            for f in files:
                full = posixpath.join(d, f) if d else f
                declared.add(full)
                if full not in present:
                    missing.append(full)
        if missing:
            problems.append('%d promised-but-missing file(s), e.g. %s'
                            % (len(missing), missing[0]))

        orphans = sorted(present - declared - set(manifests) - {'project.json'})
        if orphans:
            problems.append('%d orphan entr(ies) no manifest declares, e.g. %s'
                            % (len(orphans), orphans[0]))

        # ---- 3. script-python resources are leaves ------------------------
        code_dirs = set(posixpath.dirname(n) for n in names
                        if posixpath.basename(n) == 'code.py')
        for d in sorted(code_dirs):
            kids = set(posixpath.dirname(n) for n in names
                       if n.startswith(d + '/') and posixpath.dirname(n) != d)
            if kids:
                problems.append('script resource %s is not a leaf (%s)'
                                % (d, sorted(kids)[0]))

        notes.append('%d entries, %d resources' % (len(names), len(manifests)))
    return problems, notes


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    bad = 0
    for path in argv:
        problems, notes = verify(path)
        head = posixpath.basename(path.replace('\\', '/'))
        if problems:
            bad += 1
            print('FAIL  %s  (%s)' % (head, '; '.join(notes)))
            for p in problems:
                print('        - %s' % p)
        else:
            print('ok    %s  (%s)' % (head, '; '.join(notes)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
