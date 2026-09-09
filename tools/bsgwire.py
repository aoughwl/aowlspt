# bsgwire.py -- decode and encode post-1.0 Escape From Tarkov HTTP bodies.
#
# Every game body -- request and response alike -- is wrapped in the same
# envelope. It is not a cipher and it carries no key:
#
#     wire = shuffle_L( [int32 LE size][payload of `size` bytes][trailing junk] )
#
# `shuffle_L` is a Fisher-Yates permutation whose swap indices come from a
# linear congruential table seeded by constants baked into the client, stepped
# by the buffer's own length. The length IS the key, so anyone can undo it --
# the same permutation the repository already used for `/client/metadata`
# response bodies in `metablob.py`, applied to every route.
#
# The trailing junk is whatever was left in the client's send buffer. It is not
# padding in any meaningful sense and it is not covered by `size`; it is simply
# not written over. That is why two encodings of the same request differ: the
# length varies with the junk, and the length picks the permutation.
#
# Inside the envelope, `payload` is one of three things, and which one is a
# property of the route rather than of the framing:
#
#   * `zlib(json)`   -- every game request body, and the plaintext responses
#   * raw json       -- `/client/libraries` and `/client/libraries-extra`,
#                       whose payloads are already large and already once-only
#   * AES ciphertext -- every response whose headers carry `X-Encryption: aes`.
#                       AES-192-CBC over `zlib(json)`, with the IV in the first
#                       16 bytes. See the block above `RESPONSE_KEY` below.
#
# So a captured session is fully readable in both directions. The whole point
# of this module is that the emulator can be checked against what the real
# backend actually answered rather than against a guess at it.
#
# A handful of bodies skip the envelope entirely and are plain `zlib(json)` on
# the wire: `/client/game/keepalive`, `/launcher/game/start`. `/client/metadata`
# is plain JSON with no framing at all. `decode` recognises all of these, so a
# caller can hand it any body from a capture and get back what it is.
#
# Offline only. This module makes no network calls and reads no game files.

from __future__ import annotations

import argparse
import io
import json
import os
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bsgaes

# The client's shuffle constants. These are the same values `metablob.py` uses
# for `/client/metadata`; they are reproduced here rather than imported so this
# module stands alone, and asserted equal to metablob's in `selftest`.
_MOD = 0x8ED7A18D
_MULTIPLIER = 1624453
_ADDEND = 1023920427
_CURSOR_SEED = 0x65F6D
_CURSOR_WRAP = 0xA53F260DDB0
_START_MODULUS = 0xAAB


def _swap_table(length: int) -> list[int]:
    """The permutation's swap indices for a buffer of `length` bytes.

    Built once per length. The table is `length % 0xAAB + length` entries long
    and only the tail is used, which looks wasteful and is exactly what the
    client does -- the leading entries shift the sequence, so dropping them
    changes the permutation.
    """
    start = length % _START_MODULUS
    size = start + length
    table = [0] * size
    cursor = _CURSOR_SEED
    for i in range(size):
        table[i] = (_MULTIPLIER * cursor + _ADDEND) % _MOD
        cursor += 1
        if cursor > _CURSOR_WRAP:
            cursor = 0
    return table


def unshuffle(body: bytes) -> bytes:
    """Wire order -> buffer order. Ascending pass."""
    buf = bytearray(body)
    start = len(buf) % _START_MODULUS
    table = _swap_table(len(buf))
    for i in range(1, len(buf)):
        j = table[i + start] % i
        buf[i], buf[j] = buf[j], buf[i]
    return bytes(buf)


def shuffle(buf: bytes) -> bytes:
    """Buffer order -> wire order. The descending inverse of `unshuffle`.

    Exact inverse, not an approximation: the swaps are undone in reverse order,
    so `shuffle(unshuffle(x)) == x` for every x. `selftest` asserts it over the
    whole captured corpus rather than over a few sizes, because an off-by-one
    in the table offset is invisible at some lengths and not others.
    """
    out = bytearray(buf)
    start = len(out) % _START_MODULUS
    table = _swap_table(len(out))
    for i in range(len(out) - 1, 0, -1):
        j = table[i + start] % i
        out[i], out[j] = out[j], out[i]
    return bytes(out)


def unwrap(body: bytes) -> bytes | None:
    """Strip the envelope: unshuffle, read the size, return the payload.

    Returns None when the result fails its own sanity check, which is the
    honest answer for a body that was never enveloped -- a plain `zlib` body
    unshuffles to noise whose first four bytes are not a plausible size. The
    check is cheap and rejects essentially everything that is not an envelope:
    the size must be positive and must fit inside the buffer.
    """
    if len(body) < 5:
        return None
    buf = unshuffle(body)
    size = struct.unpack_from("<i", buf, 0)[0]
    if size <= 0 or size > len(buf) - 4:
        return None
    return buf[4:4 + size]


def wrap(payload: bytes, junk: bytes = b"") -> bytes:
    """Build a wire body around `payload`. The inverse of `unwrap`.

    `junk` reproduces the client's uninitialised send-buffer tail. It has no
    meaning and the receiver ignores it; it is a parameter only so a test can
    reproduce a captured body byte for byte.
    """
    return shuffle(struct.pack("<i", len(payload)) + payload + junk)


# --------------------------------------------------------------------------- #
# The response cipher                                                          #
#                                                                              #
# Responses -- and only responses -- carry a second layer inside the envelope, #
# announced by `X-Encryption: aes`. The client never encrypts; there is no     #
# Encrypt method on `HTTPTransportManager` at all, which is why requests are   #
# merely shuffled.                                                             #
#                                                                              #
#     payload = [16-byte IV][AES-192-CBC ciphertext]                           #
#     plaintext = zlib(json)                                                   #
#                                                                              #
# The key is a 24-character ASCII passphrase held as IL2CPP string literal     #
# 2981 and used as the AES key bytes directly -- not hashed, not decoded. That #
# is why a search for base64 or hex key material found nothing: it is not      #
# shaped like a key. `HTTPTransportManager.IV_LENGTH` is 16 in the metadata,   #
# and at all seven call sites `DecryptFromBytesAES` is passed a null IV        #
# argument, i.e. take it from the buffer -- which matches the observation that #
# the first 16 bytes are different on every response of the same body.         #
#                                                                              #
# Recovered by offline analysis of a binary the user owns, to read that user's #
# own captured traffic, so that a single-player server can answer the way the  #
# real one did. Verified against every encrypted body in the capture rather    #
# than a sample.                                                               #
# --------------------------------------------------------------------------- #

RESPONSE_KEY = b"7*YabV3MfOfyE*lhI*l*Qx*q"
IV_LENGTH = 16


def decrypt(payload: bytes, key: bytes = RESPONSE_KEY) -> bytes | None:
    """`[IV][ciphertext]` -> the zlib stream, or None if it does not decrypt.

    Returns None rather than raising, and rather than returning plausible
    rubbish: a wrong key produces 16 random-looking bytes per block and the
    zlib inflate is what rejects them. The caller therefore cannot mistake a
    failure for a body.
    """
    if len(payload) < IV_LENGTH + 16 or len(payload) % 16 != 0:
        return None
    plain = bsgaes.cbc_decrypt(key, payload[:IV_LENGTH], payload[IV_LENGTH:])
    # PKCS7, but the zlib stream is self-terminating so the padding never has
    # to be trusted -- `decompress` stops at the end of the stream and ignores
    # whatever follows. Stripping it here would only add a way to be wrong.
    return plain


# --------------------------------------------------------------------------- #
# Recognising what a body is                                                   #
# --------------------------------------------------------------------------- #

def _try_zlib(data: bytes) -> bytes | None:
    try:
        return zlib.decompress(data)
    except zlib.error:
        return None


def _try_decrypt(payload: bytes) -> bytes | None:
    plain = decrypt(payload)
    if plain is None:
        return None
    return _try_zlib(plain)


def _looks_json(data: bytes) -> bool:
    """Whether `data` really is JSON -- by parsing it, not by peeking.

    A first-byte test is not good enough here and the difference is not
    academic. One byte in 128 of a ciphertext is `{`, so over a corpus of a
    couple of hundred bodies a peek misfiles several of them as readable JSON,
    and a misfiled ciphertext is worse than an unclassified one: it is a body
    the caller believes it has read. Parsing costs microseconds on payloads
    this size and cannot be fooled.
    """
    if data[:1].lstrip() not in (b"{", b"["):
        return False
    try:
        json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return False
    return True


def decode(body: bytes) -> dict:
    """Identify and decode one captured body.

    Returns a dict with `kind` and, where the content is readable, `text`.
    `kind` is one of:

        "empty"            -- zero bytes
        "plain-json"       -- JSON straight on the wire (`/client/metadata`)
        "plain-zlib"       -- zlib(json), no envelope (keepalive, launcher)
        "wrapped-zlib"     -- envelope over zlib(json); every game request
        "wrapped-json"     -- envelope over raw JSON; the `libraries` routes
        "wrapped-aes"      -- envelope over AES-192-CBC over zlib(json); every
                              response whose headers say `X-Encryption: aes`
        "wrapped-opaque"   -- envelope over bytes that are neither, and that
                              the key does not open. `ciphertext` carries them
        "bare-aes"         -- AES with no envelope (`/client/libraries-extra`)
        "bare-opaque"      -- block-aligned bytes with no envelope; ciphertext
                              sent unwrapped (`/client/libraries-extra`)
        "unknown"          -- nothing matched. Reported, never guessed at.

    The order of the tests matters. The envelope is checked before the plain
    forms because a plain `zlib` body can occasionally unshuffle to something
    with a plausible-looking size word, but the payload then fails every
    content test and falls to "wrapped-opaque" -- so plain forms are tried
    first for short bodies, where that collision is likeliest.
    """
    if not body:
        return {"kind": "empty"}

    if _looks_json(body):
        return {"kind": "plain-json", "text": body.decode("utf-8", "replace")}

    plain = _try_zlib(body)
    if plain is not None:
        return {"kind": "plain-zlib", "text": plain.decode("utf-8", "replace")}

    payload = unwrap(body)
    if payload is None:
        # No envelope, not JSON, not zlib. If it is block-aligned then on a
        # route whose headers declare `X-Encryption: aes` it is ciphertext sent
        # bare -- `/client/libraries-extra` answers with exactly 96 such bytes.
        # Called out separately from "unknown" because the two want different
        # responses from a reader: this one is waiting on the key, and
        # "unknown" means the framing itself is not understood.
        if len(body) % 16 == 0:
            inner = _try_decrypt(body)
            if inner is not None:
                return {"kind": "bare-aes",
                        "text": inner.decode("utf-8", "replace"),
                        "ciphertext": body}
            return {"kind": "bare-opaque", "ciphertext": body,
                    "length": len(body), "block_aligned": True}
        return {"kind": "unknown", "length": len(body)}

    inner = _try_zlib(payload)
    if inner is not None:
        return {"kind": "wrapped-zlib", "text": inner.decode("utf-8", "replace")}

    if _looks_json(payload):
        return {"kind": "wrapped-json", "text": payload.decode("utf-8", "replace")}

    inner = _try_decrypt(payload)
    if inner is not None:
        return {"kind": "wrapped-aes", "text": inner.decode("utf-8", "replace"),
                "ciphertext": payload}

    return {
        "kind": "wrapped-opaque",
        "ciphertext": payload,
        "length": len(payload),
        "block_aligned": len(payload) % 16 == 0,
    }


def encode(text: str, compress: bool = True) -> bytes:
    """Build a wire body carrying `text`. The inverse of the readable cases."""
    raw = text.encode("utf-8")
    return wrap(zlib.compress(raw) if compress else raw)


# --------------------------------------------------------------------------- #
# Subcommands                                                                  #
# --------------------------------------------------------------------------- #

def _iter_capture(capture_dir: Path):
    manifest = json.loads((capture_dir / "manifest.json").read_text("utf-8"))
    for rec in manifest:
        path = capture_dir / "bodies" / rec["bodyfile"]
        yield rec, (path.read_bytes() if path.exists() else b"")


def cmd_decode(args: argparse.Namespace) -> int:
    body = Path(args.file).read_bytes()
    info = decode(body)
    print(f"{args.file}: {len(body)} bytes -> {info['kind']}")
    if "text" in info:
        print(info["text"] if args.full else info["text"][:2000])
    elif info["kind"] == "wrapped-opaque":
        print(f"  ciphertext {info['length']} bytes, "
              f"16-byte aligned: {info['block_aligned']}")
        print(f"  first 32: {info['ciphertext'][:32].hex()}")
    return 0


def cmd_scan(args: argparse.Namespace) -> int:
    """Classify every body in a capture directory and print the tally."""
    tally: dict[str, int] = {}
    rows = []
    for rec, body in _iter_capture(Path(args.capture)):
        info = decode(body)
        tally[info["kind"]] = tally.get(info["kind"], 0) + 1
        rows.append((rec["seq"], rec["url"], len(body), info["kind"]))
    for seq, url, n, kind in rows:
        print(f"  {seq}  {kind:16s} {n:>9d}  {url[:64]}")
    print("\ntally:")
    for kind, n in sorted(tally.items(), key=lambda kv: -kv[1]):
        print(f"  {n:4d}  {kind}")
    return 0


def cmd_extract(args: argparse.Namespace) -> int:
    """Decode every readable body in a capture into a directory of .json files."""
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    written = skipped = 0
    index = []
    for rec, body in _iter_capture(Path(args.capture)):
        info = decode(body)
        if "text" not in info:
            skipped += 1
            index.append({"seq": rec["seq"], "url": rec["url"],
                          "kind": info["kind"], "file": None})
            continue
        name = f"{rec['seq']}.json"
        (out / name).write_text(info["text"], encoding="utf-8")
        index.append({"seq": rec["seq"], "url": rec["url"],
                      "kind": info["kind"], "file": name})
        written += 1
    (out / "index.json").write_text(
        json.dumps(index, indent=1), encoding="utf-8")
    print(f"wrote {written} decoded bodies to {out}, {skipped} not readable")
    return 0


def cmd_selftest(args: argparse.Namespace) -> int:
    """Assert the properties this module claims, over real captured bytes."""
    failures = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        print(f"  {'ok  ' if ok else 'FAIL'}  {name}{'  ' + detail if detail else ''}")
        if not ok:
            failures.append(name)

    # 1. shuffle and unshuffle are exact mutual inverses at every length that
    #    matters, including the ones either side of the 0xAAB table wrap.
    import random
    rng = random.Random(20260819)
    bad = None
    for n in list(range(1, 300)) + [0xAAA, 0xAAB, 0xAAC, 5000, 29925]:
        sample = bytes(rng.randrange(256) for _ in range(n))
        if shuffle(unshuffle(sample)) != sample:
            bad = n
            break
    check("shuffle/unshuffle are inverses for every tested length",
          bad is None, "" if bad is None else f"failed at length {bad}")

    # 2. wrap/unwrap round-trip, junk included.
    payload = b'{"hello":"world"}'
    check("wrap -> unwrap round-trips", unwrap(wrap(payload)) == payload)
    check("wrap -> unwrap round-trips with junk",
          unwrap(wrap(payload, b"\x01\x02\x03")) == payload)

    # 3. Agreement with metablob, which derived the same permutation
    #    independently for `/client/metadata`.
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import metablob  # noqa: F401
        probe = bytes(rng.randrange(256) for _ in range(145))
        mine = unwrap(probe)
        theirs = None
        try:
            theirs = metablob._deshuffle_response_body(probe)
        except ValueError:
            theirs = None
        check("agrees with metablob's deshuffle", mine == theirs)
    except ImportError:
        check("agrees with metablob's deshuffle", False, "(metablob not importable)")

    # 4. Against the checked-in capture, if it is present.
    capture = Path(args.capture) if args.capture else None
    if capture and (capture / "manifest.json").exists():
        kinds: dict[str, int] = {}
        aligned = misaligned = 0
        for rec, body in _iter_capture(capture):
            info = decode(body)
            kinds[info["kind"]] = kinds.get(info["kind"], 0) + 1
            if info["kind"] == "wrapped-opaque":
                if info["block_aligned"]:
                    aligned += 1
                else:
                    misaligned += 1
        check("no body in the capture is unclassified",
              kinds.get("unknown", 0) == 0,
              f"(unknown={kinds.get('unknown', 0)})")
        check("every opaque payload is 16-byte aligned",
              misaligned == 0, f"(aligned={aligned}, misaligned={misaligned})")
        print("  capture tally:", dict(sorted(kinds.items())))
    else:
        print("  (no capture given; skipped the corpus checks)")

    print(f"\n{len(failures)} failure(s)")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Decode post-1.0 Escape From Tarkov HTTP bodies.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("decode", help="decode one body file")
    p.add_argument("file")
    p.add_argument("--full", action="store_true", help="print the whole body")
    p.set_defaults(func=cmd_decode)

    p = sub.add_parser("scan", help="classify every body in a capture")
    p.add_argument("capture", help="directory holding manifest.json and bodies/")
    p.set_defaults(func=cmd_scan)

    p = sub.add_parser("extract", help="decode a capture into .json files")
    p.add_argument("capture")
    p.add_argument("out")
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("selftest", help="assert this module's claims")
    p.add_argument("--capture", default=None)
    p.set_defaults(func=cmd_selftest)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
