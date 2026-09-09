#!/usr/bin/env python3
"""Read a Unity/Windows minidump without a debugger.

WHY THIS EXISTS. The client's crash handler writes
`%LOCALAPPDATA%\\Temp\\Battlestate Games\\EscapeFromTarkov\\Crashes\\Crash_*\\`
with a `Player.log` (a symbol-less stack: module + nearest exported name) and a
`crash.dmp`. The stack alone is not enough to tell WHY: on 2026-09-02 it said
`toJson <- schemaJson <- onPageQuery`, which is compatible with an
out-of-range walk, an uninitialised field and a use-after-free, and those three
have three different fixes. The dump holds the answer -- the faulting
registers and the thread stacks -- and this reads it in one command.

There is no debugger on this machine. cdb/WinDbg are not installed; the machine
has msys2 (objdump/addr2line), which can disassemble the module but cannot open
a minidump.

    python tools/dmpread.py <crash.dmp>                 # exception + registers
    python tools/dmpread.py <crash.dmp> --stack [N]     # N words of the
                                                        # faulting stack
    python tools/dmpread.py <crash.dmp> --read 0xADDR [N]

WHAT IT WILL AND WILL NOT ANSWER. These dumps carry MemoryListStream (thread
stacks) but NOT Memory64ListStream (full heap), so `--read` answers for stack
addresses and REFUSES, saying so, for anything else. A refusal is not "the
address is bad" -- three outcomes, not two.

FILL PATTERNS. A register or memory word full of one repeated byte is usually
an allocator's debug fill, and naming it is most of the diagnosis:

    0xdf  mimalloc MI_DEBUG_FREED    -- this memory HAS BEEN FREED
    0xd0  mimalloc MI_DEBUG_UNINIT   -- allocated, never written
    0xde  mimalloc MI_DEBUG_PADDING
    0xcd  MSVC CRT clean / uninitialised heap
    0xdd  MSVC CRT freed heap
    0xfe / 0xee  Windows heap free fill

The mods and the backend are nimony, and nimony's allocator IS mimalloc
(`alloc` -> `mi_malloc` in the generated C), built with MI_DEBUG on in what we
ship -- which is why 0xdf is the pattern that keeps turning up and why it is
worth this file.
"""

import struct
import sys

CONTEXT_REGS = ['Rax', 'Rcx', 'Rdx', 'Rbx', 'Rsp', 'Rbp', 'Rsi', 'Rdi',
                'R8', 'R9', 'R10', 'R11', 'R12', 'R13', 'R14', 'R15', 'Rip']

FILLS = {
    0xdf: 'mimalloc MI_DEBUG_FREED -- this memory has been FREED',
    0xd0: 'mimalloc MI_DEBUG_UNINIT -- allocated but never written',
    0xde: 'mimalloc MI_DEBUG_PADDING',
    0xcd: 'MSVC CRT uninitialised heap',
    0xdd: 'MSVC CRT freed heap',
    0xfe: 'Windows heap free fill',
    0xee: 'Windows heap free fill',
}

EXC = {
    0xc0000005: 'ACCESS_VIOLATION',
    0xc00000fd: 'STACK_OVERFLOW',
    0xc000001d: 'ILLEGAL_INSTRUCTION',
    0x80000003: 'BREAKPOINT',
    0xc0000094: 'INTEGER_DIVIDE_BY_ZERO',
    0xc0000374: 'HEAP_CORRUPTION',
}


def fill_of(value):
    """The repeated byte a 64-bit word is made of, or None."""
    b = value & 0xff
    if b == 0:
        return None
    for i in range(8):
        if (value >> (i * 8)) & 0xff != b:
            return None
    return b


class Dump:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        sig, _ver, nstreams, rva_dir = struct.unpack_from('<4sIII', self.d, 0)
        if sig != b'MDMP':
            raise SystemExit('%s is not a minidump (signature %r)' % (path, sig))
        self.streams = {}
        for i in range(nstreams):
            t, sz, rva = struct.unpack_from('<III', self.d, rva_dir + i * 12)
            if sz:
                self.streams.setdefault(t, []).append((sz, rva))
        self.ranges = []
        for sz, rva in self.streams.get(5, []):          # MemoryListStream
            n, = struct.unpack_from('<I', self.d, rva)
            for i in range(n):
                start, msz, off = struct.unpack_from('<QII', self.d,
                                                     rva + 4 + i * 16)
                self.ranges.append((start, msz, off))
        for sz, rva in self.streams.get(9, []):          # Memory64ListStream
            n, base = struct.unpack_from('<QQ', self.d, rva)
            off = base
            for i in range(n):
                start, msz = struct.unpack_from('<QQ', self.d, rva + 16 + i * 16)
                self.ranges.append((start, msz, off))
                off += msz

    def read(self, addr, n):
        for start, size, off in self.ranges:
            if start <= addr < start + size:
                k = addr - start
                return self.d[off + k: off + k + min(n, size - k)]
        return None

    def exception(self):
        if 6 not in self.streams:
            return None
        _sz, rva = self.streams[6][0]
        tid, = struct.unpack_from('<I', self.d, rva)
        code, _flags, _rec, addr = struct.unpack_from('<IIQQ', self.d, rva + 8)
        nparams, = struct.unpack_from('<I', self.d, rva + 32)
        params = struct.unpack_from('<15Q', self.d, rva + 40)[:nparams]
        _csz, crva = struct.unpack_from('<II', self.d, rva + 160)
        regs = dict(zip(CONTEXT_REGS,
                        struct.unpack_from('<17Q', self.d, crva + 0x78)))
        return tid, code, addr, params, regs


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    dmp = Dump(argv[1])
    exc = dmp.exception()
    if exc is None:
        raise SystemExit('this dump carries no ExceptionStream; nothing to say '
                         'about a fault (it may be a hang dump)')
    tid, code, addr, params, regs = exc
    print('thread %d  %s (0x%08x)  at 0x%x'
          % (tid, EXC.get(code, 'code'), code, addr))
    if code == 0xc0000005 and len(params) >= 2:
        kind = {0: 'READ', 1: 'WRITE', 8: 'EXECUTE'}.get(params[0], '?')
        bad = params[1] & 0xffffffffffffffff
        if bad == 0xffffffffffffffff:
            print('  a %s faulted; the record does not carry WHICH address '
                  '(-1 means unavailable, not address -1) -- take it from the '
                  'faulting instruction and the registers below' % kind)
        else:
            print('  a %s of 0x%x faulted' % (kind, bad))
    for i in range(0, 17, 4):
        row = []
        for n in CONTEXT_REGS[i:i + 4]:
            row.append('%-3s=%016x' % (n, regs[n]))
        print('  ' + ' '.join(row))
    named = False
    for n, v in regs.items():
        b = fill_of(v)
        if b in FILLS:
            print('  %s is 0x%02x-filled: %s' % (n, b, FILLS[b]))
            named = True
    if not named:
        print('  (no register holds a known allocator fill pattern)')

    if '--stack' in argv:
        i = argv.index('--stack')
        words = int(argv[i + 1]) if len(argv) > i + 1 and \
            argv[i + 1].isdigit() else 64
        rsp = regs['Rsp']
        b = dmp.read(rsp, words * 8)
        if b is None:
            print('the faulting stack is NOT in this dump')
        else:
            for k in range(0, len(b) - 7, 8):
                v, = struct.unpack_from('<Q', b, k)
                note = ''
                f = fill_of(v)
                if f in FILLS:
                    note = '   <- 0x%02x fill: %s' % (f, FILLS[f])
                print('  %016x: %016x%s' % (rsp + k, v, note))

    if '--read' in argv:
        i = argv.index('--read')
        a = int(argv[i + 1], 16)
        n = int(argv[i + 2]) if len(argv) > i + 2 and argv[i + 2].isdigit() else 64
        b = dmp.read(a, n)
        if b is None:
            print('0x%x is NOT COVERED by this dump -- these crash dumps carry '
                  'thread stacks only, so this is "could not look", not "bad '
                  'address"' % a)
        else:
            for k in range(0, len(b) - 7, 8):
                v, = struct.unpack_from('<Q', b, k)
                print('  %016x: %016x' % (a + k, v))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
