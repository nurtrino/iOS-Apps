#!/usr/bin/env python3
"""Reference implementation of the ISO 8601 duration parser, plus its tests.

YouTube reports `contentDetails.duration` as an ISO 8601 period — `PT4M13S`.
The API documentation describes the format as `PT#M#S`, but that understates
it: hour-long videos carry an `H` component, and the rare multi-day livestream
archive carries a `D`. A parser that only knows about minutes and seconds
silently returns 0 for those, which shows up as a video with no length rather
than as an error anybody would notice.

Proving it here first, in a language with a REPL, then transliterating to
Swift. Every case below is a real shape the API emits.

Run: python3 vela/tools/duration_reference.py
"""

CHECKS = []


def check(actual, expected, label):
    CHECKS.append((actual == expected, label, actual, expected))


def parse_duration(text):
    """ISO 8601 period -> seconds. Returns None for anything unparseable.

    Deliberately strict about structure and lenient about which components are
    present: `P`, then an optional date part, then an optional `T` and a time
    part. YouTube only ever emits days and below, so years and months are
    rejected rather than guessed at — a "month" has no fixed length, and
    inventing 30 days would put a silent lie in the UI.
    """
    if not text or text[0] != "P":
        return None

    total = 0
    number = ""
    in_time = False
    seen_any = False

    for char in text[1:]:
        if char == "T":
            # A second T, or a T with a number dangling before it, is malformed.
            if in_time or number:
                return None
            in_time = True
            continue

        if char.isdigit():
            number += char
            continue

        if not number:
            return None

        value = int(number)
        number = ""
        seen_any = True

        if in_time:
            if char == "H":
                total += value * 3600
            elif char == "M":
                total += value * 60
            elif char == "S":
                total += value
            else:
                return None
        else:
            if char == "D":
                total += value * 86400
            elif char == "W":
                total += value * 604800
            else:
                # Y and M in the date position have no fixed length.
                return None

    # A trailing number with no unit ("PT4M13") is malformed.
    if number:
        return None
    return total if seen_any else None


def format_duration(seconds):
    """Seconds -> the label shown on a thumbnail.

    Hours only appear when there are hours, and minutes are not zero-padded in
    that case only when there is no hour component — matching what every video
    UI does, so 9:05 rather than 09:05 but 1:09:05 rather than 1:9:05.
    """
    if seconds is None or seconds < 0:
        return ""
    hours, remainder = divmod(int(seconds), 3600)
    minutes, secs = divmod(remainder, 60)
    if hours > 0:
        return "%d:%02d:%02d" % (hours, minutes, secs)
    return "%d:%02d" % (minutes, secs)


def main():
    # The ordinary cases, straight from the API.
    check(parse_duration("PT4M13S"), 253, "minutes and seconds")
    check(parse_duration("PT1H2M3S"), 3723, "hours, minutes, seconds")
    check(parse_duration("PT59S"), 59, "seconds only — a short")
    check(parse_duration("PT2M"), 120, "whole minutes")
    check(parse_duration("PT1H"), 3600, "whole hours")
    check(parse_duration("PT10H30M"), 37800, "hours and minutes, no seconds")

    # Live and upcoming videos report a zero duration rather than omitting it.
    check(parse_duration("P0D"), 0, "zero-day period, as live streams report")
    check(parse_duration("PT0S"), 0, "zero seconds")

    # Multi-day archives.
    check(parse_duration("P1DT2H3M4S"), 93784, "days through seconds")
    check(parse_duration("P1W"), 604800, "one week")

    # Malformed input must be distinguishable from a genuine zero, which is why
    # this returns None rather than 0.
    check(parse_duration(""), None, "empty string")
    check(parse_duration(None), None, "nil")
    check(parse_duration("4M13S"), None, "missing leading P")
    check(parse_duration("PT4M13"), None, "trailing number with no unit")
    check(parse_duration("PT"), None, "P and T with no components")
    check(parse_duration("P"), None, "P alone")
    check(parse_duration("PTM"), None, "unit with no number")
    check(parse_duration("PT4X"), None, "unknown unit")
    check(parse_duration("PT1H2T3S"), None, "second T")
    check(parse_duration("P1Y"), None, "years rejected, not guessed")
    check(parse_duration("P1M"), None, "months in the date position rejected")

    # P1M is a month and PT1M is a minute. Getting this wrong is the classic
    # ISO 8601 bug, so it is pinned explicitly.
    check(parse_duration("PT1M"), 60, "PT1M is one minute")

    # Formatting.
    check(format_duration(253), "4:13", "format minutes and seconds")
    check(format_duration(3723), "1:02:03", "format with hours")
    check(format_duration(59), "0:59", "format under a minute")
    check(format_duration(545), "9:05", "format pads seconds, not minutes")
    check(format_duration(3600), "1:00:00", "format exactly an hour")
    check(format_duration(0), "0:00", "format zero")
    check(format_duration(None), "", "format nil")

    failures = [c for c in CHECKS if not c[0]]
    for _, label, actual, expected in failures:
        print("FAIL: %s\n  got      %r\n  expected %r" % (label, actual, expected))
    print("%d/%d checks passed" % (len(CHECKS) - len(failures), len(CHECKS)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
