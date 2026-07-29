"""Reference implementation of the thread-structure logic.

Mirrors ios/PolReader/Thread/ThreadIndex.swift. See comment_parser_reference.py
for why these algorithms live in Python as well as Swift.

4chan threads are flat: the JSON is an array in posting order and replies exist
only as >>123 quotelinks inside the comment bodies. So there is no tree to
flatten on arrival — there is a backlink index to build, and optionally a tree
to derive.
"""

from comment_parser_reference import extract_quoted_posts


class ThreadIndex:
    def __init__(self, board, posts):
        """`posts` is a list of dicts with at least `no`, `resto`, and `com`."""
        self.board = board
        self.posts = posts
        self.offsets = {p["no"]: i for i, p in enumerate(posts)}

        self.quotes = {}
        self.backlinks = {}
        for p in posts:
            quoted = extract_quoted_posts(p.get("com"))
            if not quoted:
                continue
            self.quotes[p["no"]] = quoted
            for target in quoted:
                # A quote pointing outside this thread means the target was
                # deleted. Nothing to hang a backlink on.
                if target not in self.offsets:
                    continue
                self.backlinks.setdefault(target, []).append(p["no"])

        # Parent per post, derived once here rather than inside the outline, so
        # the threaded view can ask "who is this a reply to?" without rebuilding
        # the tree. See threaded_outline for why "earlier" is load-bearing.
        self.parents = {}
        op = self.op
        if op is not None:
            for index, p in enumerate(posts):
                if p["no"] == op["no"]:
                    continue
                parent = op["no"]
                for candidate in self.quotes.get(p["no"], []):
                    candidate_offset = self.offsets.get(candidate)
                    if candidate_offset is not None and candidate_offset < index:
                        parent = candidate
                        break
                self.parents[p["no"]] = parent

    @property
    def op(self):
        for p in self.posts:
            if p.get("resto", 0) == 0:
                return p
        return self.posts[0] if self.posts else None

    def replies_to(self, no):
        return self.backlinks.get(no, [])

    def threaded_outline(self):
        """Depth-tagged array in reading order.

        A post's parent is the first post it quotes that appears *earlier* in
        the thread. Requiring "earlier" is what makes cycles impossible: 4chan
        does not stop two posters from quoting each other, and a naive
        "first quotelink is the parent" rule builds an infinite loop out of it.
        """
        op = self.op
        if op is None:
            return []

        children = {}
        for p in self.posts:
            if p["no"] == op["no"]:
                continue
            children.setdefault(self.parents[p["no"]], []).append(p["no"])

        outline = []
        stack = [(op["no"], 0)]
        visited = set()
        while stack:
            no, depth = stack.pop()
            if no in visited:
                continue
            visited.add(no)
            outline.append((no, depth))
            for child in reversed(children.get(no, [])):
                stack.append((child, depth + 1))

        for p in self.posts:
            if p["no"] not in visited:
                outline.append((p["no"], 1))
        return outline

    def flat_outline(self):
        return [(p["no"], 0) for p in self.posts]


def descendant_counts(nodes):
    """Descendants under each node, positionally aligned with `nodes`."""
    counts = [0] * len(nodes)
    ancestors = []
    for i in range(len(nodes)):
        while ancestors and nodes[ancestors[-1]][1] >= nodes[i][1]:
            ancestors.pop()
        for a in ancestors:
            counts[a] += 1
        ancestors.append(i)
    return counts


def visible(nodes, collapsed):
    """Drop the subtree under every collapsed node."""
    if not collapsed:
        return list(nodes)
    out = []
    i = 0
    while i < len(nodes):
        no, depth = nodes[i]
        out.append((no, depth))
        i += 1
        if no in collapsed:
            while i < len(nodes) and nodes[i][1] > depth:
                i += 1
    return out


def filtered(nodes, keep):
    """Remove nodes failing `keep`, along with everything beneath them."""
    out = []
    i = 0
    while i < len(nodes):
        no, depth = nodes[i]
        if keep(no):
            out.append((no, depth))
            i += 1
        else:
            i += 1
            while i < len(nodes) and nodes[i][1] > depth:
                i += 1
    return out


def ancestors_of(index, no):
    """Every post above `no` in the derived tree, nearest first."""
    out = []
    seen = set()
    current = index.parents.get(no)
    while current is not None and current not in seen:
        seen.add(current)
        out.append(current)
        current = index.parents.get(current)
    return out
