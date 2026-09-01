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
]

INTERESTING = (
    "spawn", "create", "instantiate", "init", "show", "hide", "close", "open",
    "select", "apply", "refresh", "rebuild", "bind", "fill", "clear", "toggle",
    "set_", "get_", "add", "updat",
)


def interesting(name):
    low = name.lower()
    return any(k in low for k in INTERESTING)


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


def method_rva(r, t, mi):
    """The method's RVA, by the SAME per-image methodPointers walk the name
    index and the sharedness histogram use -- so the three cannot disagree.
    None when the token's RID is out of range for its image, which is a real
    state (a method with no generated code) and not an error."""
    mp = r.MOD.get(r.image_of_type(t))
    if not mp or not mp[0]:
        return None
    base, cnt = mp
    rid = r.mtoken(mi) & 0xFFFFFF
    if not (1 <= rid <= cnt):
        return None
    va = r.rq(base + (rid - 1) * 8)
    return (va - r.IB) if va else None


def main():
    p = argparse.ArgumentParser(
        description="map the main-menu UI to Markdown + Nimony, with sharedness",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("gameasm")
    p.add_argument("metadec")
    p.add_argument("--only", default=None)
    p.add_argument("--max-methods", type=int, default=30)
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
          "refusal, not 'probably safe'.", ""]

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
            for mi in r.type_methods(t):
                try:
                    nm = r.mname(mi)
                except Exception:
                    continue
                if not interesting(nm):
                    continue
                try:
                    sig, pc = r.sig_string(mi, nm)
                except Exception:
                    sig, pc = nm, 0
                rva = method_rva(r, t, mi)
                if rva is None:
                    rows.append((nm, sig, None, "no-code", 0))
                    continue
                state, n = r.sharedness(rva)
                rows.append((nm, sig, rva, state, n))
                if len(rows) >= a.max_methods:
                    break
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
                md.append("| RVA | sharedness | signature |")
                md.append("|---|---|---|")
                for nm, sig, rva, state, n in rows:
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
                        nim.append("const %s* = 0x%x'u32   ## %s"
                                   % (nim_ident(full + "_" + nm), rva, sig))
                md.append("")
        md.append("")
        nim.append("")

    os.makedirs(os.path.dirname(a.out_md), exist_ok=True)
    open(a.out_md, "w", encoding="utf-8").write("\n".join(md))
    os.makedirs(os.path.dirname(a.out_nim), exist_ok=True)
    open(a.out_nim, "w", encoding="utf-8").write("\n".join(nim) + "\n")

    print("wrote %s and %s" % (a.out_md, a.out_nim))
    print("  %d type(s);  methods: %d unique (emitted), %d SHARED (withheld), "
          "%d unknown (withheld)" % (ntypes, nuniq, nshared, nunknown))
    if nshared or nunknown:
        print("  the withheld ones are listed in the Markdown with their state, "
              "so they are visible without being callable by accident.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
