# Shelved for 1.0: the native in-game settings work

**Status: code kept, flags OFF, not shipping in 1.0.** Owner's call, 2026-08-24:
*"revert the postfx graphics stuff - dont delete the code, but lets forget about
that all for a 1.0"*.

The settings surface that DOES ship is the browser page from `mods/uihub`
(`/aowlspt/ui/page/settings`, see `docs/UI-API.md`). It uses the same
`/aowlspt/settings/*` routes, so nothing here is on its critical path.

## What is switched off

All default to `false`; `readBoolKey` treats an absent key as false, so the code
is inert unless someone deliberately turns it on in `aowlspt-host.json`.

| flag | what it did |
|---|---|
| `settingsPostFxSubtab` | folded POSTFX into GRAPHICS as a cloned subtab strip |
| `settingsModsTab`      | the sixth MODS tab, cloned into `SettingsScreen/Toggles` |
| `settingsPages`        | Phase 3 – cloned control rows on a mod page |
| `modSettingsRender`    | fetched mod schemas over HTTP and rendered them as rows |
| `settingsNativeLifecycle` | native HIDE edge riding the `ShowScreen` postfix |

## Why it was shelved, and what is genuinely left

It did work in parts — POSTFX leaves the top row, the strip docks at the top,
the panels swap, row captions render. Three defects were never closed, all
measured, none guessed:

1. **The PostFX panel is EMPTY when shown.** Only the SELECTED tab is ever
   built: `set_IsSelected(true)` → vtable slot `0x2C8` `OnFirstSelect` →
   `CreateControls` fills `_createdControls` (+0x88). `gfxApply` switches panels
   by driving `SetActive` on the stock panel GameObjects DIRECTLY, which bypasses
   that path entirely, so the panel is activated and genuinely has no controls.
   Fixing this means making the GAME build the tab first (`ShowScreen(screen, 4)`
   for postfx, or the tab's `set_IsSelected`), then showing it — and `ShowScreen`
   is ASYNC, so it needs a poll, not an immediate read.
2. **The ~450px layout gap.** Measured live: the container `Other Settings` is
   850x785 with a `VerticalLayoutGroup`; the strip `Toggles(Clone)` is 501x46 at
   y=-20; `SettingsList` sits at y=**-420.5** and is squeezed to 354.5 tall. So
   ~374px is reserved for a 46px strip. The strip has NO `LayoutElement`
   (measured: `GetComponent` returns null) and carries the donor's
   `HorizontalLayoutGroup`. NOTE `UnityEngine.RectTransform` declares only ONE
   il2cpp field (`reapplyDrivenProperties`, static) — the anchoring values are
   native-side and reachable only through property getters, which is why the
   inspector needed the Vector2/`Rect` struct-return decoder before this was
   even measurable.
3. **The highlight lags one click behind.** Both strip toggles have
   `m_Group = 0` (no `ToggleGroup`), so a click sets one on without clearing the
   other; `gfxApply` then overwrites both from a `gGfxSel` computed a step
   earlier. The MODS strip already solved this properly — its log line says
   *"Exclusivity is NATIVE (Instantiate remapped each clone's m_Group onto the
   cloned group)"*. The postfx strip never got that treatment.

Separately, the MODS tab itself never finished building: `modsTabTick` faulted,
and fixing that oscillated between a fault (fresh `il2cpp_string_new` per call)
and silent nulls (a cached string going stale — managed strings are NOT
GC-pinned). Every diagnostic needed to resume is now in place: STAGE crumbs that
name the exact hop, a bind-time self-test, and decline-vs-absence counters so a
refusal can never masquerade as "there is no text here".

## If you pick this up again

Read facts #100, #104, #110, #114, #117, #120 first — they are the measured
traps, and re-deriving them costs hours. Then `tools/acceptance.py`, which
asserts the finished state rather than the write (CLAUDE.md rule 9b).
