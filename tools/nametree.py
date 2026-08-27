#!/usr/bin/env python3
"""Human-readable group names, and a tree with no level that is not a level.

The Python twin of `prettySegment` / `collapsedPaths` in
`aowl/src/aowlspt/settings.nim`. The nim side shapes what every MOD serves; this
side shapes the generated SPT config catalogue, which is baked into
`mods/settingshub/sptsurface.nim` and served verbatim rather than going through
`declareSettings`. Two implementations of one rule is a hazard, so the rule is
written out once here and once there in the same words, and neither is used to
verify the other -- `tools/settingsdump.py` checks the RENDERED payload.
"""


def pretty_segment(name):
    """`ArmorMaterials` -> `Armor Materials`, without `B T R Settings`.

    1. a name that already contains a space is returned verbatim
    2. `_`/`-` become a single space
    3. break before an upper following a lower or a digit
    4. break before a digit following a letter (`Level2` -> `Level 2`)
    5. break before the LAST upper of an upper-run when a lower follows it, so
       the run before it stays an acronym (`BTRSettings` -> `BTR Settings`)
    """
    if not name or " " in name:
        return name
    out = []
    for i, c in enumerate(name):
        if c in "_-":
            if out and out[-1] != " ":
                out.append(" ")
            continue
        if i > 0:
            p = name[i - 1]
            brk = False
            if c.isupper() and (p.islower() or p.isdigit()):
                brk = True
            elif c.isdigit() and (p.islower() or p.isupper()):
                brk = True
            elif (c.isupper() and p.isupper()
                  and i + 1 < len(name) and name[i + 1].islower()):
                brk = True
            if brk and out and out[-1] != " ":
                out.append(" ")
        out.append(c)
    return "".join(out).strip()


def _counts(paths):
    own, kids = {}, {}
    for q in paths:
        for i in range(1, len(q) + 1):
            k = tuple(q[:i])
            own.setdefault(k, 0)
            kids.setdefault(k, set())
            if i == len(q):
                own[k] += 1
            if i > 1:
                kids[tuple(q[:i - 1])].add(k)
    return own, kids


def collapse_paths(paths):
    """Every path with the levels that are not levels removed.

    A node with no settings of its own and exactly one child ABSORBS that child:
    one level, keeping the outer (human-written) name and dropping the inner
    (raw branch) one. Not iterated to a fixed point -- that would eat
    `Ballistics / ArmorMaterials` down to `Ballistics`.
    """
    own, kids = _counts(paths)
    out = []
    for q in paths:
        o, j = [], 0
        while j < len(q):
            o.append(q[j])
            k = tuple(q[:j + 1])
            j += 2 if (own[k] == 0 and len(kids[k]) == 1) else 1
        out.append(o)
    return out


def redundant_nodes(paths, min_depth=2):
    """Nodes at depth >= min_depth with zero own settings and exactly one child.

    The falsifiable negative: this must come back EMPTY.
    """
    own, kids = _counts(paths)
    return sorted(k for k in own
                  if len(k) >= min_depth and own[k] == 0 and len(kids[k]) == 1)
