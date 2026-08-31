# Native Unity UI from a mod — the `nu*` toolkit

Creating real Unity UI from nothing inside the IL2CPP client is **proven live**,
for both element types:

* a `TextMeshProUGUI` built from scratch — human-confirmed rendering in Tarkov's
  settings screen;
* a `UnityEngine.UI.Image` built from scratch — `IMAGEPROOF VERDICT = PASS`
  (2026-08-30): `object_new` + ctor + `AddComponent<Image>`, an auto-added
  `CanvasRenderer`, under a live Canvas, a 240x120 rect with real area.

This document is the part that makes that usable by somebody who was not there.
It covers `host/Aowlspt.Host.Il2Cpp/nuikit.nim`.

## The minimal labelled panel

```nim
# You are on the Unity thread, INSIDE one aowl_p_p_seh that somebody else
# opened (invoke2's postfix drain, the region tick, ...). Open none of your own.
let anchor = gMi2TmpOwner            # any LIVE object you already validated
let canvas = nuFindCanvas(anchor)
if canvas != nil:
  let panel = nuPanel(canvas, 40.0, -40.0, 320.0, 120.0,
                      0.05, 0.06, 0.08, 0.85, "mymod-panel")
  let label = nuLabel(canvas, gMi2Tmp, 52.0, -56.0, 296.0, 32.0,
                      "Hello from a mod", 22.0)
  # ... keep `panel` and `label`; they are handles, not pointers.
```

Both return `NuElem`, an opaque handle. `nuNone` is the refusal value; compare
with `uint32(h) == 0` or ask `nuValidHandle(h)`. Every refusal is logged with a
named reason before the handle comes back empty — nothing here declines
silently.

Positions are **top-left anchored**: `x` right, `y` **negative downward**, in
canvas units, which is the convention the live proof used.
Colours are four `float32` in 0..1, alpha last.

## The API

| call | what it does |
|---|---|
| `nuFindCanvas(anchor)` | GameObject of a live screen-space Canvas, or nil |
| `nuPanel(parentGo, x,y,w,h, r,g,b,a, name)` | a solid `Image` quad → `NuElem` |
| `nuLabel(parentGo, donorTmp, x,y,w,h, text, size, r,g,b,a, name)` | a `TextMeshProUGUI` → `NuElem` |
| `nuSetRect(h, x,y,w,h)` / `nuSetColor(h, r,g,b,a)` | geometry / colour |
| `nuSetText(h, s)` | label only; **refuses** on a panel |
| `nuSetActive(h, on)` / `nuDestroy(h)` | show/hide, tear down |
| `nuDestroyAllElems()` | tear down everything the toolkit still holds |
| `nuLive(h)` | is it still an object Unity would talk to? |
| `nuElemRect/nuElemColor/nuElemText/nuElemActive` | read the **finished state** back |
| `nuElemCount()` / `nuElemCapacity()` | 0..64 |

Flags, **both default OFF**: `nativeUiKit` (implies `nativeUi`) and
`nativeUiKitProof` (the self-test). Set them with `python tools/hostcfg.py`.

## Handle lifetime — the rules that matter

A handle is `(generation << 16) | (index + 1)` in a fixed 64-entry table.

1. **A handle is not a pointer.** It is checked on every single call: is it in
   range, is its slot still allocated, and does its generation still match.
2. **Destroying spends the handle.** After `nuDestroy`, every later call on it
   refuses with `RELEASED`. Calling `nuDestroy` twice is safe.
3. **A handle kept across a scene change refuses**, it does not crash. If the
   slot has been re-issued to a different element the refusal is
   `STALE GENERATION`; if the GameObject died but the slot is still yours, the
   liveness gate catches it, says so, and releases the slot.
4. **Readability is not liveness.** A destroyed `UnityEngine.Object` stays
   perfectly readable with `m_CachedPtr` zeroed — a null check passes and the
   next internal call dies inside Unity's C++. Every entry point therefore asks
   `Object::op_Implicit`, not "is the pointer non-null". This is why you must
   not cache the raw pointers out of a handle and use them later.
5. **The table is 64 entries.** A full table is a refusal (and the
   half-built element is destroyed), never an overwrite.
6. **Eight hard refusals self-disable the layer** for the session.

## The canvas caveat

`nuFindCanvas` **requires a live anchor** — an object you already validated.
That is not ceremony: the underlying scene-root walk falls back to the live
inspector's own preloader pointer when given nothing, which only the inspector
ever writes, so an anchorless call would find no roots on every run the
inspector was not also driving.

It prefers a Canvas whose `get_renderMode` really reads back as
ScreenSpaceOverlay or ScreenSpaceCamera, and **skips WorldSpace** — UI parented
into a world-space canvas is somewhere in the map rather than on the screen, and
would be an invisible success. If it walked roots but could ask none of them for
a Canvas, it says so as INCONCLUSIVE rather than reporting absence.

The result is cached and **re-validated for liveness on every call**, so a
canvas that died in a scene change causes a re-walk, not a fake-null
dereference.

This is the **live inspector's** discovery path (`iSceneRoots` +
`iVisComponent("Canvas")`), consumed — not a second implementation.
`natesp.nim` has its own; do not add a third.

## What the self-test proves, and what it does not

`nativeUiKitProof` runs once, riding invoke2's postfix drain: open Settings and
click a tab. It builds a panel and a label **through the toolkit**, reads
rect / colour / text / active back **off the live objects**, exercises the
setters, checks that `nuSetText` on a *panel* is refused, then destroys both and
asserts that **no spent handle still works**. Verdict is one of PASS / FAIL /
**INCONCLUSIVE**, on the line `nuikit SELFTEST: OVERALL = ...`.

The negative half is the point: a handle table with bare indices passes
everything before the teardown and fails exactly there.

**PASS does not prove a human sees pixels.** It proves the objects existed, were
alive, were active in the hierarchy, sat under a live Canvas and answered with
the geometry, colour and text they were given. A canvas behind another canvas, a
zero scale factor, or a camera that does not render it are all still possible
and none of them are visible from inside the host.

## Rules for a caller

* **Be inside exactly one `aowl_p_p_seh` that somebody else opened.** This
  toolkit opens none. The guard is not re-entrant and a nested inner guard
  disarms the outer one.
* **Allocate at creation, not per frame.** `nuPanel`/`nuLabel` allocate; the
  setters do not, except `nuSetText`, whose strings are interned so a repeated
  string costs nothing after the first.
* **Do not "simplify" the double `nuSetText`.** `LocalizedText` can clobber a
  raw `m_text` store after yours; the real setter is deliberately re-applied.
* **`nuLabel` needs a live donor TMP.** Its font asset and materials are copied
  in while the object is inactive; a from-scratch TMP with a null `m_fontAsset`
  faults in `Awake`. No donor is a refusal, not a best effort.

## Relationship to `aowlui` (`docs/UI-API.md`)

`aowlui` is the **screen** level: a retained framework with panels, labels,
toggles, tabs and config binding over two backends (the D3D11 overlay and native
Unity UI). This toolkit is the **element** level underneath it: one handle, one
GameObject, no retained screen and no reset.

Want a whole settings screen, on either backend? Use `aowlui`. Want to put one
box and one caption on screen and keep them across frames with a handle that
cannot crash you? Use this. The overlap is real; pick one per feature rather
than mixing them on the same objects.
