#!/usr/bin/env python3
"""Assertions for the thread-structure logic.

Run: python3 tools/test_thread.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from thread_reference import (  # noqa: E402
    ThreadIndex, descendant_counts, visible, filtered, ancestors_of,
)

FAILURES = []
CHECKS = 0


def check(label, actual, expected):
    global CHECKS
    CHECKS += 1
    if actual != expected:
        FAILURES.append("%s\n     expected: %r\n     actual:   %r" % (label, expected, actual))


def quote(*nos):
    """Build a comment body quoting each post number, as 4chan would emit it."""
    return "".join(
        '<a href="#p%d" class="quotelink">&gt;&gt;%d</a> ' % (no, no) for no in nos
    )


def thread(*specs):
    """specs: (no, comment). The first entry is the OP."""
    posts = []
    for i, (no, com) in enumerate(specs):
        posts.append({"no": no, "resto": 0 if i == 0 else specs[0][0], "com": com})
    return ThreadIndex("pol", posts)


# --- Backlinks --------------------------------------------------------------

t = thread(
    (100, "opening post"),
    (101, quote(100) + "first reply"),
    (102, quote(100) + "second reply"),
    (103, quote(101) + "reply to the first"),
)
check("backlinks to the OP", t.replies_to(100), [101, 102])
check("backlinks to a reply", t.replies_to(101), [103])
check("no backlinks for an unreplied post", t.replies_to(103), [])

t2 = thread(
    (200, "op"),
    (201, quote(200, 999) + "quotes a deleted post too"),
)
check("a quote to a post outside the thread yields no backlink",
      t2.replies_to(999), [])
check("the surviving quote still registers", t2.replies_to(200), [201])

t3 = thread(
    (300, "op"),
    (301, quote(300, 300) + "quotes the same post twice"),
)
check("duplicate quotes produce one backlink", t3.replies_to(300), [301])


# --- Tree derivation --------------------------------------------------------

t = thread(
    (1, "op"),
    (2, quote(1) + "a"),
    (3, quote(2) + "b"),
    (4, quote(3) + "c"),
)
check("a quote chain nests", t.threaded_outline(), [(1, 0), (2, 1), (3, 2), (4, 3)])

t = thread(
    (1, "op"),
    (2, "no quotes"),
    (3, "also no quotes"),
)
check("posts quoting nothing hang off the OP",
      t.threaded_outline(), [(1, 0), (2, 1), (3, 1)])

t = thread(
    (1, "op"),
    (2, quote(1) + "a"),
    (3, quote(1) + "b"),
    (4, quote(2) + "c"),
    (5, quote(3) + "d"),
)
check("siblings stay in posting order",
      t.threaded_outline(), [(1, 0), (2, 1), (4, 2), (3, 1), (5, 2)])

t = thread(
    (1, "op"),
    (2, "a"),
    (3, quote(5, 2) + "quotes a later post first, then an earlier one"),
    (4, "b"),
    (5, "c"),
)
check("a forward quote is skipped in favour of the first earlier one",
      t.threaded_outline(), [(1, 0), (2, 1), (3, 2), (4, 1), (5, 1)])

# The cycle guard. Two posters quoting each other is ordinary on 4chan; a rule
# of "first quotelink is the parent" without the earlier-than test loops here.
t = thread(
    (1, "op"),
    (2, quote(3) + "quotes the reply that will quote it back"),
    (3, quote(2) + "quotes back"),
)
check("mutual quoting does not loop",
      t.threaded_outline(), [(1, 0), (2, 1), (3, 2)])

t = thread(
    (1, "op"),
    (2, quote(999) + "quotes a deleted post"),
)
check("a post quoting only a deleted post hangs off the OP",
      t.threaded_outline(), [(1, 0), (2, 1)])

check("every post appears exactly once in the outline",
      sorted(no for no, _ in t.threaded_outline()), [1, 2])

t = thread((1, "lonely op"))
check("a thread with no replies is just the OP", t.threaded_outline(), [(1, 0)])


# --- Descendant counts ------------------------------------------------------

chain = [(1, 0), (2, 1), (3, 2), (4, 3)]
check("descendant counts down a chain", descendant_counts(chain), [3, 2, 1, 0])

wide = [(1, 0), (2, 1), (3, 1), (4, 1)]
check("descendant counts across siblings", descendant_counts(wide), [3, 0, 0, 0])

mixed = [(1, 0), (2, 1), (3, 2), (4, 2), (5, 1), (6, 2), (7, 3)]
check("descendant counts on a mixed tree",
      descendant_counts(mixed), [6, 2, 0, 0, 2, 1, 0])

check("descendant counts of an empty outline", descendant_counts([]), [])
check("descendant counts of a single node", descendant_counts([(1, 0)]), [0])

# Depth can jump by more than one only if the outline is malformed, but the
# algorithm must not miscount if it does.
jumpy = [(1, 0), (2, 2), (3, 1)]
check("descendant counts tolerate a depth jump",
      descendant_counts(jumpy), [2, 0, 0])


# --- Collapse ---------------------------------------------------------------

check("collapsing a node hides its whole subtree",
      visible(mixed, {2}), [(1, 0), (2, 1), (5, 1), (6, 2), (7, 3)])

check("collapsing a leaf changes nothing",
      visible(mixed, {3}), mixed)

check("collapsing the root leaves only the root",
      visible(mixed, {1}), [(1, 0)])

check("collapsing two siblings hides both subtrees",
      visible(mixed, {2, 5}), [(1, 0), (2, 1), (5, 1)])

check("collapsing a node inside an already-hidden subtree is harmless",
      visible(mixed, {2, 3}), [(1, 0), (2, 1), (5, 1), (6, 2), (7, 3)])

check("no collapsed nodes returns the outline unchanged", visible(mixed, set()), mixed)


# --- Filtering --------------------------------------------------------------

check("filtering a post removes its replies too",
      filtered(mixed, lambda no: no != 2),
      [(1, 0), (5, 1), (6, 2), (7, 3)])

check("filtering a leaf removes only the leaf",
      filtered(mixed, lambda no: no != 7),
      [(1, 0), (2, 1), (3, 2), (4, 2), (5, 1), (6, 2)])

check("filtering everything yields nothing",
      filtered(mixed, lambda no: False), [])

check("filtering nothing yields the outline unchanged",
      filtered(mixed, lambda no: True), mixed)


# --- Flat outline -----------------------------------------------------------

t = thread((1, "op"), (2, quote(1) + "a"), (3, quote(2) + "b"))
check("the flat outline keeps posting order at depth zero",
      t.flat_outline(), [(1, 0), (2, 0), (3, 0)])
check("collapsing is a no-op on a flat outline",
      visible(t.flat_outline(), {1}), [(1, 0), (2, 0), (3, 0)])


# --- Parents and ancestors --------------------------------------------------

t = thread(
    (1, "op"),
    (2, quote(1) + "a"),
    (3, quote(2) + "b"),
    (4, quote(3) + "c"),
)
check("parent of a chain reply", t.parents[3], 2)
check("parent of a post quoting only the OP", t.parents[2], 1)
check("the OP has no parent", t.parents.get(1), None)
check("ancestors run nearest-first up to the OP", ancestors_of(t, 4), [3, 2, 1])
check("ancestors of a direct OP reply", ancestors_of(t, 2), [1])
check("ancestors of the OP is empty", ancestors_of(t, 1), [])

t = thread((1, "op"), (2, "no quotes"))
check("a post quoting nothing parents to the OP", t.parents[2], 1)

t = thread((1, "op"), (2, quote(999) + "quotes a deleted post"))
check("a post quoting a deleted post parents to the OP", t.parents[2], 1)

# The cycle guard again, from the parents angle: a mutual quote must not make
# ancestor-walking loop forever.
t = thread((1, "op"), (2, quote(3) + "x"), (3, quote(2) + "y"))
check("mutual quoting still terminates when walking ancestors",
      ancestors_of(t, 3), [2, 1])


# --- Report -----------------------------------------------------------------

if FAILURES:
    print("FAILED %d of %d checks\n" % (len(FAILURES), CHECKS))
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)

print("all %d thread-structure checks passed" % CHECKS)
