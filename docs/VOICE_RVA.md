# VOICE_RVA — offline IL2CPP archaeology for two voice features

OFFLINE measurement only. No detour, no live probe, no deploy was performed. All
RVAs resolved against:

- `D:/Games/Tarkov/GameAssembly.dll` (123,891,024 bytes, 2026-08-12)
- `.cache/global-metadata.dec.dat` (decrypted, 2026-08-23)

Tool: `tools/il2cpp_resolve.py` (verbs `type`/`methods`/`shared`/`bytes`) and
`tools/fldoff.py fields`. Every command is `il2cpp_resolve.py GAMEASM METADEC <verb> …`.

**Mandatory self-check — PASS.** `fldoff.py … fields System.String` reports
`_stringLength@0x10`, `_firstChar@0x14`. The metadata layout is trusted for this run.

Imagebase `0x180000000`; runtime addr = `GameAssemblyBase + RVA`. Generated bodies
live in the `il2cpp` section (all RVAs below are `sec=il2cpp` unless noted).
`0x628110` is the universal empty-body stub (6,438 methods) — any resolve that lands
there is NOT that method's code.

Sharedness legend: **UNIQUE** = safe to detour; **SHARED** = detour has unbounded
blast radius, do not; calling a shared RVA is always fine.

---

## A. Stock bot voice / taunt trigger (to SUPPRESS or replace)

Bots are `EFT.Player` subclasses; each bot owns a `BotTalk` instance that funnels all
AI chatter. The clean, bot-only chokepoint is **`BotTalk::Say`**.

| Method | RVA | shared | shape/notes |
|---|---|---|---|
| `BotTalk::Say(EPhraseTrigger type, bool sayImmediately, Nullable<ETagStatus> additionalMask, ETagFilter tagFilter)` | `0x1a892f0` | **UNIQUE** (owners=1) | real prologue `48 89 5C 24 20 55 56 57 48 81 EC 90 00 00 00 …` |
| `BotTalk::TrySay(EPhraseTrigger)` | `0x1a896b0` | UNIQUE | funnels into Say via the query |
| `BotTalk::TrySay(EPhraseTrigger, bool withGroupDelay)` | `0x1a89700` | UNIQUE | |
| `BotTalk::TrySay(EPhraseTrigger, Nullable<ETagStatus>, bool)` | `0x1a898a0` | UNIQUE | |
| `BotTalk::SayFromQuery()` | `0x1a8a830` | UNIQUE | pulls from AddToQuery ladder |
| `BotTalk::SayAndDelay(EPhraseTrigger)` | `0x1a8ac20` | UNIQUE | |

Command (representative):
`python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat type BotTalk --shared`
`… shared 0x1a892f0`  → `sharedness=UNIQUE owners=1`
`… bytes 0x1a892f0 16` → real body, not stub.

**Best chokepoint to gate ALL stock bot speech: `BotTalk::Say` @ `0x1a892f0`
(UNIQUE).** Frame shape derived from the signature (arity=4, instance):
- RCX = `this` (BotTalk)
- EDX = `EPhraseTrigger type` (enum, `value__@0x10`, int32 by value)
- R8B = `bool sayImmediately`
- R9 = `Nullable<ETagStatus>` — a nullable value type; passed by pointer/expanded per ABI (verify frame live before *calling* it; for a **prefix suppress detour you only inspect/early-return**, so the exact R9 packing does not matter to gate it)
- stack: `ETagFilter tagFilter`
- + hidden trailing `const MethodInfo*`

A prefix detour that returns early (or zeroes the trigger) here suppresses the bot's
phrase without touching player voice. All `TrySay` overloads + `SayFromQuery` reach
this, so gating `Say` alone covers the AI-chatter path.

### Player-level speech (context; do NOT use for bot-only suppression)

| Method | RVA | shared | note |
|---|---|---|---|
| `EFT.Player::Say(EPhraseTrigger, bool demand, float delay, ETagStatus mask, int probability, bool aggressive, ETagFilter tagFilter)` | `0x721fd0` | UNIQUE | fires for LOCAL player too — suppressing here mutes the human |
| `EFT.Player::PlayPhraseClip(TaggedClip clip)` | `0x7148a0` | UNIQUE | **TAILJUMP thunk** (`jmp rel32` at +6) — a *postfix* detour has no return site; closest "emit the clip" point |
| `EFT.Player::OnPhraseTold(EPhraseTrigger, TaggedClip, TagBank, BaseSpeaker)` | `0x722390` | UNIQUE | post-selection callback |
| `EFT.Player::ShouldSay(Player talker, EPhraseTrigger)` | `0x732ac0` | UNIQUE | read-only gate predicate — good drain point |
| `EFT.Player::TriggerPhraseCommand(EPhraseTrigger, int)` | `0x628110` | — | **UNIVERSAL EMPTY STUB — not real code. Do not bind.** |

Verdict A: **`BotTalk::Say@0x1a892f0` — usable, UNIQUE, prefix-detour to suppress.**
`Player::PlayPhraseClip@0x7148a0` usable only as a prefix detour (tailjump = no
postfix). `TriggerPhraseCommand` is the stub — do not touch.

---

## B. Spatialised audio playback ("play these wav bytes at Vector3 p")

`AudioSource::PlayClipAtPoint` — **NOT PRESENT** (`methods PlayClipAtPoint` →
searched all 31282 EXHAUSTIVELY, zero hits). It is a managed C# helper Unity
stripped. We must build the clip + source ourselves.

All RVAs below are real bodies (bytes checked; none land on `0x628110`).
These are internal-call-backed wrappers but have callable managed bodies at the RVA.

| Method | RVA | arity | note |
|---|---|---|---|
| `AudioClip::Create(string name, int lengthSamples, int channels, int frequency, bool stream)` | `0x52520a0` | 5 (static) | allocate an empty clip |
| `AudioClip::Create(name, len, ch, freq, bool _3D, bool stream)` | `0x5252070` | 6 (static) | 3D overload |
| `AudioClip::SetData(float[] data, int offsetSamples)` | `0x5251dd0` | 2 (instance) | upload PCM floats (-1..1) |
| `AudioClip::CreateUserSound(name, lengthSamples, channels, frequency, bool stream)` | `0x5251880` | 5 (static) | alt allocator |
| `AudioSource::set_clip(AudioClip)` | `0x5252ed0` | 1 | |
| `AudioSource::set_spatialBlend(float)` | `0x52536f0` | 1 | pass 1.0 for full 3D |
| `AudioSource::set_volume(float)` | `0x5252d70` | 1 | |
| `AudioSource::set_loop(bool)` | `0x52534d0` | 1 | |
| `AudioSource::Play()` | `0x5252fe0` | 0 | |
| `AudioSource::PlayOneShot(AudioClip)` | `0x5253140` | 1 | |
| `AudioSource::PlayOneShot(AudioClip, float volumeScale)` | `0x5253150` | 2 | |

Commands:
`… type UnityEngine.AudioSource` and `… type UnityEngine.AudioClip`
`… methods PlayClipAtPoint` → not-found.

### From-scratch host call chain (play wav bytes at world Vector3 p)

1. Decode wav → interleaved float32 PCM, N samples, C channels, F Hz (host-side, no game call).
2. `clip = AudioClip::Create("aowl", N/C, C, F, false)` @ `0x52520a0` (static; args RCX..R9 + MethodInfo*; `il2cpp_string_new` for the name).
3. `clip.SetData(floatArr, 0)` @ `0x5251dd0` — floatArr must be a managed `float[]` (allocate via game array-new; **per-frame managed allocation is rule-7 forbidden, so build clip ONCE and cache**).
4. Create/obtain a GameObject at `p`, add/get `AudioSource`, position its Transform at `p`.
5. `src.set_clip(clip)` @ `0x5252ed0`; `src.set_spatialBlend(1.0)` @ `0x52536f0` (XMM0); optional `set_volume`.
6. `src.Play()` @ `0x5252fe0`  (or `PlayOneShot(clip)` @ `0x5253140`).

Flags / stubs / gates:
- None of the above are the empty stub; all `sec=il2cpp` real bodies.
- These are UnityEngine ICall wrappers — building the `AudioSource` **component** and a
  managed `float[]` is the unproven part (needs `object_new`/array-new/`AddComponent`),
  so this chain is **plausible, needs a live probe** to confirm component construction
  and array marshalling, per CLAUDE.md §9b (INCONCLUSIVE, not PASS).
- No token-gated `il2cpp_*` export is on this path — all are direct RVA calls.

Verdict B: **usable direct-RVA chain; `PlayClipAtPoint` not-found (build manually);
clip must be constructed once and cached (rule 7); AudioSource component construction
is the one live-probe gap.**

---

## C. "Who am I looking at" (talk-to-bot targeting) — lower priority

| Symbol | RVA / offset | shape/note |
|---|---|---|
| `EFT.Player::get_LookDirection()` → Vector3 | `0x6f8060` | real body (`48 83 EC 28 48 8B 42 60 …`) |
| `EFT.Player::get_CameraPosition()` → Transform | `0x6f7f60` | trivial getter `mov rax,[rcx+0x3B8]; ret` — can read Transform field @`0x3B8` directly instead of calling |
| `EFT.Player.HeadRotation` (Vector3 field) | offset `0x80` | public field |
| `UnityEngine.Physics::Raycast(Vector3 origin, Vector3 dir, RaycastHit hitInfo, float maxDist, int layerMask)` | `0x5328a80` | static; real body |
| `Physics::Raycast(origin, dir, maxDist, layerMask)` (no hitInfo) | `0x5328760` | static |
| `Physics::Raycast(origin, dir, hitInfo, maxDist, layerMask, QueryTriggerInteraction)` | `0x53289a0` | static, fullest overload |

Approach: origin = camera Transform position (walk `player+0x3B8` → Transform, read
world position), direction = `get_LookDirection()`, then `Physics::Raycast` with a hit
buffer; resolve the hit collider back to a bot `Player`. Vector3 args are by-value
(struct-in-register/stack per ABI — verify frame live before calling). `RaycastHit` is
a struct out-param (hidden buffer). Sharedness not reported: these are **called, not
detoured**.

Verdict C: **readily resolvable; the ray primitives exist. Collider→Player resolution
and the exact Vector3/RaycastHit marshalling need a live probe (INCONCLUSIVE).**

---

## Summary verdicts

- A: `BotTalk::Say@0x1a892f0` **UNIQUE** — detour target for bot-chatter suppression. **usable.**
- B: manual clip chain (Create `0x52520a0` / SetData `0x5251dd0` / set_clip `0x5252ed0` / set_spatialBlend `0x52536f0` / Play `0x5252fe0`); `PlayClipAtPoint` **not-found**. **usable, one live-probe gap (component + float[] construction).**
- C: `get_LookDirection@0x6f8060`, camera Transform @field `0x3B8`, `Physics::Raycast@0x5328a80`. **usable, collider→bot mapping needs a live probe.**

Anything marked "needs a live probe" is INCONCLUSIVE by design — no live call was made.
