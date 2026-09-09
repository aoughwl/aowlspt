# Spatial — map, radar and direction indicators

One mod, one position feed, three views of it. Display name **"Spatial"** —
plain, describes all three, carries no upstream project's branding.

    server   GET /aowlspt/ui/page/spatial     the page
             GET /aowlspt/ui/lib/spatial.js   the library it is built from
             GET /aowlspt/maps/index          11 maps
             GET /aowlspt/maps/map/<id>       one map's calibration
             GET /aowlspt/maps/asset/<p>.svg  terrain (image/svg+xml)
             GET /aowlspt/maps/feed           the live snapshot, or a reason
             GET /aowlspt/maps/status         diagnostics

## Where it came from

`savannt/SPT-DynamicMaps` @ `7d7aa109a855bb457342c0df98d2b2e059e061b5`,
confirmed to carry the real terrain SVGs before anything was copied (47 files,
2,639,128 bytes — read from the git tree, not assumed). Behaviour for the radar
and the indicators is specified from `Leonana69/Tyrian-Radar-Standalone` and
`acidphantasm/acidphantasm-accessibilityindicators`.

**No code is carried over from any of the three, and none could be.** They are
BepInEx/Mono plugins for pre-1.0 EFT; this build is IL2CPP with no BepInEx, and
every Harmony patch they use is a by-name route that is fatal here (fact #145).
The map art and calibration ARE reused — they are data. See
`data/maps/README.md` for provenance and the unsettled licence question.

## What touches the game, and what it is allowed to do

Exactly one file: `sp/world.nim`. It resolves **no** IL2CPP name, installs
**no** detour and calls **no** game method. It has two capabilities:

* the world pointer **borrowed** from `aowl_host_gameworld`, which the host's
  already-armed `RegisterPlayer` detour fills. No second detour is added —
  a second detour on one function overwrites the first's trampoline.
* raw reads at offsets measured with `tools/fldoff.py`, each guarded by
  `aowl_is_readable` (VirtualQuery), so a stale offset is a zero and not a fault.

Offsets, all re-measured for this mod rather than copied:

    EFT.GameWorld  AllAlivePlayersList               0x1c8
    EFT.GameWorld  RegisteredPlayers                 0x1d0
    EFT.GameWorld  MainPlayer                        0x230
    EFT.Player     <MovementContext>k__BackingField  0x60
    EFT.Player     <Profile>k__BackingField          0x9c0
    EFT.Player     <AIData>k__BackingField           0xa00
    EFT.MovementContext PreviousPosition             0x370
    EFT.Profile    Id                                0x10

Arming is gated on `gwState()`, **not** on `whenReady("EFT.GameWorld")` —
fact #141: that gate tests whether a type resolves, which is true from
`il2cpp_init` onward whether or not a world or a Unity thread exists. It is a
check that cannot fail and it has killed the client for three separate mods.

The eight live-path rules: prologue verify **n/a** (nothing is patched or
called); VirtualQuery on every hop ✓; one `aowl_p_p_seh` ✗ **n/a** — there is no
SEH region because there is no call into game code, only guarded reads; capped
iteration ✓ (128 entities, 1024 list ceiling); flag-gated default OFF ✓; self-
disable after 8 faults ✓; no per-frame managed allocation ✓ (the Unity thread
fills a preallocated buffer; all formatting and file IO is on the mod's own
timer thread); never blind-write ✓ (nothing is written to game memory at all).

## Why the draw surface is a browser page

Native Unity UI is off the table for this project. Of what is left — the D3D11
overlay or a browser — the browser is the better fit *for these three views*,
not a consolation prize: an SVG map needs pan, zoom, layer switching and a
vector rasteriser, and the overlay's renderer is hand-written per-shape C with
a bitmap font. Putting the map there would mean writing an SVG rasteriser
inside the game's Present hook.

The cost is real and is not hidden: the radar and the indicators are on a
second screen rather than over the game.

## Status, honestly

**WORKS, verified without the game** (`python mods/maps/acceptance.py URL`,
`node mods/maps/transform_test.js URL` — 9 pass / 0 fail each):
terrain serving for all 36 layers with the correct MIME type, the traversal
guard, the calibration, the page and library, the feed's four-state reporting,
the torn-write detector, and the whole coordinate transform.

**UNVERIFIED — needs a live raid.** No position has been read from a running
client in this session; a subagent may not start the game. Everything in
`sp/world.nim` is therefore unproven against real memory. The falsifying test
is in "How to falsify this" below.

**WEAK — map auto-selection.** Measured: feeding each map's own centre back into
`inferMap` resolves to that map for only **3 of 11**. Map bounds overlap
heavily, so the automatic guess is often wrong. It says so in the UI, prints how
many maps contain the point, and a hand-picked map always wins.

*What would make it exact:* the raid's location id (`bigmap`, `Woods`, …), which
each map's `internalNames` already lists. It is not in the feed because reading
it would be another unmeasured game-memory hop. The cheap alternative is the
backend: the client tells the server the location at raid start, so a hook on
that route could publish it with no game read at all. Not done here because
those routes belong to `mods/tarkov`.

**NOT DRAWN — player heading.** No rotation field was measured, so the feed
publishes `hasHeading:false`, the radar draws north-up with a banner saying so,
and the indicators show **world** bearings rather than screen-relative arrows.
A screen-relative arrow without a heading would point somewhere for every
threat and be right only when the player happens to face north — a confidently
wrong picture, which is worse than none.

**DONE — in-game overlay drawing.** This was listed BLOCKED on the grounds that
the only generic draw region was `abi/aowlspt_admin.h`'s ESP surface, owned by
another feature, and that a second Present hook is the double-detour hazard.
The hazard was real; the conclusion was not. `abi/aowlspt_region.h` is the
shared per-frame region — one dispatch point, any number of participants, each
entered through exactly one non-nested guard — and `sp/hud.nim` registers a
DRAW callback on it. No second hook, nothing borrowed from another mod's
private header.

Caveats that are part of the feature, not excuses:

* The region is armed by the **host flag `sharedRegion`, default OFF**. A mod's
  registration always succeeds; a registered participant on an unarmed region
  never fires. The mod logs those as two different states.
* Marks are FILL and BOX only. `AOWL_REGION_CMD_LINE` exists but the overlay
  rasterises a line as the axis-aligned quad spanning its endpoints, so a
  diagonal comes out as a filled rectangle.
* The radar is **north-up**, because no heading has been measured (below).
* The layout takes the screen size from `screenW`/`screenH` in config, because
  the region tracks `screenW`/`screenH` internally but nothing calls
  `aowl_region_set_screen` and no getter is exported — so asking it would
  return a value that is provably always 0.

**NOT PORTED** from upstream: loot, corpse, extract, quest, airdrop, BTR,
transit and locked-door markers; minefields; item pricing. Every one needs game
state this feed does not carry, and each is a separate measured offset chain.

## How to falsify this

Offline, no game:

    python mods/maps/acceptance.py    http://127.0.0.1:6969
    node   mods/maps/transform_test.js http://127.0.0.1:6969

Both fail loudly if broken — verified by deleting one asset and confirming
`FAIL the index names an asset that is not on disk`.

Live, needs a raid — this is the part nobody has run:

1. set `enabled: true` in `mods/maps/config.json`, deploy, start a raid;
2. `curl -s "http://127.0.0.1/aowlspt/maps/feed?ident=1"` must report
   `"state":"live"` with `localIdx >= 0`;
3. open `/aowlspt/ui/page/spatial` and pick the correct map by hand;
4. **the falsifying test:** walk 100 m in a straight line. The blue marker must
   move ~100 m in the same direction on the map. If it moves the wrong way, the
   `CoordinateRotation` handling is wrong; if it moves along the wrong axis,
   the (x, z) swap is wrong; if it does not move, the feed is stale.

Step 4 is the one that matters. Steps 1–3 only prove numbers are arriving —
they cannot prove the numbers mean what the map says they mean.

## `both`, and the bounded draw verdict (2026-09-04)

**`spatialMode="both"` draws the minimap and the radar at once** — two panes in
one dispatch, both through `mhud_draw_pane_full`, the one pane renderer, so the
two surfaces cannot drift apart. It is the only mode entitled to a second pane,
and that entitlement is a NUMBER (`mhud_pane_expect`, resolved from the mode
*before* any pane is drawn) that the ledger compares against — not an exemption
from the check. `paneCallsOver` still catches a third pane; the new
`paneCallsUnder` catches the opposite and quieter failure, `both` selected and
only one surface drawn, which the old hardcoded `> 1` test could not express at
all.

`both` is also the only mode in which `radarAnchor` / `radarX` / `radarY` /
`radarSize` are live geometry rather than migration-only keys: two panes need
two rects or they land exactly on top of each other. `radarAnchor` defaults to
`manual`, the historical absolute placement, so no existing radar moves, and it
goes through the same anchor resolver as the widget — one placement rule, not
two that can disagree. It is mirrored (`hudLiveRadarAnchor`) and compared by the
reconcile, so a value stored and never pushed reads as DRIFT rather than
agreeing with itself.

**`drawVerdictFrames` bounds the draw verdict.** "A surface is selected and
nothing has drawn *yet*" is true on frame 3 and a defect on frame 3000, and
unbounded it is a verdict no input could falsify — the exact shape §9b is about.
The clock is dispatches that got past the in-raid lifecycle gate
(`mhud_raid_frames`), counted by the C renderer, so menu frames cannot spend it.
Past the budget the diag says FAIL and names the mode.

**The mode table moved to `core/place.nim`.** `spatialMode` was the one enum in
this mod whose schema list was never checked against its own parser — precisely
the defect `widgetAnchor` shipped — because the table lived in `sp/hud.nim`,
which the offline suite cannot reach. The suite now asserts that every spelling
the schema offers is recognised, that the canonical spellings round-trip, that a
typo resolves to OFF and not to some third surface, and that no single-surface
mode claims two panes.

**The four marker kinds are named, and every one is `implemented=false`.**
Splitting the umbrella `markers` switch into `markerLoot` / `markerExtracts` /
`markerQuests` / `markerCorpses` makes nothing draw. It makes the refusal
specific about which measurement is missing per kind — no field offset has been
taken on build 1.1.0.1.46777 for the loot, exfiltration, quest or dead lists,
and `sp/world.nim` walks the ALIVE players list only. A switch that stores a
value and silently does nothing would be worse than an absent one.

**Unverified:** none of the above has been seen in a running raid — a subagent
may not start the game. `both`'s two-pane draw, the radar anchor's live
placement and the bounded FAIL are asserted offline and by counters the live
diag prints; that is evidence, not proof.
