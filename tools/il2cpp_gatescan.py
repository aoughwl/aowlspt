#!/usr/bin/env python3
"""Derive the token-gated il2cpp export map from GameAssembly.dll, OFFLINE.

Usage: il2cpp_gatescan.py <GameAssembly.dll> [out.h]

Reads the PE on disk and disassembles each `il2cpp_*` export's prologue. The
game is never started and no export is ever called. Two gate flavours are
recognised, both by their instruction shape rather than by any name list:

  STATIC  `test <tokreg>,<tokreg>` / `je trap` / `mov r8d,0x20` /
          `lea rdx,[rip+X]` / `call memcmp` / `test eax,eax` / `jne trap`
          -> the 32 expected bytes live at RVA X (RIP-relative, resolved here).

  NONCE   `mov ebx,[rip+_tls_index]` / `mov rax,gs:[0x58]` /
          `cmp qword [<slot> + rax],0` / `je trap` / `call <derivation>`
          -> the caller must first obtain a single-use nonce via the exported,
             non-stock il2cpp_nonce(apiId), then derive 32 bytes from it.

Emitting the map as GENERATED DATA is deliberate: the set of gated exports must
never be hand-maintained, because a stale or mistyped row does not fail loudly
-- it makes the export return MT19937-64 output that looks like a valid pointer.
"""
import struct, sys, json

import capstone as CS

ARG = {'rcx': 0, 'rdx': 1, 'r8': 2, 'r9': 3}


def load(path):
    d = open(path, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE")
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    optsz = struct.unpack_from("<H", d, pe + 20)[0]
    opt = pe + 24
    imgbase = struct.unpack_from("<Q", d, opt + 24)[0]
    secs = []
    so = opt + optsz
    for i in range(nsec):
        o = so + 40 * i
        nm = d[o:o + 8].rstrip(b"\0").decode()
        vs, va, rs, ptr = struct.unpack_from("<IIII", d, o + 8)
        secs.append((nm, va, vs, ptr, rs))
    return d, imgbase, secs


def make_r2o(secs):
    def r2o(rva):
        for nm, va, vs, ptr, rs in secs:
            if va <= rva < va + max(vs, rs):
                return ptr + (rva - va)
        return None
    return r2o


def exports_of(d, opt_dd_rva, r2o):
    e = r2o(opt_dd_rva)
    nnam = struct.unpack_from("<I", d, e + 24)[0]
    afun, anam, aord = struct.unpack_from("<III", d, e + 28)
    of, on, oo = r2o(afun), r2o(anam), r2o(aord)
    out = {}
    for i in range(nnam):
        nr = struct.unpack_from("<I", d, on + 4 * i)[0]
        no = r2o(nr)
        nm = d[no:d.index(b"\0", no)].decode()
        ordi = struct.unpack_from("<H", d, oo + 2 * i)[0]
        out[nm] = struct.unpack_from("<I", d, of + 4 * ordi)[0]
    return out


def analyse(d, imgbase, r2o, md, rva, depth=0):
    o = r2o(rva)
    if o is None:
        return None
    ins = list(md.disasm(d[o:o + 400], imgbase + rva))
    if depth == 0 and ins and ins[0].mnemonic == 'jmp' and ins[0].op_str.startswith('0x'):
        r = analyse(d, imgbase, r2o, md, int(ins[0].op_str, 16) - imgbase, 1)
        return r
    tokreg = static_tok = nonce_slot = deriv = None
    for i, x in enumerate(ins[:70]):
        if x.mnemonic == 'test':
            a = x.op_str.split(', ')
            if len(a) == 2 and a[0] == a[1] and a[0] in ARG and tokreg is None:
                tokreg = a[0]
        if x.mnemonic == 'mov' and x.op_str.startswith('r8d, 0x20') and static_tok is None:
            for y in ins[i:i + 4]:
                if y.mnemonic == 'lea' and 'rip + ' in y.op_str and y.op_str.startswith('rdx'):
                    disp = int(y.op_str.split('rip + ')[1].rstrip(']'), 16)
                    static_tok = (y.address - imgbase) + y.size + disp
                    break
        if (x.mnemonic == 'mov'
                and x.op_str.startswith(('r15d, 0x', 'r14d, 0x', 'r12d, 0x', 'r13d, 0x', 'ebp, 0x'))
                and nonce_slot is None):
            v = int(x.op_str.split(', ')[1], 16)
            if 0x100 <= v <= 0x2000:
                nonce_slot = v
        if (x.mnemonic == 'call' and nonce_slot and static_tok is None
                and deriv is None and x.op_str.startswith('0x')):
            t = int(x.op_str, 16) - imgbase
            if t != 0x5ef6f8:          # the lazy TLS-init helper, not a derivation
                deriv = t
    if static_tok is not None and tokreg:
        return dict(kind='static', tok=static_tok, reg=tokreg, rva=rva)
    if nonce_slot is not None and tokreg:
        return dict(kind='nonce', slot=nonce_slot, deriv=deriv, reg=tokreg, rva=rva)
    return None


def main():
    import gamepaths as _gp
    dll = sys.argv[1] if len(sys.argv) > 1 else _gp.gameasm()
    out = sys.argv[2] if len(sys.argv) > 2 else None
    d, imgbase, secs = load(dll)
    r2o = make_r2o(secs)
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    optsz = struct.unpack_from("<H", d, pe + 20)[0]
    edir = struct.unpack_from("<I", d, pe + 24 + 112)[0]
    exports = exports_of(d, edir, r2o)
    md = CS.Cs(CS.CS_ARCH_X86, CS.CS_MODE_64)

    res = {}
    for nm, rva in sorted(exports.items()):
        if not nm.startswith("il2cpp_"):
            continue
        try:
            r = analyse(d, imgbase, r2o, md, rva)
        except Exception:
            r = None
        if r:
            r['export_rva'] = rva
            res[nm] = r

    st = sorted(k for k, v in res.items() if v['kind'] == 'static')
    no = sorted(k for k, v in res.items() if v['kind'] == 'nonce')
    allil = sorted(k for k in exports if k.startswith("il2cpp_"))
    sys.stderr.write("il2cpp_* exports=%d  gated=%d (static=%d nonce=%d)\n"
                     % (len(allil), len(res), len(st), len(no)))

    L = []
    A = L.append
    A("/* GENERATED by tools/il2cpp_gatescan.py -- DO NOT EDIT BY HAND.")
    A(" *")
    A(" * Source: %s" % dll)
    A(" * il2cpp_* exports: %d   gated: %d (static %d, nonce %d)"
      % (len(allil), len(res), len(st), len(no)))
    A(" *")
    A(" * Each row was derived by disassembling the export's own prologue. Token")
    A(" * RVAs are RIP-relative targets resolved from the instruction, never")
    A(" * guessed and never copied from prose. Regenerate after any game update:")
    A(" * a stale row does NOT fail loudly, it makes the export return MT19937-64")
    A(" * output that passes a nil check and kills the client on first deref.")
    A(" */")
    A("#ifndef AOWLSPT_IL2CPP_GATES_DATA_H")
    A("#define AOWLSPT_IL2CPP_GATES_DATA_H")
    A("")
    A("#define AOWL_GATE_KIND_STATIC 1")
    A("#define AOWL_GATE_KIND_NONCE  2")
    A("")
    A("typedef struct {")
    A("    const char*   name;       /* export name                                  */")
    A("    unsigned      export_rva; /* RVA of the exported symbol                   */")
    A("    unsigned      body_rva;   /* real body (== export, or its tail-jmp target)*/")
    A("    unsigned char kind;       /* AOWL_GATE_KIND_*                             */")
    A("    unsigned char argidx;     /* 0=RCX 1=RDX 2=R8 3=R9: which arg is the token*/")
    A("    unsigned      token_rva;  /* STATIC: .rdata RVA of the 32 expected bytes  */")
    A("    unsigned      tls_slot;   /* NONCE : per-API TLS slot holding the nonce   */")
    A("    unsigned      deriv_rva;  /* NONCE : derivation fn, RCX=nonce -> ptr to 32*/")
    A("} aowl_gate_row_t;")
    A("")
    A("static const aowl_gate_row_t aowl_gate_rows[] = {")
    for nm in st:
        v = res[nm]
        A('    { "%s", 0x%X, 0x%X, AOWL_GATE_KIND_STATIC, %d, 0x%X, 0, 0 },'
          % (nm, v['export_rva'], v['rva'], ARG[v['reg']], v['tok']))
    for nm in no:
        v = res[nm]
        A('    { "%s", 0x%X, 0x%X, AOWL_GATE_KIND_NONCE, %d, 0, 0x%X, 0x%X },'
          % (nm, v['export_rva'], v['rva'], ARG[v['reg']], v['slot'], v['deriv'] or 0))
    A("};")
    A("#define AOWL_GATE_ROWS         %d" % len(st + no))
    A("#define AOWL_GATE_STATIC_COUNT %d" % len(st))
    A("#define AOWL_GATE_NONCE_COUNT  %d" % len(no))
    A("")
    A("/* il2cpp_nonce(apiId) -- exported and NON-STOCK; this is the handshake entry. */")
    A("#define AOWL_IL2CPP_NONCE_RVA 0x%X" % exports.get("il2cpp_nonce", 0))
    A("")
    A("/* The COMPLETE il2cpp_* export surface, so the layer can answer \"is this")
    A(" * one gated?\" for all %d exports, not merely for the gated subset. */" % len(allil))
    A("static const char* const aowl_il2cpp_exports[] = {")
    for nm in allil:
        A('    "%s",' % nm)
    A("};")
    A("#define AOWL_IL2CPP_EXPORT_COUNT %d" % len(allil))
    A("")
    A("#endif /* AOWLSPT_IL2CPP_GATES_DATA_H */")

    txt = "\n".join(L) + "\n"
    if out:
        open(out, "w", newline="\n", encoding="utf-8").write(txt)
        sys.stderr.write("wrote %s\n" % out)
    else:
        sys.stdout.write(txt)


if __name__ == "__main__":
    main()
