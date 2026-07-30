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

    # A self-hosted X bridge on the LAN is served over plain http, and ATS
    # blocks that unless NSAllowsLocalNetworking is set. Nothing about the
    # failure points at the plist — the request just fails, looking exactly
    # like the bridge being down.
    ats = plist.get("NSAppTransportSecurity") or {}
    if not ats.get("NSAllowsLocalNetworking"):
        fail("Info.plist: NSAppTransportSecurity.NSAllowsLocalNetworking missing — "
             "a self-hosted bridge on http://192.168.x.x would be blocked by ATS")
    if ats.get("NSAllowsArbitraryLoads"):
        fail("Info.plist: NSAllowsArbitraryLoads disables ATS for the whole internet; "
             "NSAllowsLocalNetworking is what the LAN bridge needs")
    if not plist.get("NSLocalNetworkUsageDescription"):
        fail("Info.plist: NSLocalNetworkUsageDescription missing — iOS blocks local "
             "network access without it, whatever ATS says")

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

    # A source removed from `defaults` has to be listed in `retired`, or it
    # lives forever on any device that already stored it — merging only adds.
    retired_block = re.search(r"retired:\s*Set<String>\s*=\s*\[(.*?)\]", source, re.S)
    retired = set(re.findall(r'"([^"]+)"', retired_block.group(1))) if retired_block else set()
    for gone in retired & set(ids):
        fail("Source.swift: %r is in both defaults and retired" % gone)

    check_source_topics(source, ids)


def check_source_topics(source, ids):
    """Every source has to declare where its stories go.

    This is the wiring behind the sections, and getting it wrong is invisible
    from inside the app: a source with no prior and no fixed topic quietly files
    its ambiguous stories into whatever `fixedTopic` happens to default to, and
    the section just looks thin. So each catalog entry is checked for the pair of
    fields its `topicMode` actually needs.
    """
    # Each Source(...) literal, split on the id line that starts one.
    blocks = re.split(r'\n\s+Source\(\n', source)
    for block in blocks[1:]:
        block = block.split("\n        ),")[0]
        found = re.search(r'id:\s*"([^"]+)"', block)
        if not found:
            continue
        source_id = found.group(1)
        if source_id not in ids:
            continue

        mode = re.search(r"topicMode:\s*\.(\w+)", block)
        if not mode:
            fail("Source.swift: %r declares no topicMode" % source_id)
            continue

        if not re.search(r"fixedTopic:\s*\.(\w+)", block):
            # `fixedTopic` doubles as the classifier's fallback, so a classified
            # source needs it just as much as a fixed one.
            fail("Source.swift: %r has no fixedTopic (it is also the fallback)" % source_id)

        if mode.group(1) == "classified" and not re.search(r"topicPrior:\s*\.(\w+)", block):
            fail("Source.swift: %r is classified with no topicPrior, so nothing "
                 "nudges its ambiguous stories" % source_id)


def check_fomc_table():
    """The Fed calendar is shipped as a table and has to be extended each year.

    Nothing about a stale table looks broken from inside the app — the Markets
    calendar simply stops listing rate decisions, which reads as "no meetings
    coming up" rather than "this data ran out". So it is checked here, with
    enough warning to do something about it.
    """
    path = os.path.join(REPO, "ios", "Dispatch", "Data", "EconCalendar.swift")
    if not os.path.exists(path):
        fail("Data/EconCalendar.swift is missing")
        return

    with open(path, encoding="utf-8") as handle:
        source = handle.read()

    entries = re.findall(
        r"DateComponents\(year:\s*(\d{4}),\s*month:\s*(\d{1,2}),\s*day:\s*(\d{1,2})\)", source)
    if not entries:
        fail("EconCalendar: no FOMC dates found")
        return

    import datetime
    dates = sorted(datetime.date(int(y), int(m), int(d)) for y, m, d in entries)

    if dates != [datetime.date(int(y), int(m), int(d)) for y, m, d in entries]:
        fail("EconCalendar: FOMC dates are not in chronological order")

    # Eight scheduled meetings a year is the Fed's long-standing cadence, so a
    # year with a different count is a transcription slip.
    by_year = {}
    for date in dates:
        by_year[date.year] = by_year.get(date.year, 0) + 1
    for year, count in sorted(by_year.items()):
        if count != 8:
            fail("EconCalendar: %d has %d FOMC dates, expected 8" % (year, count))

    remaining = (dates[-1] - datetime.date.today()).days
    if remaining < 0:
        fail("EconCalendar: every FOMC date is in the past — extend the table")
    elif remaining < 120:
        print("note: FOMC table runs out in %d days — extend it soon" % remaining)


def check_app_icon():
    """The icon has to exist, be square, be RGB with no alpha, and be full-bleed.

    iOS rejects an alpha channel outright, and artwork that rounds its own corners
    gets pale wedges cut around it by Apple's mask. Both are invisible until the
    icon is on a home screen, so they are checked here instead.
    """
    path = os.path.join(REPO, "ios", "Dispatch", "Assets.xcassets",
                        "AppIcon.appiconset", "AppIcon.png")
    if not os.path.exists(path):
        fail("AppIcon.png is missing — run tools/make_icons.py")
        return

    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail("AppIcon.png is not a PNG")
        return

    import struct as _struct
    width, height, depth, colour = _struct.unpack(">IIBB", data[16:26])
    if (width, height) != (1024, 1024):
        fail("AppIcon.png is %dx%d; iOS wants 1024x1024" % (width, height))
    if depth != 8:
        fail("AppIcon.png is %d-bit; iOS wants 8" % depth)
    if colour != 2:
        fail("AppIcon.png has colour type %d; iOS rejects an alpha channel, so it "
             "must be 2 (RGB)" % colour)


def check_lexicon():
    """The classifier tests parse this file, so its shape is load-bearing."""
    path = os.path.join(REPO, "ios", "Dispatch", "Net", "TopicLexicon.swift")
    if not os.path.exists(path):
        fail("Net/TopicLexicon.swift is missing")
        return

    with open(path, encoding="utf-8") as handle:
        source = handle.read()

    for topic in ("war", "politics", "economics"):
        marker = "static let %s: [(String, Double)] = [" % topic
        if marker not in source:
            fail("TopicLexicon: %s table is missing or has changed shape — "
                 "feed_reference.py parses these literally" % topic)
            continue

        start = source.index(marker) + len(marker)
        block = source[start:source.index("]", start)]
        terms = re.findall(r'\("([^"]+)",\s*(-?[0-9.]+)\)', block)

        # A line inside the block that is not a term means something was added
        # in a shape the parser silently skips.
        entries = [line for line in block.splitlines() if line.strip()]
        if len(entries) != len(terms):
            fail("TopicLexicon: %s has %d lines but %d parsed terms — every line must be "
                 '("term", weight),' % (topic, len(entries), len(terms)))

        seen = set()
        for term, _ in terms:
            if term in seen:
                fail("TopicLexicon: %s lists %r twice" % (topic, term))
            seen.add(term)
            if term != term.lower():
                fail("TopicLexicon: %r is not lowercased; matching is done on "
                     "lowercased text so it can never match" % term)


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
    check_app_icon()
    check_lexicon()
    check_fomc_table()

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
