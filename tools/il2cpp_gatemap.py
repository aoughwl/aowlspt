#!/usr/bin/env python3
"""il2cpp_gatemap.py -- OFFLINE, READ-ONLY. Which il2cpp_* exports are TOKEN-GATED.

Nothing here loads, runs or calls GameAssembly.dll. It disassembles from disk.

MEASURED on build 1.1.0.1.46777: this is NOT a stock IL2CPP export surface. A
subset of the exports takes an EXTRA trailing argument -- a pointer to a 32-byte
token -- and `memcmp`s it (0x1806206D0 is memcmp) against an expected value
before doing any work. Two flavours:

  STATIC-token  the expected 32 bytes are a constant in .rdata; this tool prints
                them. Nothing else is required of the caller.
  NONCE-token   the expected value is derived at call time from a per-API,
                SINGLE-USE 64-bit nonce held in a TLS slot (read then zeroed).
                `il2cpp_nonce(apiId)` -- an exported, NON-STOCK function at RVA
                0x5B3D60 -> 0x5B1010, a jump table over apiId in [0x19,0x95] --
                is what freshly generates that nonce and returns it.

On a token MISMATCH the export does not return NULL and does not abort. It tail-
calls a trap helper (0x5B64E0 family) that lazily seeds a per-thread MT19937-64
(0x52B7E0, constant 0x5851F42D4C957F2D, 312 words) and returns a uniform random
NON-ZERO 64-bit value (0x52A570, range [1, 0xFFFFFFFFFFFFFFFF]). That is the
"non-nil handle into unmapped memory" this project has been killed by: the null
check passes and the first dereference faults.

Usage: python tools/il2cpp_gatemap.py <GameAssembly.dll>
"""
import sys, os, collections
import capstone
from il2cpp_exportmap import PE, exports

MEMCMP_RVA = 0x6206D0

def cfg_gates(pe, md, entry, span=0xa00, depth=0, seen_fn=None):
    IB = pe.imagebase
    seen_fn = seen_fn if seen_fn is not None else set()
    if entry in seen_fn: return {}
    seen_fn.add(entry)
    lo, hi = entry, entry + span
    todo, seen, gates = [entry], set(), {}
    while todo:
        a = todo.pop(); recent = []
        while lo <= a < hi and a not in seen:
            b = pe.read(a, 16)
            if not b: break
            try: i = next(md.disasm(b, IB + a))
            except StopIteration: break
            seen.add(a); m, ops = i.mnemonic, i.op_str
            if m in ('call', 'jmp') and ops.startswith('0x'):
                t = int(ops, 16) - IB
                if t == MEMCMP_RVA:
                    sz = tok = None
                    for (rm, ro, ra, rsz) in recent[-8:]:
                        if rm == 'mov' and ro.replace(' ', '') == 'r8d,0x20': sz = 0x20
                        if rm == 'lea' and ro.startswith('rdx, [rip'):
                            body = ro.split('[rip', 1)[1].rstrip(']')
                            sign = -1 if '-' in body else 1
                            tok = ra + rsz + sign * int(body.split()[-1], 16)
                    if sz == 0x20: gates[a] = tok
                if m == 'jmp':
                    if lo <= t < hi: a = t; recent = []; continue
                    if depth < 3: gates.update(cfg_gates(pe, md, t, span, depth + 1, seen_fn))
                    break
            elif m.startswith('j') and ops.startswith('0x'):
                t = int(ops, 16) - IB
                if lo <= t < hi: todo.append(t)
            elif m in ('ret', 'int3'): break
            recent.append((m, ops, a, i.size)); a += i.size
    return gates

def main():
    if len(sys.argv) < 2: print(__doc__); return 2
    pe = PE(sys.argv[1])
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    rows = []
    for name, _o, rva, fwd in exports(pe):
        if fwd or not name.startswith('il2cpp_'): continue
        g = cfg_gates(pe, md, rva)
        if not g:
            rows.append((name, rva, 'ungated', None)); continue
        toks = [v for v in g.values() if v is not None]
        if toks:
            t = toks[0]; blob = pe.read(t, 32); s = pe.sect(t)
            rows.append((name, rva, 'STATIC-token',
                         (t, blob.hex() if blob else '<unmapped>', s[0] if s else 'NONE')))
        else:
            rows.append((name, rva, 'NONCE-token', None))
    print('token-gated il2cpp_* exports (32-byte memcmp before any work)\n')
    for n, r, k, t in sorted(rows, key=lambda x: x[0]):
        if k == 'ungated': continue
        if t: print('%-46s 0x%08x %-13s token@0x%07x[%s] %s' % (n, r, k, t[0], t[2], t[1]))
        else: print('%-46s 0x%08x %-13s per-API TLS nonce (see il2cpp_nonce)' % (n, r, k))
    print()
    print(dict(collections.Counter(k for _, _, k, _ in rows)))
    return 0

if __name__ == '__main__':
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.exit(main())
