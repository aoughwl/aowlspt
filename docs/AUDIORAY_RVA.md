# AUDIORAY_RVA — the audio path into EFT, resolved offline

Phase 2 of the raytraced-audio ("soundfx") track: **apply** a computed occlusion
gain to the game's own audio. Nothing here is live. Every line below was
produced **offline** by

```
python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll \
       .cache/global-metadata.dec.dat <verb> ...
```

against build `1.1.0.1.46777` (scope `aowlspt-ga:e0ea3ad3b76b-db:41313127`).
Re-derive them after any Tarkov update — an RVA is the first thing a patch
invalidates, and a stale RVA that still lands in the `il2cpp` section will call
*something*.

Status: **the offline half is done; the feature is still NOT implemented.** The
reason is in "The one thing that is still missing" at the bottom, and it is a
missing *fact*, not missing code.

---

## What was resolved

Every row's RVA was byte-verified against `GameAssembly.dll` with
`il2cpp_resolve.py ... bytes <RVA>`: all eight are real bodies in the `il2cpp`
section, none is the universal empty-body stub (`C2 00 00`) and none matched a
thunk shape.

### Unity's own filters and mixer — all UNIQUE

| Method | RVA | arity | sharedness |
|---|---|---|---|
| `UnityEngine.AudioLowPassFilter::set_cutoffFrequency(float)` | `0x5253E60` | 1 | **UNIQUE** |
| `UnityEngine.AudioLowPassFilter::get_cutoffFrequency()` | `0x5253E10` | 0 | **UNIQUE** |
| `UnityEngine.AudioLowPassFilter::set_lowpassResonanceQ(float)` | `0x5253EC0` | 1 | **UNIQUE** |
| `UnityEngine.Audio.AudioMixer::SetFloat(string, float)` | `0x5255CA0` | 2 | **UNIQUE** |
| `UnityEngine.Audio.AudioMixer::GetFloat(string, float)` | `0x5255D10` | 2 | **UNIQUE** |
| `UnityEngine.Audio.AudioMixer::FindMatchingGroups(string)` | `0x52557D0` | 1 | **UNIQUE** |
| `UnityEngine.Audio.AudioMixer::TransitionToSnapshot(AudioMixerSnapshot, float)` | `0x5255830` | 2 | **UNIQUE** |

Derived frames (instance methods, so `RCX = this`, then a hidden trailing
`const MethodInfo*` — NULL is acceptable, none of these is a shared generic):

```
set_cutoffFrequency :  RCX=AudioLowPassFilter*  XMM1=float value   R8 =MethodInfo*
AudioMixer::SetFloat:  RCX=AudioMixer*  RDX=Il2CppString* name  XMM2=float  R9=MethodInfo*
```

`SetFloat`'s `name` is a managed string, so it is built with `il2cpp_string_new`
— which is one of the three things that still work on this build.

`set_cutoffFrequency` bytes: `40 53 48 83 EC 30 48 8B 05 13 E7 E7 01 48 8B D9`
(`push rbx; sub rsp,0x30; mov rax,[rip+…]; mov rbx,rcx`) — an ordinary
`il2cpp_codegen_initialize`-prefixed body, not a stub.

**`UnityEngine.AudioReverbZone` DOES NOT EXIST** on this build — a genuine
zero-hit over all 31,282 types, searched exhaustively, not a search that gave
up. `UnityEngine.AudioReverbFilter` (type 30053) exists but **declares no
methods at all**, so there is no reverb setter to call and vaudio's EAX output
has nowhere to go through Unity. Reverb application is blocked for a reason that
will not change without a Unity version bump.

### BSG's own `BetterAudio` — the better target

`BetterAudio` is the game's audio front end and it already has the exact shape
the FmodOcclusion fallback wants: a master low-pass with a transition time.

| Method | RVA | arity | sharedness |
|---|---|---|---|
| `BetterAudio::SetHideoutLowPassFilter(float freq, float transitionDuration, bool forced)` | `0x1D82FE0` | 3 | **UNIQUE** |
| `BetterAudio::ApplyHideoutAudioFilter(float targetVolume, float targetFreq, float duration, bool compete)` | `0x1D83040` | 4 | **UNIQUE** |
| `BetterAudio::ApplySpatialSettingsFromBackend(ClientAudioOcclusionSettings)` | `0x1D79B30` | 1 | **UNIQUE** |
| `BetterAudio::SetEnvironmentReverbHighpass(EnvironmentType)` | `0x1D7D9D0` | 1 | **UNIQUE** |
| `BetterAudio::FadeMixerVolume(string mixerKey, float endValDb, float seconds, bool force)` | `0x1D82640` | 4 | **UNIQUE** |
| `BetterAudio::FindMixerGroup(string groupName)` | `0x1D7D0F0` | 1 | **UNIQUE** |
| `BetterAudio::ResetWorldMixerValues()` | `0x1D798F0` | 0 | **UNIQUE** |

`SetHideoutLowPassFilter` bytes: `48 83 EC 38 F3 0F 10 05 AC 37 83 04 0F 2F C1 77`
— `sub rsp,0x38; movss xmm0,[rip+…]; comiss xmm0,xmm1; ja …`. It compares a
constant against **XMM1**, which is `freq`, i.e. argument index 1 with `this` at
index 0 in RCX. That **confirms the derived frame from the code itself** rather
than from the method name:

```
SetHideoutLowPassFilter: RCX=BetterAudio*  XMM1=freq  XMM2=transitionDuration
                         R9=bool forced (byte)   [rsp+0x28]=MethodInfo*
```

Note `get_AudioMixerData` @`0x80E780` is **SHARED x3** and
`set_AudioMixerData` @`0x80E790` is **SHARED x2** — correct to *call*, and it
must **never** be detoured by name. Nothing in this design detours anything.

### Fields (from `Il2CppMetadataRegistration.fieldOffsets`, via `tools/fldoff.py`)

`BetterAudio` holds the mixer and every occlusion group directly:

| Field | Type | Offset |
|---|---|---|
| `Master` | `AudioMixer` | `0xA8` |
| `Snapshots` | `AudioMixerSnapshot[]` | `0xB0` |
| `MasterMixerGroup` | `AudioMixerGroup` | `0xB8` |
| `GunshotOccludedMixerGroup` | `AudioMixerGroup` | `0xC0` |
| `SimpleOccludedMixerGroup` | `AudioMixerGroup` | `0xC8` |
| `MutedGroup` | `AudioMixerGroup` | `0xD0` |
| `UpperOccluded` | `AudioMixerGroup` | `0xD8` |
| `LowerOccluded` | `AudioMixerGroup` | `0xE0` |

The existence of `UpperOccluded` / `LowerOccluded` / `SimpleOccludedMixerGroup`
says BSG already routes occluded sound through dedicated groups. A raytraced
gain is therefore plausibly applied by *choosing a group*, not only by moving a
cutoff — which is a cheaper and far less invasive intervention. Unmeasured.

### The raycast fallback

`UnityEngine.Physics::Raycast` is at **`0x5328A80`** (static). Bytes
`48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 70 80` — a real body. **Call it by
RVA only.** Binding it by name crashed the client (facts #144 / #145).

---

## The one thing that is still missing

**Getting a `BetterAudio*` instance.** `BetterAudio` derives from
`MonoBehaviourSingleton\`1`, whose `get_Instance` has **no non-generic body**:
the only instantiation is `class<object>` at RVA `0x33E1A40`, i.e. a **shared
generic**. Per the standing facts, a shared generic **must** be called with a
non-NULL `MethodInfo*`, and calling it with NULL is one of the reliable ways to
kill the client. `il2cpp_resolve.py` itself refuses to rate its sharedness —
generic bodies are not in the per-image `methodPointers` histogram, so the
answer is **UNKNOWN**, which is a refusal and not "probably unshared".

So the instance must be reached the way every other container in this project
was reached: **by walking from a verified live object**, validating each hop —
not by calling that generic and not by an offset that can read null.
`GameWorld` → the audio component is the obvious candidate and is **unmeasured**.

**And the second missing fact:** `AudioMixer::SetFloat` only works for a
parameter the mixer author explicitly *exposed*, and the exposed-parameter names
are authored data inside the mixer asset. They are **not** derivable from
metadata. Calling `SetFloat` with a guessed name returns `false` and changes
nothing — a silent no-op that would read exactly like a working feature that
happened to compute a gain of 1.0. `GetFloat` @`0x5255D10` is the instrument
that settles this: probe a candidate name live and see whether it returns true.

Until both are measured, Phase 2 is **BLOCKED**, and the correct thing to do is
say so rather than ship a call whose failure is indistinguishable from success.

## The order to do it in, when someone picks this up

1. Live-walk to a `BetterAudio*` from `GameWorld`, via the inspector. Record the
   hop chain as a fact.
2. With that pointer, call `GetFloat` @`0x5255D10` on `Master`@`0xA8` for each
   candidate exposed-parameter name and record which return true. This is a
   **read-only** probe and it is the falsifiable step.
3. Only then, and only if a unique exposed name exists, wire
   `SetHideoutLowPassFilter` @`0x1D82FE0` (byte-verified, UNIQUE, non-generic,
   already takes a transition time so it smooths itself) as the FmodOcclusion-
   style fallback. It needs **no** detour: it is a direct call.
4. Reverb stays blocked — `AudioReverbZone` does not exist on this build and
   `AudioReverbFilter` declares no methods.
