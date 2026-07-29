#!/usr/bin/env python3
"""Cheap local checks to run before pushing.

There is no Swift compiler in this environment, so every real compile is a CI
round trip of several minutes. These checks catch the class of mistake that is
embarrassing to spend a round trip on — an unbalanced brace, a leftover
placeholder, a source file missing from the project, a workflow whose YAML does
not parse.

They prove nothing about whether the code compiles. They only make it less
likely that a round trip is wasted.

Run: python3 tools/precheck.py
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


def strip_swift(source):
    """Remove comments and string literals so brackets inside them don't count.

    Handles // line comments, /* */ block comments (which nest in Swift),
    "..." strings with escapes, and \"\"\" multiline strings. String
    interpolation is treated as ordinary string content, which means brackets
    inside an interpolation are ignored — that under-counts rather than
    producing false positives, which is the right way to be wrong here.
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

        stripped = strip_swift(source)
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


def check_imports():
    """Every Swift file should import something; a file that imports nothing is
    usually one that was truncated mid-write."""
    for path in swift_files():
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        if "import " not in source:
            fail("%s: no import statement" % rel)
        if not source.endswith("\n"):
            fail("%s: no trailing newline" % rel)


def check_yaml():
    workflow_dir = os.path.join(REPO, ".github", "workflows")
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
        path = os.path.join(workflow_dir, name)
        try:
            with open(path) as handle:
                yaml.safe_load(handle)
        except Exception as error:  # noqa: BLE001
            fail(".github/workflows/%s: %s" % (name, error))


def check_assets():
    catalog = os.path.join(REPO, "ios", "PolReader", "Assets.xcassets")
    required = [
        os.path.join(catalog, "Contents.json"),
        os.path.join(catalog, "AppIcon.appiconset", "Contents.json"),
        os.path.join(catalog, "AppIcon.appiconset", "AppIcon.png"),
        os.path.join(catalog, "AccentColor.colorset", "Contents.json"),
        os.path.join(REPO, "ios", "PolReader", "Info.plist"),
    ]
    for path in required:
        if not os.path.exists(path):
            fail("missing required file: %s" % os.path.relpath(path, REPO))


def run(label, argv):
    result = subprocess.run(argv, cwd=REPO, capture_output=True, text=True)
    if result.returncode != 0:
        fail("%s failed:\n%s%s" % (label, result.stdout, result.stderr))
    else:
        print(result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "%s ok" % label)


def main():
    check_balance()
    check_placeholders()
    check_imports()
    check_yaml()
    check_assets()

    run("parser tests", [sys.executable, "tools/test_parser.py"])
    run("thread tests", [sys.executable, "tools/test_thread.py"])
    run("project check", [sys.executable, "tools/gen_pbxproj.py", "--check"])

    if problems:
        print("\n%d problem(s):" % len(problems))
        for problem in problems:
            print("  - " + problem)
        return 1

    count = sum(1 for _ in swift_files())
    print("\nprecheck passed (%d Swift files)" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
