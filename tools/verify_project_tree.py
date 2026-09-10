# -*- coding: utf-8 -*-
"""Verify the on-disk project tree the Gateway junctions into.

Same invariants as tools/verify_project_exports.py, applied to the working
tree instead of a built archive -- because the Designer reads the tree
directly and fails the same way:

    NullPointerException: Cannot invoke
      ResourceCollection.getInheritanceStructure() because "project" is null

A resource.json files[] naming a file that is not on disk is enough to stop
the whole project resolving; the Gateway can keep serving already-loaded
resources while the Designer, which builds the project tree from scratch on
connect, dies. "Runs fine but will not open in Designer" is the signature.

    python tools/verify_project_tree.py
    python tools/verify_project_tree.py ignition/projects/Core
"""
import io
import json
import os
import sys

ROOT = os.path.join('ignition', 'projects')

# NOTHING is exempt. An earlier version of this file waved thumbnail.png
# through on the reasoning that it is Gateway-regenerated and gitignored, so
# its absence "is not a defect" -- and that exemption hid 86 lying manifests
# while the Gateway logged a NoSuchFileException for every one of them and the
# Designer refused to open MPP and MPP_Config at all. The manifest is a
# contract with the Gateway; a file it names is either there or the manifest
# is wrong. Which of the two to fix is a judgement call
# (tools/fix_resource_manifests.py drops the entry); whether to REPORT it is
# not.


def check(project_dir):
    problems = []
    resources = 0
    for dirpath, dirnames, filenames in os.walk(project_dir):
        if '.git' in dirpath:
            continue

        if 'resource.json' in filenames:
            resources += 1
            manifest = os.path.join(dirpath, 'resource.json')
            try:
                obj = json.loads(io.open(manifest, encoding='utf-8-sig').read())
            except Exception as e:
                problems.append('%s :: unreadable JSON (%s)' % (manifest, e))
                continue
            files = obj.get('files')
            if files is None:
                problems.append('%s :: no files[] array' % manifest)
                continue
            if not isinstance(files, list):
                problems.append('%s :: files[] is %s, not an array'
                                % (manifest, type(files).__name__))
                continue
            for f in files:
                if not os.path.isfile(os.path.join(dirpath, f)):
                    problems.append('%s :: promises %s -- NOT ON DISK' % (manifest, f))

        else:
            # A folder holding content but no manifest is invisible to the
            # scanner; a view folder like that renders as "View Not Found".
            content = [f for f in filenames
                       if f in ('view.json', 'code.py', 'query.sql', 'style.json',
                                'props.json', 'config.json', 'data.bin')]
            if content:
                problems.append('%s :: content (%s) but NO resource.json'
                                % (dirpath, ', '.join(sorted(content))))

        # A script-python resource is a LEAF: code.py + resource.json, no
        # child folders. A child makes the Gateway render it as a folder and
        # BlueRidge.Common.Util stops resolving.
        if 'code.py' in filenames and dirnames:
            problems.append('%s :: script resource is not a leaf (%s)'
                            % (dirpath, ', '.join(sorted(dirnames))))
    return problems, resources


def main(argv):
    targets = argv or [os.path.join(ROOT, d) for d in sorted(os.listdir(ROOT))
                       if os.path.isdir(os.path.join(ROOT, d))]
    bad = 0
    for t in targets:
        problems, n = check(t)
        name = os.path.basename(t.rstrip('/\\'))
        if problems:
            bad += 1
            print('FAIL  %-12s %d resources, %d problem(s)' % (name, n, len(problems)))
            for p in problems:
                print('        - %s' % p.replace('\\', '/'))
        else:
            print('ok    %-12s %d resources' % (name, n))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
