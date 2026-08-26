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

**BLOCKED — in-game overlay drawing.** The radar and the indicators are pure
2D and would suit the overlay, but the only existing generic draw region is
`abi/aowlspt_admin.h`'s ESP surface, which another feature owns, and adding a
second Present hook is the double-detour hazard. *Unblock:* agreement to
publish into that existing region (it already carries per-frame primitives),
after which `RadarView`/`IndicatorView`'s maths ports directly — they are
already pure functions of the snapshot.

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
