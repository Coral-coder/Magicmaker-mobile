#!/usr/bin/env python3
"""Unregister Swift files from ios/MagicMaker.xcodeproj. Usage: remove_swift.py File.swift [...]"""
import io, re, sys
P = "/home/user/Magicmaker-mobile/ios/MagicMaker.xcodeproj/project.pbxproj"
s = io.open(P, encoding="utf-8").read()
for name in sys.argv[1:]:
    before = s.count("\n")
    lines = [l for l in s.split("\n") if not re.search(r"/\* %s( in Sources)? \*/" % re.escape(name), l)]
    s = "\n".join(lines)
    print("removed %d lines for %s" % (before - s.count("\n"), name))
io.open(P, "w", encoding="utf-8").write(s)
