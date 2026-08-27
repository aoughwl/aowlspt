# The in-game debug overlay (`debugUi` / `debugEsp`)

A Minecraft-F3-style info panel and in-world markers over AI bots, drawn as
**real Unity UI by the game itself** — not a D3D/ImGui overlay. It exists to
answer one live question quickly: *are the AI bots spawned, where are they, and
are they moving?*

Both features are **opt-in and default OFF**. Nothing is drawn until the toggle
key is pressed, and neither feature ever writes to game state — the only writes
are into UI objects the overlay itself cloned.

---

## Turning it on

In `aowlspt-host.json`, beside the host DLL:

```json
{
  "debugUi":  true,
  "debugEsp": true
}
```

`debugUi` gives the panel, `debugEsp` adds the in-world bot markers. Either one
arms the same per-frame detour, so setting only `debugEsp` still works.

Then press **F3** in game. Press it again to hide.

---

## What it draws

### The panel

One cloned Unity label per line, in the game's own font, in the game's own
canvas, scaling with the game's own resolution. Which lines appear, and in what
order, is `panelFields` in the layout file:

| field     | shows |
|-----------|-------|
| `fps`     | frames per second, plus the host's own tick counter |
| `frame`   | how many times the detour has fired |
| `build`   | host name/version and the client build |
| `map`     | `GameWorld.LocationId`, or `menu / no GameWorld` |
| `raid`    | whether a GameWorld is live, and its pointer |
| `bots`    | registered / AI / alive counts |
| `pos`     | your player's world position |
| `rot`     | your player's yaw and pitch |
| `botlist` | the first few AI bots with world coordinates and a dead marker |
| `note1` `note2` `note3` | free text from the keys of the same name |

An unrecognised field name prints as `?name` rather than vanishing, so a typo in
the config is visible on screen instead of being a mysteriously missing row.

`botlist` is the line to add when chasing frozen bots: it needs no camera and no
projection, so it works even if world→screen is unavailable, and a bot whose
coordinates never change between refreshes is *visibly* frozen.

### The markers

One cloned label per registered AI bot, positioned by projecting the bot's world
position to screen space with `Camera.main.WorldToScreenPoint`. Bots behind the
camera and bots past `espMaxDistance` get no marker. Text is whatever
`espFields` asks for (`role`, `nick`, `dist`, `pos`), plus `[dead]` when the bot
is not in the alive list.

If `Camera::get_main` or `Camera::WorldToScreenPoint` does not verify on the
running build, the markers are skipped, one warning is logged, and the panel's
`botlist` field remains the fallback.

---

## The layout file

`aowlspt-debugui.json`, beside the host DLL. Every key is optional; anything
absent keeps the built-in default, and unknown keys are ignored.

It is read at boot **and again on every toggle-on**, so you can edit it, press
F3 twice, and see the new layout without restarting the game.

```json
{
  "panelEnabled":    true,
  "panelAnchor":     "topleft",
  "panelX":          16,
  "panelY":          -16,
  "panelFontSize":   18,
  "panelLineHeight": 22,
  "panelThrottle":   10,
  "panelColor":      "1,1,0.62",
  "panelFields":     "fps,frame,build,map,raid,bots,pos,rot,botlist",

  "espEnabled":      true,
  "espFontSize":     14,
  "espMaxMarkers":   24,
  "espMaxDistance":  400,
  "espYOffset":      24,
  "espColor":        "1,0.35,0.3",
  "espFields":       "role,nick,dist",

  "toggleKey":       114,
  "espToggleKey":    0,

  "note1": "",
  "note2": "",
  "note3": ""
}
```

| key | meaning |
|-----|---------|
| `panelEnabled` | draw the panel at all |
| `panelAnchor` | `topleft`, `topright`, `bottomleft`, `bottomright`, `top`, `bottom`, `center` |
| `panelX` / `panelY` | offset from that corner, in canvas units. **Unity's Y grows upward**, so a top anchor wants a *negative* Y to move down. |
| `panelFontSize` | point size of every panel line |
| `panelLineHeight` | vertical spacing between lines |
| `panelThrottle` | refresh every Nth frame, 1..600. 10 is invisible to a human and costs a tenth as much as 1. |
| `panelColor` | `r,g,b` in 0..1. A value that does not parse into three numbers leaves the colour alone — a half-applied colour is never written. |
| `panelFields` | comma-separated, one line each, in order (max 12) |
| `espEnabled` | draw markers |
| `espFontSize` | point size of a marker |
| `espMaxMarkers` | 0..48; the label pool is built once at this size |
| `espMaxDistance` | metres; farther bots are skipped |
| `espYOffset` | pixels above the bot's feet |
| `espColor` | `r,g,b` in 0..1 |
| `espFields` | any of `role`, `nick`, `dist`, `pos` |
| `toggleKey` | virtual-key code. 114 = `VK_F3`, 115 = F4, 116 = F5. |
| `espToggleKey` | 0 means the markers follow the panel toggle; a non-zero code gives them their own key |
| `note1..3` | free text, shown by the `note1..3` fields |

The schema is **flat** on purpose. The host has no JSON parser and does not want
one on a per-frame path; a shallow key scan is enough for flat keys, whereas a
nested schema read by a shallow scanner would happily find `"x"` inside the
wrong object.

The label pool is sized when the overlay first builds, from `panelFields` and
`espMaxMarkers`. Changing *those two* takes effect on the next game start;
everything else (positions, colours, sizes, which fields show, the throttle)
applies on the next toggle-on.

---

## How it is built (and why it cannot crash the client)

* **Clone, never create.** Every label is
  `UnityEngine.Object::Instantiate(Object)` — one static call, one reference
  argument, no `System.Type` and no generic `MethodInfo*` — applied to the
  client's own bottom-left version label, which exists in the menu and in a
  raid. The clone is re-parented into the canvas root with
  `TMP_DefaultControls::SetParentAndAlign`. Nothing depends on
  `il2cpp_object_new` or `AddComponent<T>`.
* **On the Unity thread.** Everything runs inside a prefix detour on
  `EFT.UI.PreloaderUI::Update`, which is the Unity main thread. If it ever fires
  on the host thread it refuses outright.
* **Guarded.** The whole per-frame body runs under one `aowl_p_p_seh` VEH/setjmp
  guard, every pointer hop is `VirtualQuery`-checked before it is followed, every
  iteration is capped, and every store checks the destination is committed and
  writable first. A fault is caught, logged and skipped; after eight faults the
  overlay switches itself off for the session rather than fault every refresh.
* **Verified per build.** Every managed function it calls is checked by RVA *and*
  by a 16-byte prologue compare before it is called. On any build whose bytes
  differ, the lookup returns null and the step is skipped — the overlay goes
  blank, the game does not.
* **Read-only towards the game.** Bot data comes from the same read-only
  `GameWorld.RegisteredPlayers` walk `botDiag` already uses.

See `abi/aowlspt_debugui.h` for the RVAs, the disassembled evidence for each
calling convention, and the offline-resolved field offsets.

---

## Widgets (drag, snap, toggle, persist)

The single stacked column is now **N independent widgets**. Each is one Unity
label holding several lines, with its own anchor, its own offset, and its own
on/off — and each can be dragged with the mouse.

| widget | default corner | shows |
|---|---|---|
| `fps` | top-left | fps, host ticks, frame-time min/p50/p95/p99/max |
| `scene` | top-left | map id, raid state and the GameWorld pointer |
| `pos` | top-left | your world position and yaw/pitch |
| `mem` | top-right | process working set, private bytes, system load |
| `bots` | bottom-left | registered / AI / alive, then per-bot coordinates |
| `prof` | top-right | **per-participant budget vs actual** (see below) |
| `build` | bottom-left | host name/version, client build, detour fire count |
| `notes` | bottom-right | the three free-text note slots |

### The keys

* **F3** — show / hide.
* **Ctrl+F3** — enter / leave **edit mode**. Default OFF within a visible panel.
* In edit mode: **left-drag** a widget; **1**–**9** toggle a widget; **0**
  resets every widget to its built-in corner.

Edit mode is its own state because a left click that grabbed a widget would
otherwise change what the mouse does in a raid. The overlay **does not hook or
swallow input** — it polls `GetAsyncKeyState`/`GetCursorPos`, so the game still
receives every click. The on-screen banner says so.

**Why the F10 bug cannot recur here.** F10 never reached the D3D overlay because
Windows delivers it as `WM_SYSKEYDOWN`, not `WM_KEYDOWN`. This overlay reads no
window message at all: the async key state is updated by the raw-input thread
*before* any message exists, so there is no classification to get wrong. That
argument is *measured* rather than asserted — the first time the toggle edge
fires, the host log records which route saw it and the vk code.

### Snapping

A drop snaps to the screen edges, to the corners, and to other widgets (flush
left/top edges, or abutting with a small gap). A snap **rebinds the anchor**
rather than nudging the offset, which is what makes the saved layout survive a
resolution change: a widget dropped bottom-right is stored as *"bottom-right,
minus 12"*, not as *"x = 2436"*. A widget is also always pulled back on-screen,
so a bad drag can never make one unreachable.

Screen bounds come from the game window's own `GetClientRect` divided by the
canvas's **measured** `scaleFactor`. Never from a constant, and a read that
comes back below 16px is refused rather than used.

### Persistence

Two files, beside the host DLL:

| file | written by | holds |
|---|---|---|
| `aowlspt-debugui.json` | **you** | which widgets exist, their titles and fields |
| `aowlspt-debugui-layout.json` | **the overlay** | only `on` / `anchor` / `x` / `y` |

The overlay never writes to your file, so a drag cannot destroy anything you
typed; deleting the layout file resets every placement. The layout file is
written on every drop and every widget toggle — never per frame — and a failed
write is logged as a warning rather than silently losing the arrangement.

Keys are flat and dotted (`w.fps.x`), not nested, because the host's shallow
key scanner would happily find an `"x"` belonging to a different object.

### The profiler widget

`prof` shows, for every participant of the shared region
(`abi/aowlspt_region.h`):

```
  name   last / budget ms   peak   calls  [skip N] [over N] [FAULTS N] [flag]
```

**No new detour and no new timer.** The region dispatcher already times each
participant against the budget it declared at registration, and already counts
overruns, faults and skipped frames — this reads that accounting through
`aowl_region_status_x` and formats it.

It refuses to invent numbers: a participant that has never been called shows
`--`, not `0.000`. An unarmed region says *"region NOT ARMED — no per-mod timing
is being collected"*, and an armed region with nothing registered says *"that is
not 'nothing is slow' — it is 'nothing is measured'"*.
