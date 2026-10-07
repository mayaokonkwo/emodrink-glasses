#!/usr/bin/env python3
"""Remove every HermesGlasses.xcodeproj entry for one or more files.

The inverse of tools/pbx-register.py. For each basename it deletes the
single-line entries whose comment names the file: PBXBuildFile (in Sources,
Resources, Frameworks or Embed Frameworks), PBXFileReference, the group's
child line and the build phase's line. Comments may carry a folder prefix
("EmoDrink/DrinkCatalog.swift"), so the match is on the last path part.

Multi-line objects (PBXGroup blocks) are left alone. After removal no
removed object id may appear anywhere in the file, or nothing is written.

Usage (from the repo root):
  tools/pbx-unregister.py [--dry-run] [--project PATH] <basename> [<basename> ...]
  e.g. tools/pbx-unregister.py PeopleView.swift yolo11n.mlpackage
"""
import re
import sys

args = sys.argv[1:]
dry = False
project = 'HermesGlasses.xcodeproj/project.pbxproj'
names = []
i = 0
while i < len(args):
    a = args[i]
    if a == '--dry-run':
        dry = True
    elif a == '--project':
        i += 1
        project = args[i]
    else:
        names.append(a)
    i += 1
if not names:
    sys.exit(__doc__)

lines = open(project).read().split('\n')
SUFFIX = r'(?: in (?:Sources|Resources|Frameworks|Embed Frameworks))?'
removed_ids = set()
keep = [True] * len(lines)

for name in names:
    comment = re.compile(r'/\* (?:[^*]*/)?' + re.escape(name) + SUFFIX + r' \*/')
    single_object = re.compile(r'^\t+(\w+) /\* [^*]+ \*/ = \{isa = PBX(?:BuildFile|FileReference);.*\};$')
    list_entry = re.compile(r'^\t+(\w+) /\* [^*]+ \*/,$')
    hits = 0
    for n, line in enumerate(lines):
        if not keep[n] or not comment.search(line):
            continue
        m = single_object.match(line) or list_entry.match(line)
        if not m:
            print(f'skip (multi-line object, edit by hand if needed): {line.strip()}')
            continue
        keep[n] = False
        hits += 1
        if single_object.match(line):
            removed_ids.add(m.group(1))
        print(f'{"would remove" if dry else "remove"}: {line.strip()}')
    if hits == 0:
        sys.exit(f'no pbxproj entry for {name}')

out = [l for l, k in zip(lines, keep) if k]
text = '\n'.join(out)
left = sorted(i for i in removed_ids if re.search(r'\b' + i + r'\b', text))
if left:
    sys.exit(f'ids still referenced after removal, nothing written: {left}')
if not dry:
    open(project, 'w').write(text)
print(f'{"dry run, " if dry else ""}{len(lines) - len(out)} lines for {len(names)} file(s)')
