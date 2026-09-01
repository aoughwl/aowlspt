#!/usr/bin/env python3
r"""gen_uimap.py -- map Tarkov's main-menu UI, offline, with the safety baked in.

    python tools/gen_uimap.py GAMEASM METADEC
    python tools/gen_uimap.py GAMEASM METADEC --only EFT.Settings.

Emits `docs/UI-MAP.md` and `aowl/src/aowlspt/uimap.nim`.

## Why generate, and why NOT generate everything

Every UI feature in this repo has begun the same way: resolve a type, find its
fields, work out which method to call, check the RVA is not shared. That is
identical work, it is offline, and it is what a machine should do once. It is
also the reason mods CLONE live widgets and relabel them -- counterfeiting a
control was what was available before the prefab types and their spawners were
mapped.

But this deliberately does NOT wrap all 31,282 types and 208,632 methods, and
the reason is not size:

  * **28.3% of by-name lookups on this build land on a SHARED RVA.** A uniform
    binding makes a shared address look exactly like a unique one, and
    detouring a shared one fires for every method that shares it. Sharedness
    has to travel WITH each symbol or the binding is a trap.
  * **Resolving is harmless; calling is what kills the client.** A frame shape
    inferred from a method NAME faulted on this very build. So every signature
    here is DERIVED from metadata (returnType@8, parameterStart@16,
    parameterCount@34), never from the name.
  * **Instantiated generic layouts are not reachable offline** -- all 33,464
    Il2CppGenericClass entries have a null cached_class in the file. Those are
    emitted as GENERIC. `0x0` would be a fabricated offset that reads the
    object header.

So: resolve broadly (that is `aowlspt-names.idx`, 373,616 entries with share
counts), expose narrowly, and only where the safety data comes with it.

## What this does not claim

It reports what the BINARY DECLARES. Nothing is verified against a running
client: a pointer walk still has to be proven live. This removes the lookup, not
the proof.
"""

from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import il2cpp_resolve as ir   # noqa: E402

GROUPS = [
    ("settings-controllers", "EFT.Settings."),
    ("settings-core",        "Bsg.GameSettings"),
    ("spawnable-prefabs",    "UISpawnable"),
    # Added after docs/NATIVE-CONTROLS.md 7: the map was last generated with
    # `--only EFT.Settings.`, so it contained NONE of the widget types a mod
    # author actually instantiates (SettingControl, SettingToggle,
    # SettingFloatSlider, SettingSelectSlider, SettingDropDown) and no
    # spawner at all.
    ("settings-widgets",     "EFT.UI.Settings."),
    ("settings-toggles",     "EFT.UI.Toggle"),
    ("ui-spawners",          "UISpawner"),
]

# There used to be an INTERESTING name filter here. It was deleted, not
# widened: it silently hid `BindTo` -- the one method the whole native-control
# construction path needs -- and a method list filtered by NAME is exactly the
# "inferred from the name" habit the rest of this tool refuses. Every declared
# method is now listed, and TRUNCATION (--max-methods) is ANNOUNCED in the
# Markdown rather than being an invisible `break`.


def nim_ident(full):
    out = []
    up = True
    for ch in full:
        if ch.isalnum():
            out.append(ch.upper() if up else ch)
            up = False
        else:
            up = True
    s = "".join(out)
    return s[0].upper() + s[1:] if s else "X"


# The per-image methodPointers walk now lives in ONE place, il2cpp_resolve, so
# this file, the `typemethods` verb and the sharedness histogram cannot drift
# apart. (Indexing one image's table with another image's token is a
# documented past bug.)
method_rva = ir.method_rva_of


def resolve_nim_idents(nim):
    """Turn ("CONST", ident, rva, sig) placeholders into `const` lines with
    UNIQUE identifiers.

    C# overloads share a method name, so `Type_Method` is not a key. A
    collision is never resolved by dropping one or by letting the last write
    win -- both mean an agent asks for `BindTo` and gets an address whose
    frame shape is a DIFFERENT method's. Every member of an overload set is
    renamed (arity suffix, then an index if arity does not separate them) and
    the set is announced in a comment above it.
    """
    counts = {}
    for e in nim:
        if isinstance(e, tuple):
            counts[e[1]] = counts.get(e[1], 0) + 1
    seen, out = {}, []
    for e in nim:
        if not isinstance(e, tuple):
            out.append(e)
            continue
        _, ident, rva, sig, pc = e
        if counts[ident] > 1:
            # arity is the METADATA parameterCount@34, not a comma count in a
            # rendered signature string.
            cand = "%sArity%d" % (ident, pc)
            n = seen.get(cand, 0)
            seen[cand] = n + 1
            if n:
                cand = "%s_%d" % (cand, n + 1)
            out.append("# OVERLOAD SET: %d methods are named %s; each gets a "
                       "distinct ident, none is 'the' one." % (counts[ident],
                                                               ident))
            ident = cand
        out.append("const %s* = 0x%x'u32   ## %s" % (ident, rva, sig))
    return out


def main():
    p = argparse.ArgumentParser(
        description="map the main-menu UI to Markdown + Nimony, with sharedness",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("gameasm")
    p.add_argument("metadec")
    p.add_argument("--only", default=None)
    p.add_argument("--max-methods", type=int, default=200)
    p.add_argument("--out-md", default=os.path.join(REPO, "docs", "UI-MAP.md"))
    p.add_argument("--out-nim", default=os.path.join(
        REPO, "aowl", "src", "aowlspt", "uimap.nim"))
    a = p.parse_args()

    r = ir.Resolver(a.gameasm, a.metadec)

    # THE SELF-CHECK, before one offset is trusted. System.String's layout is
    # independently known; if this build does not reproduce it the fieldOffsets
    # base is wrong and every number below is wrong the SAME way -- silently.
    got = {}
    for t, full in r.find("System.String"):
        if full == "System.String":
            for f in r.declared_fields(t):
                got[f[0]] = f[1]
            break
    if got.get("_stringLength") != 0x10 or got.get("_firstChar") != 0x14:
        print("SELF-CHECK FAILED: System.String._stringLength@0x10 / "
              "_firstChar@0x14 did not reproduce (got %r). REFUSING to emit a "
              "map -- every offset would be wrong the same way." % got)
        return 2
    print("self-check ok: System.String._stringLength@0x10 _firstChar@0x14")

    # SECOND self-check: the base-class walk. It silently answered "no base
    # class" for every type whose base is a generic instance (and for the
    # 11,571 whose base is the 0x1c OBJECT intrinsic), which is what made
    # `UIAnimatedToggleSpawner <- UISpawner`1<AnimatedToggle>` invisible.
    pok, prows = ir.self_check_parents(r)
    for tyname, anc, verdict in prows:
        print("   parent-chain %s <- %s : %s" % (tyname, anc, verdict))
    if not pok:
        print("PARENT-CHAIN SELF-CHECK FAILED -- refusing to emit a map; every "
              "inheritance claim below would be wrong the same way.")
        return 2

    print("building the shared-RVA histogram over all methods...")
    r.shared_rva_counts()

    groups = [g for g in GROUPS if (a.only is None or g[1] == a.only)]
    md = ["# Tarkov main-menu UI map", "",
          "Generated by `tools/gen_uimap.py` from `GameAssembly.dll` + the "
          "decrypted global-metadata. This is what the BINARY DECLARES; "
          "nothing here is verified against a running client, so a pointer "
          "walk still has to be proven live.", "",
          "**Offsets are three-state**: a real offset, `--` for a const with no "
          "storage, `GENERIC` for an uninstantiated generic definition (IL2CPP "
          "writes an all-zero fieldOffsets array for those, so `0x0` would be a "
          "fabricated offset that reads the object header).", "",
          "**Every method carries its sharedness.** 28.3% of by-name lookups on "
          "this build land on an RVA with more than one owner, and detouring "
          "one of those fires for every method sharing it. `unknown` means the "
          "address is not in the methodPointers histogram at all -- that is a "
          "refusal, not 'probably safe'.", "",
          "A method with RVA `-` and sharedness `no-code` is a GENERIC "
          "DEFINITION: its bodies are one per INSTANTIATION, in "
          "`genericMethodPointers`. `-` is not 'no such method' and it is "
          "certainly not address 0 -- ask "
          "`il2cpp_resolve.py GAMEASM METADEC genericmethods <Type>::<Name>`.",
          ""]

    nim = ["## uimap.nim -- GENERATED by tools/gen_uimap.py. Do not hand-edit.",
           "##",
           "## Field offsets and method RVAs for Tarkov's main-menu UI, read",
           "## from metadata offline. This removes the LOOKUP, not the proof:",
           "## a pointer must still be shown live before it is walked.",
           "##",
           "## ONLY `unique` RVAs are emitted as callable constants. A `shared`",
           "## RVA is correct to CALL but catastrophic to DETOUR (it fires for",
           "## every method sharing it), and an `unknown` one is not in the",
           "## methodPointers histogram at all -- both are listed in",
           "## docs/UI-MAP.md and deliberately withheld here, so a constant in",
           "## this file is never the dangerous kind.",
           ""]

    ntypes = nuniq = nshared = nunknown = 0
    for label, prefix in groups:
        md.append("## %s (`%s`)\n" % (label, prefix))
        nim.append("# ---- %s ----" % label)
        for t, full in sorted(r.find(prefix), key=lambda x: x[1]):
            try:
                flds = list(r.declared_fields_ex(t))
            except Exception:
                flds = []
            rows = []
            declared = r.type_methods(t)
            truncated = 0
            for mi in declared:
                try:
                    nm = r.mname(mi)
                except Exception:
                    continue
                if len(rows) >= a.max_methods:
                    truncated = len(declared) - len(rows)
                    break
                try:
                    sig, pc = r.sig_string(mi, nm)
                except Exception:
                    sig, pc = nm, -1
                rva = method_rva(r, t, mi)
                if rva is None:
                    rows.append((nm, sig, pc, None, "no-code", 0))
                    continue
                state, n = r.sharedness(rva)
                rows.append((nm, sig, pc, rva, state, n))
            if not flds and not rows:
                continue
            ntypes += 1
            md.append("### `%s`\n" % full)
            if flds:
                md.append("| offset | field | type |")
                md.append("|---|---|---|")
                for f in flds[:40]:
                    name = f["name"]
                    off = f["off"]
                    ftype = f["typename"]
                    # THREE-STATE, and each state is a different fact:
                    #   no storage  -> a C# const, inlined at every use site;
                    #                  its fieldOffsets entry reads 0x0 and is
                    #                  MEANINGLESS, not "offset zero".
                    #   layout None -> an uninstantiated generic definition;
                    #                  IL2CPP writes an all-zero array for it.
                    #   otherwise   -> a real offset.
                    if not f["has_storage"]:
                        show = "--"
                    elif off is None or f.get("layout") is None:
                        show = "GENERIC"
                    else:
                        show = "0x%x" % off
                    md.append("| `%s` | `%s` | %s%s |"
                              % (show, name, ftype,
                                 " *(static)*" if f["static"] else ""))
                md.append("")
            if rows:
                md.append("%d method(s) declared." % len(declared))
                md.append("")
                md.append("| RVA | sharedness | signature |")
                md.append("|---|---|---|")
                for nm, sig, pc, rva, state, n in rows:
                    if state == "unique":
                        nuniq += 1
                    elif state == "shared":
                        nshared += 1
                    elif state == "unknown":
                        nunknown += 1
                    md.append("| %s | %s | `%s` |" % (
                        ("0x%x" % rva) if rva is not None else "-",
                        state if state != "shared" else "**shared x%d**" % n,
                        sig))
                    if state == "unique" and rva is not None:
                        # A PLACEHOLDER, not the final line: OVERLOADS collide
                        # on this identifier (14 of them did on this build --
                        # `SettingFloatSlider.BindTo` alone has two, at
                        # 0x16fb4c0 and 0x16fb810). Emitting both as the same
                        # `const` is a duplicate definition AND, if it were
                        # ever accepted, a silent pick of one overload's
                        # address for a call frame of the other. Names are
                        # made unique in one pass at the end.
                        nim.append(("CONST", nim_ident(full + "_" + nm),
                                    rva, sig, pc))
                if truncated:
                    # An invisible `break` reads as "that is all there is".
                    md.append("")
                    md.append("**TRUNCATED: %d further declared method(s) are "
                              "NOT listed** (--max-methods=%d). This is not a "
                              "statement that they do not exist."
                              % (truncated, a.max_methods))
                md.append("")
        md.append("")
        nim.append("")

    nim = resolve_nim_idents(nim)

    # Line endings are pinned EXPLICITLY. Both generated files are tracked and
    # `.gitattributes` says `* -text`, so whatever this writes is what is
    # committed; leaving it to the platform default would make a regeneration
    # on a non-Windows box a 700-line whole-file diff against the CRLF copy
    # already in the tree.
    os.makedirs(os.path.dirname(a.out_md), exist_ok=True)
    with open(a.out_md, "w", encoding="utf-8", newline="\r\n") as fh:
        fh.write("\n".join(md))
    os.makedirs(os.path.dirname(a.out_nim), exist_ok=True)
    with open(a.out_nim, "w", encoding="utf-8", newline="\r\n") as fh:
        fh.write("\n".join(nim) + "\n")

    print("wrote %s and %s" % (a.out_md, a.out_nim))
    print("  %d type(s);  methods: %d unique (emitted), %d SHARED (withheld), "
          "%d unknown (withheld)" % (ntypes, nuniq, nshared, nunknown))
    if nshared or nunknown:
        print("  the withheld ones are listed in the Markdown with their state, "
              "so they are visible without being callable by accident.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
