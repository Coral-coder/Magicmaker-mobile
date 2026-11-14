#!/usr/bin/env python3
"""Register Swift files in ios/MagicMaker.xcodeproj. Usage: add_swift.py Group/File.swift [...]
Idempotent: a file already referenced is skipped."""
import hashlib, io, re, sys
P = "/home/user/Magicmaker-mobile/ios/MagicMaker.xcodeproj/project.pbxproj"
s = io.open(P, encoding="utf-8").read()
def ident(tag):
    return hashlib.sha1(tag.encode()).hexdigest()[:24].upper()
for arg in sys.argv[1:]:
    group, name = arg.split("/")
    if re.search(r"/\* %s \*/ = \{isa = PBXFileReference" % re.escape(name), s):
        print("skip (already registered)", arg); continue
    ref, build = ident("ref:" + arg), ident("build:" + arg)
    assert ref not in s and build not in s
    # PBXBuildFile
    m = re.search(r"/\* Begin PBXBuildFile section \*/\n", s)
    s = s[:m.end()] + "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (build, name, ref, name) + s[m.end():]
    # PBXFileReference
    m = re.search(r"/\* Begin PBXFileReference section \*/\n", s)
    s = s[:m.end()] + "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };\n" % (ref, name, name) + s[m.end():]
    # Group child
    m = re.search(r"/\* %s \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n" % re.escape(group), s)
    assert m, "group not found: " + group
    s = s[:m.end()] + "\t\t\t\t%s /* %s */,\n" % (ref, name) + s[m.end():]
    # Sources build phase
    m = re.search(r"isa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n", s)
    assert m, "sources phase not found"
    s = s[:m.end()] + "\t\t\t\t%s /* %s in Sources */,\n" % (build, name) + s[m.end():]
    print("registered", arg)
io.open(P, "w", encoding="utf-8").write(s)
