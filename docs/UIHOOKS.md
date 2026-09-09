# UIHOOKS — subscribe to a screen instead of hunting for it

**Files:** `abi/aowlspt_uihooks.h` (the site table),
`host/Aowlspt.Host.Il2Cpp/uihooks.nim` (the registry + dispatch),
three lines of wiring in `aowlhost.nim`.

---

## 1. The problem, measured

Four cosmetic UI features found their control by walking the live Unity tree on
a cadence, **forever**, on the Unity main thread:

| feature | cadence | file |
|---|---|---|
| `singleplayerRebrand` | ~10 Hz scene-root re-walk, 18 ms slice | `splrebrand.nim` |
| `uxVersionBrand` | 120-frame throttle on the PreloaderUI rider | `modstab.nim` |
| `uxHideSeasons` | 120-frame re-check | `modstab.nim` |
| `uxHideModeButton` | 4-frame hunt, up to 300 s | `modstab.nim` |

Every one of them is looking for something that appears **once**, on a definite
user action.

The instrument is the host's own log (`python tools/hostlog.py summary`). The
rebrand's line, repeated at ~100 ms intervals for a whole session:

```
singleplayer rebrand: not resolved -- BUDGET, not absence: the scan for node
"MainCaption" under screen "Matchmaker Offline Raid Screen" (scan reached level
4 of 12, visited 64 node(s)) was CUT OFF by the WALL-CLOCK SLICE (18 ms)
```

64 nodes of interop per slice, ~10 times a second, resolving nothing, for as
long as the client ran. Tarkov is main-thread bound; that time comes out of bot
AI and rendering.

## 2. The mechanism

The game announces the action. Each concrete EFT menu screen has its own `Show`
on its own concrete type — non-generic, **UNIQUE** (one owner at that RVA), a
real body. A **POSTFIX** detour there fires exactly when the screen is shown and
hands the live screen object over in `RCX`.

A feature therefore:

1. calls `uihWant(site)` from its flag block — **before** the arm pass;
2. gets `<feature>OnScreenShown(self)` called with the live screen;
3. applies its change once, reads the finished state back, and goes idle.

Between events the feature's rider returns on an integer compare and touches
nothing.

### The sites (offline-verified, build 1.1.0.1.46777)

Produced by
`python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat typemethods|bytes|shared …`.
The game was never run to obtain them.

| id | method | RVA | sharedness | prologue (16) | armed by |
|---|---|---|---|---|---|
| 0 | `EFT.UI.Matchmaker.MatchmakerOfflineRaidScreen::Show(OfflineRaidScreenController)` | `0x1788590` | **UNIQUE** | `48 89 5C 24 08 57 48 83 EC 30 80 3D 2F 61 93 05` | `splrebrand.nim` |
| 1 | `EFT.UI.MenuScreen::Awake()` | `0x1538360` | **UNIQUE** | `40 53 48 83 EC 20 80 3D 2D 55 B8 05 00 48 8B D9` | *(nobody yet)* |
| 2 | `EFT.UI.MenuScreen::Show(MatchmakerPlayersController, ExpansionsPlayerInfo, GameModeDescriptor, Profile, SeasonalRewardController)` | `0x15387A0` | **UNIQUE** | `48 89 5C 24 10 48 89 74 24 18 48 89 4C 24 08 57` | `modload.nim` (the deferred mod release gate) |

Both steal 17 / 16 bytes respectively; the only relative operand cut is a
RIP-relative `cmp byte [rip+…],0` displacement, which `aowl_copy_relocated`
fixes up — the same shape as `SettingsScreen::Show` @`0x171FA00`, detoured by
this host for months. Nothing else in the repo detours either RVA (grepped).

### Two candidates that were REJECTED, and why

* **`EFT.UI.Screens.UIScreen::ShowGameObject(bool)` @`0x172E7B0`** (UNIQUE, real
  body) would be one universal hook. But telling *which* screen was shown from
  inside it needs the receiver's class, and `il2cpp_object_get_class` is
  `mov rax,[rcx]; ret` — for a bad pointer it returns a **plausible number**
  rather than failing. A per-screen site needs no type identification at all:
  the site *is* the answer.
* **`EFT.UI.MenuScreen::Show(MainMenuBaseScreenController)` @`0x1538760`** is the
  true show event for the main menu, but its prologue is
  `48 83 EC 48 | 48 85 D2 | 74 31 | 48 8B 42 68 | 4C 8B 4A ..` — the 14-byte
  steal **cuts across a `jcc rel8`**, which `aowl_copy_relocated` refuses to
  relocate. The bind would fail safely, but a site that can never bind does not
  belong in a table of subscribable sites. `MenuScreen::Awake` is listed instead
  and is honestly labelled a **construction** event, not a show event.

`ScreenController\`2::ShowScreen` is not a candidate at all: uninstantiated
generic, RVA `None`, and a NULL `MethodInfo*` is not acceptable for shared
generics (`docs/NATIVE_SCREEN_NAV.md` §2).

## 3. The API

```nim
uihWant(site: int)            # subscribe.  MUST run before the single uihArm.
uihArm(verbose: bool)         # install one postfix detour per WANTED site. Once.
uihBound(site: int): bool     # did my site actually bind?  Read AFTER uihArm.
uihEpoch(site: int): int      # monotonic count of GOOD show events
uihSelf(site: int): Il2CppPtr # last receiver, re-liveness-checked on the way out
uihFires(site: int): int      # raw firings, including ones with a bad receiver
uihStatusLines(): seq[string] # one line per site for the boot summary
```

Delivery is a **direct call**, not a callback table: `uihDispatch` is a
hand-written `if` chain. A table of proc pointers is a call into possibly-freed
code with no way to verify it first, which is the class of failure the rest of
this host spends its effort refusing.

`uihEpoch` / `uihSelf` exist for a subscriber that would rather poll a single
integer from its own rider than be called from the detour.

### The other half: TOGGLE events (`nativetabs.nim`)

There are two event sources in this host and a feature author should see both in
one place. They are deliberately **separate detours on separate functions**;
neither may install the other's.

| event | what it answers | owner | API |
|---|---|---|---|
| **screen shown** | "the screen I want to edit is on screen NOW, here it is" | `uihooks.nim` (this doc) | `uihWant(site)` → `<feature>OnScreenShown(self)` |
| **toggle changed** | "a `UnityEngine.UI.Toggle` was switched, here it is" | `nativetabs.nim` | `ntOnToggle(register)` |

`nativetabs.nim` owns the **one** postfix on `UnityEngine.UI.Toggle::set_isOn`
@`0x55BA430`. **Do not add a second detour there** — the second overwrites the
first's trampoline and the first feature dies silently. Consume `ntOnToggle`
instead. Symmetrically, `nativetabs` consumes *this* file's screen events rather
than binding its own show hook.

> Status as written: `ntOnToggle` is being built by the nativetabs agent and is
> **not** consumed by anything in `uihooks.nim` today — uihooks needs no toggle
> event. This row is here so the next author does not go looking for a second
> `set_isOn` hook. Verify the symbol exists before calling it.

Note that `splrebrand.nim` **calls** `Toggle::set_isOn` at that same RVA to force
the practice toggle. Calling a byte-verified RVA is not detouring it and does not
contend — but it *does* mean a `set_isOn` postfix will fire for our own write, so
a toggle subscriber must be re-entrancy-safe.

### Wiring, in `aowlhost.nim` — the order is load-bearing

```nim
      splWantShowHook()      # every subscriber's Want, FIRST
      uihArm(true)           # ONE arm pass
      splShowHookVerdict()   # every subscriber's read-back, AFTER
```

Arming per subscriber would install a **second detour on a site two features
share, and the second overwrites the first's trampoline** — the failure this
repo has already paid for once.

### Rule 3 (`aowl_p_p_seh` is not re-entrant)

`uihooks.nim` **opens no guard**. It is a dispatcher: it reads two registers,
`duOk` + `iUnityAlive`-checks the receiver, and calls the subscriber. The
subscriber opens its own single guard (`splrebrand`'s `cSplTickGuarded`), exactly
as `settingsTabInitFired` does for the settings probe. A guard here would nest
inside the subscriber's and **disarm** it.

The subscriber returns `bool`: `false` means *its* guard reported a fault.
After `UihMaxDispatchFaults` (3) faulted dispatches uihooks stops dispatching to
that site for the session; the hook stays installed and keeps counting, so the
fire count stays honest.

## 4. The reference migration: `splrebrand.nim`

* the show event sets `gSplScreen` from the handed receiver
  (`Component::get_transform`, inside the guard, liveness-checked — it returns
  its argument unchanged on failure, so a bare non-nil check would be wrong);
* it opens a **bounded window** (`SplShowWindowFrames` = 1800 frames) and does
  the first pass immediately, on the Unity thread, in the postfix;
* while the window is open the existing per-frame re-assert runs from **cached
  pointers** — no walking. That is deliberate: `LocalizedText` **clobbers** a
  caption after we set it, so the relabel must be re-asserted, not merely
  issued, and at `Show` postfix time the caption may not be populated yet;
* the window **closes early** after `SplSettleFrames` (90) consecutive frames on
  which the finished-state readback already held — i.e. frames on which we did
  nothing. A run of those is the only honest evidence LocalizedText has stopped
  fighting;
* in event-driven mode `splFindScreen` (the scene-root walk) is **never
  entered**. The legacy cadence survives only for the case where the hook did
  **not** bind, and `splShowHookVerdict` says so at `warn` level. A silent
  fallback would be the worst outcome.

### The cost readback (CLAUDE.md §9b)

`gSplNodes` is incremented at the *one* place each walker charges its node
budget, so it cannot drift from the walk. Two log lines, both falsifiable:

* on every window close — frames spent, nodes visited, nodes/frame **while
  open**;
* 60 s after a window closes — **IDLE PROOF PASS/FAIL**: nodes visited while the
  feature claimed to be idle. Non-zero is a FAIL and prints as one.

## 5. Migration recipe for `modstab.nim` (for the next agent)

Do these in order; each is independent of the others.

### 5a. `uxVersionBrand` — it does not need a hook at all, only a STOP

The version brand rides the shared `PreloaderUI::Update` detour on a 120-frame
throttle and already logs *"applied 62 ms after the first tick"*. It is not
hunting for an event it lacks; it is **re-running after it has already won**.

The fix is a latch, not a subscription:

1. after the apply, read the finished state back (the live `AlphaLabel` TMP reads
   the branded string);
2. on PASS, set a `gVerDone` latch and **return at the top of the rider from
   then on**;
3. re-arm the latch only if the label pointer fails `duOk` / `iUnityAlive` —
   i.e. the label was destroyed and the screen rebuilt. Do **not** re-arm on a
   timer.

Assert the *negative*: "no TMP under the version panel still reads the stock
version string". Then log the same shape of cost line `splCloseWindow` prints.

### 5b. `uxHideSeasons` and `uxHideModeButton` — subscribe to site 1

Both act on children of `EFT.UI.MenuScreen`.

1. `modsWantShowHook()` → `uihWant(UihSiteMenuScreen)`, called from the flag
   block, and add the call **above** `uihArm(true)` in `aowlhost.nim`;
2. add a branch to `uihDispatch` in `uihooks.nim`:
   `if site == UihSiteMenuScreen: result = modsOnMenuScreenShown(self)`;
3. `modsOnMenuScreenShown(self)` — convert with `iToTransform` **inside** your
   guard, liveness-check the result, then run your existing bounded walk **from
   that transform only**. Delete the scene-root entry point;
4. **use a window, not a single shot.** Site 1 is `Awake` — a *construction*
   event. The screen's own children exist, but a child MenuScreen populates
   later may not. Copy splrebrand's shape: a frame cap plus an early close on a
   settle count of the finished state;
5. read the verdict back with `uihBound(UihSiteMenuScreen)` after `uihArm`, and
   `warn` if it did not bind rather than falling back silently;
6. keep the existing cadence code, reachable only when the hook did not bind.

**Do not** promote `MenuScreen::Show` @`0x1538760` into the table to get a truer
event without first solving the `jcc rel8` steal — see §2.

**Site 2 is the way round that**, added 2026-09-01: the PRIVATE 5-arg
`MenuScreen::Show` overload @`0x15387A0` that the public one calls. Its 15-byte
steal is three `mov [rsp+disp8],reg` plus `push rdi` — **no relative operand at
all** — and it takes the `Profile`, so it cannot run before a profile has been
chosen. `modload.nim` subscribes by POLLING `uihEpoch(UihSiteMenuShow)` from its
existing per-frame tick rather than by being dispatched, deliberately: releasing
the mods means `modhost.loadAll`, which must not run inside a detour postfix.

### 5c. Verify, do not assume

* `python tools/hostlog.py summary` — the `uihooks:` lines say BOUND/NOT BOUND,
  fires, live-receiver count, rejected receivers and faulted dispatches, all
  separately. A fire whose receiver was rejected is **not** an epoch, and
  collapsing the two would hide the exact case the receiver check exists for.
* the show hook must fire **at least once per screen open and never more than
  once** — that is `uihFires(site)` against the number of times you opened the
  screen. It is a count, so it can fail.
* the live tree is what settles a UI question: read the finished state back with
  the inspector (`findtext`, `label`), not a log line saying "ok".
