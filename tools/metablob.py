#!/usr/bin/env python3
"""metablob.py -- obtain and install the EFT /client/metadata section-layout blob.

Post-1.0 Escape from Tarkov ships an encrypted IL2CPP ``global-metadata.dat``.
During ``il2cpp_init`` GameAssembly.dll POSTs ``{"version":..,"key":..}`` to the
backend's ``/client/metadata`` and receives ``{"data":{"value":"<hex>"}}`` -- a
per-VERSION section-layout blob it uses to finish decrypting its own metadata.

aowlspt's emulator has to serve that endpoint. This dev utility makes obtaining
and installing a version's layout blob a two-minute chore. It is offline: it
makes NO network calls. It reads BSG's own owned binary and (optionally) a
Fiddler capture the user already made, and writes one small JSON into aowlspt.

Everything here is a faithful port of the reference tool XM-MetadataDecrypt
(MIT): ``eft_metadata_key/core.py`` (the offline header transform -> version +
internalKey) and ``gui/MetadataDecryptGui/MetadataDecryptor.cs`` (the full
decrypt pipeline, used here only to VERIFY a recovered layout).

Subcommands:
  derive           <gamedir>                 offline: version, internalKey, requestKey
  extract-capture  <gamedir> <capture.txt>   pull layout from a Fiddler capture, verify, install
  from-metadata    <decrypted.dat> <version> reconstruct a blob from a decrypted header (experimental)
  install          <version> <blob|hex>      write mods/tarkov/data/metadata/<version>.json
  status           <gamedir>                 report install version and whether a blob exists
  selftest         [gamedir]                 assert D:\\Games\\Tarkov -> 1.1.0.1.46777 / 0x876F9333
  test                                       self-contained unit tests (no game files needed)

Stdlib only. Cross-platform, but see METABLOB.md: the request key / capture
subKey derive from the metadata file's on-disk CREATION time, which only Python
on Windows reports reliably -- run there, and never copy the .dat first.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

# --------------------------------------------------------------------------- #
# Constants (read directly off the game's own routines; plain integers, not    #
# secrets, stable across builds).                                              #
# --------------------------------------------------------------------------- #

HEADER_XOR_SIZE = 0x200
IL2CPP_MAGIC = 0xFAB11BAF          # "AF 1B B1 FA" little-endian
IL2CPP_FORMAT_VERSION = 0x1F       # 31 -> "1F 00 00 00"

_MULTIPLIER = 0x1657A1
_ADDEND = 0x3CF8479F
_MODULUS = 0xC4653218
_KEY_MODULUS = 0x8BA
_SUB_KEY_MODULUS = 0xA
_SUB_KEY_OFFSET = 5

_WINDOWS_EPOCH_OFFSET_SECONDS = 11644473600
_FILETIME_TICKS_PER_SECOND = 10_000_000

# Where the installed blob lives inside aowlspt. Coordinated with the
# /client/metadata route: mods/tarkov/data/metadata/<version>.json holding
# {"version","internalKey","valueHex"} where valueHex is the UN-shuffled raw
# layout (version-constant; the runtime re-shuffles it per client subKey).
_REPO_ROOT = Path(__file__).resolve().parent.parent
_METADATA_DIR = _REPO_ROOT / "mods" / "tarkov" / "data" / "metadata"

# Cached 1.0.x server `value` blobs from MetadataDecryptor.cs -- used only as
# length/parse test vectors (we have no 1.0.x game file to fully decrypt).
_CACHED_VALUES = {
    "1.0.6.5.46221": "305c009900e00de0c00c00041d4103a1d15401173f56c0a42000900881001c060099b003090000240002400c64b40010a01010b0c400090b00a0b049f7800040000e100000e095fbc84470101b18085890acb0bf98090438f420d00c5d710f40b90f33d810004008",
    "1.0.5.0.45581": "00d031510001000e0dc00059d02386c30509406cc0820094fdd5ef04b0ab61c0b04200cb1404099803e8b00d0098a0800e000014c0140100700c09000201191004100022a00f000a240400e00f013049807b00005140c0e0c561049ac04f10010500c1ef464f00040b1240a01cc01049250820ce600210107207c71f40b800d80301801e1a0158af00ec2800026fd0d4",
    "1.0.4.1.44155": "20f010c5003cf400700b90001f74ba3134fd04cd338200da270081029810c84f3010b095041000c7002a0100b7b0fbe107c00000c120081907f031b206880f080e00100117d0221030200126808102c88080005a00090c00ec48830079a10408c00ffd4890086ee108100a8000cd01301d000680780010004019d0080041181800ccc7d0a201001ce12408a0b0a10100",
}


# --------------------------------------------------------------------------- #
# Primitive helpers (ports of core.py / MetadataDecryptor.cs)                   #
# --------------------------------------------------------------------------- #

def _u32(value: int) -> int:
    return value & 0xFFFFFFFF


def _nibble_shuffle(value: int) -> int:
    return _u32(
        ((((value & 0x66666666) | (8 * (value & 0xF1111111)) | ((value >> 3) & 0x11111111)) >> 2) & 0x33333333)
        | (4 * ((value & 0x62222222) | ((8 * (value & 0xF1111111)) & 0xF3333333) | ((value >> 3) & 0x11111111)))
    )


def _transform_key(value: int) -> int:
    """The client's ubiquitous key transform: (value%0x8BA)*mul+add mod modulus."""
    return _u32(((value % _KEY_MODULUS) * _MULTIPLIER + _ADDEND) % _MODULUS)


def _creation_filetime_low32(path: Path) -> int:
    """Low 32 bits of the file's Windows-creation-time FILETIME.

    On Windows Python this is the file's true creation time (st_birthtime, or
    st_ctime which is creation time on NT). On POSIX/WSL there is usually no
    birth time and st_ctime is *change* time, so the value -- and any subKey /
    request key derived from it -- will be wrong. See METABLOB.md.
    """
    stat = path.stat()
    if hasattr(stat, "st_birthtime_ns"):
        unix_ns = stat.st_birthtime_ns
    elif os.name == "nt" and hasattr(stat, "st_ctime_ns"):
        unix_ns = stat.st_ctime_ns
    elif hasattr(stat, "st_birthtime"):
        unix_ns = int(stat.st_birthtime * 1_000_000_000)
    else:
        unix_ns = int(stat.st_ctime * 1_000_000_000)
    filetime = unix_ns // 100 + _WINDOWS_EPOCH_OFFSET_SECONDS * _FILETIME_TICKS_PER_SECOND
    return _u32(filetime)


def _sub_key_from_filetime(filetime_low32: int) -> int:
    """subKey in [5, 14]: TransformKey(filetime)%0xA + 5."""
    return _transform_key(filetime_low32) % _SUB_KEY_MODULUS + _SUB_KEY_OFFSET


# --------------------------------------------------------------------------- #
# Hex-string layout shuffle (port of MetadataDecryptor.FetchHeaderProperties)  #
#                                                                              #
# The server `value` is a permutation of the true layout's hex string, keyed   #
# by TransformKey(subKey). Applying the ASCENDING shuffle with the right subKey #
# recovers the true (version-constant) layout. The DESCENDING pass is its exact #
# inverse -- what the emulator route applies to re-shuffle the stored raw       #
# layout for each client's own subKey.                                          #
# --------------------------------------------------------------------------- #

def shuffle_layout_hex(value: str, sub_key: int) -> str:
    """served value -> true layout. Ascending Fisher-Yates over hex chars."""
    transformed = _transform_key(sub_key)
    chars = list(value)
    n = len(chars)
    for i in range(n):
        j = transformed % (i + 1)
        chars[i], chars[j] = chars[j], chars[i]
    return "".join(chars)


def unshuffle_layout_hex(value: str, sub_key: int) -> str:
    """true layout -> served value. Descending inverse of shuffle_layout_hex."""
    transformed = _transform_key(sub_key)
    chars = list(value)
    n = len(chars)
    for i in range(n - 1, -1, -1):
        j = transformed % (i + 1)
        chars[i], chars[j] = chars[j], chars[i]
    return "".join(chars)


@dataclass(frozen=True)
class HeaderProperty:
    data_size: int
    data_offset: int


def parse_layout(layout_hex: str) -> list[HeaderProperty]:
    """Parse a (raw, un-shuffled) layout hex string into (size, offset) records.

    Each record is 16 hex chars: 8 hex big-endian DataSize then 8 hex DataOffset.
    """
    if len(layout_hex) % 16 != 0:
        raise ValueError(f"layout length {len(layout_hex)} is not a multiple of 16 hex chars")
    props: list[HeaderProperty] = []
    for i in range(len(layout_hex) // 16):
        chunk = layout_hex[i * 16:i * 16 + 16]
        data_size = int(chunk[0:8], 16)
        data_offset = int(chunk[8:16], 16)
        props.append(HeaderProperty(data_size, data_offset))
    return props


def layout_is_sane(props: list[HeaderProperty], file_size: int) -> bool:
    """A cheap pre-filter: every section must fit inside the file.

    It is ONLY a pre-filter -- the authoritative test is `verify_decrypt`, which
    runs the real decrypt and checks the IL2CPP magic. An earlier version of this
    also required strictly-ascending offsets and rejected zero-size sections; a
    real 1.1.0.1.46777 layout (18 records, verified) has neither property -- its
    sections are out of offset order and two are legitimately zero-size -- so
    those extra constraints threw out the one true subKey. Keep this loose and
    let the decrypt decide."""
    if not props:
        return False
    for p in props:
        # A section's bytes must lie within the file. Zero-size and out-of-order
        # are both fine; a wrong subKey shows up as an offset past the end.
        if p.data_offset > file_size or p.data_offset + p.data_size > file_size:
            return False
    return True


# --------------------------------------------------------------------------- #
# Offline derive (port of core.py)                                             #
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class MetadataInfo:
    game_version: str
    internal_key: int
    sub_key: int
    metadata_request_key: int

    @property
    def internal_key_hex(self) -> str:
        return f"0x{self.internal_key:08X}"


def find_metadata_file(game_dir: str | os.PathLike) -> Path:
    path = Path(game_dir) / "EscapeFromTarkov_Data" / "il2cpp_data" / "Metadata" / "global-metadata.dat"
    if not path.is_file():
        raise FileNotFoundError(f"global-metadata.dat not found under {game_dir!s}")
    return path


def _decrypt_header_words(data: bytearray) -> tuple[int, int, int]:
    """XOR the 0x200-byte header against the next 0x200 bytes, nibble-shuffle the
    header-pointed words, and return (internal_key, data_start, count)."""
    if len(data) < HEADER_XOR_SIZE * 2:
        raise ValueError("global-metadata.dat is too small to contain the expected header")
    if struct.unpack_from("<I", data, 0)[0] == IL2CPP_MAGIC:
        raise ValueError(
            "global-metadata.dat already starts with the plain IL2CPP magic -- "
            "this file isn't BSG-header-transformed, or was already decrypted upstream"
        )
    for i in range(HEADER_XOR_SIZE):
        data[i] ^= data[i + HEADER_XOR_SIZE]

    size = struct.unpack_from("<I", data, 0)[0]
    offset = struct.unpack_from("<I", data, 4)[0]
    start = int(offset)
    count = int(size // 4)
    if start < 8 or count <= 0 or start + count * 4 > len(data):
        raise ValueError("global-metadata.dat header layout is invalid (unexpected size/offset fields)")

    internal_key = 0
    for index in range(count):
        pos = start + index * 4
        value = _nibble_shuffle(struct.unpack_from("<I", data, pos)[0])
        struct.pack_into("<I", data, pos, value)
        if index == 0:
            internal_key = value
    return internal_key, start, count


def derive(metadata_path: str | os.PathLike) -> MetadataInfo:
    path = Path(metadata_path)
    data = bytearray(path.read_bytes())
    internal_key, start, _count = _decrypt_header_words(data)

    end = start + 4
    while end < len(data) and data[end] != 0:
        end += 1
    version = data[start + 4:end].decode("ascii", errors="strict")
    if not (0 < len(version) <= 64):
        raise ValueError("global-metadata.dat header decoded to an implausible version string")

    sub_key = _sub_key_from_filetime(_creation_filetime_low32(path))
    request_key = _transform_key(_u32(internal_key + sub_key))
    return MetadataInfo(version, internal_key, sub_key, request_key)


def derive_from_game_dir(game_dir: str | os.PathLike) -> MetadataInfo:
    return derive(find_metadata_file(game_dir))


# --------------------------------------------------------------------------- #
# Full decrypt pipeline (port of MetadataDecryptor.cs) -- used only to VERIFY  #
# a recovered layout against the real encrypted file.                          #
# --------------------------------------------------------------------------- #

def _get_key_from_header_list(props: list[HeaderProperty]) -> int:
    b0 = b1 = b2 = b3 = 0xAA
    for p in props:
        size = p.data_size
        offset = p.data_offset
        b0 ^= ((size & 0xFF) ^ ((offset >> 24) & 0xFF)) & 0xFF
        b1 ^= (((size >> 8) & 0xFF) ^ ((offset >> 16) & 0xFF)) & 0xFF
        b2 ^= (((size >> 16) & 0xFF) ^ ((offset >> 8) & 0xFF)) & 0xFF
        b3 ^= ((offset & 0xFF) ^ ((size >> 24) & 0xFF)) & 0xFF
    return _u32(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))


def _apply_keyed_permutation(buffer: bytearray, secret_key: int) -> None:
    if len(buffer) <= 1:
        return
    swap_base = _transform_key(secret_key)
    for i in range(len(buffer) - 1, 0, -1):
        j = swap_base % (i + 1)
        buffer[i], buffer[j] = buffer[j], buffer[i]


def _decrypt_metadata_body(metadata: bytearray, props: list[HeaderProperty]) -> None:
    header_list_key = _get_key_from_header_list(props)
    key_stream = bytearray(len(metadata))
    for i in range(len(key_stream)):
        key_stream[i] = (i + 2 * (i // 0xFE) + 1) & 0xFF
    _apply_keyed_permutation(key_stream, header_list_key)
    for i in range(HEADER_XOR_SIZE, len(metadata)):
        metadata[i] ^= key_stream[i]


def _reinsert_headers(metadata: bytearray, props: list[HeaderProperty], key: int) -> None:
    header_properties_count = 31
    transformed = _transform_key(key)
    positions: list[int] = []
    available = list(range(1, header_properties_count + 1))
    for i in range(len(props)):
        index = transformed % (header_properties_count - i)
        positions.append(available[index])
        del available[index]
    positions.sort()

    used_size = len(metadata) - 8 * len(positions)
    for i in range(len(positions)):
        offset = positions[i] * 8
        # Buffer.BlockCopy(metadata, offset, metadata, offset+8, used_size-offset)
        metadata[offset + 8:offset + 8 + (used_size - offset)] = metadata[offset:offset + (used_size - offset)]
        struct.pack_into("<I", metadata, offset, props[i].data_size)
        struct.pack_into("<I", metadata, offset + 4, props[i].data_offset)
        used_size += 8

    for i in range(header_properties_count):
        base = 8 + i * 8
        data_size = struct.unpack_from("<I", metadata, base)[0]
        data_offset = struct.unpack_from("<I", metadata, base + 4)[0]
        struct.pack_into("<I", metadata, base, data_offset)
        struct.pack_into("<I", metadata, base + 4, data_size)


def _reorder_type_definitions(metadata: bytearray, key: int) -> None:
    field_count = 26
    type_def_offset_pos = 160
    type_def_size_pos = 164
    type_def_struct_size = 88

    transformed = _transform_key(key)
    field_order = list(range(field_count))
    for i in range(field_count):
        frm = field_count - 1 - i
        to = transformed % (frm + 1)
        field_order[frm], field_order[to] = field_order[to], field_order[frm]

    # Exact field-size list from MetadataDecryptor.cs: 16 fours, 8 twos, 2 fours.
    field_sizes = [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
                   4, 4, 4,
                   2, 2, 2, 2, 2, 2, 2, 2,
                   4, 4]

    field_offsets = [0] * field_count
    running = 0
    for i in range(field_count):
        field = field_order[i]
        field_offsets[field] = running
        running += field_sizes[field]

    raw_offset = struct.unpack_from("<i", metadata, type_def_offset_pos)[0]
    raw_size = struct.unpack_from("<I", metadata, type_def_size_pos)[0]

    rel = 0
    while rel < raw_size:
        entry_offset = raw_offset + rel
        temp = bytearray(type_def_struct_size)
        dst = 0
        for field in range(field_count):
            size = field_sizes[field]
            src = entry_offset + field_offsets[field]
            temp[dst:dst + size] = metadata[src:src + size]
            dst += size
        metadata[entry_offset:entry_offset + type_def_struct_size] = temp
        rel += type_def_struct_size


def decrypt_with_layout(metadata_bytes: bytes, props: list[HeaderProperty]) -> bytes:
    """Full decrypt of an encrypted global-metadata.dat given its TRUE layout.

    Mirrors MetadataDecryptor.Decrypt but takes the already-recovered layout
    (list of HeaderProperty) instead of a Fiddler capture. Returns the decrypted
    bytes. Used for verification only."""
    metadata = bytearray(metadata_bytes)
    magic = struct.unpack_from("<I", metadata, 0)[0]
    if magic == IL2CPP_MAGIC:
        return bytes(metadata)  # already plain

    # header transform -> internalKey ("key"), then restore standard header
    for i in range(HEADER_XOR_SIZE):
        metadata[i] ^= metadata[i + HEADER_XOR_SIZE]
    size = struct.unpack_from("<I", metadata, 0)[0]
    offset = struct.unpack_from("<I", metadata, 4)[0]
    data_start = int(offset)
    count = int(size // 4)
    key = 0
    for i in range(count):
        pos = data_start + i * 4
        v = _nibble_shuffle(struct.unpack_from("<I", metadata, pos)[0])
        struct.pack_into("<I", metadata, pos, v)
        if i == 0:
            key = v
    struct.pack_into("<I", metadata, 0, IL2CPP_MAGIC)
    struct.pack_into("<I", metadata, 4, IL2CPP_FORMAT_VERSION)

    _decrypt_metadata_body(metadata, props)
    _reinsert_headers(metadata, props, key)
    _reorder_type_definitions(metadata, key)
    return bytes(metadata)


def verify_decrypt(metadata_bytes: bytes, props: list[HeaderProperty]) -> tuple[bool, str]:
    """Decrypt and check the output looks like real IL2CPP v31 metadata."""
    try:
        out = decrypt_with_layout(metadata_bytes, props)
    except Exception as exc:  # noqa: BLE001 -- surface the reason to the caller
        return False, f"decrypt raised: {exc!r}"
    if out[:4] != b"\xAF\x1B\xB1\xFA":
        return False, f"bad magic: {out[:4].hex(' ')}"
    if out[4:8] != b"\x1F\x00\x00\x00":
        return False, f"bad format version: {out[4:8].hex(' ')}"
    if b"System.Object" not in out:
        return False, "decrypted output does not contain 'System.Object'"
    return True, "magic AF 1B B1 FA, version 31, contains System.Object"


# --------------------------------------------------------------------------- #
# Fiddler capture parsing (port of ExtractResponseJsonFromCaptureFile +        #
# RequestShuffleEncryption.DeShuffle)                                          #
# --------------------------------------------------------------------------- #

def _deshuffle_response_body(body: bytes) -> bytes:
    """Length-keyed byte deshuffle of a /client/metadata response body -> JSON."""
    mod = 0x8ED7A18D
    multiplier = 1624453
    addend = 1023920427
    cursor_wrap = 0xA53F260DDB0

    backup = bytearray(body)
    start_entry = len(backup) % 0xAAB
    table_size = start_entry + len(backup)

    table = [0] * table_size
    cursor = 0x65F6D
    for i in range(table_size):
        table[i] = (multiplier * cursor + addend) % mod
        cursor += 1
        if cursor > cursor_wrap:
            cursor = 0

    for i in range(1, len(backup)):
        swap_index = table[i + start_entry] % i
        backup[i], backup[swap_index] = backup[swap_index], backup[i]

    size = struct.unpack_from("<i", backup, 0)[0]
    if size <= 0 or size > len(backup) - 4:
        raise ValueError(
            "deshuffled response failed its sanity check -- the captured body may be truncated "
            "or corrupted (e.g. a text editor changed line endings). Re-save it fresh from Fiddler."
        )
    return bytes(backup[4:4 + size])


def extract_response_json_from_capture(capture_path: str | os.PathLike) -> str:
    data = Path(capture_path).read_bytes()
    text = data.decode("latin-1")  # 1:1 byte<->char, safe for locating ASCII markers

    req_idx = text.rfind("/client/metadata")
    if req_idx < 0:
        raise ValueError(
            "no /client/metadata request found in this capture file (narrow Fiddler's filter "
            "to gw-pvp.escapefromtarkov.com and re-save)."
        )
    resp_idx = text.find("HTTP/1.1 200", req_idx)
    if resp_idx < 0:
        raise ValueError(
            "no 200 OK response found after the /client/metadata request -- if the real client's "
            "call failed too, capture a fresh one."
        )
    header_end = text.find("\r\n\r\n", resp_idx)
    if header_end < 0:
        raise ValueError("could not find the end of the response headers in this capture.")

    headers = text[resp_idx:header_end]
    content_length = _read_content_length(headers)
    body_start = header_end + 4
    if body_start + content_length > len(data):
        raise ValueError(
            "capture file is truncated -- the response body is shorter than its declared "
            "Content-Length. Re-save it from Fiddler (Save > Selected Sessions > Request & Response)."
        )
    body = data[body_start:body_start + content_length]
    deshuffled = _deshuffle_response_body(body)
    return deshuffled.decode("utf-8")


def _read_content_length(headers: str) -> int:
    for line in headers.split("\r\n"):
        if line.lower().startswith("content-length:"):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                pass
    raise ValueError("response has no Content-Length header; can't determine body length.")


def extract_value_from_capture(capture_path: str | os.PathLike) -> str:
    """Return the raw (still subKey-shuffled) `value` hex string from a capture."""
    response_json = extract_response_json_from_capture(capture_path)
    obj = json.loads(response_json)
    value = (obj.get("data") or {}).get("value")
    if not value:
        raise ValueError(
            f"server response has no data.value (err={obj.get('err')}, errmsg={obj.get('errmsg')}). "
            "Make sure the captured response is a genuine 200 OK reply to /client/metadata."
        )
    return value


def recover_layouts_from_value(shuffled_value: str, file_size: int) -> list[tuple[str, int]]:
    """Brute-force subKey 5..14 to turn a captured (subKey-shuffled) value into the
    version-constant raw layout. Returns every (raw_layout_hex, sub_key) that
    passes the cheap within-file pre-filter, in subKey order.

    A capture from ANY install of the same version works: the value is shuffled
    with THAT machine's subKey, but the recovered raw layout is identical for
    everyone. The pre-filter usually leaves more than one candidate, so the
    caller settles it authoritatively with `verify_decrypt` -- the real subKey is
    the one whose layout actually decrypts the metadata to the IL2CPP magic."""
    hits: list[tuple[str, int]] = []
    for sub_key in range(_SUB_KEY_OFFSET, _SUB_KEY_OFFSET + _SUB_KEY_MODULUS):
        candidate = shuffle_layout_hex(shuffled_value, sub_key)
        try:
            props = parse_layout(candidate)
        except ValueError:
            continue
        if layout_is_sane(props, file_size):
            hits.append((candidate, sub_key))
    if not hits:
        raise ValueError(
            "no candidate subKey (5..14) produced an in-file layout from this value. "
            "The capture may be for a different game version than the supplied gamedir."
        )
    return hits


# --------------------------------------------------------------------------- #
# from-metadata: reconstruct a blob from an already-decrypted header           #
# --------------------------------------------------------------------------- #

def layout_from_decrypted_header(decrypted_bytes: bytes) -> str:
    """Build a full-31-section layout hex string from a decrypted IL2CPP header.

    A decrypted global-metadata.dat begins with the standard
    Il2CppGlobalMetadataHeader: uint32 magic, uint32 version, then 32 int32
    (offset,size) section pairs -- i.e. the section table. We emit all 31
    relocatable sections as (size,offset) records (the same 16-hex encoding the
    server blob uses).

    IMPORTANT: this is a best-effort, UNVERIFIED reconstruction. BSG's real blob
    is a version-specific SUBSET of these sections (observed captures carry 13 or
    18 records, not 31), chosen by an internalKey-derived permutation. From a
    decrypted file alone that subset (and its size) is not recoverable, so a blob
    produced here will very likely NOT satisfy a real client. Prefer
    extract-capture. See METABLOB.md."""
    if decrypted_bytes[:4] != b"\xAF\x1B\xB1\xFA":
        raise ValueError("this file does not start with the plain IL2CPP magic AF 1B B1 FA")
    header_properties_count = 31
    parts: list[str] = []
    for i in range(header_properties_count):
        base = 8 + i * 8
        data_offset = struct.unpack_from("<I", decrypted_bytes, base)[0]
        data_size = struct.unpack_from("<I", decrypted_bytes, base + 4)[0]
        parts.append(f"{data_size:08x}{data_offset:08x}")
    return "".join(parts)


# --------------------------------------------------------------------------- #
# install / status                                                             #
# --------------------------------------------------------------------------- #

def blob_path(version: str) -> Path:
    return _METADATA_DIR / f"{version}.json"


def install_blob(version: str, internal_key: int, value_hex: str) -> Path:
    value_hex = value_hex.strip().lower()
    int(value_hex, 16)  # validate hex
    if len(value_hex) % 16 != 0:
        raise ValueError(f"valueHex length {len(value_hex)} is not a multiple of 16 hex chars")
    _METADATA_DIR.mkdir(parents=True, exist_ok=True)
    out = blob_path(version)
    payload = {
        "version": version,
        "internalKey": f"0x{internal_key:08X}",
        "valueHex": value_hex,
    }
    text = json.dumps(payload, indent=2) + "\n"
    out.write_bytes(text.encode("utf-8"))  # LF, no BOM
    return out


def load_blob_value(arg: str) -> str:
    """A blob argument may be a file path (raw hex, or the installed JSON) or hex."""
    p = Path(arg)
    if p.is_file():
        raw = p.read_text(encoding="utf-8").strip()
        if raw.startswith("{"):
            return json.loads(raw)["valueHex"]
        return raw.strip()
    return arg.strip()


# --------------------------------------------------------------------------- #
# Subcommand handlers                                                          #
# --------------------------------------------------------------------------- #

def cmd_derive(args: argparse.Namespace) -> int:
    info = derive_from_game_dir(args.gamedir)
    print(f"gameVersion         {info.game_version}")
    print(f"internalKey         {info.internal_key_hex}")
    print(f"subKey              {info.sub_key}  (from this file's creation time)")
    print(f"metadataRequestKey  {info.metadata_request_key}")
    if os.name != "nt":
        print("WARNING: not on Windows -- subKey/metadataRequestKey derive from the file's "
              "creation time, which is unreliable off Windows. version/internalKey are fine.",
              file=sys.stderr)
    return 0


def cmd_extract_capture(args: argparse.Namespace) -> int:
    meta_path = find_metadata_file(args.gamedir)
    meta_bytes = meta_path.read_bytes()
    file_size = len(meta_bytes)

    info = derive(meta_path)
    print(f"gameVersion   {info.game_version}")
    print(f"internalKey   {info.internal_key_hex}")

    shuffled_value = extract_value_from_capture(args.capture)
    print(f"captured value: {len(shuffled_value)} hex chars ({len(shuffled_value)//16} records once parsed)")

    candidates = recover_layouts_from_value(shuffled_value, file_size)
    print(f"{len(candidates)} candidate subKey(s) survived the in-file pre-filter: "
          f"{[sk for _, sk in candidates]}")

    # The authoritative test: the real layout is the one that decrypts the
    # metadata to the IL2CPP magic. Try each surviving candidate through the full
    # decrypt and keep the one that works. This is what makes a foreign capture
    # (shuffled with someone else's subKey) resolve correctly too.
    raw_layout = None
    for candidate, sub_key in candidates:
        props = parse_layout(candidate)
        ok, detail = verify_decrypt(meta_bytes, props)
        if ok:
            raw_layout = candidate
            print(f"subKey {sub_key}: {len(props)} sections, "
                  f"offsets {props[0].data_offset}..{props[-1].data_offset}")
            print(f"verify OK: {detail}")
            break
        else:
            print(f"subKey {sub_key}: did not decrypt ({detail})")
    if raw_layout is None:
        print("VERIFY FAILED: no candidate layout decrypted the metadata. The "
              "capture and the gamedir may be different builds.", file=sys.stderr)
        return 2

    out = install_blob(info.game_version, info.internal_key, raw_layout)
    print(f"installed {out}")
    return 0


def cmd_from_metadata(args: argparse.Namespace) -> int:
    decrypted = Path(args.decrypted).read_bytes()
    raw_layout = layout_from_decrypted_header(decrypted)
    props = parse_layout(raw_layout)
    # Re-derive: confirm the encoding round-trips back to the same header pairs.
    for i, p in enumerate(props):
        base = 8 + i * 8
        off = struct.unpack_from("<I", decrypted, base)[0]
        sz = struct.unpack_from("<I", decrypted, base + 4)[0]
        assert (p.data_size, p.data_offset) == (sz, off), "encode/decode mismatch"
    print(f"reconstructed a full-31-section layout ({len(raw_layout)} hex chars) from the header.")
    print("WARNING: experimental/UNVERIFIED. The real blob is a version-specific SUBSET "
          "(captures show 13 or 18 records, not 31) and is not runtime-verifiable from a "
          "decrypted file. Prefer extract-capture. See METABLOB.md.")
    # internalKey unknown from a decrypted file; store 0x0 as a placeholder.
    out = install_blob(args.version, 0, raw_layout)
    print(f"installed {out} (internalKey placeholder 0x00000000 -- fill in from `derive`)")
    return 0


def cmd_install(args: argparse.Namespace) -> int:
    value_hex = load_blob_value(args.blob)
    internal_key = int(args.internal_key, 16) if args.internal_key else 0
    out = install_blob(args.version, internal_key, value_hex)
    print(f"installed {out}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    try:
        info = derive_from_game_dir(args.gamedir)
        print(f"install version   {info.game_version}")
        print(f"internalKey       {info.internal_key_hex}")
        version = info.game_version
    except Exception as exc:  # noqa: BLE001
        print(f"could not read install: {exc}", file=sys.stderr)
        version = None

    if version:
        bp = blob_path(version)
        if bp.is_file():
            data = json.loads(bp.read_text(encoding="utf-8"))
            print(f"blob installed    YES  {bp}")
            print(f"                  valueHex {len(data['valueHex'])} hex chars, "
                  f"internalKey {data.get('internalKey')}")
        else:
            print(f"blob installed    NO   (expected {bp})")
    return 0


def cmd_selftest(args: argparse.Namespace) -> int:
    import gamepaths as _gp
    gamedir = args.gamedir or _gp.gamedir()
    info = derive_from_game_dir(gamedir)
    assert info.game_version == "1.1.0.1.46777", f"version mismatch: {info.game_version}"
    assert info.internal_key == 0x876F9333, f"internalKey mismatch: {info.internal_key_hex}"
    print(f"selftest OK: {gamedir} -> {info.game_version} / {info.internal_key_hex}")
    if os.name == "nt":
        print(f"  (subKey {info.sub_key}, metadataRequestKey {info.metadata_request_key})")
    return 0


def cmd_test(_args: argparse.Namespace) -> int:
    import random

    # 1. shuffle/deshuffle are exact mutual inverses (round-trip) for every subKey.
    rng = random.Random(0xEF7)
    for sub_key in range(_SUB_KEY_OFFSET, _SUB_KEY_OFFSET + _SUB_KEY_MODULUS):
        for _ in range(20):
            n = rng.choice([16, 32, 208, 288])
            s = "".join(rng.choice("0123456789abcdef") for _ in range(n))
            assert shuffle_layout_hex(unshuffle_layout_hex(s, sub_key), sub_key) == s
            assert unshuffle_layout_hex(shuffle_layout_hex(s, sub_key), sub_key) == s
    print("PASS shuffle/deshuffle round-trip (mutual inverses) for subKey 5..14")

    # 2. subKey math: always in [5, 14].
    for x in range(0, 100000, 7):
        sk = _sub_key_from_filetime(x)
        assert 5 <= sk <= 14, sk
    print("PASS subKey always in [5,14]")

    # 3. transform_key matches the known reference value for the live install:
    #    metadataRequestKey = transform_key(0x876F9333 + 12) == 3132852448.
    assert _transform_key(_u32(0x876F9333 + 12)) == 3132852448
    print("PASS transform_key against live-install request key (internalKey 0x876F9333, subKey 12)")

    # 4. cached 1.0.x value blobs: length is a multiple of 16 and parses to
    #    (size,offset) records. (No 1.0.x game file, so full decrypt is NOT tested.)
    for version, value in _CACHED_VALUES.items():
        assert len(value) % 16 == 0, (version, len(value))
        props = parse_layout(value)
        assert len(props) == len(value) // 16
        print(f"PASS cached {version}: {len(value)} hex chars -> {len(props)} (size,offset) records")
    print("NOTE: the cached 1.0.x blobs cannot be full-decrypt-verified (no 1.0.x game file).")

    # 5. Fiddler capture plumbing: build a synthetic shuffled body + HTTP
    #    transcript and confirm the parser + body-deshuffle recover the value.
    def _encode_response_body(payload: bytes) -> bytes:
        # forward of _deshuffle_response_body: prepend LE size, then apply the
        # deshuffle swaps in reverse so deshuffle undoes them.
        mod, mul, add, wrap = 0x8ED7A18D, 1624453, 1023920427, 0xA53F260DDB0
        buf = bytearray(struct.pack("<i", len(payload)) + payload)
        # pad so length differs from payload+4 (exercises the size field)
        buf += b"\x00" * 5
        start_entry = len(buf) % 0xAAB
        table = []
        cursor = 0x65F6D
        for _ in range(start_entry + len(buf)):
            table.append((mul * cursor + add) % mod)
            cursor += 1
            if cursor > wrap:
                cursor = 0
        for i in range(len(buf) - 1, 0, -1):
            swap_index = table[i + start_entry] % i
            buf[i], buf[swap_index] = buf[swap_index], buf[i]
        return bytes(buf)

    sample_value = _CACHED_VALUES["1.0.4.1.44155"]
    payload = json.dumps({"err": 0, "data": {"value": sample_value}}).encode("utf-8")
    body = _encode_response_body(payload)
    assert _deshuffle_response_body(body) == payload
    transcript = (
        b"POST https://gw-pvp.escapefromtarkov.com/client/metadata HTTP/1.1\r\n"
        b"Host: gw-pvp.escapefromtarkov.com\r\n\r\n{}\r\n\r\n"
        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
    )
    import tempfile
    with tempfile.NamedTemporaryFile("wb", suffix=".txt", delete=False) as tf:
        tf.write(transcript)
        cap_path = tf.name
    try:
        assert extract_value_from_capture(cap_path) == sample_value
    finally:
        os.unlink(cap_path)
    print("PASS Fiddler capture parse + body deshuffle + Content-Length (synthetic round-trip)")

    print("ALL TESTS PASSED")
    return 0


# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="metablob", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("derive", help="offline: print version, internalKey, requestKey")
    d.add_argument("gamedir")
    d.set_defaults(func=cmd_derive)

    e = sub.add_parser("extract-capture", help="pull layout from a Fiddler capture, verify, install")
    e.add_argument("gamedir")
    e.add_argument("capture")
    e.set_defaults(func=cmd_extract_capture)

    f = sub.add_parser("from-metadata", help="reconstruct a blob from a decrypted header (experimental)")
    f.add_argument("decrypted")
    f.add_argument("version")
    f.set_defaults(func=cmd_from_metadata)

    i = sub.add_parser("install", help="write mods/tarkov/data/metadata/<version>.json")
    i.add_argument("version")
    i.add_argument("blob", help="raw hex, a file of raw hex, or an existing blob JSON")
    i.add_argument("--internal-key", default=None, help="internalKey hex, e.g. 0x876F9333")
    i.set_defaults(func=cmd_install)

    s = sub.add_parser("status", help="report install version and whether a blob exists")
    s.add_argument("gamedir")
    s.set_defaults(func=cmd_status)

    st = sub.add_parser("selftest", help="assert D:\\Games\\Tarkov -> 1.1.0.1.46777 / 0x876F9333")
    st.add_argument("gamedir", nargs="?", default=None)
    st.set_defaults(func=cmd_selftest)

    t = sub.add_parser("test", help="self-contained unit tests (no game files needed)")
    t.set_defaults(func=cmd_test)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
