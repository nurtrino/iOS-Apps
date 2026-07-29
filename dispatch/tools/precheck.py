#!/usr/bin/env python3
"""Cheap local checks to run before pushing.

There is no Swift compiler in this environment, so every real compile is a CI
round trip of several minutes. These checks catch the class of mistake that is
embarrassing to spend a round trip on — an unbalanced brace, a trailing comma in
a call, a source file missing from the project, an API that does not exist on
the deployment target, a workflow whose YAML does not parse.

They prove nothing about whether the code compiles. They only make it less
likely that a round trip is wasted. The parsing layer, which is where the real
bugs are, is covered properly by `test_feeds.py` — run from here so one command
does everything.

Run: python3 dispatch/tools/precheck.py
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

DEPLOYMENT_TARGET = "16.0"

problems = []


def fail(message):
    problems.append(message)


def swift_files():
    root = os.path.join(REPO, "ios")
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)


def strip_source(source):
    """Remove comments and literals so brackets inside them don't count.

    Handles // line comments, /* */ block comments (which nest in Swift),
    "..." strings with escapes, and \"\"\" multiline strings. String
    interpolation is treated as ordinary string content, so brackets inside an
    interpolation are ignored — that under-counts rather than producing false
    positives, which is the right way to be wrong here.

    Two properties the callers depend on:

    **A string becomes `_`, not nothing.** Deleting it turns
    `("b", "<strong>", "</strong>")` into `(, , )`, which reads as a trailing
    comma that is not there. A placeholder keeps the structure intact.

    **Newlines survive.** Every line of the output corresponds to the same line
    of the input, so a problem can be reported at a line number that means
    something. A block comment spanning ten lines has to leave ten newlines
    behind or every later report is off by ten.
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
            if c == "\n":
                out.append("\n")
            i += 1
            continue

        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
            continue

        if source.startswith('"""', i):
            end = source.find('"""', i + 3)
            body_end = n if end < 0 else end + 3
            out.append("_")
            out.append("\n" * source.count("\n", i, body_end))
            i = body_end
            continue

        if source.startswith("/*", i):
            block_depth = 1
            i += 2
            continue

        if c == '"':
            out.append("_")
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

        out.append(c)
        i += 1

    return "".join(out)


def check_balance():
    pairs = {")": "(", "]": "[", "}": "{"}
    openers = set("([{")

    for path in swift_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            stripped = strip_source(handle.read())

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


def check_trailing_commas():
    """Swift 5 rejects a trailing comma in a call or tuple.

    Array and dictionary literals allow one, so only `,` immediately before a
    closing parenthesis is an error. It is an easy mistake to make when a call
    is spread over several lines and an argument is deleted from the end, and
    the compiler error it produces is a full CI round trip away.
    """
    for path in swift_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            lines = strip_source(handle.read()).splitlines()

        for number, line in enumerate(lines, 1):
            body = line.rstrip()

            # On one line: `foo(a, b, )`.
            if re.search(r",\s*\)", body):
                fail("%s:%d: trailing comma before ')' — not allowed in Swift 5" % (rel, number))
                continue

            # Across lines: an argument ending in a comma, then the closing
            # parenthesis. `strip_source` preserves line numbering, so the
            # report points at the offending comma rather than near it.
            if not body.endswith(","):
                continue
            for following in lines[number:]:
                if not following.strip():
                    continue
                if following.lstrip().startswith(")"):
                    fail("%s:%d: trailing comma before ')' — not allowed in Swift 5"
                         % (rel, number))
                break


def check_deployment_target_apis():
    """Symbols that do not exist on the deployment target.

    Every one of these compiles fine against a recent SDK and fails only when
    the minimum version is applied, so they are easy to reach for and expensive
    to discover.
    """
    banned = {
        "@Observable": "iOS 17",
        "ContentUnavailableView": "iOS 17",
        ".scrollTargetBehavior": "iOS 17",
        ".scrollPosition(": "iOS 17",
        ".symbolEffect(": "iOS 17",
        "@Previewable": "iOS 17",
        ".containerRelativeFrame(": "iOS 17",
        "MeshGradient": "iOS 18",
        ".onScrollGeometryChange": "iOS 18",
    }
    for path in swift_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            source = strip_source(handle.read())
        for symbol, version in banned.items():
            if symbol in source:
                fail("%s: uses %s, which needs %s (deployment target is %s)"
                     % (rel, symbol, version, DEPLOYMENT_TARGET))


def check_placeholders():
    markers = ["<#", "#>", "FIXME:", "XXX:"]
    for path in swift_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                for marker in markers:
                    if marker in line:
                        fail("%s:%d: leftover placeholder %r" % (rel, number, marker))


def check_declarations():
    """Catch files truncated mid-write."""
    for path in swift_files():
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

    Background refresh is gated on two Info.plist keys *and* on the identifier
    matching the one the code registers. Get any of the three wrong and the
    build still succeeds, the code still runs, and the refresh simply never
    happens — which is exactly the class of mistake worth catching without a
    device.
    """
    path = os.path.join(REPO, "ios", "Dispatch", "Info.plist")
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

    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                "CFBundleDisplayName"):
        if not plist.get(key):
            fail("Info.plist: %s missing" % key)

    modes = plist.get("UIBackgroundModes") or []
    if "fetch" not in modes:
        fail("Info.plist: UIBackgroundModes must contain 'fetch' — the scheduled "
             "refresh is dropped without it")

    permitted = plist.get("BGTaskSchedulerPermittedIdentifiers") or []
    if not permitted:
        fail("Info.plist: BGTaskSchedulerPermittedIdentifiers is empty — iOS refuses "
             "to schedule an identifier that is not listed")

    # The identifier in the plist and the one in the code have to be the same
    # string. Nothing checks this at build time and a mismatch is invisible.
    source_path = os.path.join(REPO, "ios", "Dispatch", "Data", "BackgroundRefresh.swift")
    if os.path.exists(source_path):
        with open(source_path, encoding="utf-8") as handle:
            source = handle.read()
        match = re.search(r'identifier\s*=\s*"([^"]+)"', source)
        if not match:
            fail("BackgroundRefresh.swift: no background task identifier found")
        elif match.group(1) not in permitted:
            fail("BackgroundRefresh.swift registers %r, which is not in "
                 "BGTaskSchedulerPermittedIdentifiers %r" % (match.group(1), permitted))


def check_assets():
    catalog = os.path.join(REPO, "ios", "Dispatch", "Assets.xcassets")
    required = [
        os.path.join(catalog, "Contents.json"),
        os.path.join(catalog, "AppIcon.appiconset", "Contents.json"),
        os.path.join(catalog, "AppIcon.appiconset", "AppIcon.png"),
        os.path.join(catalog, "AccentColor.colorset", "Contents.json"),
    ]
    for item in required:
        if not os.path.exists(item):
            fail("missing required file: %s" % os.path.relpath(item, REPO))


def check_catalog_ids():
    """Source and section ids have to be unique.

    They key the on-disk feed caches and the read-state entries, so a duplicate
    means two sources quietly overwriting each other's articles.
    """
    path = os.path.join(REPO, "ios", "Dispatch", "Model", "Source.swift")
    if not os.path.exists(path):
        fail("Model/Source.swift is missing")
        return
    with open(path, encoding="utf-8") as handle:
        source = handle.read()

    ids = re.findall(r'\n\s+id:\s*"([^"]+)"', source)
    duplicates = {value for value in ids if ids.count(value) > 1}
    if duplicates:
        fail("Source.swift: duplicate catalog ids %s" % sorted(duplicates))


def run(label, argv):
    result = subprocess.run(argv, cwd=REPO, capture_output=True, text=True)
    if result.returncode != 0:
        fail("%s failed:\n%s%s" % (label, result.stdout, result.stderr))
    else:
        print(result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "%s ok" % label)


def main():
    check_balance()
    check_trailing_commas()
    check_deployment_target_apis()
    check_placeholders()
    check_declarations()
    check_yaml()
    check_info_plist()
    check_assets()
    check_catalog_ids()

    run("parser tests", [sys.executable, "tools/test_feeds.py"])
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
