# bsgaes.py -- AES decryption, table-driven, standard library only.
#
# Exists because this machine has no pip and therefore no `pycryptodome`, and
# because `bsgwire` needs AES-192-CBC to read a captured Escape From Tarkov
# response. It was decrypt-only until `tools/consistency.py` had to REWRITE the
# manifest injected into EscapeFromTarkov.exe; the encrypt direction below is
# held to the same FIPS-197 known answers.
#
# The "equivalent inverse cipher" of FIPS-197 section 5.3.5 -- the round keys
# are reordered and pushed through InvMixColumns once, up front, so the inner
# loop is four table lookups and an XOR per column rather than a field
# multiplication per byte. About forty times the speed of the direct form,
# which is the difference between reading the 4 MB `/client/items` body and
# giving up on it.
#
# `selftest` checks it against the FIPS-197 appendix C known-answer vectors for
# all three key sizes. That matters more than usual here: this module was
# written to confirm a recovered key, and a subtly wrong AES would have turned
# a correct key into a negative result and sent the search off in the wrong
# direction for hours.
"""Table-driven AES decrypt (equivalent inverse cipher), stdlib only."""
import struct
_S=[0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16]
_Si=[0]*256
for i,v in enumerate(_S): _Si[v]=i
def _m(a,b):
    r=0
    for _ in range(8):
        if b&1: r^=a
        h=a&0x80; a=(a<<1)&0xff
        if h: a^=0x1b
        b>>=1
    return r
# forward T tables (for key schedule only we need sbox) ; inverse T tables:
Td0=[0]*256;Td1=[0]*256;Td2=[0]*256;Td3=[0]*256
for x in range(256):
    s=_Si[x]
    v=(_m(s,14)<<24)|(_m(s,9)<<16)|(_m(s,13)<<8)|_m(s,11)
    Td0[x]=v
    Td1[x]=((v>>8)|(v<<24))&0xffffffff
    Td2[x]=((v>>16)|(v<<16))&0xffffffff
    Td3[x]=((v>>24)|(v<<8))&0xffffffff
Rcon=[0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,0x6c,0xd8,0xab,0x4d]
M=0xffffffff

def dec_schedule(key):
    """Equivalent-inverse-cipher round keys (list of 4*(Nr+1) uint32) + Nr."""
    Nk=len(key)//4; Nr={4:10,6:12,8:14}[Nk]
    w=list(struct.unpack(">%dI"%Nk,key))
    for i in range(Nk,4*(Nr+1)):
        t=w[i-1]
        if i%Nk==0:
            t=((t<<8)|(t>>24))&M
            t=(_S[(t>>24)&0xff]<<24)|(_S[(t>>16)&0xff]<<16)|(_S[(t>>8)&0xff]<<8)|_S[t&0xff]
            t^=Rcon[i//Nk-1]<<24
        elif Nk>6 and i%Nk==4:
            t=(_S[(t>>24)&0xff]<<24)|(_S[(t>>16)&0xff]<<16)|(_S[(t>>8)&0xff]<<8)|_S[t&0xff]
        w.append(w[i-Nk]^t)
    # reverse round-key order and apply InvMixColumns to the middle rounds
    dk=[0]*len(w)
    for r in range(Nr+1):
        for c in range(4): dk[4*r+c]=w[4*(Nr-r)+c]
    for r in range(1,Nr):
        for c in range(4):
            v=dk[4*r+c]
            dk[4*r+c]=(Td0[_S[(v>>24)&0xff]]^Td1[_S[(v>>16)&0xff]]^Td2[_S[(v>>8)&0xff]]^Td3[_S[v&0xff]])
    return dk,Nr

def dec_block(ct,dk,Nr):
    s0,s1,s2,s3=struct.unpack(">4I",ct)
    s0^=dk[0];s1^=dk[1];s2^=dk[2];s3^=dk[3]
    k=4
    for _ in range(Nr-1):
        t0=Td0[s0>>24]^Td1[(s3>>16)&0xff]^Td2[(s2>>8)&0xff]^Td3[s1&0xff]^dk[k]
        t1=Td0[s1>>24]^Td1[(s0>>16)&0xff]^Td2[(s3>>8)&0xff]^Td3[s2&0xff]^dk[k+1]
        t2=Td0[s2>>24]^Td1[(s1>>16)&0xff]^Td2[(s0>>8)&0xff]^Td3[s3&0xff]^dk[k+2]
        t3=Td0[s3>>24]^Td1[(s2>>16)&0xff]^Td2[(s1>>8)&0xff]^Td3[s0&0xff]^dk[k+3]
        s0,s1,s2,s3=t0,t1,t2,t3; k+=4
    o=bytearray(16)
    for i,(a,b,c,d) in enumerate(((s0,s3,s2,s1),(s1,s0,s3,s2),(s2,s1,s0,s3),(s3,s2,s1,s0))):
        v=(_Si[a>>24]<<24)|(_Si[(b>>16)&0xff]<<16)|(_Si[(c>>8)&0xff]<<8)|_Si[d&0xff]
        v^=dk[k+i]
        struct.pack_into(">I",o,4*i,v)
    return bytes(o)

def enc_schedule(key):
    """Forward-cipher round keys (list of 4*(Nr+1) uint32) + Nr.

    Added for `tools/consistency.py`, which must REWRITE an AES-256-CBC blob
    inside EscapeFromTarkov.exe, not merely read one. The module header's
    "decryption only" claim is no longer true; the encrypt direction is held to
    the same FIPS-197 known answers below, in both directions, because an
    encryptor that is subtly wrong here produces an exe that fails the game's
    own consistency check with no diagnostic at all.
    """
    Nk=len(key)//4; Nr={4:10,6:12,8:14}[Nk]
    w=list(struct.unpack(">%dI"%Nk,key))
    for i in range(Nk,4*(Nr+1)):
        t=w[i-1]
        if i%Nk==0:
            t=((t<<8)|(t>>24))&M
            t=(_S[(t>>24)&0xff]<<24)|(_S[(t>>16)&0xff]<<16)|(_S[(t>>8)&0xff]<<8)|_S[t&0xff]
            t^=Rcon[i//Nk-1]<<24
        elif Nk>6 and i%Nk==4:
            t=(_S[(t>>24)&0xff]<<24)|(_S[(t>>16)&0xff]<<16)|(_S[(t>>8)&0xff]<<8)|_S[t&0xff]
        w.append(w[i-Nk]^t)
    return w,Nr

def _xtime(a): return ((a<<1)^0x1b)&0xff if a&0x80 else (a<<1)

def enc_block(pt,ek,Nr):
    s=bytearray(pt)
    for i in range(4):
        v=ek[i]
        for j in range(4): s[4*i+j]^=(v>>(24-8*j))&0xff
    for r in range(1,Nr+1):
        s=bytearray(_S[b] for b in s)
        # ShiftRows (state is column-major: s[4*c+r])
        t=bytearray(16)
        for c in range(4):
            for r2 in range(4): t[4*c+r2]=s[4*((c+r2)&3)+r2]
        s=t
        if r!=Nr:
            for c in range(4):
                a=s[4*c:4*c+4]
                x=a[0]^a[1]^a[2]^a[3]
                b0=a[0]
                s[4*c+0]=a[0]^x^_xtime(a[0]^a[1])
                s[4*c+1]=a[1]^x^_xtime(a[1]^a[2])
                s[4*c+2]=a[2]^x^_xtime(a[2]^a[3])
                s[4*c+3]=a[3]^x^_xtime(a[3]^b0)
        for c in range(4):
            v=ek[4*r+c]
            for j in range(4): s[4*c+j]^=(v>>(24-8*j))&0xff
    return bytes(s)

def ecb_encrypt(key,data):
    ek,Nr=enc_schedule(key);out=bytearray()
    for i in range(0,len(data),16): out+=enc_block(data[i:i+16],ek,Nr)
    return bytes(out)

def cbc_encrypt(key,iv,data):
    ek,Nr=enc_schedule(key);out=bytearray();prev=iv
    for i in range(0,len(data),16):
        b=bytes(x^y for x,y in zip(data[i:i+16],prev))
        c=enc_block(b,ek,Nr);out+=c;prev=c
    return bytes(out)

def pkcs7_pad(data,bs=16):
    n=bs-(len(data)%bs)
    return data+bytes([n])*n

def pkcs7_unpad(data,bs=16):
    if not data or len(data)%bs: raise ValueError("not a whole number of blocks")
    n=data[-1]
    if n<1 or n>bs or data[-n:]!=bytes([n])*n: raise ValueError("bad PKCS#7 padding")
    return data[:-n]

def cbc_decrypt(key,iv,data):
    dk,Nr=dec_schedule(key);out=bytearray();prev=iv
    for i in range(0,len(data),16):
        b=data[i:i+16];d=dec_block(b,dk,Nr)
        out+=bytes(x^y for x,y in zip(d,prev));prev=b
    return bytes(out)
def ecb_decrypt(key,data):
    dk,Nr=dec_schedule(key);out=bytearray()
    for i in range(0,len(data),16): out+=dec_block(data[i:i+16],dk,Nr)
    return bytes(out)


# --------------------------------------------------------------------------- #
# Known-answer tests: FIPS-197 appendix C.                                     #
# --------------------------------------------------------------------------- #

_VECTORS = [
    # (key, plaintext, ciphertext), all hex, from FIPS-197 C.1/C.2/C.3
    ("000102030405060708090a0b0c0d0e0f",
     "00112233445566778899aabbccddeeff",
     "69c4e0d86a7b0430d8cdb78070b4c55a"),
    ("000102030405060708090a0b0c0d0e0f1011121314151617",
     "00112233445566778899aabbccddeeff",
     "dda97ca4864cdfe06eaf70a0ec0d7191"),
    ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
     "00112233445566778899aabbccddeeff",
     "8ea2b7ca516745bfeafc49904b496089"),
]


def selftest() -> int:
    failures = 0
    for key_hex, pt_hex, ct_hex in _VECTORS:
        key = bytes.fromhex(key_hex)
        got = ecb_decrypt(key, bytes.fromhex(ct_hex))
        ok = got == bytes.fromhex(pt_hex)
        bits = len(key) * 8
        print(f"  {'ok  ' if ok else 'FAIL'}  AES-{bits} FIPS-197 known answer")
        if not ok:
            failures += 1
    # CBC chaining, checked against a hand-computed two-block case built out of
    # the ECB primitive: CBC decrypt is ECB decrypt then XOR with the previous
    # ciphertext block, so this catches a chaining or IV mistake specifically.
    key = bytes.fromhex(_VECTORS[1][0])
    iv = bytes(range(16))
    c1 = bytes.fromhex(_VECTORS[1][2])
    c2 = bytes.fromhex(_VECTORS[1][2])
    want = (bytes(a ^ b for a, b in zip(ecb_decrypt(key, c1), iv))
            + bytes(a ^ b for a, b in zip(ecb_decrypt(key, c2), c1)))
    ok = cbc_decrypt(key, iv, c1 + c2) == want
    print(f"  {'ok  ' if ok else 'FAIL'}  AES-192-CBC chains and uses its IV")
    if not ok:
        failures += 1

    # --- encrypt direction (added for tools/consistency.py) ----------------- #
    for key_hex, pt_hex, ct_hex in _VECTORS:
        key = bytes.fromhex(key_hex)
        got = ecb_encrypt(key, bytes.fromhex(pt_hex))
        ok = got == bytes.fromhex(ct_hex)
        print(f"  {'ok  ' if ok else 'FAIL'}  AES-{len(key)*8} FIPS-197 known answer (ENCRYPT)")
        if not ok:
            failures += 1
    # CBC encrypt must be the exact inverse of CBC decrypt, and must NOT be
    # ECB in disguise: two identical plaintext blocks must encrypt differently.
    key = bytes.fromhex(_VECTORS[2][0])
    iv = bytes(range(16, 32))
    msg = pkcs7_pad(b"consistency injector round trip, 41 bytes.")
    ct = cbc_encrypt(key, iv, msg)
    ok = cbc_decrypt(key, iv, ct) == msg
    print(f"  {'ok  ' if ok else 'FAIL'}  AES-256-CBC encrypt/decrypt round trip")
    failures += 0 if ok else 1
    two = cbc_encrypt(key, iv, b"\x00" * 32)
    ok = two[:16] != two[16:]
    print(f"  {'ok  ' if ok else 'FAIL'}  AES-256-CBC is chained, not ECB (negative control)")
    failures += 0 if ok else 1
    try:
        pkcs7_unpad(b"\x00" * 16)
        ok = False
    except ValueError:
        ok = True
    print(f"  {'ok  ' if ok else 'FAIL'}  PKCS#7 unpad REFUSES bad padding (negative control)")
    failures += 0 if ok else 1
    print("")
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    import sys
    sys.exit(selftest())
