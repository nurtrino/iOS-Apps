#!/usr/bin/env python3
"""Generate ios/Dispatch.xcodeproj from what is actually on disk.

There is no Xcode in this environment, so the project file is written by hand.
That is fine — the format is stable and mostly mechanical — but it has one
sharp edge: a source file that exists on disk and is *not* listed in the
project simply is not compiled, and the failure surfaces much later as an
"undefined symbol" at link time, pointing at the use rather than the omission.

Generating the file list by walking the directory removes that failure mode
entirely, and `--check` re-runs the generation to assert the committed project
still matches the tree.

Run: python3 dispatch/tools/gen_pbxproj.py [--check]
"""

import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

PROJECT_NAME = "Dispatch"
BUNDLE_ID = "com.nurtrino.dispatch"
DEPLOYMENT_TARGET = "16.0"
SWIFT_VERSION = "5.0"

# The Swift module cannot be called "Dispatch".
#
# `Dispatch` is Apple's own module — libdispatch, where `DispatchQueue` lives —
# and Foundation imports it. A target whose module is also named `Dispatch`
# therefore makes Foundation depend on us and us depend on Foundation, and the
# build dies with:
#
#     error: circular dependency between modules 'Dispatch' and 'Foundation'
#
# There is no source-level fix; the module simply needs another name. The
# product, the scheme, the .app and the name on the home screen all stay
# "Dispatch" — only the Swift module differs, and nothing refers to it by name.
MODULE_NAME = "DispatchNews"

# Module names that collide with a system framework in the same way. Not
# exhaustive, but these are the ones an app is plausibly named after.
RESERVED_MODULE_NAMES = {
    "Dispatch", "Foundation", "Combine", "Network", "Contacts", "Photos",
    "Vision", "Speech", "Metal", "Charts", "Observation", "Testing", "Swift",
    "Darwin", "Security", "Accounts", "Intents", "Messages", "Social",
}

IOS_DIR = os.path.join(REPO, "ios")
SOURCE_ROOT = os.path.join(IOS_DIR, PROJECT_NAME)
PROJECT_DIR = os.path.join(IOS_DIR, PROJECT_NAME + ".xcodeproj")

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".xcassets": "folder.assetcatalog",
    ".png": "image.png",
}


def oid(seed):
    """A stable 24-hex-character object id derived from the path.

    Deterministic so that regenerating an unchanged tree produces a
    byte-identical file and `--check` means something.
    """
    return hashlib.md5(seed.encode("utf-8")).hexdigest()[:24].upper()


def collect():
    """Swift sources and resources, relative to SOURCE_ROOT, sorted."""
    sources = []
    resources = []
    for dirpath, dirnames, filenames in os.walk(SOURCE_ROOT):
        # Asset catalogs are added whole, never walked into.
        dirnames[:] = sorted(d for d in dirnames if not d.endswith(".xcassets"))
        for name in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, name), SOURCE_ROOT)
            if name.endswith(".swift"):
                sources.append(rel)
        for name in sorted(os.listdir(dirpath)):
            if name.endswith(".xcassets"):
                rel = os.path.relpath(os.path.join(dirpath, name), SOURCE_ROOT)
                if rel not in resources:
                    resources.append(rel)
    return sorted(sources), sorted(resources)


class Tree:
    """Directory tree mirroring the on-disk layout, for PBXGroup output."""

    def __init__(self, name, path=None):
        self.name = name
        self.path = path
        self.children = {}
        self.files = []

    def add(self, rel):
        parts = rel.split(os.sep)
        node = self
        for part in parts[:-1]:
            if part not in node.children:
                node.children[part] = Tree(part, part)
            node = node.children[part]
        node.files.append((parts[-1], rel))


def build_tree(paths):
    root = Tree(PROJECT_NAME, PROJECT_NAME)
    for path in paths:
        root.add(path)
    return root


def emit_groups(node, prefix, lines, file_refs):
    """Depth-first, emitting child groups before the parent that names them."""
    child_ids = []
    for key in sorted(node.children):
        child = node.children[key]
        child_ids.append(emit_groups(child, prefix + "/" + key, lines, file_refs))

    entries = []
    for cid, name in child_ids:
        entries.append("\t\t\t\t%s /* %s */," % (cid, name))
    for name, rel in sorted(node.files):
        entries.append("\t\t\t\t%s /* %s */," % (file_refs[rel], name))

    group_id = oid("group:" + prefix)
    lines.append("\t\t%s /* %s */ = {" % (group_id, node.name))
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.extend(entries)
    lines.append("\t\t\t);")
    if node.path:
        lines.append("\t\t\tpath = %s;" % node.path)
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")
    return group_id, node.name


def settings_block(pairs, indent="\t\t\t\t"):
    return "\n".join("%s%s = %s;" % (indent, key, value) for key, value in pairs)


def generate():
    if MODULE_NAME in RESERVED_MODULE_NAMES:
        raise SystemExit(
            "MODULE_NAME %r collides with a system module — the build will fail with "
            "'circular dependency between modules'" % MODULE_NAME
        )

    sources, resources = collect()
    if not sources:
        raise SystemExit("no Swift sources found under %s" % SOURCE_ROOT)

    all_files = sources + resources + ["Info.plist"]
    file_refs = {rel: oid("fileref:" + rel) for rel in all_files}
    build_files = {rel: oid("buildfile:" + rel) for rel in sources + resources}

    project_id = oid("project")
    target_id = oid("target")
    product_id = oid("product")
    products_group_id = oid("group:Products")
    main_group_id = oid("group:main")
    sources_phase_id = oid("phase:sources")
    resources_phase_id = oid("phase:resources")
    frameworks_phase_id = oid("phase:frameworks")
    project_config_list_id = oid("configlist:project")
    target_config_list_id = oid("configlist:target")

    out = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")

    # PBXBuildFile
    out.append("")
    out.append("/* Begin PBXBuildFile section */")
    for rel in sources:
        name = os.path.basename(rel)
        out.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (build_files[rel], name, file_refs[rel], name))
    for rel in resources:
        name = os.path.basename(rel)
        out.append("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (build_files[rel], name, file_refs[rel], name))
    out.append("/* End PBXBuildFile section */")

    # PBXFileReference
    out.append("")
    out.append("/* Begin PBXFileReference section */")
    for rel in sorted(all_files):
        name = os.path.basename(rel)
        ext = os.path.splitext(name)[1]
        file_type = FILE_TYPES.get(ext, "text")
        out.append(
            "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = \"<group>\"; };"
            % (file_refs[rel], name, file_type, name)
        )
    out.append(
        "\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; "
        "includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };"
        % (product_id, PROJECT_NAME, PROJECT_NAME)
    )
    out.append("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    out.append("")
    out.append("/* Begin PBXFrameworksBuildPhase section */")
    out.append("\t\t%s /* Frameworks */ = {" % frameworks_phase_id)
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    out.append("")
    out.append("/* Begin PBXGroup section */")
    group_lines = []
    tree = build_tree(sorted(set(sources + resources + ["Info.plist"])))
    root_group_id, _ = emit_groups(tree, PROJECT_NAME, group_lines, file_refs)
    out.extend(group_lines)

    out.append("\t\t%s /* Products */ = {" % products_group_id)
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append("\t\t\t\t%s /* %s.app */," % (product_id, PROJECT_NAME))
    out.append("\t\t\t);")
    out.append("\t\t\tname = Products;")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")

    out.append("\t\t%s = {" % main_group_id)
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append("\t\t\t\t%s /* %s */," % (root_group_id, PROJECT_NAME))
    out.append("\t\t\t\t%s /* Products */," % products_group_id)
    out.append("\t\t\t);")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    out.append("/* End PBXGroup section */")

    # PBXNativeTarget
    out.append("")
    out.append("/* Begin PBXNativeTarget section */")
    out.append("\t\t%s /* %s */ = {" % (target_id, PROJECT_NAME))
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;"
               % (target_config_list_id, PROJECT_NAME))
    out.append("\t\t\tbuildPhases = (")
    out.append("\t\t\t\t%s /* Sources */," % sources_phase_id)
    out.append("\t\t\t\t%s /* Frameworks */," % frameworks_phase_id)
    out.append("\t\t\t\t%s /* Resources */," % resources_phase_id)
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append("\t\t\t);")
    out.append("\t\t\tname = %s;" % PROJECT_NAME)
    out.append("\t\t\tproductName = %s;" % PROJECT_NAME)
    out.append("\t\t\tproductReference = %s /* %s.app */;" % (product_id, PROJECT_NAME))
    out.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    out.append("\t\t};")
    out.append("/* End PBXNativeTarget section */")

    # PBXProject
    out.append("")
    out.append("/* Begin PBXProject section */")
    out.append("\t\t%s /* Project object */ = {" % project_id)
    out.append("\t\t\tisa = PBXProject;")
    out.append("\t\t\tattributes = {")
    out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    out.append("\t\t\t\tLastUpgradeCheck = 1500;")
    out.append("\t\t\t\tTargetAttributes = {")
    out.append("\t\t\t\t\t%s = {" % target_id)
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t};")
    out.append("\t\t\t};")
    out.append("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"%s\" */;"
               % (project_config_list_id, PROJECT_NAME))
    out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    out.append("\t\t\tdevelopmentRegion = en;")
    out.append("\t\t\thasScannedForEncodings = 0;")
    out.append("\t\t\tknownRegions = (")
    out.append("\t\t\t\ten,")
    out.append("\t\t\t\tBase,")
    out.append("\t\t\t);")
    out.append("\t\t\tmainGroup = %s;" % main_group_id)
    out.append("\t\t\tproductRefGroup = %s /* Products */;" % products_group_id)
    out.append("\t\t\tprojectDirPath = \"\";")
    out.append("\t\t\tprojectRoot = \"\";")
    out.append("\t\t\ttargets = (")
    out.append("\t\t\t\t%s /* %s */," % (target_id, PROJECT_NAME))
    out.append("\t\t\t);")
    out.append("\t\t};")
    out.append("/* End PBXProject section */")

    # PBXResourcesBuildPhase
    out.append("")
    out.append("/* Begin PBXResourcesBuildPhase section */")
    out.append("\t\t%s /* Resources */ = {" % resources_phase_id)
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for rel in resources:
        out.append("\t\t\t\t%s /* %s in Resources */," % (build_files[rel], os.path.basename(rel)))
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXResourcesBuildPhase section */")

    # PBXSourcesBuildPhase
    out.append("")
    out.append("/* Begin PBXSourcesBuildPhase section */")
    out.append("\t\t%s /* Sources */ = {" % sources_phase_id)
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for rel in sources:
        out.append("\t\t\t\t%s /* %s in Sources */," % (build_files[rel], os.path.basename(rel)))
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXSourcesBuildPhase section */")

    # XCBuildConfiguration
    shared_project = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ANALYZER_NONNULL", "YES"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("GCC_C_LANGUAGE_STANDARD", "gnu11"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET),
        ("SDKROOT", "iphoneos"),
        # Left at the default (minimal) on purpose: the app is written for the
        # Swift 5 concurrency model, and turning on complete checking would
        # promote a pile of warnings to errors in a build nobody here can run
        # locally to triage.
        ("SWIFT_STRICT_CONCURRENCY", "minimal"),
        ("SWIFT_VERSION", SWIFT_VERSION),
    ]

    debug_project = shared_project + [
        ("DEBUG_INFORMATION_FORMAT", "dwarf"),
        ("ENABLE_TESTABILITY", "YES"),
        ("GCC_OPTIMIZATION_LEVEL", "0"),
        ("GCC_PREPROCESSOR_DEFINITIONS", "(\n\t\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t)"),
        ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
        ("ONLY_ACTIVE_ARCH", "YES"),
        ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
        ("SWIFT_OPTIMIZATION_LEVEL", "\"-Onone\""),
    ]

    release_project = shared_project + [
        ("DEBUG_INFORMATION_FORMAT", "\"dwarf-with-dsym\""),
        ("ENABLE_NS_ASSERTIONS", "NO"),
        ("GCC_OPTIMIZATION_LEVEL", "s"),
        ("MTL_ENABLE_DEBUG_INFO", "NO"),
        ("SWIFT_COMPILATION_MODE", "wholemodule"),
        ("SWIFT_OPTIMIZATION_LEVEL", "\"-O\""),
        ("VALIDATE_PRODUCT", "YES"),
    ]

    shared_target = [
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("ENABLE_PREVIEWS", "YES"),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("INFOPLIST_FILE", "%s/Info.plist" % PROJECT_NAME),
        ("LD_RUNPATH_SEARCH_PATHS",
         "(\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t)"),
        ("MARKETING_VERSION", "1.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID),
        ("PRODUCT_MODULE_NAME", MODULE_NAME),
        ("PRODUCT_NAME", "\"$(TARGET_NAME)\""),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("TARGETED_DEVICE_FAMILY", "\"1,2\""),
    ]

    configs = [
        (oid("config:project:Debug"), "Debug", debug_project),
        (oid("config:project:Release"), "Release", release_project),
        (oid("config:target:Debug"), "Debug", shared_target),
        (oid("config:target:Release"), "Release", shared_target),
    ]

    out.append("")
    out.append("/* Begin XCBuildConfiguration section */")
    for config_id, name, pairs in configs:
        out.append("\t\t%s /* %s */ = {" % (config_id, name))
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.append(settings_block(pairs))
        out.append("\t\t\t};")
        out.append("\t\t\tname = %s;" % name)
        out.append("\t\t};")
    out.append("/* End XCBuildConfiguration section */")

    out.append("")
    out.append("/* Begin XCConfigurationList section */")
    for list_id, label, debug_id, release_id in [
        (project_config_list_id, "PBXProject \\\"%s\\\"" % PROJECT_NAME,
         oid("config:project:Debug"), oid("config:project:Release")),
        (target_config_list_id, "PBXNativeTarget \\\"%s\\\"" % PROJECT_NAME,
         oid("config:target:Debug"), oid("config:target:Release")),
    ]:
        out.append("\t\t%s /* Build configuration list for %s */ = {" % (list_id, label))
        out.append("\t\t\tisa = XCConfigurationList;")
        out.append("\t\t\tbuildConfigurations = (")
        out.append("\t\t\t\t%s /* Debug */," % debug_id)
        out.append("\t\t\t\t%s /* Release */," % release_id)
        out.append("\t\t\t);")
        out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
        out.append("\t\t\tdefaultConfigurationName = Release;")
        out.append("\t\t};")
    out.append("/* End XCConfigurationList section */")

    out.append("\t};")
    out.append("\trootObject = %s /* Project object */;" % project_id)
    out.append("}")
    out.append("")

    return "\n".join(out), sources, resources


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{name}.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{name}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def main():
    check_only = "--check" in sys.argv
    content, sources, resources = generate()

    pbxproj_path = os.path.join(PROJECT_DIR, "project.pbxproj")
    scheme_dir = os.path.join(PROJECT_DIR, "xcshareddata", "xcschemes")
    scheme_path = os.path.join(scheme_dir, PROJECT_NAME + ".xcscheme")
    scheme = SCHEME.format(target_id=oid("target"), name=PROJECT_NAME)

    if check_only:
        problems = []
        if not os.path.exists(pbxproj_path):
            problems.append("project.pbxproj is missing")
        elif open(pbxproj_path).read() != content:
            problems.append("project.pbxproj is stale — run dispatch/tools/gen_pbxproj.py")
        if not os.path.exists(scheme_path):
            problems.append("shared scheme is missing")
        elif open(scheme_path).read() != scheme:
            problems.append("shared scheme is stale — run dispatch/tools/gen_pbxproj.py")

        # Both directions: every listed source exists, and every source on disk
        # is listed. The generator makes the second direction true by
        # construction, but asserting it catches a hand-edit.
        for rel in sources:
            if not os.path.exists(os.path.join(SOURCE_ROOT, rel)):
                problems.append("listed but missing on disk: %s" % rel)
        listed = set(sources)
        for dirpath, dirnames, filenames in os.walk(SOURCE_ROOT):
            dirnames[:] = [d for d in dirnames if not d.endswith(".xcassets")]
            for name in filenames:
                if name.endswith(".swift"):
                    rel = os.path.relpath(os.path.join(dirpath, name), SOURCE_ROOT)
                    if rel not in listed:
                        problems.append("on disk but not in the project: %s" % rel)

        if problems:
            for problem in problems:
                print("FAIL: " + problem)
            return 1
        print("project.pbxproj is current: %d sources, %d resources"
              % (len(sources), len(resources)))
        return 0

    os.makedirs(PROJECT_DIR, exist_ok=True)
    os.makedirs(scheme_dir, exist_ok=True)
    with open(pbxproj_path, "w") as handle:
        handle.write(content)
    with open(scheme_path, "w") as handle:
        handle.write(scheme)

    print("wrote %s" % os.path.relpath(pbxproj_path, REPO))
    print("  %d Swift sources, %d resources" % (len(sources), len(resources)))
    for rel in sources:
        print("    %s" % rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
