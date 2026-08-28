#!/usr/bin/env python3
"""Cheap local checks to run before pushing.

There is no Swift compiler in this environment, so every real compile is a CI
round trip of several minutes. These checks catch the class of mistake that is
embarrassing to spend a round trip on — an unbalanced brace, a leftover
placeholder, a source file missing from the project, a workflow whose YAML does
not parse.

Macro's own silent-failure surface is notifications: a BGTaskScheduler
identifier missing from the plist does not fail the build, it just means iOS
refuses every schedule request and the app never fetches in the background.
So the plist checks here assert the exact plumbing the notification path
depends on, including that the identifier in Swift and the identifier in the
plist are the same string.

They prove nothing about whether the code compiles. They only make it less
likely that a round trip is wasted.

Run: python3 macro/tools/precheck.py
"""

import os
import re
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


def strip_source(source):
    """Remove comments and literals so brackets inside them don't count.

    Handles // line comments, /* */ block comments (which nest), "..." strings
    with escapes, and \"\"\" multiline strings. String interpolation is treated
    as ordinary string content, so brackets inside an interpolation are
    ignored — that under-counts rather than producing false positives, which is
    the right way to be wrong here.
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

        out.append(c)
        i += 1

    return "".join(out)


def check_balance():
    pairs = {")": "(", "]": "[", "}": "{"}
    openers = set("([{")

    for path in swift_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            source = handle.read()

        stripped = strip_source(source)
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

    Background fetch and the task identifier are both gated on Info.plist
    entries. Omit one and the build still succeeds, the code still runs, and
    the background path simply never fires — which is exactly the class of
    mistake worth catching without a device.
    """
    path = os.path.join(REPO, "ios", "Macro", "Info.plist")
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
    if "fetch" not in modes:
        fail("Info.plist: UIBackgroundModes must contain 'fetch' — "
             "background refresh and headline alerts both depend on it")

    identifiers = plist.get("BGTaskSchedulerPermittedIdentifiers") or []
    if not identifiers:
        fail("Info.plist: BGTaskSchedulerPermittedIdentifiers missing — "
             "iOS silently refuses to schedule undeclared task ids")

    # The Swift constant and the plist entry must be the same string, or the
    # scheduler rejects every request without an error anyone sees.
    swift_path = os.path.join(REPO, "ios", "Macro", "Notify", "BackgroundRefresh.swift")
    if os.path.exists(swift_path):
        with open(swift_path, encoding="utf-8") as handle:
            source = handle.read()
        match = re.search(r'static let identifier = "([^"]+)"', source)
        if not match:
            fail("BackgroundRefresh.swift: cannot find the task identifier constant")
        elif match.group(1) not in identifiers:
            fail("task id mismatch: Swift uses %r, Info.plist permits %r"
                 % (match.group(1), identifiers))
    else:
        fail("Notify/BackgroundRefresh.swift is missing")

    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if not plist.get(key):
            fail("Info.plist: %s missing" % key)


def check_feed_catalog():
    """Every shipped feed address must at least be a well-formed https URL.

    A typo here does not fail anything at build time — the source just shows
    as quiet forever.
    """
    path = os.path.join(REPO, "ios", "Macro", "Model", "FeedSource.swift")
    if not os.path.exists(path):
        fail("Model/FeedSource.swift is missing")
        return
    with open(path, encoding="utf-8") as handle:
        source = handle.read()

    urls = re.findall(r'"(https?://[^"]+)"', source)
    if len(urls) < 10:
        fail("FeedSource.swift: only %d feed URLs found — catalog looks truncated" % len(urls))
    for url in urls:
        if not url.startswith("https://"):
            fail("FeedSource.swift: %s is not https — ATS would block it" % url)
        if " " in url:
            fail("FeedSource.swift: %s contains a space" % url)


def check_assets():
    catalog = os.path.join(REPO, "ios", "Macro", "Assets.xcassets")
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
    check_feed_catalog()
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
