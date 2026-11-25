#!/usr/bin/env python3
"""Adds the MagicMakerWatch target (watchOS 10 app embedded in MagicMaker) to project.pbxproj.

Re-reads the file, inserts the watch objects and the iPhone Watch/ files, verifies the result and
writes it back in one go. Refuses to run twice. Usage:

    python3 add_watch_target.py [path/to/project.pbxproj] [--check]

--check: build and verify in memory only, write nothing.
"""
import hashlib
import os
import re
import sys

PBX = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else \
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "MagicMaker.xcodeproj", "project.pbxproj")
CHECK_ONLY = "--check" in sys.argv

WATCH_TARGET = "MagicMakerWatch"
IOS_TARGET = "MagicMaker"
WATCH_BUNDLE_SUFFIX = ".watchkitapp"

# iPhone files: group MagicMaker/Watch. (name, in iOS Sources, in watch Sources)
IPHONE_FILES = [
    ("WatchProtocol.swift", True, True),
    ("WatchFavoritesStore.swift", True, False),
    ("WatchBridge.swift", True, False),
    ("WatchContextBuilder.swift", True, False),
    ("WatchFavoritesSection.swift", True, False),
    ("VFDWatchSection.swift", True, False),
]
# Watch files: group MagicMakerWatch. (name, phase) phase: sources / resources / none
WATCH_FILES = [
    ("MagicMakerWatchApp.swift", "sources"),
    ("WatchModel.swift", "sources"),
    ("WatchTheme.swift", "sources"),
    ("FavoritesPage.swift", "sources"),
    ("StatusPage.swift", "sources"),
    ("StopPage.swift", "sources"),
    ("Assets.xcassets", "resources"),
    ("Info.plist", "none"),
]


def uid(name):
    return hashlib.md5(("MagicMakerWatch/" + name).encode()).hexdigest()[:24].upper()


# ---------------------------------------------------------------- OpenStep plist parser (verify)

class Parser:
    TOKEN = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:[^"\\]|\\.)*"|[{}()=;,]|[^\s{}()=;,"]+', re.S)

    def __init__(self, text):
        self.toks = []
        for m in self.TOKEN.finditer(text):
            t = m.group(0)
            if t[0].isspace() or t.startswith("/*") or t.startswith("//"):
                continue
            self.toks.append(t)
        self.i = 0

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def value(self):
        t = self.next()
        if t == "{":
            d = {}
            while self.toks[self.i] != "}":
                k = self.scalar(self.next())
                if k in d:
                    raise ValueError("duplicate key " + k)
                if self.next() != "=":
                    raise ValueError("expected = after " + k)
                d[k] = self.value()
                if self.next() != ";":
                    raise ValueError("expected ; after value of " + k)
            self.i += 1
            return d
        if t == "(":
            a = []
            while self.toks[self.i] != ")":
                a.append(self.value())
                if self.toks[self.i] == ",":
                    self.i += 1
            self.i += 1
            return a
        return self.scalar(t)

    @staticmethod
    def scalar(t):
        if t.startswith('"'):
            return bytes(t[1:-1], "utf-8").decode("unicode_escape")
        return t


def parse(text):
    p = Parser(text)
    root = p.value()
    if p.i != len(p.toks):
        raise ValueError("trailing tokens")
    return root


# ---------------------------------------------------------------- text helpers

def object_block(text, oid):
    """(start, end) of the object `oid` (from its tab-indented key line to its closing '};')."""
    m = re.search(r"^\t\t" + oid + r"(?: /\*.*?\*/)? = \{", text, re.M)
    if not m:
        raise SystemExit("object %s not found" % oid)
    if text[m.end():m.end() + 1] != "\n":   # one-line object
        end = text.index("};\n", m.end()) + 3
        return m.start(), end
    end = text.index("\n\t\t};\n", m.end()) + len("\n\t\t};\n")
    return m.start(), end


def insert_in_list(text, oid, key, line, after=None):
    """Adds `line` (one list entry) to list `key` of object `oid`, after the entry containing
    `after` (or at the end)."""
    s, e = object_block(text, oid)
    block = text[s:e]
    m = re.search(r"^(\t+)" + re.escape(key) + r" = \(\n(.*?)^\1\);", block, re.M | re.S)
    if not m:
        raise SystemExit("list %s not found in %s" % (key, oid))
    indent = m.group(1) + "\t"
    body = m.group(2)
    entry = indent + line + ",\n"
    if after:
        idx = body.find(after)
        if idx < 0:
            raise SystemExit("%s not in %s.%s" % (after, oid, key))
        cut = body.index("\n", idx) + 1
        body = body[:cut] + entry + body[cut:]
    else:
        body = body + entry
    block = block[:m.start(2)] + body + block[m.end(2):]
    return text[:s] + block + text[e:]


SECTION_ORDER = [
    "PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference",
    "PBXFileSystemSynchronizedBuildFileExceptionSet", "PBXFileSystemSynchronizedRootGroup",
    "PBXFrameworksBuildPhase", "PBXGroup", "PBXHeadersBuildPhase", "PBXNativeTarget", "PBXProject",
    "PBXResourcesBuildPhase", "PBXShellScriptBuildPhase", "PBXSourcesBuildPhase", "PBXTargetDependency",
    "PBXVariantGroup", "XCBuildConfiguration", "XCConfigurationList",
]


def add_to_section(text, isa, chunk):
    """Appends `chunk` (complete object lines) at the end of section `isa`, creating the section
    in Xcode's alphabetical place when it does not exist yet."""
    end_marker = "/* End %s section */" % isa
    if end_marker in text:
        i = text.index(end_marker)
        return text[:i] + chunk + text[i:]
    later = SECTION_ORDER[SECTION_ORDER.index(isa) + 1:]
    pos = None
    for other in later:
        m = "/* Begin %s section */" % other
        if m in text:
            pos = text.index(m)
            break
    if pos is None:
        pos = text.index("\t};\n\trootObject")
    section = "/* Begin %s section */\n%s/* End %s section */\n\n" % (isa, chunk, isa)
    return text[:pos] + section + text[pos:]


# ---------------------------------------------------------------- build

def main():
    with open(PBX, "r", encoding="utf-8") as f:
        original = f.read()
    tree = parse(original)
    objs = tree["objects"]
    if any(o.get("isa") == "PBXNativeTarget" and o.get("name") == WATCH_TARGET for o in objs.values()):
        raise SystemExit("MagicMakerWatch is already in the project; nothing to do")

    root_id = tree["rootObject"]
    project = objs[root_id]
    main_group = project["mainGroup"]
    products_group = project["productRefGroup"]
    ios_target = next(k for k, o in objs.items()
                      if o.get("isa") == "PBXNativeTarget" and o.get("name") == IOS_TARGET)
    ios = objs[ios_target]
    ios_sources = next(p for p in ios["buildPhases"] if objs[p]["isa"] == "PBXSourcesBuildPhase")
    ios_resources = next(p for p in ios["buildPhases"] if objs[p]["isa"] == "PBXResourcesBuildPhase")
    app_group = next(c for c in objs[main_group]["children"]
                     if objs[c].get("isa") == "PBXGroup" and objs[c].get("path") == "MagicMaker")
    if any(objs[c].get("path") == "Watch" for c in objs[app_group]["children"]):
        raise SystemExit("MagicMaker/Watch group already exists")

    # The iPhone target's values, so the watch app starts in step (the CI sed keeps it so).
    ios_cfgs = [objs[c] for c in objs[ios["buildConfigurationList"]]["buildConfigurations"]]
    def ios_setting(key):
        vals = {c["buildSettings"].get(key) for c in ios_cfgs}
        if len(vals) != 1 or None in vals:
            raise SystemExit("iPhone target %s differs between configurations: %s" % (key, vals))
        return vals.pop()
    marketing = ios_setting("MARKETING_VERSION")
    build = ios_setting("CURRENT_PROJECT_VERSION")
    team = ios_setting("DEVELOPMENT_TEAM")
    ios_bundle = ios_setting("PRODUCT_BUNDLE_IDENTIFIER")

    ID = {
        "product": uid("product:MagicMakerWatch.app"),
        "target": uid("target:MagicMakerWatch"),
        "watchGroup": uid("group:MagicMakerWatch"),
        "phoneGroup": uid("group:Watch"),
        "wSources": uid("phase:watch.sources"),
        "wFrameworks": uid("phase:watch.frameworks"),
        "wResources": uid("phase:watch.resources"),
        "embed": uid("phase:ios.embedWatch"),
        "proxy": uid("proxy:watch"),
        "dep": uid("dep:watch"),
        "cfgList": uid("configlist:watch"),
        "cfgDebug": uid("config:watch.Debug"),
        "cfgRelease": uid("config:watch.Release"),
        "embedFile": uid("buildfile:embed:MagicMakerWatch.app"),
    }

    def ftype(name):
        if name.endswith(".swift"):
            return "sourcecode.swift"
        if name.endswith(".xcassets"):
            return "folder.assetcatalog"
        if name.endswith(".plist"):
            return "text.plist.xml"
        raise SystemExit("unknown file type " + name)

    buildfiles, filerefs = [], []
    ios_src_lines, w_src_lines, w_res_lines = [], [], []
    phone_children, watch_children = [], []

    for name, in_ios, in_watch in IPHONE_FILES:
        ref = uid("fileref:Watch/" + name)
        filerefs.append('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = "<group>"; };\n'
                        % (ref, name, ftype(name), name))
        phone_children.append("%s /* %s */" % (ref, name))
        if in_ios:
            bf = uid("buildfile:ios:Watch/" + name)
            buildfiles.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bf, name, ref, name))
            ios_src_lines.append("%s /* %s in Sources */" % (bf, name))
        if in_watch:
            bf = uid("buildfile:watch:Watch/" + name)
            buildfiles.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bf, name, ref, name))
            w_src_lines.append("%s /* %s in Sources */" % (bf, name))

    for name, phase in WATCH_FILES:
        ref = uid("fileref:MagicMakerWatch/" + name)
        filerefs.append('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = "<group>"; };\n'
                        % (ref, name, ftype(name), name))
        watch_children.append("%s /* %s */" % (ref, name))
        if phase == "none":
            continue
        bf = uid("buildfile:watch:MagicMakerWatch/" + name)
        label = "Sources" if phase == "sources" else "Resources"
        buildfiles.append("\t\t%s /* %s in %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bf, name, label, ref, name))
        (w_src_lines if phase == "sources" else w_res_lines).append("%s /* %s in %s */" % (bf, name, label))

    filerefs.append("\t\t%s /* MagicMakerWatch.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MagicMakerWatch.app; sourceTree = BUILT_PRODUCTS_DIR; };\n" % ID["product"])
    buildfiles.append("\t\t%s /* MagicMakerWatch.app in Embed Watch Content */ = {isa = PBXBuildFile; fileRef = %s /* MagicMakerWatch.app */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };\n" % (ID["embedFile"], ID["product"]))

    def lst(lines, indent="\t\t\t\t"):
        return "".join(indent + l + ",\n" for l in lines)

    groups = (
        "\t\t%s /* Watch */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\t\t\t);\n\t\t\tpath = Watch;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n"
        % (ID["phoneGroup"], lst(phone_children))
        + "\t\t%s /* MagicMakerWatch */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\t\t\t);\n\t\t\tpath = MagicMakerWatch;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n"
        % (ID["watchGroup"], lst(watch_children))
    )

    proxy = ("\t\t%s /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = %s /* Project object */;\n"
             "\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = %s;\n\t\t\tremoteInfo = %s;\n\t\t};\n"
             % (ID["proxy"], root_id, ID["target"], WATCH_TARGET))
    embed = ("\t\t%s /* Embed Watch Content */ = {\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
             "\t\t\tdstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";\n\t\t\tdstSubfolderSpec = 16;\n\t\t\tfiles = (\n"
             "\t\t\t\t%s /* MagicMakerWatch.app in Embed Watch Content */,\n\t\t\t);\n\t\t\tname = \"Embed Watch Content\";\n"
             "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n" % (ID["embed"], ID["embedFile"]))
    frameworks = ("\t\t%s /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                  "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n" % ID["wFrameworks"])
    target = ("\t\t%s /* %s */ = {\n\t\t\tisa = PBXNativeTarget;\n"
              "\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;\n"
              "\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t\t%s /* Resources */,\n\t\t\t);\n"
              "\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = %s;\n"
              "\t\t\tpackageProductDependencies = (\n\t\t\t);\n\t\t\tproductName = %s;\n"
              "\t\t\tproductReference = %s /* MagicMakerWatch.app */;\n"
              "\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t};\n"
              % (ID["target"], WATCH_TARGET, ID["cfgList"], WATCH_TARGET, ID["wSources"], ID["wFrameworks"],
                 ID["wResources"], WATCH_TARGET, WATCH_TARGET, ID["product"]))
    resources = ("\t\t%s /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                 "\t\t\tfiles = (\n%s\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
                 % (ID["wResources"], lst(w_res_lines)))
    sources = ("\t\t%s /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
               "\t\t\tfiles = (\n%s\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
               % (ID["wSources"], lst(w_src_lines)))
    dep = ("\t\t%s /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = %s /* %s */;\n"
           "\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n\t\t};\n" % (ID["dep"], ID["target"], WATCH_TARGET, ID["proxy"]))

    def cfg(oid, name):
        s = [
            "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
            "CODE_SIGN_STYLE = Automatic;",
            "CURRENT_PROJECT_VERSION = %s;" % build,
            "DEVELOPMENT_TEAM = %s;" % team,
            "ENABLE_DEBUG_DYLIB = NO;",
            "ENABLE_PREVIEWS = NO;",
            "GENERATE_INFOPLIST_FILE = YES;",
            "INFOPLIST_FILE = MagicMakerWatch/Info.plist;",
            "INFOPLIST_KEY_CFBundleDisplayName = MagicMaker;",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations = \"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown\";",
            "INFOPLIST_KEY_WKCompanionAppBundleIdentifier = %s;" % ios_bundle,
            "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp = NO;",
            "LD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t);",
            "MARKETING_VERSION = %s;" % marketing,
            "PRODUCT_BUNDLE_IDENTIFIER = %s%s;" % (ios_bundle, WATCH_BUNDLE_SUFFIX),
            "PRODUCT_NAME = \"$(TARGET_NAME)\";",
            "SDKROOT = watchos;",
            "SKIP_INSTALL = YES;",
            "SUPPORTED_PLATFORMS = \"watchos watchsimulator\";",
            "SWIFT_VERSION = 5.9;",
            "TARGETED_DEVICE_FAMILY = 4;",
            "WATCHOS_DEPLOYMENT_TARGET = 10.0;",
        ]
        body = "".join("\t\t\t\t" + l + "\n" for l in s)
        return ("\t\t%s /* %s */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n%s\t\t\t};\n\t\t\tname = %s;\n\t\t};\n"
                % (oid, name, body, name))

    cfglist = ("\t\t%s /* Build configuration list for PBXNativeTarget \"%s\" */ = {\n\t\t\tisa = XCConfigurationList;\n"
               "\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n"
               "\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Debug;\n\t\t};\n"
               % (ID["cfgList"], WATCH_TARGET, ID["cfgDebug"], ID["cfgRelease"]))

    text = original
    text = add_to_section(text, "PBXBuildFile", "".join(buildfiles))
    text = add_to_section(text, "PBXContainerItemProxy", proxy)
    text = add_to_section(text, "PBXCopyFilesBuildPhase", embed)
    text = add_to_section(text, "PBXFileReference", "".join(filerefs))
    text = add_to_section(text, "PBXFrameworksBuildPhase", frameworks)
    text = add_to_section(text, "PBXGroup", groups)
    text = add_to_section(text, "PBXNativeTarget", target)
    text = add_to_section(text, "PBXResourcesBuildPhase", resources)
    text = add_to_section(text, "PBXSourcesBuildPhase", sources)
    text = add_to_section(text, "PBXTargetDependency", dep)
    text = add_to_section(text, "XCBuildConfiguration", cfg(ID["cfgDebug"], "Debug") + cfg(ID["cfgRelease"], "Release"))
    text = add_to_section(text, "XCConfigurationList", cfglist)

    # Existing objects: groups, the iPhone target, the project.
    text = insert_in_list(text, main_group, "children", "%s /* MagicMakerWatch */" % ID["watchGroup"], after=app_group)
    text = insert_in_list(text, app_group, "children", "%s /* Watch */" % ID["phoneGroup"])
    text = insert_in_list(text, products_group, "children", "%s /* MagicMakerWatch.app */" % ID["product"])
    for line in ios_src_lines:
        text = insert_in_list(text, ios_sources, "files", line)
    text = insert_in_list(text, ios_target, "buildPhases", "%s /* Embed Watch Content */" % ID["embed"], after=ios_resources)
    s, e = object_block(text, ios_target)
    block = text[s:e].replace("\t\t\tdependencies = (\n\t\t\t);",
                              "\t\t\tdependencies = (\n\t\t\t\t%s /* PBXTargetDependency */,\n\t\t\t);" % ID["dep"])
    if ID["dep"] not in block:
        raise SystemExit("iPhone target dependencies list is not empty; add the dependency by hand")
    text = text[:s] + block + text[e:]
    text = insert_in_list(text, root_id, "targets", "%s /* %s */" % (ID["target"], WATCH_TARGET))
    s, e = object_block(text, root_id)
    block = text[s:e]
    anchor = "\t\t\t\tTargetAttributes = {\n"
    if anchor not in block:
        raise SystemExit("TargetAttributes not found")
    block = block.replace(anchor, anchor + "\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;\n"
                          "\t\t\t\t\t\tProvisioningStyle = Automatic;\n\t\t\t\t\t};\n" % ID["target"], 1)
    text = text[:s] + block + text[e:]

    verify(original, text, ID, ios_target, ios_bundle)

    if CHECK_ONLY:
        print("check only: verified, nothing written")
        return
    with open(PBX, "r", encoding="utf-8") as f:
        if f.read() != original:
            raise SystemExit("project.pbxproj changed while this ran (another workflow?); run again")
    tmp = PBX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, PBX)
    print("added %s (%s %s (%s)) to %s" % (WATCH_TARGET, ios_bundle + WATCH_BUNDLE_SUFFIX, marketing, build, PBX))


REF_KEYS = {"fileRef", "children", "files", "buildPhases", "dependencies", "target", "targetProxy",
            "containerPortal", "remoteGlobalIDString", "buildConfigurationList", "buildConfigurations",
            "productReference", "mainGroup", "productRefGroup", "targets"}


def verify(original, text, ID, ios_target, ios_bundle):
    old = parse(original)["objects"]
    tree = parse(text)
    objs = tree["objects"]
    new_ids = set(objs) - set(old)
    hexid = re.compile(r"^[0-9A-F]{24}$")
    bad = [i for i in new_ids if not hexid.match(i)]
    if bad:
        raise SystemExit("new ids not 24-hex: %s" % bad)
    if len(new_ids) != len(set(objs)) - len(set(old)) or not set(old) <= set(objs):
        raise SystemExit("objects lost")
    # Every reference resolves.
    def refs(o):
        for k, v in o.items():
            if k in REF_KEYS:
                for r in (v if isinstance(v, list) else [v]):
                    yield k, r
    for oid, o in objs.items():
        for k, r in refs(o):
            if r not in objs:
                raise SystemExit("%s.%s -> %s does not resolve" % (oid, k, r))
    if tree["rootObject"] not in objs:
        raise SystemExit("rootObject does not resolve")
    # Each file reference in exactly one group (products included).
    owner = {}
    for oid, o in objs.items():
        if o.get("isa") in ("PBXGroup", "PBXVariantGroup"):
            for c in o["children"]:
                owner.setdefault(c, []).append(oid)
    for oid, o in objs.items():
        if o.get("isa") == "PBXFileReference" and len(owner.get(oid, [])) != 1:
            raise SystemExit("file %s (%s) is in %d groups" % (oid, o.get("path"), len(owner.get(oid, []))))
    # Each build file in exactly one phase; no file twice in one target's phase.
    phase_of = {}
    for oid, o in objs.items():
        if "files" in o and o.get("isa", "").endswith("BuildPhase"):
            seen = set()
            for bf in o["files"]:
                phase_of.setdefault(bf, []).append(oid)
                fr = objs[bf]["fileRef"]
                if fr in seen:
                    raise SystemExit("%s twice in phase %s" % (fr, oid))
                seen.add(fr)
    for oid, o in objs.items():
        if o.get("isa") == "PBXBuildFile" and len(phase_of.get(oid, [])) != 1:
            raise SystemExit("build file %s is in %d phases" % (oid, len(phase_of.get(oid, []))))
    # Targets: phases as designed.
    watch = objs[ID["target"]]
    ios = objs[ios_target]
    def phase(t, isa):
        return [p for p in t["buildPhases"] if objs[p]["isa"] == isa]
    def names(p):
        return sorted(objs[objs[bf]["fileRef"]]["path"] for bf in objs[p]["files"])
    w_src = names(phase(watch, "PBXSourcesBuildPhase")[0])
    want = sorted([n for n, ph in WATCH_FILES if ph == "sources"] + [n for n, _, w in IPHONE_FILES if w])
    if w_src != want:
        raise SystemExit("watch Sources %s != %s" % (w_src, want))
    if names(phase(watch, "PBXResourcesBuildPhase")[0]) != ["Assets.xcassets"]:
        raise SystemExit("watch Resources wrong")
    ios_src = names(phase(ios, "PBXSourcesBuildPhase")[0])
    for n, in_ios, _ in IPHONE_FILES:
        if ios_src.count(n) != 1:
            raise SystemExit("%s in iPhone Sources %d times" % (n, ios_src.count(n)))
    for n, _ in WATCH_FILES:
        if n in ios_src and n not in [x for x, _, _ in IPHONE_FILES]:
            raise SystemExit("watch file %s in iPhone Sources" % n)
    embeds = phase(ios, "PBXCopyFilesBuildPhase")
    if len(embeds) != 1 or objs[embeds[0]]["dstSubfolderSpec"] != "16" \
            or objs[embeds[0]]["dstPath"] != "$(CONTENTS_FOLDER_PATH)/Watch" or names(embeds[0]) != ["MagicMakerWatch.app"]:
        raise SystemExit("Embed Watch Content wrong")
    if ios["dependencies"] != [ID["dep"]] or objs[ID["dep"]]["target"] != ID["target"]:
        raise SystemExit("iPhone target dependency wrong")
    for c in objs[watch["buildConfigurationList"]]["buildConfigurations"]:
        bs = objs[c]["buildSettings"]
        if bs["PRODUCT_BUNDLE_IDENTIFIER"] != ios_bundle + WATCH_BUNDLE_SUFFIX or bs["SDKROOT"] != "watchos" \
                or bs["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] != ios_bundle \
                or bs.get("SKIP_INSTALL") != "YES":
            raise SystemExit("watch build settings wrong")
    # Every MARKETING_VERSION / CURRENT_PROJECT_VERSION line agrees (the CI sed rewrites them all).
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        vals = set(re.findall(r"^\s*" + key + r" = \"?([^\";]+)\"?;", text, re.M))
        if len(vals) != 1:
            raise SystemExit("%s values differ: %s" % (key, vals))
    print("verified: %d new objects, every reference resolves" % len(new_ids))


if __name__ == "__main__":
    main()
