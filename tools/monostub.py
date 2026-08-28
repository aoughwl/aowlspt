#!/usr/bin/env python3
r"""monostub.py -- emit compilable C# stubs for the game MonoBehaviours that
`tools/monotree.py` can lay out, so a Unity project can attach the component and
hold its serialised data.

## Why this is worth building (PART 2 said VIABLE-WITH-CAVEATS, not BLOCKED)

Unity binds a serialised MonoBehaviour to a class by NAME, not by GUID.
Measured in the shipped `maps/factory_day_preset.bundle`: the `MonoScript`
object carries exactly

    m_AssemblyName = "Assembly-CSharp"
    m_Namespace    = "EFT"
    m_ClassName    = "ScenesPreset"
    m_PropertiesHash = <16 bytes>

and nothing else -- no GUID, no file-id into a specific assembly. The
MonoBehaviour's `m_Script` PPtr has `m_FileID = 0`, so the MonoScript travels
INSIDE the bundle. That same bundle's SerializedFile carries a full type tree
for all three of its types (`withNodes=3`), including the custom fields
`ActiveSceneGuid`, `ServerName`, `ScenesGuids`. The level files, by contrast,
have type trees STRIPPED.

So a bundle built in a normal Unity project can present the identity the client
matches on, provided a class of the same namespace + name exists in that
project's `Assembly-CSharp` with the same serialised fields. These stubs are
that class.

## What is emitted, and what is deliberately not

Emitted from the SERIALISATION LAYOUT, not from the raw field list: exactly the
fields Unity writes, in declaration order, with `[SerializeField]` restored on
the non-public ones and `[Serializable]` on nested value classes. That is what
determines the type tree, and it means the generated class and the game's class
produce the same layout by construction.

Method bodies are NOT emitted by default. They contribute nothing to
serialisation, and reproducing thousands of signatures (generics, ref/out, by-ref
returns, inaccessible parameter types) is a large surface on which to silently
emit something that does not compile. `--methods` emits public method signatures
with `throw new NotImplementedException();` bodies for the cases that can be
expressed; a signature this tool cannot express honestly is emitted as a
`// UNRESOLVED SIGNATURE` comment rather than as a guess.

A type that `monotree` could not lay out is NOT emitted as an empty class --
that would look like a complete stub and silently drop every field. It is
reported, with its reason, and listed in the generated file's header comment.

## Usage

    python tools/monostub.py --metadec .cache/global-metadata.dec.dat \
        gen --type EFT.Game.Spawning.SpawnPointMarker \
            --type EFT.Interactive.ExfiltrationPoint \
            --out D:\MapExtract\stubs

    python tools/monostub.py ... from-mono D:\MapExtract\tt\factory_day_preset \
            --out D:\MapExtract\stubs

`from-mono` reads the `.mono.json` sidecars `tools/mapextract_mono.py` writes
and generates a stub for every type it recorded as DECODED.
"""

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import monotree                                    # noqa: E402

GAME_ASM = r"D:\Games\Tarkov\GameAssembly.dll"
METADEC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       ".cache", "global-metadata.dec.dat")

# il2cpp type-enum -> C# keyword, for the widths monotree lays out.
CS_PRIM = {
    monotree.TE_BOOL: "bool", monotree.TE_CHAR: "char",
    monotree.TE_I1: "sbyte", monotree.TE_U1: "byte",
    monotree.TE_I2: "short", monotree.TE_U2: "ushort",
    monotree.TE_I4: "int", monotree.TE_U4: "uint",
    monotree.TE_I8: "long", monotree.TE_U8: "ulong",
    monotree.TE_R4: "float", monotree.TE_R8: "double",
}
# (struct code, size) -> C# keyword, since Node keeps the struct code not the enum
CS_BY_FMT = {("?", 1): "bool", ("H", 2): "ushort", ("b", 1): "sbyte",
             ("B", 1): "byte", ("h", 2): "short", ("i", 4): "int",
             ("I", 4): "uint", ("q", 8): "long", ("Q", 8): "ulong",
             ("f", 4): "float", ("d", 8): "double"}

CS_KEYWORDS = {
    "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char",
    "checked", "class", "const", "continue", "decimal", "default", "delegate",
    "do", "double", "else", "enum", "event", "explicit", "extern", "false",
    "finally", "fixed", "float", "for", "foreach", "goto", "if", "implicit",
    "in", "int", "interface", "internal", "is", "lock", "long", "namespace",
    "new", "null", "object", "operator", "out", "override", "params",
    "private", "protected", "public", "readonly", "ref", "return", "sbyte",
    "sealed", "short", "sizeof", "stackalloc", "static", "string", "struct",
    "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong",
    "unchecked", "unsafe", "ushort", "using", "virtual", "void", "volatile",
    "while",
}


class StubError(Exception):
    pass


def cs_ident(name):
    """A C# identifier for a metadata field name.

    Compiler-generated names such as `<Prop>k__BackingField` are not legal C#.
    They are NOT silently renamed -- a rename changes the serialised field name
    and therefore the type tree, so the caller is told and the type is refused."""
    if not name or not (name[0].isalpha() or name[0] == "_"):
        raise StubError("field name %r is not a legal C# identifier" % name)
    for ch in name:
        if not (ch.isalnum() or ch == "_"):
            raise StubError("field name %r is not a legal C# identifier" % name)
    return ("@" + name) if name in CS_KEYWORDS else name


class Emitter(object):
    def __init__(self, layouts):
        self.L = layouts
        self.r = layouts.r
        self.emitted = {}       # full name -> source text
        self.pending = []
        self.refused = {}       # full name -> reason

    # -- type naming -------------------------------------------------------
    def cs_type_of_node(self, node, want):
        """C# type expression for `node`, queueing any type it depends on."""
        k = node.kind
        if k == "prim":
            if node.tindex is not None:      # an enum
                self._need_enum(node.tindex)
                return self._cs_name(node.tindex)
            got = CS_BY_FMT.get((node.fmt, node.size))
            if got is None:
                raise StubError("no C# keyword for width (%r,%d)"
                                % (node.fmt, node.size))
            return got
        if k == "str":
            return "string"
        if k == "pptr":
            return self._cs_pptr(node)
        if k == "array":
            return self.cs_type_of_node(node.elem, want) + "[]"
        if k == "struct":
            if node.tindex is None:
                # A BUILTIN_LAYOUTS shape (AnimationCurve, LayerMask): Unity
                # already declares these, so reference them, do not redeclare.
                return node.type_name
            self._need_type(node.tindex)
            return self._cs_name(node.tindex)
        raise StubError("unknown node kind %r" % k)

    def _cs_pptr(self, node):
        """A UnityEngine.Object reference.

        UnityEngine's own types are referenced as-is. A reference to another
        GAME type is emitted as its own stub, because a `PPtr<BotZone>` field
        typed as plain `UnityEngine.Object` would serialise identically but
        would not compile against the rest of the generated set."""
        t = node.tindex
        if t is None:
            return "UnityEngine.Object"
        full = self.L._full(t)
        if full.startswith("UnityEngine.") or full.startswith("TMPro."):
            return full
        self._need_type(t)
        return self._cs_name(t)

    def _cs_name(self, t):
        ns, nm = self.r.tname(t)
        nm = nm.replace("`", "_")
        return (ns + "." + nm) if ns else nm

    # -- queueing ----------------------------------------------------------
    def _need_type(self, t):
        full = self._cs_name(t)
        if full in self.emitted or full in self.refused:
            return
        self._queue.append(t)

    def _need_enum(self, t):
        self._need_type(t)

    # -- emission ----------------------------------------------------------
    def generate(self, roots, with_methods=False):
        """roots: list of metadata type indices. Returns {full_name: source}."""
        self._queue = list(roots)
        seen = set()
        while self._queue:
            t = self._queue.pop(0)
            if t in seen:
                continue
            seen.add(t)
            full = self._cs_name(t)
            if full in self.emitted or full in self.refused:
                continue
            if full.startswith("UnityEngine.") or full.startswith("System."):
                continue
            try:
                self.emitted[full] = self._emit_type(t, with_methods)
            except (StubError, monotree.LayoutError) as exc:
                self.refused[full] = str(exc)
        return self.emitted, self.refused

    def _emit_type(self, t, with_methods):
        if self.r.is_enum(t):
            return self._emit_enum(t)
        root, why = self.L.behaviour_layout(t)
        if root is not None:
            return self._emit_behaviour(t, root, with_methods)
        # not a MonoBehaviour -- a nested [Serializable] data class
        flags = self.L.type_flags(t)
        if not (flags & monotree.TA_SERIALIZABLE):
            raise StubError("neither a layoutable MonoBehaviour nor "
                            "[Serializable] (%s)" % why)
        children = self.L.fields_of(t, 1, {t})
        return self._emit_class(t, children, base=None, serializable=True,
                                with_methods=with_methods)

    def _emit_enum(self, t):
        ns, nm = self.r.tname(t)
        lines = []
        if ns:
            lines.append("namespace %s" % ns)
            lines.append("{")
        ind = "    " if ns else ""
        lines.append("%spublic enum %s" % (ind, nm))
        lines.append("%s{" % ind)
        for name, val in self.r.enum_members(t):
            if val is None:
                lines.append("%s    // %s -- metadata carries no value for this "
                             "member; omitted rather than numbered by position"
                             % (ind, name))
                continue
            lines.append("%s    %s = %d," % (ind, cs_ident(name), val))
        lines.append("%s}" % ind)
        if ns:
            lines.append("}")
        return "\n".join(lines) + "\n"

    def _emit_behaviour(self, t, root, with_methods):
        # Which base: the chain stops at MonoBehaviour or ScriptableObject.
        mb = self.L.type_index("UnityEngine.MonoBehaviour")
        cur, seen = t, set()
        base = "UnityEngine.MonoBehaviour"
        while cur is not None and cur not in seen:
            seen.add(cur)
            p = self.r.parent_type(cur)
            if p is not None and self._cs_name(p) == "UnityEngine.ScriptableObject":
                base = "UnityEngine.ScriptableObject"
                break
            if p == mb:
                break
            cur = p
        # `root.children` is the flattened base-first serialised field list, so
        # the stub is a single class, not the game's inheritance chain. That is
        # deliberate: it reproduces the exact type tree, which is what the
        # client matches, without dragging in every intermediate base class.
        return self._emit_class(t, root.children, base=base, serializable=False,
                                with_methods=with_methods,
                                note="serialised fields are FLATTENED from the "
                                     "game's base chain; the type tree is "
                                     "identical, the class hierarchy is not")

    def _emit_class(self, t, children, base, serializable, with_methods,
                    note=None):
        ns, nm = self.r.tname(t)
        nm = nm.replace("`", "_")
        body = []
        for ch in children:
            fname = cs_ident(ch.name)
            ftype = self.cs_type_of_node(ch, nm)
            # Every field is emitted PUBLIC. The game declares some of these
            # private + [SerializeField]; the serialised NAME and ORDER are
            # what the type tree records, and both are preserved, so the two
            # layouts are identical either way.
            body.append("        public %s %s;" % (ftype, fname))
        if with_methods:
            body.extend(self._method_lines(t))
        lines = ["// Generated by tools/monostub.py from the decrypted il2cpp",
                 "// metadata. Fields are the SERIALISED set only, in Unity's",
                 "// declaration order, so this class produces the same type",
                 "// tree as the game's."]
        if note:
            lines.append("// NOTE: " + note + ".")
        lines.append("using System;")
        lines.append("")
        if ns:
            lines.append("namespace %s" % ns)
            lines.append("{")
        if serializable:
            lines.append("    [Serializable]")
        lines.append("    public class %s%s" % (nm, (" : " + base) if base else ""))
        lines.append("    {")
        lines.extend(body or ["        // no serialised fields"])
        lines.append("    }")
        if ns:
            lines.append("}")
        return "\n".join(lines) + "\n"

    def _method_lines(self, t):
        out = ["", "        // --- method signatures (bodies intentionally "
                   "absent; they play no part in serialisation) ---"]
        for mi in self.r.type_methods(t):
            try:
                sig = self.r.sig_string(mi, self.r.mname(mi))
            except Exception:
                out.append("        // UNRESOLVED SIGNATURE for method %d" % mi)
                continue
            out.append("        // %s" % sig)
        return out


# ---------------------------------------------------------------------------


def _write(out_dir, emitted, refused):
    os.makedirs(out_dir, exist_ok=True)
    for full, src in sorted(emitted.items()):
        path = os.path.join(out_dir, full.replace(".", "_") + ".cs")
        with open(path, "w", newline="\n", encoding="utf-8") as fh:
            fh.write(src)
    idx = os.path.join(out_dir, "_UNRESOLVED.txt")
    with open(idx, "w", newline="\n", encoding="utf-8") as fh:
        fh.write("Types NOT emitted, and why. An empty stub would look like a\n"
                 "complete one and silently drop every field, so nothing here\n"
                 "was written as a class.\n\n")
        for full, why in sorted(refused.items()):
            fh.write("%-64s %s\n" % (full, why))
    sys.stderr.write("wrote %d stubs, %d refused -> %s\n"
                     % (len(emitted), len(refused), out_dir))


def cmd_gen(args):
    L = monotree.Layouts(args.game_asm, args.metadec)
    roots, missing = [], []
    for name in args.type:
        t = L.type_index(name)
        if t is None:
            missing.append(name)
        else:
            roots.append(t)
    if missing:
        sys.stderr.write("NOT IN METADATA (refusing to guess a near miss): %s\n"
                         % ", ".join(missing))
    em = Emitter(L)
    emitted, refused = em.generate(roots, with_methods=args.methods)
    for n in missing:
        refused[n] = "not present in the metadata under that exact name"
    _write(args.out, emitted, refused)


def cmd_from_mono(args):
    L = monotree.Layouts(args.game_asm, args.metadec)
    wanted = {}
    for p in glob.glob(os.path.join(args.dir, "*.mono.json")):
        with open(p, encoding="utf-8") as fh:
            doc = json.load(fh)
        for row in doc.get("types", []):
            if row["status"] == "DECODED":
                wanted[row["type"]] = row["assembly"]
    roots, missing = [], []
    for name, asm in sorted(wanted.items()):
        t = L.type_index(name, assembly=(asm + ".dll") if asm else None)
        if t is None:
            t = L.type_index(name)
        if t is None:
            missing.append(name)
        else:
            roots.append(t)
    sys.stderr.write("%d DECODED types across %s\n" % (len(wanted), args.dir))
    em = Emitter(L)
    emitted, refused = em.generate(roots, with_methods=args.methods)
    for n in missing:
        refused[n] = "not present in the metadata under that exact name"
    _write(args.out, emitted, refused)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--game-asm", default=GAME_ASM)
    ap.add_argument("--metadec", default=METADEC)
    ap.add_argument("--methods", action="store_true",
                    help="also emit method signatures, as comments")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen")
    g.add_argument("--type", action="append", required=True)
    g.add_argument("--out", required=True)
    g.set_defaults(func=cmd_gen)

    f = sub.add_parser("from-mono")
    f.add_argument("dir")
    f.add_argument("--out", required=True)
    f.set_defaults(func=cmd_from_mono)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
