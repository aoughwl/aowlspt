#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""consistency.py -- read and rewrite the client's OWN consistency manifest.

WHY THIS EXISTS
---------------
`tools/dlss.py` resynced `D:\\Aowlspt\\ConsistencyInfo` -- the plain JSON file
next to the exe -- and the client still refused to boot:

    files-checker|Consistency ensurance failed. File size does not match.
    File: "EscapeFromTarkov_Data\\Plugins\\x86_64\\nvngx_dlss.dll"

MEASURED (offline disassembly + a decrypt that round-trips): the client NEVER
READS that file. `FilesChecker.ConsistencyController::TryFillConsistencyMetadatas`
@0x27d4310 builds its dictionary from an AES-256-CBC blob INJECTED INTO
`EscapeFromTarkov.exe` itself, via `FilesChecker.ResourceInjector::Read`
@0x27d8dd0. There is NO fallback: both catch blocks in that method only call
`AbstractLogger::LogException`, so a failure to read the resource leaves the
dictionary EMPTY rather than reaching for the plain file. The plain
`ConsistencyInfo` is the LAUNCHER's manifest (it lists `ConsistencyInfo`,
`EscapeFromTarkov.exe` and `Uninstall.exe`, which the embedded copy does not).

THE CONTAINER FORMAT, measured from the disassembly and confirmed by a
round trip against `D:\\Games\\Tarkov\\ConsistencyInfo`
--------------------------------------------------------------------
The blob is appended to the exe, in front of the Authenticode certificate:

    at P                : u8   ivLen          (16)
    at P+1              : u8[ivLen] IV
    at P+1+ivLen        : i32  cipherLen      (little endian)
    at P+5+ivLen        : u8[cipherLen] ciphertext
    at S-8              : i64  P              (a back-pointer to the record)
    at S                : u8[32] signature

`Read` seeks to `S-8`, reads the i64, seeks there, reads the IV length byte,
the IV, the i32 length, then wraps a bounded sub-stream in a `CryptoStream`
and copies it out. So `P + 5 + ivLen + cipherLen == S - 8` exactly, and that
identity is this tool's first structural check.

  * `signature` = SHA-256(ASCII("BSG_RESOURCE_V1")). That label is a RESOURCE
    MARKER, not a key or a secret. It was not read out of a string table by
    eye: every one of the 32,305 metadata string literals was SHA-256'd and
    the digests searched for in the exe, and exactly ONE matched, at file
    offset 0x27066d. `ResourceInjector::.ctor` @0x27da1e0 does literally
    `_resourceSignature = GetHash(<literal>)`.
  * `GetHash(s)` @0x27d9de0 = `new SHA256Managed().ComputeHash(
    Encoding.ASCII.GetBytes(s))` -- 32 bytes, so AES-256.
  * The cipher key is `GetHash(buildId)`. NO BSG KEY LITERAL IS STORED IN THIS
    FILE. The build id is DERIVED AT RUNTIME (see `discover_key`) and every
    candidate is proved or rejected by decryption, never assumed: the decrypted
    document must be valid JSON *and* its own `"Version"` must equal the
    candidate. On this install that resolves to the ordinary client version
    string, which is public and printed on the main menu.
  * Aes.Create() with no Mode/Padding assignment => CBC + PKCS#7.

SERIALISATION. The payload was written by Newtonsoft with HTML string escaping:
`&` appears as `\\u0026`. `dumps_newtonsoft` reproduces that, and `inject`
REFUSES to write anything unless re-serialising the UNMODIFIED document
reproduces the decrypted plaintext byte for byte. That is the check that cannot
pass vacuously.

VERBS
    dump    [--root R] [--entry PATH] [--json OUT]
    verify  [--root R] [--entry PATH]        three-way, PASS/FAIL/INCONCLUSIVE
    inject  [--root R] (--entry PATH --size N --checksum C | --from-json F)
            [--out FILE | --install]
    selftest

Exit codes: 0 PASS, 1 FAIL, 3 INCONCLUSIVE.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import shutil
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import bsgaes  # noqa: E402

LIVE_DEFAULT = r"D:\Aowlspt"
EXE_NAME = "EscapeFromTarkov.exe"
CI_NAME = "ConsistencyInfo"
SIGNATURE_LABEL = "BSG_RESOURCE_V1"      # a resource marker, not a key
DLL_REL = r"EscapeFromTarkov_Data\Plugins\x86_64\nvngx_dlss.dll"

PASS, FAIL, INCONCLUSIVE = 0, 1, 3


# --------------------------------------------------------------------------- #
# checksum -- the SAME formula tools/dlss.py uses (fact #90)                   #
# --------------------------------------------------------------------------- #
def ci_checksum(data):
    """byte-sum mod 2^32, stored as a SIGNED int32."""
    return ctypes.c_int32(sum(data) & 0xFFFFFFFF).value


def ci_checksum_file(path):
    s = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            s += sum(chunk)
    return ctypes.c_int32(s & 0xFFFFFFFF).value


# --------------------------------------------------------------------------- #
# container                                                                   #
# --------------------------------------------------------------------------- #
class Refused(Exception):
    """A structural or cryptographic refusal. Never a plausible wrong answer."""


def signature_bytes(label=SIGNATURE_LABEL):
    return hashlib.sha256(label.encode("ascii")).digest()


def locate(blob, label=SIGNATURE_LABEL):
    """Find THE injected record. Returns a dict describing it.

    Every occurrence of the signature is considered and each is checked
    structurally; exactly one must survive. A second survivor is a refusal,
    not a coin flip.
    """
    sig = signature_bytes(label)
    cands = []
    start = 0
    while True:
        s = blob.find(sig, start)
        if s < 0:
            break
        start = s + 1
        if s < 8:
            continue
        (p,) = struct.unpack_from("<q", blob, s - 8)
        if not (0 < p < s - 8 - 5):
            continue
        ivlen = blob[p]
        if ivlen not in (16,):                       # AES block size
            continue
        (clen,) = struct.unpack_from("<i", blob, p + 1 + ivlen)
        if clen <= 0 or clen % 16:
            continue
        if p + 1 + ivlen + 4 + clen != s - 8:        # the structural identity
            continue
        cands.append({
            "sig_off": s, "rec_off": p, "iv": bytes(blob[p + 1:p + 1 + ivlen]),
            "cipher_off": p + 5 + ivlen, "cipher_len": clen,
            "tail_off": s + len(sig),
        })
    if not cands:
        raise Refused("no injected resource: signature SHA-256(%r) not found, "
                      "or found without a well-formed record behind it" % label)
    if len(cands) > 1:
        raise Refused("%d well-formed records carry the signature; refusing to "
                      "guess which one the client reads" % len(cands))
    return cands[0]


def decrypt_record(blob, rec, key):
    ct = blob[rec["cipher_off"]:rec["cipher_off"] + rec["cipher_len"]]
    pt = bsgaes.cbc_decrypt(key, rec["iv"], ct)
    return bsgaes.pkcs7_unpad(pt)


# --------------------------------------------------------------------------- #
# key discovery -- derived, proved, never hardcoded                           #
# --------------------------------------------------------------------------- #
def key_candidates(root, explicit=None, metadata=None):
    """Build ids to TRY, cheapest first. None of these is trusted; each is put
    to `decrypt_record` and rejected unless the plaintext is JSON whose own
    "Version" equals the candidate."""
    out = []

    def add(v, why):
        if v and all(v != o for o, _ in out):
            out.append((v, why))

    if explicit:
        add(explicit, "--key")
    # The launcher's plain manifest sits next to the exe and names the build.
    try:
        with open(os.path.join(root, CI_NAME), "rb") as f:
            add(json.loads(f.read().decode("utf-8")).get("Version"),
                "%s/%s \"Version\"" % (root, CI_NAME))
    except Exception:
        pass
    # Last resort: every ASCII string literal in the decrypted metadata.
    if metadata and os.path.exists(metadata):
        for lit in _metadata_literals(metadata):
            add(lit, "global-metadata string literal")
    return out


def _metadata_literals(path):
    d = open(path, "rb").read()
    lo, ls = struct.unpack_from("<ii", d, 8)          # prop 0: stringLiteral
    do, _ = struct.unpack_from("<ii", d, 16)          # prop 1: stringLiteralData
    for i in range(ls // 8):
        L, DI = struct.unpack_from("<ii", d, lo + i * 8)
        s = d[do + DI:do + DI + L]
        try:
            yield s.decode("utf-8")
        except UnicodeDecodeError:
            continue


def discover_key(blob, rec, root, explicit=None, metadata=None):
    """Returns (key_bytes, build_id, why). Raises Refused if nothing decrypts."""
    tried = []
    for build_id, why in key_candidates(root, explicit, metadata):
        try:
            k = hashlib.sha256(build_id.encode("ascii")).digest()
        except UnicodeEncodeError:
            continue
        try:
            pt = decrypt_record(blob, rec, k)
            doc = json.loads(pt.decode("utf-8"))
        except Exception:
            tried.append(build_id)
            continue
        if doc.get("Version") != build_id:
            # Decrypted to JSON but the document disagrees with the key that
            # opened it. Say so; do not quietly accept it.
            raise Refused("key %r decrypted the blob but the manifest calls "
                          "itself %r -- refusing an inconsistent pair"
                          % (build_id, doc.get("Version")))
        return k, build_id, why
    raise Refused("no candidate build id decrypted the resource (tried %d: %s)"
                  % (len(tried), ", ".join(repr(t) for t in tried[:5])))


# --------------------------------------------------------------------------- #
# Newtonsoft-compatible serialisation                                         #
# --------------------------------------------------------------------------- #
# Newtonsoft's StringEscapeHandling.EscapeHtml set, with UPPERCASE hex digits.
# MEASURED against the shipped payload, which contains both `&` (&) and
# `+` (+) inside asset paths -- an escaper that misses `+`, or that emits
# lowercase hex, produces a payload 30 bytes short of the shipped one, which is
# exactly what `rebuild`'s gate refused the first time this ran.
_HTML_ESCAPES = {"&": "\\u0026", "<": "\\u003C", ">": "\\u003E",
                 "'": "\\u0027", "+": "\\u002B"}


def dumps_newtonsoft(doc):
    """Compact JSON with Newtonsoft's HTML string escaping (StringEscapeHandling
    .EscapeHtml). `inject` proves this reproduces the shipped bytes before it
    is allowed to write anything."""
    s = json.dumps(doc, separators=(",", ":"), ensure_ascii=False)
    for ch, esc in _HTML_ESCAPES.items():
        s = s.replace(ch, esc)
    return s.encode("utf-8")


# --------------------------------------------------------------------------- #
# the loaded state                                                            #
# --------------------------------------------------------------------------- #
class Embedded(object):
    def __init__(self, path, blob, rec, key, build_id, why, plain):
        self.path, self.blob, self.rec = path, blob, rec
        self.key, self.build_id, self.key_why = key, build_id, why
        self.plain = plain
        self.doc = json.loads(plain.decode("utf-8"))

    def entry(self, rel):
        hits = [e for e in self.doc["Entries"] if e.get("Path") == rel]
        return hits[0] if len(hits) == 1 else None


def load(root=LIVE_DEFAULT, exe=None, key=None, metadata=None):
    path = exe or os.path.join(root, EXE_NAME)
    if not os.path.exists(path):
        raise Refused("no such file: %s" % path)
    blob = open(path, "rb").read()
    rec = locate(blob)
    k, build_id, why = discover_key(blob, rec, root, key, metadata)
    plain = decrypt_record(blob, rec, k)
    return Embedded(path, blob, rec, k, build_id, why, plain)


# --------------------------------------------------------------------------- #
# rebuild                                                                     #
# --------------------------------------------------------------------------- #
def rebuild(emb, new_doc, iv=None):
    """Return new whole-file bytes carrying `new_doc`.

    LENGTH IS PRESERVED. The ciphertext must occupy exactly the bytes it does
    today, because the Authenticode certificate directory that follows the
    record records a FILE OFFSET; shifting it would silently invalidate it.
    A shorter payload is padded with trailing newlines (JSON ignores trailing
    whitespace); a longer one is REFUSED rather than shifting the tail.
    """
    # Gate: our serialiser must reproduce the shipped bytes exactly.
    # (trailing newlines are OUR OWN capacity padding, added below; JSON
    # ignores them, so they are not part of what the serialiser must reproduce)
    round_trip = dumps_newtonsoft(emb.doc)
    if round_trip != emb.plain.rstrip(b"\n"):
        raise Refused("serialiser does not reproduce the shipped payload "
                      "(%d vs %d bytes) -- refusing to rewrite it"
                      % (len(round_trip), len(emb.plain)))
    body = dumps_newtonsoft(new_doc)
    # PKCS#7 always adds 1..16 bytes, so the largest plaintext that still
    # encrypts to exactly `cipher_len` bytes is `cipher_len - 1`.
    cap = emb.rec["cipher_len"] - 1
    if len(body) > cap:
        raise Refused("new manifest is %d bytes, %d more than the %d the record "
                      "can hold without moving the Authenticode certificate"
                      % (len(body), len(body) - cap, cap))
    body = body + b"\n" * (cap - len(body))
    ct = bsgaes.cbc_encrypt(emb.key, iv or emb.rec["iv"],
                            bsgaes.pkcs7_pad(body))
    if len(ct) != emb.rec["cipher_len"]:
        raise Refused("re-encrypted payload is %d bytes, the record holds %d"
                      % (len(ct), emb.rec["cipher_len"]))
    out = bytearray(emb.blob)
    out[emb.rec["cipher_off"]:emb.rec["cipher_off"] + len(ct)] = ct
    out[emb.rec["rec_off"] + 1:emb.rec["rec_off"] + 1 + len(emb.rec["iv"])] = \
        iv or emb.rec["iv"]
    if len(out) != len(emb.blob):
        raise Refused("rebuild changed the file length")
    return bytes(out)


def replace_file(path, data, backup_dir):
    """Write `data` over `path`, BREAKING any hardlink (the live exe is
    hardlinked to \\ripstage), with a timestamped backup taken first."""
    os.makedirs(backup_dir, exist_ok=True)
    backup = os.path.join(backup_dir, os.path.basename(path))
    shutil.copy2(path, backup)
    tmp = path + ".new"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)                 # a NEW inode: the hardlink is broken
    return backup


# --------------------------------------------------------------------------- #
# verbs                                                                       #
# --------------------------------------------------------------------------- #
def cmd_dump(a):
    try:
        emb = load(a.root, a.exe, a.key, a.metadata)
    except Refused as e:
        print("INCONCLUSIVE  %s" % e)
        return INCONCLUSIVE
    print("file        %s (%d bytes)" % (emb.path, len(emb.blob)))
    print("record      at 0x%x, ciphertext 0x%x..0x%x (%d bytes), signature at 0x%x"
          % (emb.rec["rec_off"], emb.rec["cipher_off"],
             emb.rec["cipher_off"] + emb.rec["cipher_len"],
             emb.rec["cipher_len"], emb.rec["sig_off"]))
    print("iv          %s" % emb.rec["iv"].hex())
    print("build id    %r  (from %s)" % (emb.build_id, emb.key_why))
    print("manifest    Version=%r  %d entries, %d critical, %d bytes of JSON"
          % (emb.doc.get("Version"), len(emb.doc["Entries"]),
             sum(1 for e in emb.doc["Entries"] if e.get("IsCritical")),
             len(emb.plain)))
    for rel in (a.entry or [DLL_REL]):
        e = emb.entry(rel)
        print("entry       %s" % (json.dumps(e) if e else "%s -- NOT IN MANIFEST" % rel))
    plain_path = os.path.join(a.root, CI_NAME)
    if os.path.exists(plain_path):
        try:
            pl = json.loads(open(plain_path, "rb").read().decode("utf-8"))
            E = {e["Path"]: e for e in emb.doc["Entries"]}
            L = {e["Path"]: e for e in pl["Entries"]}
            common = set(E) & set(L)
            disagree = [p for p in common
                        if (E[p].get("Size"), E[p].get("Checksum")) != (L[p].get("Size"), L[p].get("Checksum"))]
            print("plain file  %s: %d entries, %d only there, %d only embedded, "
                  "%d of %d common entries DISAGREE on Size/Checksum"
                  % (plain_path, len(L), len(set(L) - set(E)), len(set(E) - set(L)),
                     len(disagree), len(common)))
        except Exception as ex:
            print("plain file  unreadable: %s" % ex)
    if a.json:
        open(a.json, "wb").write(emb.plain)
        print("wrote       %s" % a.json)
    return PASS


def cmd_verify(a):
    try:
        emb = load(a.root, a.exe, a.key, a.metadata)
    except Refused as e:
        print("INCONCLUSIVE  %s" % e)
        return INCONCLUSIVE
    rels = a.entry or [DLL_REL]
    verdict = PASS
    plain_path = os.path.join(a.root, CI_NAME)
    plain_doc = None
    try:
        plain_doc = json.loads(open(plain_path, "rb").read().decode("utf-8"))
    except Exception:
        pass
    for rel in rels:
        e = emb.entry(rel)
        if e is None:
            print("INCONCLUSIVE  %s: not exactly one entry in the embedded manifest" % rel)
            verdict = max(verdict, INCONCLUSIVE)
            continue
        disk = os.path.join(a.root, rel.replace("\\", os.sep))
        if not os.path.exists(disk):
            print("FAIL          %s: entry exists but the file does not" % rel)
            verdict = FAIL
            continue
        size = os.path.getsize(disk)
        cks = ci_checksum_file(disk)
        why = []
        if e["Size"] != size:
            why.append("embedded Size %d != on-disk %d" % (e["Size"], size))
        if e["Checksum"] != cks:
            why.append("embedded Checksum %d != recomputed %d" % (e["Checksum"], cks))
        p = None
        if plain_doc is not None:
            hits = [x for x in plain_doc["Entries"] if x.get("Path") == rel]
            p = hits[0] if len(hits) == 1 else None
        if p is None:
            note = "  (plain file: no single entry -- the client does not read it anyway)"
        elif (p["Size"], p["Checksum"]) != (e["Size"], e["Checksum"]):
            note = "  (plain file DISAGREES: Size %d Checksum %d -- cosmetic; " \
                   "the client reads only the embedded copy)" % (p["Size"], p["Checksum"])
        else:
            note = "  (plain file agrees)"
        if why:
            print("FAIL          %s: %s%s" % (rel, "; ".join(why), note))
            verdict = FAIL
        else:
            print("PASS          %s: embedded == on-disk (Size %d, Checksum %d)%s"
                  % (rel, size, cks, note))
    if a.all_sizes:
        bad = 0
        for e in emb.doc["Entries"]:
            disk = os.path.join(a.root, e["Path"].replace("\\", os.sep))
            try:
                if os.path.getsize(disk) != e["Size"]:
                    bad += 1
                    print("FAIL          size %s: %d != %d"
                          % (e["Path"], e["Size"], os.path.getsize(disk)))
            except OSError:
                bad += 1
                print("FAIL          absent %s" % e["Path"])
        print("%s        whole-manifest SIZE sweep: %d of %d entries mismatch"
              % ("PASS " if not bad else "FAIL ", bad, len(emb.doc["Entries"])))
        if bad:
            verdict = FAIL
    return verdict


def cmd_inject(a):
    try:
        emb = load(a.root, a.exe, a.key, a.metadata)
    except Refused as e:
        print("INCONCLUSIVE  %s" % e)
        return INCONCLUSIVE
    doc = json.loads(emb.plain.decode("utf-8"))
    changes = []
    if a.from_json:
        new_doc = json.loads(open(a.from_json, "rb").read().decode("utf-8"))
        doc = new_doc
        changes.append("whole manifest from %s" % a.from_json)
    else:
        if not a.entry:
            print("INCONCLUSIVE  nothing to do: give --entry or --from-json")
            return INCONCLUSIVE
        for rel in a.entry:
            hits = [e for e in doc["Entries"] if e.get("Path") == rel]
            if len(hits) != 1:
                print("INCONCLUSIVE  %s: %d entries, need exactly 1" % (rel, len(hits)))
                return INCONCLUSIVE
            e = hits[0]
            size, cks = a.size, a.checksum
            if size is None or cks is None:
                disk = os.path.join(a.root, rel.replace("\\", os.sep))
                if not os.path.exists(disk):
                    print("INCONCLUSIVE  %s: no --size/--checksum and the file is "
                          "not on disk to measure" % rel)
                    return INCONCLUSIVE
                size = os.path.getsize(disk) if size is None else size
                cks = ci_checksum_file(disk) if cks is None else cks
            changes.append("%s Size %d->%d Checksum %d->%d"
                           % (rel, e["Size"], size, e["Checksum"], cks))
            e["Size"], e["Checksum"] = size, cks
    try:
        data = rebuild(emb, doc, iv=os.urandom(16) if a.new_iv else None)
    except Refused as e:
        print("FAIL          %s" % e)
        return FAIL
    for c in changes:
        print("change        %s" % c)
    # Prove the rebuild round-trips BEFORE anything is written.
    rec2 = locate(data)
    back = json.loads(decrypt_record(data, rec2, emb.key).decode("utf-8"))
    if back != doc:
        print("FAIL          rebuilt image does not decrypt back to the intended "
              "manifest -- nothing written")
        return FAIL
    print("round trip    rebuilt image decrypts to the intended manifest "
          "(%d entries)" % len(back["Entries"]))
    if a.out:
        open(a.out, "wb").write(data)
        print("wrote         %s (%d bytes)" % (a.out, len(data)))
        return PASS
    if not a.install:
        print("DRY RUN       nothing written. Pass --out FILE or --install.")
        return PASS
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_dir = os.path.join(a.root, "aowlspt-backup", "consistency-" + stamp)
    backup = replace_file(emb.path, data, backup_dir)
    print("installed     %s" % emb.path)
    print("backup        %s" % backup)
    print("ROLLBACK      copy \"%s\" \"%s\"" % (backup, emb.path))
    v = load(a.root, a.exe, a.key, a.metadata)
    ok = json.loads(v.plain.decode("utf-8")) == doc
    print("%s          re-read from disk %s the intended manifest"
          % ("PASS" if ok else "FAIL", "IS" if ok else "IS NOT"))
    return PASS if ok else FAIL


# --------------------------------------------------------------------------- #
# selftest -- with falsifiers                                                 #
# --------------------------------------------------------------------------- #
def _synth(build_id="9.9.9.9.1", label=SIGNATURE_LABEL, entries=None):
    """Build a synthetic 'exe' carrying an injected manifest, the same way the
    launcher does. Returns (blob, doc, key)."""
    doc = {"Version": build_id, "Entries": entries or [
        {"Path": r"a\b.dll", "Size": 10, "Checksum": 100, "IsCritical": True},
        {"Path": r"a\c&d.dat", "Size": 20, "Checksum": 200, "IsCritical": False},
    ]}
    # Leave slack, exactly as the real record does: the launcher pads to a
    # block boundary, so an edit that lengthens the JSON a little still fits.
    plain = dumps_newtonsoft(doc) + b"\n" * 64
    key = hashlib.sha256(build_id.encode("ascii")).digest()
    iv = bytes(range(16))
    ct = bsgaes.cbc_encrypt(key, iv, bsgaes.pkcs7_pad(plain))
    head = b"MZ" + b"\x00" * 4094
    p = len(head)
    rec = bytes([16]) + iv + struct.pack("<i", len(ct)) + ct
    blob = head + rec + struct.pack("<q", p) + signature_bytes(label) + b"CERT"
    return blob, doc, key


def selftest():
    fails = []

    def check(ok, what):
        print("  %s  %s" % ("ok  " if ok else "FAIL", what))
        if not ok:
            fails.append(what)

    blob, doc, key = _synth()
    rec = locate(blob)
    check(rec["cipher_len"] % 16 == 0 and rec["rec_off"] == 4096,
          "locate finds the synthetic record by its structural identity")
    check(json.loads(decrypt_record(blob, rec, key).decode("utf-8")) == doc,
          "decrypt_record recovers the manifest")

    # FALSIFIER 1: a WRONG key must not decrypt.
    bad = hashlib.sha256(b"not-the-build-id").digest()
    try:
        decrypt_record(blob, rec, bad)
        ok = False
    except Exception:
        ok = True
    check(ok, "a wrong key FAILS to decrypt (padding refuses it)")

    # FALSIFIER 2: a corrupted length must be refused structurally.
    b2 = bytearray(blob)
    struct.pack_into("<i", b2, rec["cipher_off"] - 4, rec["cipher_len"] + 16)
    try:
        locate(bytes(b2))
        ok = False
    except Refused:
        ok = True
    check(ok, "a corrupted cipherLen is REFUSED, not read past")

    # FALSIFIER 3: a missing signature is a refusal, not an empty manifest.
    b3 = blob.replace(signature_bytes(), b"\x00" * 32)
    try:
        locate(b3)
        ok = False
    except Refused:
        ok = True
    check(ok, "no signature => Refused (never a silently empty manifest)")

    # FALSIFIER 4: key discovery must reject a key/document mismatch.
    b4, d4, k4 = _synth(build_id="1.2.3")
    r4 = locate(b4)
    import tempfile
    tmp = tempfile.mkdtemp(prefix="consist-")
    open(os.path.join(tmp, CI_NAME), "w").write(json.dumps({"Version": "1.2.3", "Entries": []}))
    k, bid, why = discover_key(b4, r4, tmp)
    check(k == k4 and bid == "1.2.3", "discover_key derives the build id from the plain file")
    open(os.path.join(tmp, CI_NAME), "w").write(json.dumps({"Version": "9.9.9", "Entries": []}))
    try:
        discover_key(b4, r4, tmp)
        ok = False
    except Refused:
        ok = True
    check(ok, "a build id that does not open the blob is REFUSED (negative control)")

    # ROUND TRIP: inject then dump.
    emb = Embedded("synthetic", b4, r4, k4, "1.2.3", "synthetic", decrypt_record(b4, r4, k4))
    nd = json.loads(json.dumps(d4))
    nd["Entries"][0]["Size"] = 58977904
    nd["Entries"][0]["Checksum"] = -282693640
    out = rebuild(emb, nd)
    check(len(out) == len(b4), "rebuild preserves the file length exactly")
    back = json.loads(decrypt_record(out, locate(out), k4).decode("utf-8"))
    check(back == nd, "inject -> dump round-trips the edited manifest")
    check(json.loads(decrypt_record(b4, r4, k4).decode("utf-8")) == d4,
          "the original image is untouched by rebuild")

    # FALSIFIER 5: an over-long manifest must be refused, not silently shifted.
    big = json.loads(json.dumps(d4))
    big["Entries"] += [{"Path": "x" * 4000, "Size": 1, "Checksum": 1, "IsCritical": False}]
    try:
        rebuild(emb, big)
        ok = False
    except Refused:
        ok = True
    check(ok, "a manifest too large for the record is REFUSED (would move the cert)")

    # FALSIFIER 6: the serialiser gate must fire when it cannot reproduce bytes.
    broken = Embedded("synthetic", b4, r4, k4, "1.2.3", "synthetic",
                      decrypt_record(b4, r4, k4))
    broken.plain = broken.plain + b" "
    try:
        rebuild(broken, d4)
        ok = False
    except Refused:
        ok = True
    check(ok, "rebuild REFUSES when re-serialising cannot reproduce the shipped "
              "bytes (the check that could otherwise pass vacuously)")

    # HTML escaping is actually exercised: entry 'a\c&d.dat' contains '&'.
    check(b"\\u0026" in dumps_newtonsoft(d4),
          "dumps_newtonsoft reproduces Newtonsoft's HTML escaping of '&'")

    # SIGNED, not unsigned: a payload whose byte sum passes 2^31 must go
    # negative. 0xff * 8421505 = 2147483775 -> -2147483521.
    check(ci_checksum(b"\xff" * 4) == 1020
          and ci_checksum(b"\xff" * 8421505) == -2147483521
          and (sum(b"\xff" * 8421505) & 0xFFFFFFFF) == 2147483775,
          "ci_checksum is byte-sum mod 2^32 as a SIGNED int32 (the unsigned "
          "formula would answer 2147483775 here)")

    shutil.rmtree(tmp, ignore_errors=True)
    print("")
    print("%d failure(s)" % len(fails))
    return FAIL if fails else PASS


# --------------------------------------------------------------------------- #
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=LIVE_DEFAULT)
    ap.add_argument("--exe", default=None, help="override the exe path")
    ap.add_argument("--key", default=None, help="build id (NOT stored in this file)")
    ap.add_argument("--metadata", default=None,
                    help="decrypted global-metadata, for last-resort key search")
    sub = ap.add_subparsers(dest="cmd")

    d = sub.add_parser("dump")
    d.add_argument("--entry", action="append")
    d.add_argument("--json", default=None)
    d.set_defaults(fn=cmd_dump)

    v = sub.add_parser("verify")
    v.add_argument("--entry", action="append")
    v.add_argument("--all-sizes", action="store_true",
                   help="sweep every entry's SIZE against the install (cheap)")
    v.set_defaults(fn=cmd_verify)

    i = sub.add_parser("inject")
    i.add_argument("--entry", action="append")
    i.add_argument("--size", type=int, default=None)
    i.add_argument("--checksum", type=int, default=None)
    i.add_argument("--from-json", default=None)
    i.add_argument("--out", default=None)
    i.add_argument("--install", action="store_true")
    i.add_argument("--new-iv", action="store_true")
    i.set_defaults(fn=cmd_inject)

    s = sub.add_parser("selftest")
    s.set_defaults(fn=lambda a: selftest())

    a = ap.parse_args(argv)
    if not getattr(a, "fn", None):
        ap.print_help()
        return INCONCLUSIVE
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
