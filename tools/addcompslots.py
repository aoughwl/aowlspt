#!/usr/bin/env python3
"""addcompslots.py -- find the game's OWN cached `MethodInfo*` .data slots for
`UnityEngine.GameObject::AddComponent<T>()`, offline, from GameAssembly.dll.

WHY THIS EXISTS
===============
`AddComponent<T>()` is SHARED generic code: one compiled body at 0x2A9AE90
serves every T, and the T is carried entirely by the hidden trailing
`MethodInfo*`. So attaching a component needs a real per-T `MethodInfo*`.

We must not synthesise one, and we cannot ask reflection for one (the export
surface is token-gated: a gated export returns a uniform random non-zero
uint64, which passes a nil check and kills the client on first dereference).

But the game already computed every `MethodInfo*` it needs. IL2CPP never embeds
one as an immediate -- it emits a load from a per-token `.data` slot that a
metadata initialiser fills the first time the owning method runs:

    mov rcx, [rip+X]        ; the GameObject (or whatever)
    mov rdx, [rip+Y]        ; <- Y is the MethodInfo* slot for THIS T
    call AddComponent<T>

So the whole job is: find every call site of 0x2A9AE90, and recover the RDX
slot RVA from the RIP-relative load that feeds it. That is what this script
does. The `RectTransform` slot 0x6E19580 that the invoke2 ladder hardcoded was
found by hand this exact way, inside
`TMPro.TMP_DefaultControls::CreateUIElementRoot`; this reproduces it and every
other one, so adding a new component type is a DATA change, not another
reverse-engineering session.

WHAT THIS SCRIPT CAN AND CANNOT ESTABLISH
=========================================
It establishes, exactly:
  * the set of `.data` slot RVAs that are used as the `MethodInfo*` for
    `AddComponent<T>`, and
  * for each one, the ENCLOSING METHOD (resolved from the per-image
    methodPointers tables, the same ground truth every other RVA in this repo
    comes from) and the call-site RVA.

It does NOT establish WHICH T a slot is for. The slot is a runtime pointer; its
generic argument is only knowable once the metadata initialiser has filled it.
The enclosing method name is strong CIRCUMSTANTIAL evidence (a method called
`CreateUIElementRoot` that makes exactly one AddComponent call is very probably
adding a RectTransform) and it is deliberately reported as evidence, not as an
answer.

The ATTRIBUTION IS SETTLED AT RUNTIME, not here. `abi/aowlspt_nativeui.h`
refuses to trust a slot until the component it produced has an object-header
klass identical to that of a LIVE, independently walked instance of the same
type. A slot attributed to the wrong T therefore fails closed and is disabled,
rather than silently attaching the wrong component. See `AowlNuSlot` there.

That split is the point: this script narrows the candidates from "all of .data"
to a handful with provenance, and the host proves the last step against the
finished state.

USAGE
=====
  python tools/addcompslots.py <GameAssembly.dll> <global-metadata.dec.dat> \
        [--target 0x2A9AE90] [--window 64] [--max 0]

  --target  the shared generic body to find call sites of. Defaults to
            AddComponent<T>. Any generic method works.
  --window  how far back from the call to look for the RDX load (bytes).
  --max     stop after N call sites (0 = no limit).

Output is one line per call site, plus a grouped summary by slot, plus a
C-table stub ready to paste into `abi/aowlspt_nativeui.h`.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from il2cpp_resolve import Resolver  # noqa: E402

# `mov rdx, [rip+disp32]`  -- REX.W + 8B /r with modrm 0x15 (rdx, RIP-relative)
MOV_RDX_RIP = b"\x48\x8b\x15"
# `mov rcx, [rip+disp32]`  -- the receiver load, reported as corroboration
MOV_RCX_RIP = b"\x48\x8b\x0d"

ADDCOMPONENT_GENERIC_RVA = 0x2A9AE90

# The largest plausible distance from a method's first byte to a call inside
# its body. Beyond this the "nearest preceding start" rule is not attributing,
# it is guessing; see SlotScan.enclosing.
MAX_GAP = 0x8000


class SlotScan(object):
    def __init__(self, resolver):
        self.R = resolver
        self._method_index = None

    # ---- section helpers ------------------------------------------------

    def section(self, name):
        for nm, vaddr, vsize, rawptr, rawsize in self.R.SEC:
            if nm == name:
                return (vaddr, vsize, rawptr, rawsize)
        return None

    def data_ranges(self):
        """Every writable data section, as (lo_rva, hi_rva). A recovered slot
        that does not land in one of these is reported and DISCARDED: a
        `MethodInfo*` cache slot is by construction in initialised data, so a
        hit in code means the backward scan latched onto an unrelated `mov`."""
        out = []
        for nm, vaddr, vsize, rawptr, rawsize in self.R.SEC:
            if nm in (".data", ".rdata", "il2cppd"):
                out.append((nm, vaddr, vaddr + vsize))
        return out

    def in_data(self, rva):
        for nm, lo, hi in self.data_ranges():
            if lo <= rva < hi:
                return nm
        return None

    # ---- enclosing-method attribution -----------------------------------

    def method_index(self):
        """Sorted [(rva, "Full.Type::method")] over every method in every
        image, built from the SAME per-image methodPointers walk that
        `shared_rva_counts` uses -- so an attribution here cannot disagree with
        a sharedness verdict there."""
        if self._method_index is not None:
            return self._method_index
        R = self.R
        rows = []
        for t in range(R.NTYPES):
            mp = R.MOD.get(R.image_of_type(t))
            if not mp or not mp[0]:
                continue
            base, cnt = mp
            ns, nm = R.tname(t)
            tn = (ns + "." + nm) if ns else nm
            for mi in R.type_methods(t):
                rid = R.mtoken(mi) & 0xFFFFFF
                if not (1 <= rid <= cnt):
                    continue
                va = R.rq(base + (rid - 1) * 8)
                if va:
                    rows.append((va - R.IB, tn + "::" + R.mname(mi)))
        rows.sort()
        self._method_index = rows
        return rows

    def enclosing(self, rva):
        """The method whose body contains `rva`, or None.

        Binary search for the greatest method start <= rva. There is no length
        field in the metadata, so "contains" is approximated by "starts before
        and is the nearest such start". That is honest but not airtight, and it
        is why the caller prints it as EVIDENCE. A folded/shared start is
        annotated so a name that serves 6438 methods cannot be read as an
        identification.

        A start more than MAX_GAP bytes before the call is REJECTED rather
        than reported. Without that cap the nearest-start rule always finds
        *something*, and it produced exactly one confidently-wrong line in the
        first run of this tool -- a call at 0x2DBBE0A attributed to
        `System.Reflection.TypeFilter::.ctor @0x2CB7710`, over a megabyte
        earlier. A name is worse than a blank when it is invented."""
        rows = self.method_index()
        lo, hi = 0, len(rows)
        while lo < hi:
            mid = (lo + hi) // 2
            if rows[mid][0] <= rva:
                lo = mid + 1
            else:
                hi = mid
        if lo == 0:
            return None
        start, name = rows[lo - 1]
        if rva - start > MAX_GAP:
            return None
        state, n = self.R.sharedness(start)
        return (start, name, state, n)

    # ---- the scan --------------------------------------------------------

    def call_sites(self, target_rva, limit=0):
        """Every `E8 rel32` in the generated-code section whose destination is
        `target_rva`.

        Scanning for the ENCODING rather than disassembling means a byte
        sequence inside an immediate or a jump table can masquerade as a call.
        Two filters cut that down: the destination must be exactly the target
        (a 1-in-2^32 coincidence per candidate), and the recovered slot must
        land in a data section. Anything surviving both is reported with its
        raw bytes so it can be eyeballed."""
        sec = self.section("il2cpp")
        if sec is None:
            raise SystemExit("no `il2cpp` section in this PE -- generated code "
                             "lives there on this build; refusing to scan "
                             "`.text`, which would find nothing and say so "
                             "as if it were an answer")
        vaddr, vsize, rawptr, rawsize = sec
        blob = self.R.b
        n = min(vsize, rawsize)
        out = []
        i = 0
        end = n - 5
        while i < end:
            j = blob.find(b"\xe8", rawptr + i, rawptr + end)
            if j < 0:
                break
            i = (j - rawptr) + 1
            rel = struct.unpack_from("<i", blob, j + 1)[0]
            nxt = vaddr + (j - rawptr) + 5      # RVA of the next instruction
            if nxt + rel == target_rva:
                out.append((vaddr + (j - rawptr), j))
                if limit and len(out) >= limit:
                    break
        return out

    def slot_for(self, call_rva, call_off, window):
        """The RDX RIP-relative load that most immediately precedes the call.

        Backward, nearest-first: the LAST `mov rdx,[rip+X]` before the call is
        the one whose value is still live in RDX at the call. Anything earlier
        would have been clobbered by it."""
        blob = self.R.b
        lo = max(0, call_off - window)
        best = None
        k = lo
        while k <= call_off - 7:
            if blob[k:k + 3] == MOV_RDX_RIP:
                disp = struct.unpack_from("<i", blob, k + 3)[0]
                # RVA of the instruction start = call_rva - (call_off - k)
                ins_rva = call_rva - (call_off - k)
                best = (ins_rva, ins_rva + 7 + disp)
            k += 1
        return best

    def receiver_for(self, call_rva, call_off, window):
        blob = self.R.b
        lo = max(0, call_off - window)
        best = None
        k = lo
        while k <= call_off - 7:
            if blob[k:k + 3] == MOV_RCX_RIP:
                disp = struct.unpack_from("<i", blob, k + 3)[0]
                ins_rva = call_rva - (call_off - k)
                best = ins_rva + 7 + disp
            k += 1
        return best

    # ---- offline slot -> T attestation ----------------------------------

    def slot_static_token(self, rva):
        """The STATIC qword the DLL ships in `.data` at `rva` -- for an
        unresolved metadata-usage slot this is the encoded token, the SAME value
        the live host reads before il2cpp_codegen_initialize_runtime_metadata
        resolves it. Read from the file image, not a live process."""
        R = self.R
        for nm, vaddr, vsize, rawptr, rawsize in R.SEC:
            if vaddr <= rva < vaddr + vsize:
                return struct.unpack_from("<Q", R.b, rawptr + (rva - vaddr))[0]
        return None

    def slot_type_arg(self, rva):
        """Resolve `.data` slot `rva` to the generic type argument T of the
        AddComponent<T> its token encodes -- WITHOUT running the game.

        The runtime resolver 0x5251C0 decodes an unresolved slot value as
        kind = token>>29, index = (token>>1)&0x0FFFFFFF; for a MethodRef
        (kind 6) the index selects Il2CppMetadataRegistration.methodSpecs[index],
        whose methodInst generic-inst names T. Returns
        (token, kind, index, methodName, [type-arg names]) or None fields where
        it cannot resolve. This is what pins each kind's slot to a PROVEN T, so
        the runtime klass check is corroboration rather than the sole authority."""
        R = self.R
        if getattr(R, "MREG", None) is None:
            R._find_metadata_registration()
        mr = R.MREG
        val = self.slot_static_token(rva)
        if val is None:
            return None
        tok = val & 0xFFFFFFFF
        kind = (tok >> 29) & 0x7
        index = (tok >> 1) & 0x0FFFFFFF
        ms_cnt = struct.unpack_from("<i", R.b, R.v2f(mr + 0x40))[0]
        ms_ptr = R.rq(mr + 0x48)
        gi_ptr = R.rq(mr + 0x18)
        name = None
        args = []
        if kind == 6 and 0 <= index < ms_cnt:
            mdef, class_inst, method_inst = struct.unpack_from(
                "<iii", R.b, R.v2f(ms_ptr + index * 12))
            try:
                name = R.mname(mdef)
            except Exception:
                name = None
            if method_inst >= 0:
                gi = R.rq(gi_ptr + method_inst * 8)
                argc = struct.unpack_from("<Q", R.b, R.v2f(gi))[0]
                argv = R.rq(gi + 8)
                for k in range(min(int(argc), 8)):
                    tp = R.rq(argv + k * 8)
                    o = R.v2f(tp)
                    data = struct.unpack_from("<Q", R.b, o)[0]
                    bits = struct.unpack_from("<I", R.b, o + 8)[0]
                    tenum = (bits >> 16) & 0xFF
                    if tenum in (0x11, 0x12):   # VALUETYPE / CLASS
                        ns, nm = R.tname(data)
                        args.append((ns + "." + nm) if ns else nm)
                    else:
                        args.append("tenum=0x%x" % tenum)
        return (val, kind, index, name, args)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    gameasm, metadec = argv[1], argv[2]
    target = ADDCOMPONENT_GENERIC_RVA
    window = 64
    limit = 0
    slottypes = []
    rest = argv[3:]
    i = 0
    while i < len(rest):
        if rest[i] == "--target":
            target = int(rest[i + 1], 0)
            i += 2
        elif rest[i] == "--window":
            window = int(rest[i + 1], 0)
            i += 2
        elif rest[i] == "--max":
            limit = int(rest[i + 1], 0)
            i += 2
        elif rest[i] == "--slottype":
            slottypes.append(int(rest[i + 1], 0))
            i += 2
        else:
            sys.stderr.write("unknown argument %r\n" % rest[i])
            return 2

    R = Resolver(gameasm, metadec)

    # --slottype: resolve one or more .data slot RVAs to the generic argument T
    # of AddComponent<T> their token encodes, OFFLINE. This is the reproducible
    # attestation the host's `attested` flag stands on -- decode the same static
    # token the live host warms, and name T from methodSpecs. Falsifiable: a
    # different slot decodes to a different T, so a swapped RVA is caught here,
    # not by a runtime klass check against a possibly-mistyped donor.
    if slottypes:
        S = SlotScan(R)
        for rva in slottypes:
            res = S.slot_type_arg(rva)
            if res is None:
                print("slot 0x%X: NOT in .data / unreadable" % rva)
                continue
            val, kind, index, name, args = res
            T = ("%s<%s>" % (name, ",".join(args))) if name else "UNRESOLVED"
            print("slot 0x%X  static-token=0x%08X  kind=%d  index=0x%X  -> %s"
                  % (rva, val & 0xFFFFFFFF, kind, index, T))
        return 0

    # Self-check, before any answer is printed, exactly as `fldoff.py` does:
    # if the field decoder cannot reproduce System.String's known layout then
    # nothing else this resolver says is trustworthy either.
    rows = R.all_fields_ex(R.find_one("System.String"))
    got = dict((r["name"], r["off"]) for r in rows)
    if got.get("_stringLength") != 0x10 or got.get("_firstChar") != 0x14:
        raise SystemExit("SELF-CHECK FAILED: System.String does not read back "
                         "_stringLength@0x10/_firstChar@0x14; the metadata "
                         "pair is wrong for this binary. Refusing to print "
                         "slot addresses that would look plausible.")

    S = SlotScan(R)
    state, owners = R.sharedness(target)
    print("target        0x%X  (%s, %d owner method(s))" % (target, state, owners))
    if state == "unknown":
        print("  NOTE: that address is not in the methodPointers histogram at "
              "all. It is not 'not shared' -- it is unrecognised. Check you "
              "passed a static RVA from THIS GameAssembly.dll.")
    print("window        %d bytes back from each call for `mov rdx,[rip+X]`" % window)
    print("data sections " + ", ".join(
        "%s 0x%X..0x%X" % (nm, lo, hi) for nm, lo, hi in S.data_ranges()))
    print("")

    sites = S.call_sites(target, limit)
    print("%d call site(s) of 0x%X in the `il2cpp` section" % (len(sites), target))
    print("")

    groups = {}
    rejected = 0
    for call_rva, call_off in sites:
        got_slot = S.slot_for(call_rva, call_off, window)
        if got_slot is None:
            rejected += 1
            continue
        ins_rva, slot = got_slot
        sec = S.in_data(slot)
        if sec is None:
            rejected += 1
            continue
        enc = S.enclosing(call_rva)
        recv = S.receiver_for(call_rva, call_off, window)
        groups.setdefault(slot, []).append((call_rva, ins_rva, enc, recv, sec))

    print("=== BY SLOT (each slot is ONE generic instantiation, i.e. one T) ===")
    for slot in sorted(groups):
        uses = groups[slot]
        sec = uses[0][4]
        print("")
        print("slot 0x%X   [%s]   %d call site(s)" % (slot, sec, len(uses)))
        for call_rva, ins_rva, enc, recv, _sec in uses[:8]:
            if enc is None:
                who = "<no enclosing method found>"
            else:
                start, name, st, n = enc
                who = "%s @0x%X" % (name, start)
                if st == "shared":
                    who += " [SHARED x%d -- NOT an identification]" % n
                elif st == "unknown":
                    who += " [start not in methodPointers -- unattributed]"
            print("    call @0x%-9X  rdx<-[rip] @0x%-9X  in %s"
                  % (call_rva, ins_rva, who))
            if recv is not None:
                print("        (rcx <- .data 0x%X, the receiver's class slot)" % recv)
        if len(uses) > 8:
            print("    ... and %d more call site(s)" % (len(uses) - 8))

    print("")
    print("%d call site(s) discarded: no `mov rdx,[rip+X]` within the window, "
          "or the recovered address was not in a data section." % rejected)
    print("")
    print("=== C TABLE STUB (paste into abi/aowlspt_nativeui.h, then attribute "
          "each T from the enclosing method AND let the host's runtime klass "
          "check settle it) ===")
    for slot in sorted(groups):
        enc = groups[slot][0][2]
        name = enc[1] if enc else "?"
        print("    /* evidence: %s (+%d other site(s)) */" % (name, len(groups[slot]) - 1))
        print("    { \"<T>\", 0x%Xu, 0, 0, 0 }," % slot)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
