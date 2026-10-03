#!/usr/bin/env python3
"""Generate MagicMaker.xcodeproj for opening directly in Xcode."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "MagicMaker"
BUNDLE_ID = "com.lightwave.MMIOS"

SWIFT_SOURCES = [
    "MagicMaker/MagicMakerApp.swift",
    "MagicMaker/Core/HexUtils.swift",
    "MagicMaker/Core/MagicModels.swift",
    "MagicMaker/Core/PresetCatalog.swift",
    "MagicMaker/Core/MagicClassifier.swift",
    "MagicMaker/Core/StarlightSerial.swift",
    "MagicMaker/Core/PacketPatterns.swift",
    "MagicMaker/Data/MagicStore.swift",
    "MagicMaker/BLE/BleCentral.swift",
    "MagicMaker/BLE/AndroidRelayGattClient.swift",
    "MagicMaker/BLE/AndroidWifiRelayClient.swift",
    "MagicMaker/BLE/RelayBackend.swift",
    "MagicMaker/BLE/BleTransmitter.swift",
    "MagicMaker/BLE/BleCoordinator.swift",
    "MagicMaker/ViewModels/AppViewModel.swift",
    "MagicMaker/Views/ContentView.swift",
    "MagicMaker/Views/RecordTab.swift",
    "MagicMaker/Views/PresetsTab.swift",
    "MagicMaker/Views/AutoTab.swift",
    "MagicMaker/Views/FilesTab.swift",
    "MagicMaker/Views/LabTab.swift",
]


def uid(n: int) -> str:
    return f"A1{n:06X}0000000000000001"[:24]


# Fixed IDs
PROJECT_ID = uid(1)
TARGET_ID = uid(2)
ROOT_GROUP = uid(3)
PRODUCTS_GROUP = uid(4)
PRODUCT_REF = uid(5)
SOURCES_PHASE = uid(6)
RESOURCES_PHASE = uid(7)
FRAMEWORKS_PHASE = uid(8)
PROJECT_CONFIG_LIST = uid(9)
TARGET_CONFIG_LIST = uid(10)
DEBUG_PROJECT = uid(11)
RELEASE_PROJECT = uid(12)
DEBUG_TARGET = uid(13)
RELEASE_TARGET = uid(14)
MAIN_GROUP = uid(15)
MAGICMAKER_GROUP = uid(16)
CORE_GROUP = uid(17)
BLE_GROUP = uid(18)
DATA_GROUP = uid(19)
VM_GROUP = uid(20)
VIEWS_GROUP = uid(21)
ASSETS_REF = uid(22)
INFOPLIST_REF = uid(23)
NATIVE_TARGET = uid(24)
BUILD_CONFIG_SECTION = uid(25)

file_refs = {}
build_files = {}
for i, path in enumerate(SWIFT_SOURCES, start=100):
    file_refs[path] = uid(i)
    build_files[path] = uid(i + 1000)

pbxproj = ROOT / f"{PROJECT_NAME}.xcodeproj" / "project.pbxproj"
pbxproj.parent.mkdir(parents=True, exist_ok=True)

lines = [
    "// !$*UTF8*$!",
    "{",
    "\tarchiveVersion = 1;",
    "\tclasses = {",
    "\t};",
    "\tobjectVersion = 56;",
    "\tobjects = {",
    "",
    "/* Begin PBXBuildFile section */",
]
for path in SWIFT_SOURCES:
    name = Path(path).name
    lines.append(
        f"\t\t{build_files[path]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {name} */; }};"
    )
lines.append(
    f"\t\t{uid(2000)} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS_REF} /* Assets.xcassets */; }};"
)
lines.append("/* End PBXBuildFile section */")
lines.append("")
lines.append("/* Begin PBXFileReference section */")
lines.append(
    f"\t\t{PRODUCT_REF} /* MagicMaker.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MagicMaker.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
)
for path in SWIFT_SOURCES:
    name = Path(path).name
    lines.append(
        f"\t\t{file_refs[path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
    )
lines.append(
    f"\t\t{ASSETS_REF} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};"
)
lines.append(
    f"\t\t{INFOPLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};"
)
lines.append("/* End PBXFileReference section */")
lines.append("")
lines.append("/* Begin PBXFrameworksBuildPhase section */")
lines.append(
    f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};"
)
lines.append("/* End PBXFrameworksBuildPhase section */")
lines.append("")
lines.append("/* Begin PBXGroup section */")
lines.append(
    f"\t\t{MAIN_GROUP} = {{isa = PBXGroup; children = ({MAGICMAKER_GROUP} /* MagicMaker */, {PRODUCTS_GROUP} /* Products */); sourceTree = \"<group>\"; }};"
)
lines.append(
    f"\t\t{PRODUCTS_GROUP} /* Products */ = {{isa = PBXGroup; children = ({PRODUCT_REF} /* MagicMaker.app */); name = Products; sourceTree = \"<group>\"; }};"
)

def group(gid, name, children_ids, path=None):
    path_line = f"; path = {path}" if path else ""
    kids = ", ".join(children_ids)
    return f"\t\t{gid} /* {name} */ = {{isa = PBXGroup; children = ({kids}); name = {name}{path_line}; sourceTree = \"<group>\"; }};"

core_children = [f"{file_refs[p]} /* {Path(p).name} */" for p in SWIFT_SOURCES if "/Core/" in p]
ble_children = [f"{file_refs[p]} /* {Path(p).name} */" for p in SWIFT_SOURCES if "/BLE/" in p]
data_children = [f"{file_refs[p]} /* {Path(p).name} */" for p in SWIFT_SOURCES if "/Data/" in p]
vm_children = [f"{file_refs[p]} /* {Path(p).name} */" for p in SWIFT_SOURCES if "/ViewModels/" in p]
views_children = [f"{file_refs[p]} /* {Path(p).name} */" for p in SWIFT_SOURCES if "/Views/" in p]

lines.append(group(CORE_GROUP, "Core", core_children, path="Core"))
lines.append(group(BLE_GROUP, "BLE", ble_children, path="BLE"))
lines.append(group(DATA_GROUP, "Data", data_children, path="Data"))
lines.append(group(VM_GROUP, "ViewModels", vm_children, path="ViewModels"))
lines.append(group(VIEWS_GROUP, "Views", views_children, path="Views"))

mm_children = [
    f"{file_refs['MagicMaker/MagicMakerApp.swift']} /* MagicMakerApp.swift */",
    f"{CORE_GROUP} /* Core */",
    f"{BLE_GROUP} /* BLE */",
    f"{DATA_GROUP} /* Data */",
    f"{VM_GROUP} /* ViewModels */",
    f"{VIEWS_GROUP} /* Views */",
    f"{ASSETS_REF} /* Assets.xcassets */",
    f"{INFOPLIST_REF} /* Info.plist */",
]
lines.append(group(MAGICMAKER_GROUP, "MagicMaker", mm_children, path="MagicMaker"))
lines.append("/* End PBXGroup section */")
lines.append("")
lines.append("/* Begin PBXNativeTarget section */")
lines.append(
    f"\t\t{NATIVE_TARGET} /* MagicMaker */ = {{isa = PBXNativeTarget; buildConfigurationList = {TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"MagicMaker\" */; buildPhases = ({SOURCES_PHASE} /* Sources */, {FRAMEWORKS_PHASE} /* Frameworks */, {RESOURCES_PHASE} /* Resources */); buildRules = (); dependencies = (); name = MagicMaker; productName = MagicMaker; productReference = {PRODUCT_REF} /* MagicMaker.app */; productType = \"com.apple.product-type.application\"; }};"
)
lines.append("/* End PBXNativeTarget section */")
lines.append("")
lines.append("/* Begin PBXProject section */")
lines.append(
    f"\t\t{PROJECT_ID} /* Project object */ = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 1500; ORGANIZATIONNAME = MagicMaker; TargetAttributes = {{{NATIVE_TARGET} = {{CreatedOnToolsVersion = 15.0; }}; }}; }}; buildConfigurationList = {PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject \"MagicMaker\" */; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {MAIN_GROUP}; productRefGroup = {PRODUCTS_GROUP} /* Products */; projectDirPath = \"\"; projectRoot = \"\"; targets = ({NATIVE_TARGET} /* MagicMaker */); }};"
)
lines.append("/* End PBXProject section */")
lines.append("")
lines.append("/* Begin PBXResourcesBuildPhase section */")
lines.append(
    f"\t\t{RESOURCES_PHASE} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid(2000)} /* Assets.xcassets in Resources */,); runOnlyForDeploymentPostprocessing = 0; }};"
)
lines.append("/* End PBXResourcesBuildPhase section */")
lines.append("")
lines.append("/* Begin PBXSourcesBuildPhase section */")
src_files = ", ".join(f"{build_files[p]} /* {Path(p).name} in Sources */" for p in SWIFT_SOURCES)
lines.append(
    f"\t\t{SOURCES_PHASE} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({src_files},); runOnlyForDeploymentPostprocessing = 0; }};"
)
lines.append("/* End PBXSourcesBuildPhase section */")
lines.append("")

COMMON_TARGET = """
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = MagicMaker/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = MagicMaker;
\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";
\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tENABLE_DEBUG_DYLIB = NO;
\t\t\t\tOTHER_LDFLAGS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"-ld_classic",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
""".format(bundle=BUNDLE_ID)

lines.append("/* Begin XCBuildConfiguration section */")
lines.append(
    f"\t\t{DEBUG_PROJECT} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; COPY_PHASE_STRIP = NO; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; GCC_DYNAMIC_NO_PIC = NO; GCC_OPTIMIZATION_LEVEL = 0; GCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\",); IPHONEOS_DEPLOYMENT_TARGET = 17.0; MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE; ONLY_ACTIVE_ARCH = YES; SDKROOT = iphoneos; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_OPTIMIZATION_LEVEL = \"-Onone\"; }}; name = Debug; }};"
)
lines.append(
    f"\t\t{RELEASE_PROJECT} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; COPY_PHASE_STRIP = NO; DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\"; ENABLE_NS_ASSERTIONS = NO; IPHONEOS_DEPLOYMENT_TARGET = 17.0; MTL_ENABLE_DEBUG_INFO = NO; SDKROOT = iphoneos; SWIFT_COMPILATION_MODE = wholemodule; VALIDATE_PRODUCT = YES; }}; name = Release; }};"
)
lines.append(
    f"\t\t{DEBUG_TARGET} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{{COMMON_TARGET}\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; }}; name = Debug; }};"
)
lines.append(
    f"\t\t{RELEASE_TARGET} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{{COMMON_TARGET}\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule; }}; name = Release; }};"
)
lines.append("/* End XCBuildConfiguration section */")
lines.append("")
lines.append("/* Begin XCConfigurationList section */")
lines.append(
    f"\t\t{PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject \"MagicMaker\" */ = {{isa = XCConfigurationList; buildConfigurations = ({DEBUG_PROJECT} /* Debug */, {RELEASE_PROJECT} /* Release */); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};"
)
lines.append(
    f"\t\t{TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"MagicMaker\" */ = {{isa = XCConfigurationList; buildConfigurations = ({DEBUG_TARGET} /* Debug */, {RELEASE_TARGET} /* Release */); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};"
)
lines.append("/* End XCConfigurationList section */")
lines.append("\t};")
lines.append(f"\trootObject = {PROJECT_ID} /* Project object */;")
lines.append("}")

pbxproj.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Wrote {pbxproj}")

# Workspace
workspace = ROOT / f"{PROJECT_NAME}.xcodeproj" / "project.xcworkspace" / "contents.xcworkspacedata"
workspace.parent.mkdir(parents=True, exist_ok=True)
workspace.write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Workspace version="1.0">\n'
    '   <FileRef location="self:"></FileRef>\n'
    '</Workspace>\n',
    encoding="utf-8",
)

# Scheme
scheme_dir = ROOT / f"{PROJECT_NAME}.xcodeproj" / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / f"{PROJECT_NAME}.xcscheme").write_text(
    f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{NATIVE_TARGET}" BuildableName="MagicMaker.app" BlueprintName="MagicMaker" ReferencedContainer="container:MagicMaker.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{NATIVE_TARGET}" BuildableName="MagicMaker.app" BlueprintName="MagicMaker" ReferencedContainer="container:MagicMaker.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
""",
    encoding="utf-8",
)
print("Done.")
