#!/usr/bin/env python3
"""Every #selector(x) must name an @objc member in the same file.

The type-check harness rewrites #selector away (Linux has no ObjC runtime), so this is the
only thing standing between a renamed method and an unrecognised-selector crash at runtime.
"""
import re, sys, pathlib
root = pathlib.Path(sys.argv[1]); bad = 0
for f in sorted(root.rglob('*.swift')):
    t = f.read_text(encoding='utf-8')
    sels = re.findall(r'#selector\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)', t)
    objc = set(re.findall(r'@objc\s+(?:private |internal |public |fileprivate )*func\s+([A-Za-z_][A-Za-z0-9_]*)', t))
    for s in sels:
        if s.split('.')[-1] not in objc:
            print(f"  {f.relative_to(root)}: #selector({s}) has no @objc method"); bad += 1
sys.exit(1 if bad else 0)
