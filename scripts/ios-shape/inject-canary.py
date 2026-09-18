#!/usr/bin/env python3
"""Insert one deliberate type error into a guarded region, to prove it is really compiled.

Two details that matter, both learned the hard way:

  * The canary is a DECLARATION only (`let x: Int = "..."`), never an expression. A statement
    like `_ = x` is illegal at file scope and yields "expressions are not allowed at the top
    level" instead of the type error — which reads as "branch not checked" when it is.

  * It targets the LAST occurrence of the marker. The first is usually the file-scope
    `#if canImport(X) / import X` guard; the last is the one wrapping actual behaviour, which
    is what we want to prove is being compiled.
"""
import io, sys
path, marker = sys.argv[1], sys.argv[2]
lines = io.open(path, encoding='utf-8').read().splitlines(True)
hits = [i for i, l in enumerate(lines) if l.strip() == marker]
if not hits:
    raise SystemExit("marker not found: " + marker)
lines.insert(hits[-1] + 1, 'let __gog_canary: Int = "not an int"\n')
io.open(path, 'w', encoding='utf-8').writelines(lines)
