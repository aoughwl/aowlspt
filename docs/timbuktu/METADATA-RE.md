# GameAssembly.dll — global-metadata.dat loader / decryptor: static RE findings

Target: `D:\Games\Tarkov\GameAssembly.dll` (123,891,024 bytes, x64, image base `0x180000000`,
Unity 2022.3.43f2 IL2CPP, build path `D:\BuildAgent\temp\buildTmp\unity-cheat-proof\...`).
Metadata: `EscapeFromTarkov_Data\il2cpp_data\Metadata\global-metadata.dat`, 27,776,072 bytes.

All work below is **pure static analysis** (pefile + capstone in WSL). The game was never run,
nothing was written to `D:\Games\Tarkov`, BattlEye was not touched.

---

## HEADLINE — the two answers

### 1. The section layout comes from the NETWORK, at runtime, from inside GameAssembly.dll itself

GameAssembly.dll does **not** contain the metadata section layout and does not compute it.
It **POSTs to `https://<BackendUrl>/client/metadata` over WinHTTP during `il2cpp_init`**, before a
single line of C# runs, and parses the section layout out of the JSON response.

The whole client side of that exchange is native code in `.text`, fully reconstructable:

| item | value |
|---|---|
| HTTP worker | RVA `0x51E070` |
| request builder / cmdline parser | RVA `0x51F060` |
| verb | `POST` (UTF-16 literal at RVA `0x64ECDD8`) |
| path | `/client/metadata` (UTF-16 at RVA `0x64ECE08`) |
| port | **443**, hardcoded (`mov r8d, 0x1BB` at `0x51E0E7`) |
| TLS | `WINHTTP_FLAG_SECURE` = `0x800000` set at `0x51E108` |
| **cert validation** | **disabled** — `WinHttpSetOption(WINHTTP_OPTION_SECURITY_FLAGS=0x1F, 0x3300)` at `0x51E0B5` / `0x51E15F`. `0x3300` = IGNORE_UNKNOWN_CA \| IGNORE_CERT_WRONG_USAGE \| IGNORE_CERT_CN_INVALID \| IGNORE_CERT_DATE_INVALID |
| headers | `Content-Type: application/json` (`0x64ECE30`), `Cookie: PHPSESSID=<token>` (`0x64ECAF0`) |
| body | `{"version": "<ver>", "key": "<key>"}` — literal fragments at `0x64ECDE8` / `0x64ECDF8` |
| response parse | regex `\{[\s\n]*"value"\s*:\s*"([0-9a-fA-F]+)"[\s\n]*\}` (`0x64ECDA0`, fn `0x520C70`) and fallback `(value)"\s*:\s*"([0-9a-fA-F]+)` (`0x64ECD80`, fn `0x521100`) |

**Where the backend host and token come from — the command line only.** `0x51F060` calls
`GetCommandLineW` and runs two `std::wregex` matches over it:

```
.*BackendUrl['"]\s*:\s*['"]https:/+([a-z0-9A-Z-_\.]+)['"].*     @ 0x64ECB20
.*-token=([a-z0-9A-Z-_]+).*                                     @ 0x64ECB98
```

There is **no hardcoded host anywhere in the DLL** (searched ASCII + UTF-16: no
`escapefromtarkov`, no `prod.`, no other https URL) and **no disk cache / fallback** in the path.

Consequences for an offline client, in order of importance:

* The layout **is** a per-version constant that an emulator can serve. Serving `/client/metadata`
  is necessary and — for this gate — sufficient. This is what a SPT-style server must add.
* The captured host group is `[a-z0-9A-Z-_.]+`; **it cannot contain a colon**. You cannot point it
  at `127.0.0.1:6969`. The request always goes to **port 443** of whatever host is in
  `BackendUrl`. An offline server must listen on 443 (or the host must be redirected there).
* TLS is required but **any certificate works** — self-signed is fine; all four cert errors are
  explicitly ignored.
* The launcher must still supply `-token=<...>`; it is echoed as `Cookie: PHPSESSID=`. A permissive
  emulator can ignore its value, but the regex must match or the request is never built at all.

### 2. Where `il2cpp_init` fails

The failure is **in the metadata path**, not in a separate anti-tamper/environment gate — at least
as far as GameAssembly.dll is concerned. The chain is short and there is nothing in front of it:

```
il2cpp_init                RVA 0x5B1440   (export)
 └─ Runtime::Init          RVA 0x5AAAC0
     … RoInitialize, allocator ctors, CoInitializeEx, WSAStartup …   <- no gate
     └─ (std::function @ 0x5A93F0) MetadataCache::Initialize wrapper
         └─ MetadataCache::Initialize   RVA 0x5C67C0
             └─ LoadAndDecryptMetadata  RVA 0x523A70   -> bool
                 test al,al ; je 0x5C7217   (at 0x5C67E1)  -> plain `ret false`
```

`0x5A93F0` writes `!result` into its out-param; `il2cpp_init` returns that as its `bool`.
So **a false from `0x523A70` is exactly "`il2cpp_init` returned 0"**.

Inside `0x523A70` the only hard failure that is cheap (sub-second, no network round trip) is:

```
edx = headerDerivedValue            ; produced by 0x5244E0 from the decoded 0x200-byte header
if (edx != 0) {
    if (!FetchLayout(&versionStr, edx, tableVal, &layoutVec))   ; 0x524870 -> 0x51F060 -> 0x51E070
        return false;                                            ; 0x523BF1: xor bl,bl ; jmp ret
    ApplyLayout(...)                                             ; 0x522FB0 / 0x524D10
}
```

If `BackendUrl` is absent from the command line the regex fails and `0x51F060` bails **without any
socket activity** — an essentially instant failure, which matches a ~200 ms process lifetime far
better than a TCP/TLS timeout would.

**Anti-tamper / environment gates: none found in GameAssembly.dll.**

* No `BattlEye`, `BEClient`, `BEService` string, ASCII or UTF-16 — zero hits across 123 MB.
* No `NtQueryInformationProcess`, no `CheckRemoteDebuggerPresent`, no `DbgUiRemoteBreakin`.
  `IsDebuggerPresent` appears only inside CRT `__report_gsfailure` / `_CxxThrowException` paths.
* No parent-process check, no volume/hardware-id read anywhere in the call closure of `0x523A70`
  (1,647 functions walked, full import-usage list produced — only WinHTTP, bcrypt SHA-256,
  CRT/locale/heap, file I/O for the .dat itself, and `GetCommandLineW`).
* The pervasive `call 0x51CD50 / 0x51CCC0 / 0x51D3F0` triple decorating every obfuscated function
  is **not** an environment check. `0x51CD50` / `0x51CCC0` seed a `std::mt19937_64` (constants
  `0x5851F42D4C957F2D`, `0xB5026F5AA96619E9`, 312-word state) to build a random string, SHA-256 it
  via bcrypt, and register it in a global map at `.data 0x70B2C40`; `0x51D3F0` stringifies an
  integer, appends `':'`, and looks it up in that map. It is an opaque-predicate / flattened-
  dispatch mechanism, freshly randomised every run, environment-independent.

So: **the exit-code 35 → 23 shift when the BattlEye service is started is not GameAssembly.dll.**
That gate lives in `EscapeFromTarkov.exe` / `UnityPlayer.dll` / the BE loader, outside this binary.
Fixing `/client/metadata` gets you past the metadata gate; it will not by itself explain or resolve
the BE-dependent exit code.

---

## Loader map (RVAs, image base `0x180000000`)

| RVA | role |
|---|---|
| `0x5B1440` | export `il2cpp_init` (`0x5B1470` = `il2cpp_init_utf16`) |
| `0x5AAAC0` | `Runtime::Init` |
| `0x5C67C0` | `MetadataCache::Initialize`; calls the decryptor at `0x5C67DC` |
| `0x523A70` | **metadata load + decrypt driver**, returns bool |
| `0x5A8D10` | metadata-file loader wrapper (obfuscated, control-flow flattened) |
| `0x5A8570` | **real file reader** — builds `Metadata\<name>`, `CreateFileW` / `ReadFile`, returns buffer + size. `ReadFile` call site `0x5A8757` |
| `0x5A88F0` / `0x5A8290` | decoy twin of the pair above. `0x5A8290` VirtualAllocs an RWX page, writes 15- and 24-byte blobs and `call rdi`s them; the blobs disassemble to garbage (`00 48 33 8b c8 48 15 7a 27 00 00 44 b9 2d 7f` → `add [rax+0x33],cl; mov ecx,eax; adc rax,0x277a; …` then falls into zero fill). Unreachable at runtime: `0x523A70` requires `0x5A88F0` to return NULL. Obfuscator chaff |
| `0x5244E0` | header decode → version string + the int that selects the layout path |
| `0x524870` | builds the JSON `key` field (decimal-ises `hash(headerVal + tableVal)`), then calls the fetcher |
| `0x51F060` | cmdline regexes + request assembly + response-regex dispatch |
| `0x51E070` | WinHTTP POST worker |
| `0x520C70`, `0x521100` | JSON `"value"` regex extractors (invoked through `std::function`) |
| `0x522FB0`, `0x524D10` | consume the layout vector and apply it to the buffer |
| `0x51CA70`, `0x51CB20` | bcrypt SHA-256 provider + hash helper (`SHA256` literal at `0x64ECC20`) |
| `0x51D800` | integer hash used for the `key` and for table indexing |

`.data` globals: `0x70B7628` = decrypted-metadata object pointer (its `[+0]` / `[+4]` int fields are
range-checked `0 <= x <= 0x100` at `0x523ADA`–`0x523B00`); `0x70B7910` = result of the decoy probe.

PE layout worth knowing: `.text` RVA `0x1000` size `0x62608C`; a separate **85 MB section literally
named `il2cpp`** at RVA `0x628000` size `0x510FA6C` holding generated method bodies; `.rdata` RVA
`0x5738000`; `.data` RVA `0x6B61000`. All loader / crypto / network code above is in `.text`.

## Cipher notes (cross-check against XM-MetadataDecrypt)

Consistent with the public tool's description, and independently visible in the binary:

* **Not AES.** Zero `aesenc` / `aesdec` / `aesimc` / `aeskeygenassist` opcodes; no AES S-box or
  inverse S-box; no round-constant table. No ChaCha/Salsa `expand 32-byte k`. No Blowfish, Twofish,
  RC5/RC6 tables. No `BCryptEncrypt` / `BCryptDecrypt` import — bcrypt is used **only** for SHA-256.
  Everything is bespoke code, which matches "keystream XOR + keyed permutation".
* File shape supports it: whole-file entropy 7.9991/8, but the **last ~150 bytes are structured** —
  a byte run descending by exactly 4 (mod 256) with occasional −6 steps
  (`… 73 6f 6b 67 63 5f 5b 57 53 4f 4b 47 43 3f 3b 37 …`). That is the tool's
  `keyStream[i] = i + 2*(i/0xFE) + 1` showing through where the plaintext tail is constant — an
  independent confirmation of the keystream formula.
* Size 27,776,072 is 8-aligned but not 16-aligned, consistent with a byte-oriented stream rather
  than a 128-bit block cipher.

One detail the binary adds over the tool: the **`key` sent to the server is a decimal string**, not
hex (`0x524870` divides by 10 via `mul 0xCCCCCCCD ; shr 3` and adds `'0'`), while the **response
`value` is parsed as hex**. An emulator endpoint should expect something shaped like
`{"version": "1.1.0.1.46777", "key": "2272334131"}` (decimal of `0x876F9333`) and must reply with
`{"value":"<hex blob>"}` — the regex accepts either a bare `{"value":"…"}` object or the
`…"value":"…"` fragment inside a larger body.

## What would be needed next

1. **Obtain the layout blob for 1.1.0.1.46777.** It is not in the client. Options: capture the
   `/client/metadata` response once from a legitimate session, or solve the layout from the
   metadata itself (the section table is `(DataSize, DataOffset)` pairs; any candidate is
   verifiable against the `AF 1B B1 FA` / `1F 00 00 00` magic + readable-type-name oracle).
   Nothing inside GameAssembly.dll can produce it.
2. **Serve it on port 443** of whatever host goes into `-config={"BackendUrl":"https://<host>"}`,
   with any TLS certificate (validation is off), and accept a `PHPSESSID` cookie.
3. **Separately** chase the 35 → 23 exit code in `EscapeFromTarkov.exe` / `UnityPlayer.dll`;
   it is provably not in GameAssembly.dll.

## Corrections to earlier assumptions

* "No `BCryptDecrypt` ⇒ probably AES-NI" — wrong; there is no hardware AES either. The cipher is
  entirely custom, and bcrypt SHA-256 is reachable from the metadata path only through the
  obfuscator's opaque-predicate machinery.
* The `global-metadata.dat` string has exactly two xrefs (`0x5A890F`, `0x5A8D39`), and one of the
  two functions they sit in is deliberately dead. Following the wrong one leads to nonsense
  self-modifying stubs and wastes a lot of time.
* The magic `0xFAB11BAF` does **not** appear as an immediate anywhere in the DLL; there is no
  plaintext-magic check to anchor on.
