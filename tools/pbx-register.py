#!/usr/bin/env python3
"""Register a new .swift file in HermesGlasses.xcodeproj.

The project has no synchronized groups, so a new file needs four entries:
PBXBuildFile, PBXFileReference, the group's children, and the Sources build
phase. This inserts all four right after an existing sibling file's entries.

Usage (from the repo root):
  tools/pbx-register.py <path-in-group> <sibling-basename> <buildfile-id> <fileref-id>
  e.g. tools/pbx-register.py BuildCheck/Procedure.swift AiSeeClipRecorder.swift \
         AAAA00000000000000000A5B AAAA00000000000000000A5C
"""
import re
import sys

P = 'HermesGlasses.xcodeproj/project.pbxproj'
path, sib, bid, rid = sys.argv[1:5]
name = path.split('/')[-1]
s = open(P).read()
for i in (bid, rid):
    if i in s:
        sys.exit(f'id {i} already used')
if f'/* {name} */' in s:
    sys.exit(f'{name} already registered')


def after(pattern, line):
    global s
    m = list(re.finditer(pattern, s, re.M))
    if len(m) != 1:
        sys.exit(f'anchor not found exactly once: {pattern}')
    j = s.index('\n', m[0].end()) + 1
    s = s[:j] + line + s[j:]


e = re.escape(sib)
after(r'^\t\t\w+ /\* ' + e + r' in Sources \*/ = \{isa = PBXBuildFile;',
      f'\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {rid} /* {name} */; }};\n')
after(r'^\t\t\w+ /\* ' + e + r' \*/ = \{isa = PBXFileReference;',
      f'\t\t{rid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path}; sourceTree = "<group>"; }};\n')
after(r'^\t\t\t\t\w+ /\* ' + e + r' \*/,$', f'\t\t\t\t{rid} /* {name} */,\n')
after(r'^\t\t\t\t\w+ /\* ' + e + r' in Sources \*/,$', f'\t\t\t\t{bid} /* {name} in Sources */,\n')
open(P, 'w').write(s)
print(f'registered {path}')
