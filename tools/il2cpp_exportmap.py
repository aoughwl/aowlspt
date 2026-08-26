#!/usr/bin/env python3
"""il2cpp_exportmap.py -- OFFLINE, READ-ONLY map of GameAssembly.dll's export surface.

Nothing here runs, loads or calls the target. It parses the PE export directory,
locates each export's bytes on disk, and classifies the prologue with capstone.

Usage:  python tools/il2cpp_exportmap.py <GameAssembly.dll> [--all] [--json out.json]

Classification vocabulary (each is a MEASURED byte property, not a guess):
  ret0-stub     immediate `ret`/`ret imm16` or xor eax,eax + ret  (no observable work)
  const-stub    returns a LITERAL constant, no memory touched (e.g. `mov eax,0x10; ret`)
  accessor      <=3 insns: dereferences the receiver and returns the loaded value.
                REAL CODE, but it TRUSTS its argument -- there is no validation, so a
                bogus receiver yields plausible garbage or a fault. This is the
                booby-trap shape, and it is inlining, not hardening.
  tailjump      first instruction is an unconditional jmp (thunk / ICF-folded alias)
  body          anything else: real straight-line code before the first ret
  unmapped      export RVA falls outside every section  (would fault if called)
  forwarder     export entry points inside the export directory: a DLL forwarder string
"""
import sys, struct, json, collections

IMAGEBASE_DEFAULT = 0x180000000

def u16(b,o): return struct.unpack_from('<H',b,o)[0]
def u32(b,o): return struct.unpack_from('<I',b,o)[0]
def u64(b,o): return struct.unpack_from('<Q',b,o)[0]

class PE:
    def __init__(self, path):
        self.data = open(path,'rb').read()
        d = self.data
        pe = u32(d,0x3c)
        assert d[pe:pe+4]==b'PE\0\0', 'not a PE'
        nsec = u16(d,pe+6)
        optsz = u16(d,pe+20)
        opt = pe+24
        self.magic = u16(d,opt)
        assert self.magic == 0x20b, 'not PE32+'
        self.imagebase = u64(d,opt+24)
        ndd = u32(d,opt+108)
        self.dd = [(u32(d,opt+112+i*8), u32(d,opt+116+i*8)) for i in range(ndd)]
        self.sections=[]
        so = opt+optsz
        for i in range(nsec):
            b = so+i*40
            name = d[b:b+8].rstrip(b'\0').decode('latin1')
            vsz, va, rsz, ptr = u32(d,b+8), u32(d,b+12), u32(d,b+16), u32(d,b+20)
            chars = u32(d,b+36)
            self.sections.append((name,va,vsz,ptr,rsz,chars))
    def sect(self, rva):
        for s in self.sections:
            if s[1] <= rva < s[1]+max(s[2],s[4]): return s
        return None
    def off(self, rva):
        s = self.sect(rva)
        if not s: return None
        o = rva - s[1] + s[3]
        if o >= len(self.data) or rva - s[1] >= s[4]: return None
        return o
    def read(self, rva, n):
        o = self.off(rva)
        if o is None: return None
        return self.data[o:o+n]

def exports(pe):
    erva, esz = pe.dd[0]
    o = pe.off(erva)
    d = pe.data
    nfun = u32(d,o+20); nnam = u32(d,o+24)
    afun = u32(d,o+28); anam = u32(d,o+32); aord = u32(d,o+36)
    ofun, onam, oord = pe.off(afun), pe.off(anam), pe.off(aord)
    base = u32(d,o+16)
    byord = {}
    for i in range(nnam):
        nr = u32(d,onam+i*4)
        no = pe.off(nr)
        e = d.index(b'\0', no)
        name = d[no:e].decode('latin1')
        ordn = u16(d,oord+i*2)
        byord[ordn] = name
    out=[]
    for i in range(nfun):
        f = u32(d,ofun+i*4)
        if f == 0: continue
        out.append((byord.get(i, '@ord%d'%(base+i)), base+i, f,
                    erva <= f < erva+esz))
    return out

def classify(pe, rva, md):
    b = pe.read(rva, 48)
    if b is None or len(b) < 4: return ('unmapped', '', [])
    ins=[]
    try:
        for i in md.disasm(b, pe.imagebase+rva):
            ins.append((i.address, i.mnemonic, i.op_str, i.size))
            if i.mnemonic in ('ret','jmp','int3') or len(ins)>=8: break
    except Exception:
        pass
    if not ins: return ('undecodable', b[:8].hex(), [])
    hexs = b[:8].hex()
    m0 = ins[0][1]
    if m0 in ('ret',):
        return ('ret0-stub', hexs, ins)
    if m0 == 'jmp':
        return ('tailjump', hexs, ins)
    # const-stub: <=3 setup insns then ret, only writing eax/rax
    kinds = [x[1] for x in ins]
    if 'ret' in kinds:
        n = kinds.index('ret')
        body = ins[:n]
        if all(x[1] in ('xor','mov','lea','movzx','movsx','sub','and') and
               x[2].split(',')[0].strip() in ('eax','rax','al','ax') for x in body) and n<=3:
            if n==1 and body[0][1]=='xor' and body[0][2].replace(' ','')=='eax,eax':
                return ('ret0-stub', hexs, ins)
            srcs = ' '.join(x[2] for x in body)
            if '[' in srcs:
                return ('accessor', hexs, ins)
            return ('const-stub', hexs, ins)
    return ('body', hexs, ins)

def main():
    args=[a for a in sys.argv[1:] if not a.startswith('--')]
    flags=set(a for a in sys.argv[1:] if a.startswith('--'))
    if not args:
        print(__doc__); return 2
    import capstone
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    pe = PE(args[0])
    exps = exports(pe)
    rows=[]
    rvacount = collections.Counter(e[2] for e in exps if not e[3])
    for name, ordn, rva, isfwd in exps:
        if isfwd:
            o = pe.off(rva); s = pe.data.index(b'\0', o)
            rows.append(dict(name=name, ordinal=ordn, rva=rva, kind='forwarder',
                             detail=pe.data[o:s].decode('latin1'), section='-', bytes='', shared=1))
            continue
        s = pe.sect(rva)
        kind, hexs, ins = classify(pe, rva, md)
        rows.append(dict(name=name, ordinal=ordn, rva=rva, kind=kind,
                         section=(s[0] if s else 'NONE'), bytes=hexs,
                         detail='; '.join('%s %s'%(i[1],i[2]) for i in ins[:4]),
                         shared=rvacount[rva]))
    show = rows if '--all' in flags else [r for r in rows if r['name'].startswith('il2cpp_')]
    print('imagebase 0x%x  sections: %s' % (pe.imagebase, ', '.join(
        '%s@0x%x+0x%x' % (s[0], s[1], max(s[2],s[4])) for s in pe.sections)))
    print('exports total %d  (il2cpp_* = %d)' % (len(rows), sum(1 for r in rows if r['name'].startswith('il2cpp_'))))
    print()
    print('%-52s %-10s %-9s %-12s %s' % ('EXPORT','RVA','SECTION','KIND','FIRST BYTES / INSNS'))
    for r in sorted(show, key=lambda r: r['name']):
        print('%-52s 0x%08x %-9s %-12s %s %s%s' % (
            r['name'], r['rva'], r['section'], r['kind'], r['bytes'], r['detail'],
            '   [RVA shared by %d exports]'%r['shared'] if r['shared']>1 else ''))
    print()
    c = collections.Counter(r['kind'] for r in show)
    print('summary:', dict(c))
    for f in flags:
        if f.startswith('--json='):
            json.dump(rows, open(f[7:],'w'), indent=1)
    return 0

if __name__ == '__main__':
    sys.exit(main())
