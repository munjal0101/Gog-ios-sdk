#!/usr/bin/env python3
"""Copy the SDK sources and rewrite ONLY the two constructs Linux Swift cannot parse.

  @objc <decl>   ->  <decl>            (ObjC runtime absent)
  #selector(x)   ->  Selector("x")     (ditto)

Nothing else is touched. The real sources are never modified.
"""
import re, shutil, sys, pathlib

src = pathlib.Path(sys.argv[1]); dst = pathlib.Path(sys.argv[2])
if dst.exists(): shutil.rmtree(dst)
shutil.copytree(src, dst)

# UIKit.UIGestureRecognizerSubclass is a Clang submodule; it cannot exist on Linux. The shim
# declares those methods on the base class instead, so the import is dropped for the harness.
# ⚠️ Consequence, stated so it is not forgotten: the harness cannot verify that this import is
# PRESENT. Only Xcode can. It is required — see PlaytimeAutoHook.swift.
subm = re.compile(r'^import UIKit\.UIGestureRecognizerSubclass\n', re.MULTILINE)
sel = re.compile(r'#selector\(\s*([^)]*?)\s*\)')
obj = re.compile(r'@objc\s+', re.MULTILINE)
changed = []
for f in sorted(dst.rglob('*.swift')):
    t = f.read_text(encoding='utf-8')
    n = subm.sub('', obj.sub('', sel.sub(lambda m: 'Selector("%s")' % m.group(1).replace('"', ''), t)))
    if n != t:
        f.write_text(n, encoding='utf-8')
        changed.append(f.relative_to(dst).as_posix())
print("rewritten:", *changed, sep="\n  ")
