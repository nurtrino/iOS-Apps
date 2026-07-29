#!/usr/bin/env python3
"""Cheap local checks to run before pushing.

Vela has no pure-logic test suite of its own — its behaviour is playback,
downloads and Keychain access, none of which can be exercised without a
device. So these checks lean harder on the things that *are* statically
verifiable, in particular the Info.plist keys: a missing background mode
does not fail the build, it just silently stops audio the moment the app
leaves the foreground.

There is no Swift compiler in this environment, so every real compile is a CI
round trip of several minutes. These checks catch the class of mistake that is
embarrassing to spend a round trip on — an unbalanced brace, a leftover
placeholder, a source file missing from the project, a workflow whose YAML does
not parse.

They prove nothing about whether the code compiles. They only make it less
likely that a round trip is wasted.

Run: python3 vela/tools/precheck.py
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

problems = []


def fail(message):
    problems.append(message)


def swift_files():
    root = os.path.join(REPO, "ios")
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)


def kotlin_files():
    """No Android port for this app yet."""
    return iter(())


def source_files():
    for path in swift_files():
        yield path, False
    for path in kotlin_files():
        yield path, True


def strip_source(source, char_literals=False):
    """Remove comments and literals so brackets inside them don't count.

    Handles // line comments, /* */ block comments (which nest in both
    languages), "..." strings with escapes, and \"\"\" multiline strings.
    String interpolation is treated as ordinary string content, so brackets
    inside an interpolation are ignored — that under-counts rather than
    producing false positives, which is the right way to be wrong here.

    `char_literals` handles Kotlin's '...' form. It matters more than it looks:
    without it, the perfectly ordinary char literal '"' opens a string that
    swallows the rest of the file and reports a phantom imbalance. Swift has no
    char literal, and stripping ' there would eat real code, so it is opt-in.
    """
    out = []
    i = 0
    n = len(source)
    block_depth = 0

    while i < n:
        c = source[i]

        if block_depth > 0:
            if source.startswith("/*", i):
                block_depth += 1
                i += 2
                continue
            if source.startswith("*/", i):
                block_depth -= 1
                i += 2
                continue
            i += 1
            continue

        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
            continue

        if source.startswith("/*", i):
            block_depth = 1
            i += 2
            continue

        if source.startswith('"""', i):
            end = source.find('"""', i + 3)
            i = n if end < 0 else end + 3
            continue

        if c == '"':
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    break
                if source[i] == "\n":
                    break
                i += 1
            continue

        if char_literals and c == "'":
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == "'":
                    i += 1
                    break
                if source[i] == "\n":
                    break
                i += 1
            continue

        out.append(c)
        i += 1

    return "".join(out)


def check_balance():
    pairs = {")": "(", "]": "[", "}": "{"}
    openers = set("([{")

    for path, char_literals in source_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            source = handle.read()

        stripped = strip_source(source, char_literals=char_literals)
        stack = []
        for c in stripped:
            if c in openers:
                stack.append(c)
            elif c in pairs:
                if not stack:
                    fail("%s: unbalanced '%s' with nothing open" % (rel, c))
                    break
                if stack[-1] != pairs[c]:
                    fail("%s: '%s' closes '%s'" % (rel, c, stack[-1]))
                    break
                stack.pop()
        else:
            if stack:
                fail("%s: %d unclosed %s" % (rel, len(stack), "".join(stack)))


def check_placeholders():
    markers = ["<#", "#>", "FIXME:", "XXX:"]
    for path, _ in source_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                for marker in markers:
                    if marker in line:
                        fail("%s:%d: leftover placeholder %r" % (rel, number, marker))


def check_declarations():
    """Catch files truncated mid-write."""
    for path, _ in source_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        if "import " not in source:
            fail("%s: no import statement" % rel)
        if not source.endswith("\n"):
            fail("%s: no trailing newline" % rel)


def check_yaml():
    workflow_dir = os.path.join(os.path.dirname(REPO), ".github", "workflows")
    if not os.path.isdir(workflow_dir):
        return
    try:
        import yaml
    except ImportError:
        print("note: PyYAML not installed, skipping workflow parse")
        return
    for name in sorted(os.listdir(workflow_dir)):
        if not name.endswith((".yml", ".yaml")):
            continue
        try:
            with open(os.path.join(workflow_dir, name)) as handle:
                yaml.safe_load(handle)
        except Exception as error:  # noqa: BLE001
            fail(".github/workflows/%s: %s" % (name, error))


def check_info_plist():
    """The capabilities that fail silently rather than loudly.

    Background audio, Picture in Picture and saving to Photos are all gated on
    Info.plist entries. Omit one and the build still succeeds, the code still
    runs, and the feature simply never works — which is exactly the class of
    mistake worth catching without a device.
    """
    path = os.path.join(REPO, "ios", "Vela", "Info.plist")
    if not os.path.exists(path):
        fail("Info.plist is missing")
        return

    import plistlib
    try:
        with open(path, "rb") as handle:
            plist = plistlib.load(handle)
    except Exception as error:  # noqa: BLE001
        fail("Info.plist does not parse: %s" % error)
        return

    modes = plist.get("UIBackgroundModes") or []
    if "audio" not in modes:
        fail("Info.plist: UIBackgroundModes must contain 'audio' — "
             "background playback and PiP both depend on it")

    if not plist.get("NSPhotoLibraryAddUsageDescription"):
        fail("Info.plist: NSPhotoLibraryAddUsageDescription missing — "
             "saving to Photos crashes without it")

    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if not plist.get(key):
            fail("Info.plist: %s missing" % key)


def check_assets():
    catalog = os.path.join(REPO, "ios", "Vela", "Assets.xcassets")
    required = [
        os.path.join(catalog, "Contents.json"),
        os.path.join(catalog, "AppIcon.appiconset", "Contents.json"),
        os.path.join(catalog, "AppIcon.appiconset", "AppIcon.png"),
        os.path.join(catalog, "AccentColor.colorset", "Contents.json"),
    ]
    for item in required:
        if not os.path.exists(item):
            fail("missing required file: %s" % os.path.relpath(item, REPO))


def run(label, argv):
    result = subprocess.run(argv, cwd=REPO, capture_output=True, text=True)
    if result.returncode != 0:
        fail("%s failed:\n%s%s" % (label, result.stdout, result.stderr))
    else:
        print(result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "%s ok" % label)


def main():
    check_balance()
    check_placeholders()
    check_declarations()
    check_yaml()
    check_info_plist()
    check_assets()

    run("project check", [sys.executable, "tools/gen_pbxproj.py", "--check"])

    if problems:
        print("\n%d problem(s):" % len(problems))
        for problem in problems:
            print("  - " + problem)
        return 1

    print("\nprecheck passed (%d Swift files)" % sum(1 for _ in swift_files()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
