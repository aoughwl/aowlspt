# Debug

The F3 debug overlay's configuration surface, and the per-mod profiler.

Display name is **Debug**. Guid `aowl.debug`. Nothing about it is branded.

## A. The F3 overlay

The Minecraft-style info panel is drawn Unity-natively by the host
(`host/Aowlspt.Host.Il2Cpp/debugui.nim`) and is toggled by a configurable
virtual-key code that ships as **114 = VK_F3**. This mod does not draw it. What
it adds is that every choice about it is a **setting** instead of a hand edit:

| setting | what it controls |
|---|---|
| `overlayFields` | **which lines, in what order**, top to bottom |
| `overlayAnchor`, `overlayX`, `overlayY` | where on screen |
| `overlayFontSize`, `overlayLineHeight`, `overlayColor` | how it looks |
| `overlayThrottle` | how often it rebuilds its text |
| `overlayToggleKey` | which key opens it |
| `overlayEnabled` | whether it draws at all |

Applying any of them rewrites `aowlspt-debugui.json` beside the host DLL, and
the host re-reads that file **on every toggle-on**. So the round trip is
*change a setting → press F3 off → press F3 on*. No rebuild, no restart.

Line names: `fps`, `frame`, `frametime`, `build`, `map`, `raid`, `bots`, `pos`,
`rot`, `botlist`, `prof`, `prof1`..`prof8`, `note1`..`note3`. An unrecognised
name prints itself with a `?` rather than vanishing, so a typo is visible on
screen instead of being an inexplicably missing row.

`frametime` and `prof*` are new and come from the profiler. They print an
explicit "profiler OFF" when it is off — never a zero.

**It refuses rather than guessing where to write.** The target directory is
derived from this mod's own directory (up two levels) and then *checked*: it
must already contain the host's `aowlspt-host.json`. If it does not, nothing is
written and the log says where it looked. Under the simulator that refusal is
the expected output.

## B. The profiler

The aowlspt-shaped answer to ModProfiler. Not a port — ModProfiler is
BepInEx/Mono and reflects over plugins; this build is IL2CPP and reflection
faults. Same idea, different route: aowlspt funnels every mod's per-frame work
and every host feature's per-frame work through a small number of dispatch
points **whose source we own**, so those are instrumented directly.

| dispatch point | slots |
|---|---|
| `host/common/modhost.nim` `tickMods` | one per **mod**, keyed by guid |
| `aowlhost.nim` `patchFired`/`patchReturned`, the shared `PreloaderUI::Update` rider chain | one per **host rider** |
| the same rider chain | the frame-time histogram |

Reported per slot: absolute ms over a rolling window, share of the window's
**wall time**, call count, and single-worst-call peak. Plus frame time as
min/p50/p95/p99/max.

**Backend route timing is not instrumented** and is reported as
`UNMEASURED`, never as zero. `AOWL_PROF_KIND_ROUTE` is reserved for it.

### It cannot kill the client

No IL2CPP name is resolved, no game method called, no detour bound, no game
memory read, no byte patched. The entire native surface is a shared page this
process created plus a `QueryPerformanceCounter` pair. **No new detour** — it
rides dispatch points that already exist.

### Its error bars, stated rather than hidden

* A begin/end pair costs ~50 ns (measured at startup by timing 4096 empty
  scopes). It is **published and never subtracted** — subtracting an estimate
  from a number you then read back is a self-comparison.
* A slot within 3x of that is tagged `[at the noise floor]`, not reported as a
  measurement.
* The share denominator is the window's **wall time**, deliberately not the sum
  of the slots. Slots over the sum of slots always totals 100% and is therefore
  a statistic that cannot be wrong.
* `-1` share renders `--`. There is no window in which "I could not look" is
  printed as `0.0%`.
* On the backend and the simulator there is no frame source, and the report
  says **NOT A FRAME SOURCE** instead of inventing a frame time.

### How to falsify it

`selfTestSpinMs` makes *this* mod busy-spin N ms per tick. Measured in the
simulator, 500 ticks, 20-tick window:

| spin | `aowl.debug` reported |
|---|---|
| 5 ms | 177.378 ms / 20 calls, 56.7%, peak 9.945 ms |
| 0 ms | 0.013 ms / 20 calls, 0.0%, peak 0.004 ms |

Four orders of magnitude, from one setting. The first version of that spin was
capped by its own iteration guard at ~0.9 ms and the profiler reported 0.9 ms —
the profiler was right and the test was wrong, which is why the knob is
separate from the thing it tests.

**What that does NOT establish**, and the live test that would: only one mod was
loaded, so it does not show the cost lands on *this* mod rather than a sibling.
Load Debug alongside other mods, set the spin, and check that every other row is
unchanged.

## Reading it

* In game: put `prof`, `prof1`..`prof8`, `frametime` in `overlayFields` and
  press F3.
* Over HTTP: `GET /aowlspt/debug/profile`.
* In the log: the mod prints the report once, after 400 ticks.

## Defaults

Both halves are **OFF**. Loading the mod changes nothing on screen until a
setting is turned on.
