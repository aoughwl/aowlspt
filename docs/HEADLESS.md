# Headless and unattended running — what is actually possible

The question was "is it easy enough to add a `--headless` launch arg?". The
honest answer is **no, not for the game client — and the flag most worth having
is not a client flag at all.**

This document records what was measured, so that nobody re-derives it and so
that no future `--headless` flag silently degrades into something weaker than
its name.

---

## The short version

| What | Verdict | Where it lives |
| --- | --- | --- |
| A truly headless **Tarkov client** | **Not possible.** Nothing here can make the client run without a renderer. | — |
| A headless **server-side run** (no client at all) | **Works today, and is the right answer for CI.** | `python tools/headless.py` |
| A **cheap** client run (small window, no exclusive fullscreen) | Works, in the sense that the switches are Unity's own and reach the client. Its effect on frame cost is **unmeasured**. | `aowlspt-launch --low-render` |
| A **virtual display** so a real raid runs off the user's monitors | Plausible, needs a driver install, **not installed on this machine**. | see below |

---

## Option 1 — Unity's `-batchmode -nographics`

**Measured:** `UnityPlayer.dll` in `D:\Aowlspt` contains the strings
`batchmode`, `nographics` and the diagnostic `"-nographics requires
-batchmode"`, plus `PlayerInitEngineNoGraphics` and the batch-mode player-loop
proxies `PostLateUpdate/BatchModeUpdate` and
`PostLateUpdate/PlayerRenderUIEBatchModeOffscreen`. So the *engine* in this
build has the batch-mode code paths compiled in.

**That is the whole of the evidence, and it is not much.** What has NOT been
established, and is not establishable from this side:

* whether BSG's own bootstrapper and BattlEye (`EscapeFromTarkov_BE.exe`) pass
  the switches through at all — `EscapeFromTarkov.exe` is packed, its string
  table is not readable, so its argument handling could not be inspected;
* whether the client survives the switches. It almost certainly does not in any
  useful sense: everything aowlspt does to the client — the live inspector, the
  auto-raid press ladder, the settings screen, the overlays — drives it
  **through its UI**, and a batch-mode player renders no UI at all;
* whether a raid can even be entered without a camera.

Nothing here has ever booted this client with these switches. The launcher can
pass them (`--low-render --nographics-anyway`) so that the experiment can be run
deliberately by someone watching, and it says in its own help and at launch time
that it is expected to fail. **It is not part of any automated mode.**

## Option 2 — small window / low resolution

This needed no new plumbing: `aowlspt-launch --args "..."` has always appended
arbitrary switches to the client's command line. `--low-render` is a spelling of
that, folded in at parse time so `--dry-run` prints the exact command line a
real launch would use.

Measured present in `UnityPlayer.dll`: `screen-width`, `screen-height`,
`screen-fullscreen`, `window-mode`, `popupwindow`.

**Not measured: whether it is actually cheaper.** The frame meter (`frameMeter`
flag, prints `RECENT (last 512 of 512) mean=Xms (Yfps)`) is how that would be
settled, and it requires a live raid, which a subagent must not run. A
resolution drop from 3840x2160 to 1280x720 is nine times fewer pixels and ought
to help a GPU-bound frame, but the ~32ms/frame figure has never been attributed
to the GPU rather than to the CPU-side game loop, and if it is CPU-bound the
saving is near zero. **Do not quote a speedup for this flag until it has been
metered.**

There is deliberately **no frame-rate cap**, because the host has no flag for
one; capping fps would mean calling
`UnityEngine.Application::set_targetFrameRate` at an RVA, which is a separate,
verifiable piece of work and not something to smuggle into a launcher flag.

## Option 3 — skipping our own overlay rendering

Not built. It reduces only our own cost, and our own cost has not been shown to
be the problem. Worth doing only after the frame meter says so.

## Option 4 — no client at all: `tools/headless.py`

**This is the real headless mode and it is the one that was built.** It runs
what needs no GPU, no display and no logged-in desktop:

```
python tools\headless.py --list            # suites and their prerequisites
python tools\headless.py                   # run them
python tools\headless.py --mutate NAME     # prove they can FAIL
```

Three suites today, all pre-existing work wired into one verdict — the
contribution is the single honest entry point and exit code, not new checks:

* `backend-selftest` — the backend drives every route it owns over the real
  wire, zlib framing included, and parses its own settings payload strictly;
* `admintrader` — `tools/acceptance_admintrader.py`, the mod loaded into
  `aowlspt-sim` against the real 41 MB `db.json`;
* `betacheck` — `tools/betacheck.py --spawn`, which starts its own backend,
  creates a profile and then **independently re-reads** it.

Rules it obeys, from CLAUDE.md §9b:

* **A missing prerequisite is INCONCLUSIVE, never PASS**, and the exit code
  says so (2). A run where nothing ran exits 2 and prints "this is NOT a pass".
* **The verdict is the child's exit code**, never a substring of its output. A
  suite that prints the word PASS while failing does not pass.
* **`--mutate` inverts the verdict**: a mutated run that fails exits 0
  ("FALSIFIER OK") and a mutated run that *passes* exits 1, because a check that
  cannot see an injected defect is the defect.

## Option 5 — an Indirect Display Driver (a virtual monitor)

The right instinct, and the correct Windows analogue of Xvfb — but note the
mechanism differs. Xvfb is a *software* framebuffer; that would be useless here
because the client is D3D11 and wants a GPU. An **Indirect Display Driver**
(IDD) instead presents a virtual monitor that Windows treats as real while the
**GPU still renders normally**. That is what would let a real raid run at a
resolution we choose, on no physical screen, while the user does something else.

**Measured on this machine, 2026-08-31 — no IDD is installed.**
`Get-CimInstance Win32_VideoController` returns exactly one adapter (NVIDIA
GeForce RTX 2060 SUPER, 3840x2160, driver 32.0.15.8142) and `Get-PnpDevice
-Class Display,Monitor` lists that adapter plus four `Generic PnP Monitor`
entries, of which three are `OK`. There is no `Root\`-enumerated display device,
no `IddSampleDriver`, and `pnputil /enum-drivers` shows only `nv_dispi.inf` in
the display class. **Installing one is a system-level change and is the user's
decision, not a tool's.**

What it would buy over option 2: the game runs at full speed on the GPU, on a
monitor that does not exist, and does not occupy a screen the user is using.
Option 2 only makes the window small — it is still on a real desktop, still in
the way.

Failure modes to expect, and they are the reason this is a proposal and not a
patch:

* **Session lock / logoff.** An IDD's virtual monitor lives in an interactive
  session. If the session locks or the user logs out, the display can go away
  under the running game. That is worse than no headless mode, because runs
  become flaky rather than absent.
* **RDP is a trap.** Connecting over RDP swaps in the RDP display and can sever
  the GPU from the session. Do not "fix" a virtual-display problem with RDP.
* **Enumeration.** Whether this client offers the virtual monitor's modes in its
  own display list is unknown and has not been tested.

**Does the launcher need to target a display?**

> **CORRECTION, 2026-08-31.** This section previously said "no `monitor` string
> at all", and that is **wrong**. Re-measured with `strings -a UnityPlayer.dll`:
> the bare token `monitor` is present (`grep -Fx` count 1), and so is the
> diagnostic **`"The command-line parameter 'adapter' has been removed. Please
> use 'monitor' instead."`** — which is Unity's own message about `-monitor`.
> Also present: `force-device-index`, `displays`, `displayRefreshRate`,
> `force-driver-type-warp`. The earlier claim was most likely made with a search
> that did not match a bare token. **`-monitor N` is very probably usable on
> this build.** It has still NOT been passed to the client, so "the string is
> there" is the measurement and "it works" is not.

Independently of `-monitor`, a display can be chosen by moving the window after
it appears. That is now built: **`tools/offscreen.py`**, and `tools/harness.py
run --offscreen`. See below.

An IDD is still the only thing that gets a raid onto a display that does not
exist; the risk is entirely in the driver, not in the flag.

---

## What `--low-render` does and does not do

Does: appends `-screen-width W -screen-height H -screen-fullscreen 0
-popupwindow` (default 1280x720, `--render-size WxH` to change) ahead of any
`--args` you typed, so yours still win. Prints the mode at launch. `--dry-run`
prints the exact resulting command line.

Does **not**: make anything headless. The renderer runs. The window is visible
and on a real monitor. There is no frame cap. The host's overlays are untouched.
It does not pass `-batchmode`/`-nographics`.

`--headless` is accepted as an alias only because it is what people will type.
The flag is named `--low-render` everywhere else, on purpose.

---

## Option 6 — park the window off every monitor (BUILT, 2026-08-31)

This is the cheap 80%, and it is the answer to "run a test raid while I do
something else". The client renders normally on the GPU, in a window, at a
position that intersects **no monitor**. Nothing is on the user's screen. It is
not headless and the tool never says it is.

```
python tools\offscreen.py --selftest              # offline; no game needed
python tools\offscreen.py monitors | where | rvas
python tools\harness.py run --offscreen --profile <id> --until "host running"
```

`--offscreen` implies `--low-render`, because a **fullscreen** Unity window
cannot be parked. Measured on the running client 2026-08-31: its window is
`'EscapeFromTarkov'` at rect `(0,0)-(3840,2160)` — the full primary monitor.

### The assertion is a negative, and it is the finished state

Not "SetWindowPos returned non-zero". After the fact: does the window rect
intersect any monitor? Answered two independent ways that must agree —
`MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL)` (Windows' own opinion) and our
own intersection of `GetWindowRect` against every `EnumDisplayMonitors` rect. A
disagreement is **INCONCLUSIVE**, never a pass.

**A minimised window is a distinct, non-passing outcome.** Windows reports a
minimised window at `(-32000,-32000)`, which reads as "off-screen" to a naive
check — and minimised is precisely the state Unity is most likely to throttle.
That would have been a false pass.

`harness.py --offscreen` **re-checks at the end of the run**, not only after the
move: the client changes window mode several times during boot and can put
itself back on a display. A run that reaches its sentinel but ends NOT PARKED is
reported as incomplete, not 0.

`--selftest` runs the classifier against a window the tool creates itself and
demands VISIBLE → OFF-SCREEN → VISIBLE-when-straddling-an-edge → MINIMISED. A
classifier that cannot say anything but OFF-SCREEN is useless, and that selftest
is what makes shipping one impossible. **PASS on this machine, 2 monitors.**

## The throttle question — NOT SETTLED

An off-screen window is not minimised, so the position itself should not
throttle anything. **Focus** is the variable, and it is not resolved:

* **Measured:** `UnityEngine.Application::set_runInBackground` is **ABSENT from
  this build's metadata** — the managed linker stripped the unused setter. We
  therefore **cannot turn `runInBackground` on**. `get_runInBackground` exists
  at RVA `0x525BE20` and `get_isFocused` at `0x525BDD0`, both
  `sharedness=UNIQUE` with real bodies, so both are *readable* live.
* **Not measured:** what BSG set `Run In Background` to. It lives in
  `globalgamemanagers`, not in anything read here.
* `python tools\offscreen.py throttle` settles it behaviourally off the host's
  `frameMeter` line, comparing two windows of readings and refusing a verdict
  from fewer than two readings per window. `frameMeter` is already set in the
  live `aowlspt-host.json`.

Until that has been run, **do not assume a parked client keeps full frame rate
when it does not have the foreground.** `park --defocus` is opt-in for exactly
this reason; the default leaves focus on the client.
