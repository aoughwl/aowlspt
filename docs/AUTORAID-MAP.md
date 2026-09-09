# AUTORAID-MAP — the three flows, with the evidence behind each claim

`mods/autoraid` (`aowl.autoraid`), written 2026-09-04. One DLL,
`sides = {sideClient, sideServer}`.

Every claim below is tagged **MEASURED** (somebody read it off the live client,
off `GameAssembly.dll`, or off the wire, and the command is named) or
**inferred** (it follows from something measured, but has not itself been
observed). A MEASURED label on an inference poisons the document the same way it
poisoned the fact store, so the tags are not decoration.

Nothing in this document has been verified **live for this mod** yet. The
measurements are the host's and the tools', re-used; the mod's own live
behaviour is unproven and is listed as such in §5.

---

## 0. What the mod is, in one paragraph

Three features on one code base: a command-line raid (`--raid="Woods"` on the
launcher), a map menu on a key (`F8`, gated), and an optional spawned default
loadout (server side). The client half **installs no detour, resolves no IL2CPP
name and writes nothing into game memory**. It reaches Unity through three
existing host facilities — `everyMain` for the tick, the `ui.show` event bus for
screen arrivals, the shared region for drawing — and makes every state change by
CALLING the method the game itself calls at a byte-verified RVA.

---

## 1. Flow A — the command-line raid

```
aowlspt-launch --raid="Woods"
      |                                                    (agent H owns this)
      v  the launcher forwards an unknown --name=value as -aowl.name=value
EscapeFromTarkov.exe ... -aowl.raid=Woods
      |
      v  the HOST parses every -aowl.<name>=<value> token once, at boot
aowlspt/args.nim  ->  cmdArg("raid")            [ar/cmdline.nim]
      |
      v  onLoad: declareArgs(...), report the token found (or its absence)
      |          then every(1000, waitForDrain) -- OFF Unity's thread, and it
      |          touches nothing in the game
      v  call("aowlspt.host::main_thread").bound == true
everyMain(onMainTick) registered  ->  onMainThread(armFromCmdline)
      |
      v  machine.arm("Woods", "pmc", "-aowl.raid")
   [the state machine, §2]
      |
      v  poll call("aowlspt.host::raid_phase") every 2 s
   phase == DEPLOYED   ->  AutoRaid CMDLINE VERDICT PASS
   machine refused     ->  AutoRaid CMDLINE VERDICT FAIL <why>
   240 s, still going  ->  AutoRaid CMDLINE VERDICT INCONCLUSIVE <why>
```

* **MEASURED** — the host's main-thread drain must have FIRED before anything
  touches Unity. Crash `Crash_2026-09-02_211541986`: a mod's `everyMain` tick ran
  on the HOST's own thread and called `UnityEngine.Input::GetKey`, whose native
  body in UnityPlayer (`+0x58CF70`) fetches a global manager pointer and
  dereferences it at `+0x4A0` **with no null test**. The pointer was NULL.
  `call("aowlspt.host::main_thread").bound` is the gate, and NOT BOUND IS A
  REFUSAL, not a fallback.
* **MEASURED** — `DEPLOYED` is the game's own deploy signal, from the host's
  `raidphase.nim` (`SpatialAudioSystem::AfterGameStarted` @0x2194770,
  `ExfiltrationTimerSoundPlayer::AfterGameStarted` @0xA4CAF0). The mod does not
  install those detours; a second detour on one function overwrites the first's
  trampoline.
* **inferred** — that `--raid` reaches the client as `-aowl.raid`. That is agent
  H's launcher change and the mod builds against the contract, not against an
  observation.
* **Refusals are not retried.** `machine.arm` refuses when a live `GameWorld` is
  readable, and that refusal is terminal for the command-line path: retrying it
  would press at a UI that is not there.

---

## 2. The raid-entry state machine (`ar/machine.nim`)

A port of `host/Aowlspt.Host.Il2Cpp/autoraid.nim`. The flow:

```
   WAIT-MENU ──(SettingsScreen over the menu)──> PRE-MENU ──┐
       │                                                    │
       │ press PlayButton (atomic find-and-press)   <───────┘
       v
     SIDE ──press the side control, then THIS screen's own NextButton──┐
       │   readback: the screen goes INACTIVE                          │
       v                                                               │
  WAIT-LOCATION  <── site 4 (MatchMakerSelectionLocationScreen::Show) ─┘
       │
       v
  SELECT-MAP ──press the tile whose Label reads the map, then THIS
       │        screen's own NextButton; readback: screen INACTIVE
       v
  WAIT-OFFLINE  <── site 0 (MatchmakerOfflineRaidScreen::Show)
       │
       v
  SCREEN-NEXT   the generic table: row 0 offline raid (site 0),
       │        row 1 insurance (site 5), row 2 accept (site 6).
       │        Press THAT screen's own NextButton from THAT receiver.
       v
     DONE        the accept screen advanced. HANDS OFF for the session.
```

### 2.1 Every screen comes from its own `::Show` receiver

**MEASURED, three times in one session (2026-09-02).** The host's original
`NEXT->location`, post-SIDE and `NEXT->insurance` steps each timed out after 45 s
while their own census already showed the screen on screen. Every one was the
same mistake: hunting a `NextButton` across the scene roots for a screen nobody
had handed us. The rule that came out of it: **a screen is advanced only from its
own `::Show` receiver.**

The mod gets those receivers from the host's generic bus (`ar/showbus.nim`):

| site | method | RVA | used for |
|---|---|---|---|
| 0 | `MatchmakerOfflineRaidScreen::Show` | 0x1788590 | SCREEN-NEXT row 0 |
| 2 | `MenuScreen::Show(5-arg)` | 0x15387A0 | WAIT-MENU root, exit fallback |
| 3 | `MatchMakerSideSelectionScreen::Show` | 0x1790180 | SIDE |
| 4 | `MatchMakerSelectionLocationScreen::Show` | 0x178ACB0 | SELECT-MAP |
| 5 | `MatchmakerInsuranceScreen::Show` | 0x1769910 | SCREEN-NEXT row 1 |
| 6 | `MatchMakerAcceptScreen::Show` | 0x1773EF0 | SCREEN-NEXT row 2 |
| 7 | `MenuScreen::ShowInRaid` | 0x1539650 | raid exit |
| 8 | `SessionEndUI::Awake` | 0x1726850 | raid exit, results |

**MEASURED** — site 1 (`MenuScreen::Awake`) is never wanted and never read.
Wanting it bound that method for the first time on any build this project has
run, and the very next boot died at MENU ARRIVAL in `SeasonWidgetData::From
@0x141FFD0+0x133` under `MenuScreen::Show(5-arg) @0x15387A0+0x994`. Three boots,
three deaths.

**inferred** — that the host's `ui.show` payload carries `{site,name,rva,epoch,
receiver}` and that `aowlspt.host::ui_show_status` reports per-site
`{bound,epoch,receiver}`. Agent H is building both against exactly these names.

### 2.2 What the port CHANGED, and why

| Host | Mod | Why |
|---|---|---|
| rides the `TarkovApplication::Update` drain slot | `everyMain` | a mod may not add a second detour: the second overwrites the first's trampoline and silently kills the first feature |
| falls back to enumerating `DontDestroyOnLoad` roots | never enumerates; climbs with `Transform::get_root` from a live receiver | **MEASURED** `Scene::GetRootGameObjects` ALLOCATES (a List and an array), banned on a per-frame path; and in a raid the enumeration is the LOCATION scene, where the menu is not — which is exactly why `raidexit` refused with "step SHOW-IN-RAID found nothing" while the menu was alive |
| keeps `ArNext1..ArReady` (all-roots NextButton hunts) | DELETED; replaced by `WAIT-LOCATION` / `WAIT-OFFLINE` | those steps were measured wrong three times; keeping a superseded path "just in case" is how a run quietly becomes the weaker one |
| ONE `aowl_p_p_seh` around the whole tick body | one guard per CALL (callrva's), none around the tick | `aowl_crva_invoke` REFUSES to arm inside another guard (`GUARD_BUSY`, checked on its own flag AND the shim's) because nesting disarms the outer one. Nothing is ever nested; every read is `VirtualQuery`-gated instead |
| per-step budget counted from "the guarded body did not return" | per-step budget counted from the DELTA in callrva's process-wide fault counter, with a CRUMB naming the operation | strictly better information. **MEASURED** the budget must stay PER STEP: on 2026-09-02 one recovered PRE-MENU fault plus two SIDE faults tripped a session-wide budget of three and switched the whole feature off |
| `Component::GetComponent(String)` | `GetComponent(Type)` via `GetTypeFromHandle` and an offline `Il2CppType` RVA | **MEASURED** the String overload returns NULL for every node on this build; a walk of all 1263 nodes of an open Settings screen found ZERO TMP components while `label` reads their text fine |

### 2.3 The three press routes — and why there is no fourth

**MEASURED 2026-09-02, two deterministic client deaths.** The host's generic
press read a "UnityEvent" at component `+0x100` for every klass that was not a
`DefaultUIButton`. On an `EFT.UI.AnimatedToggle` (which derives from
`UnityEngine.UI.Toggle`) that offset is `toggleTransition` — **an enum**. Layout,
from `tools/fldoff.py`:

```
0x100 toggleTransition  ToggleTransition   <- AN ENUM, not an event
0x108 graphic           Graphic
0x110 m_Group           ToggleGroup
0x118 onValueChanged    ToggleEvent        <- the real event
0x120 m_IsOn            bool
```

A small integer is not null, is not a GameObject and is not a known klass, so it
passed every guard, and was then CALLED as a UnityEvent.

| klass | route | source of the RVA + prologue |
|---|---|---|
| `EFT.UI.AnimatedToggle` | `Toggle::Set(true, true)` @0x55BA450 | `abi/aowlspt_premenu.h` row [1], UNIQUE, non-virtual |
| `EFT.UI.DefaultUIButton` | `_button`@0x108 → `TweenAnimatedButton::OnPointerClick(NULL)` @0x14359B0 | `abi/aowlspt_premenu.h` row [2] |
| `UnityEngine.UI.Button` | `Button::Press()` @0x539A7A0 | `abi/aowlspt_navui.h` |
| anything else | **NOT PRESSED**, reported | there is no generic route because the generic route is what faulted |

**MEASURED** — `OnPointerClick`'s own sixteen bytes are
`cmp byte [rcx+0x68],0 / je / mov rcx,[rcx+0x70] / test rcx,rcx / je / …`: it
gates on `_interactable`, loads its `Action OnClick` and invokes it, and **never
reads** the `PointerEventData` in RDX. That is why NULL is a safe argument — a
statement about this disassembly, not about Unity. Firing
`DefaultUIButton.OnClick`@+0x120 directly reaches the same handler but skips that
gate, and **MEASURED 2026-09-02** that left the profile/mode screen
half-transitioned with neither card clickable. The direct-UnityEvent path
therefore survives only as an ANNOUNCED fallback when `_button` is unreachable.

### 2.4 SELECT-MAP: the map is chosen by the text a person reads

**MEASURED live with the inspector, 2026-09-02:**

```
Matchmaker Location Selection          <- the site-4 receiver
  +- Content -> Map -> Image
  |    +- "Location Template(Clone)"   <- ONE PER MAP, ALL IDENTICALLY NAMED,
  |         |                             so the OBJECT NAME cannot select a map
  |         +- Info -> Text            <- reads "NOT AVAILABLE" etc: a STATUS,
  |         |                             and a red herring
  |         +- Button Panel
  |              +- AnimatedToggle     <- the control
  |                   +- SizeLabel
  |                        +- Label    <- TMP, reads "WOODS"
  +- ScreenDefaultButtons -> NextButton, BackButton
```

**MEASURED offer set, 2026-09-02:** `[RESERVE][LIGHTHOUSE][INTERCHANGE][CUSTOMS]
[GROUND ZERO][ICEBREAKER][WOODS]` — seven, not the twelve the menu lists. A map
that is not on offer produces a refusal that NAMES every map that was.

### 2.5 SIDE: the side is chosen STRUCTURALLY

**MEASURED live with the inspector, 2026-09-02:**

```
MatchMaker Side Selection Screen       <- the site-3 receiver
  +- PMCs                              <- the container for BOTH sides
  |    +- PMCPlayerMV                  <- the PMC character MODEL (deep, huge)
  |    +- AnimatedToggleSpawner -> AnimatedToggle    <- the PMC control
  |    +- Button                                     <- and its Button
  |    +- ScavPlayerMV                  <- the SCAV side, NESTED INSIDE the
  |    |    +- AnimatedToggleSpawner       PMC container
  |    |    +- Button
  |    +- RandomToggleSpawner -> RandomToggle
  +- ScreenDefaultButtons -> NextButton, BackButton
```

The controls are called `AnimatedToggle` and `Button` — no name contains "pmc" —
and they carry no `DefaultUIButton`, so there is no caption either. "The PMC
control" is therefore a STRUCTURAL fact: the first control under `PMCs` that is
NOT inside a `scav` subtree.

**MEASURED** — this is why the walk must be a TRUE level-by-level BFS. A
breadth-per-node walk takes a level and then recurses into child 0, which here is
`PMCPlayerMV`, and spends its whole 40-node cap in the character mesh: the
depth-first version reported ZERO pressable nodes under a screen that had two.
`ar/uitree.collectBFS` uses its own queue; `walkActive`/`collect` are the
breadth-per-node shape and are used only where the subtree is known shallow.

### 2.6 PRE-MENU: the finished state is THE MENU BEING USABLE

**MEASURED 2026-09-02.** `SettingsScreen::Close()` @0x1720B10 HIDES the settings
screen and does **not** restore the menu: its own readback passed ("no ACTIVE
SettingsScreen remains") and WAIT-MENU then sat for its full 180 s bound with no
MenuScreen active at all. That is the exact shape of a check that cannot fail —
the step asserted the thing it had just done rather than the thing it was for.

So the ladder is (1) the screen's own `BackButton`, scoped to its subtree, and
(2) `Close()` as an announced fallback; and the finished state is an ACTIVE,
PRESSABLE `PlayButton` obtained from the SAME function WAIT-MENU uses.

**MEASURED** — `ChatScreen` reads ACTIVE in a healthy menu too (both censuses on
2026-09-02, one with Settings over the menu and one with PLAY pressable). It is a
normal part of the menu and is never touched.

---

## 3. Flow B — the map menu on a key

```
config: hotkeys=false (SHIPPED OFF), menuKey="F8", enterKey="None"
      |
      v  everyMain tick -> menu.poll()   [Unity's thread ONLY]
UnityEngine.Input::GetKeyDown @0x531EB80, CALLED at a byte-verified RVA
      |     prologue 40 53 48 83 EC 20 48 8B 05 9B 71 DB 01 8B D9 48
      |     return type is ONE BYTE (AL); the icall's upper EAX bits are junk
      |     control key: Joystick8Button19 (509) -- if IT reads down too the
      |     press is REFUSED and counted
      v
menu opens -> abi/aowlspt_region.h participant `autoraid.menu`
      |        DRAW callback is C over a POD mirror: holds no game pointer,
      |        allocates nothing, cannot fault inside the region's guard
      v  Enter -> machine.arm(label) -> the same state machine as Flow A
```

* **MEASURED (twice, independently)** — `Input::GetKeyDown` @0x531EB80 and its
  sixteen prologue bytes: once for `abi/aowlspt_admin.h` on 2026-08-31, once for
  `mods/maps/sp/hud.nim` on 2026-09-01. The agreement is the self-check.
* **MEASURED** — the return type is `bool` in AL with EAX bits 8..31 UNDEFINED;
  the method tail-jumps into Unity's native icall. Declaring it `int32_t` made
  maps' overlay open on ANY keypress (41 toggles in a raid where M was pressed a
  handful of times).
* **MEASURED** — off Unity's thread this call is an access violation, not a
  theoretical hazard (see §1).
* **inferred** — nothing about this mod's own region participant. Registration
  and ARMING are reported as separate facts and the verdict reads the region's
  own `drawn` counter, so "opened but nothing painted" is a FAIL rather than a
  silent success.

---

## 4. Flow C — the spawned loadout (server side)

### 4.1 The measured wire order, which settles the whole design

**MEASURED** by agent S from the real capture (`data/capture/raid1`), one menu
cycle:

```
/client/game/profile/list        <-- the ONLY request that carries the PMC
                                     Inventory (match/local/start sends
                                     profile: null, tarkov.nim:2381)
/client/game/profile/select
/client/raid/configuration
/client/match/local/start
/client/match/local/end
/client/game/profile/list        <-- the NEXT cycle's fetch
```

`profile/list` is fetched **ONCE per menu cycle and NEVER after select or
configuration**.

**This invalidated the first design of this mod, and the failure would have been
invisible.** Applying on `tarkov.raid.configured` or `tarkov.profile.selected`
mints the items into the stored profile *after* the client has already been
handed its copy — so the kit arrives on the NEXT menu cycle, one raid late,
every time, **while the verdict says PASS**, because tarkov really did mint them.
That is a check that cannot fail: it asserts our own write and never asks whether
the write reached the client. Only the wire could catch it.

### 4.2 The handshake

```
mods/autoraid (backend)                      mods/tarkov (backend)
  loadoutMode == "spawned", applyAt == "listing"
  loadout.json read at load
        |
        |  tarkov.profile.listing   {session, profileId, cycle}
        |<==================================================  SYNCHRONOUS,
        |   emitted from INSIDE onProfileList, BEFORE the      inside the
        |   profile document is serialised and served          request
        |
        |  autoraid.loadout.apply
        |-------------------------------------------------->
        |   {profileId, spec:{clear,gear}, ephemeral:true,
        |    reason:"tarkov.profile.listing"}
        |                                     move worn gear to the STASH,
        |                                     applyLoadout(), record minted ids
        |  autoraid.loadout.result            under autoraid.minted.<profileId>
        |<--------------------------------------------------
        |   {profileId, verdict, requested, minted, placed, rejected, why}
        v
  AutoRaid LOADOUT VERDICT PASS|FAIL|INCONCLUSIVE   (logged VERBATIM)
        |
        |  tarkov.profile.selected / tarkov.raid.configured
        |<--------------------------------------------------
        v   OBSERVED, NEVER APPLIED FROM. One log line saying they are too
            late for the coming raid; kept as the standing evidence that the
            order above still holds.

  at match end, mods/tarkov strips every minted subtree from the posted
  profile before saveProfile, respecting the raidCarriedFullInventory guard
```

* **Synchronous is load-bearing.** An event that merely fired "around then"
  would be a race, and a race that loses is indistinguishable from the
  one-raid-late bug above. The `emit` happens inside the listing handler's call
  stack; by the time it returns the items are in the document about to be
  served.
* **Idempotence is per (profileId, cycle)**, from the `cycle` field — not per
  profile and not on a clock. Per-profile would silently refuse the second raid
  of a session; a clock would be a guess. Beyond that this mod does not guard:
  tarkov refuses a second mint while a minted set is active and says why, and
  that refusal is logged as the verdict.
* **MEASURED (from `tarkov.nim:2524-2539`)** — the whole stored profile is
  replaced by the posted one at match end EXCEPT under the
  `raidCarriedFullInventory` guard, and death does not re-remove gear. So
  minted-before-raid gear is indistinguishable from owned gear after a raid and
  would land in the stash on extract. Ephemerality is therefore a RECORDED SET
  of minted ids plus a strip step, not a property of the items.
* **MEASURED offline, 2026-09-04** — every `query` and every `tpl` in the
  shipped `loadout.json` was checked against `D:\Aowlspt\aowlspt\db.json` with
  the SAME matching rule `emu/spawn.searchItemsCounted` uses (substring over the
  English locale name, intersected with `templates.items`). Four entries carry a
  `tpl` because the name is genuinely ambiguous: `5.45x39mm BT gs` (also three
  ammo packs), `PACA Soft Armor` (also the Rivals Edition), `9x18mm PM PS gs
  PPO` (also two packs), and `PM 9x18PM 90-93 8-round magazine` (**two template
  ids share that exact name**). `loadout.nim` REFUSES an ambiguous query rather
  than taking the first hit, so each would have been a named refusal, not a
  wrong item.
* **inferred** — the `tarkov.profile.listing` payload shape and the fact that
  tarkov handles `autoraid.loadout.apply` inline. Both are agent S's, and this
  mod builds against the names.

## 5. What is verified, and what is not

**MEASURED 2026-09-05, five consecutive boots on Woods (`aowlspt-launch --raid
Woods`, then `--raidexit 45`).** The map above was written offline; this is
what the live client said.

Verified:

1. **The command-line raid ENTRY, end to end, 5 of 5 boots** -- PLAY at ~0:42,
   SIDE (Toggle::Set), SELECT-MAP "WOODS", offline NEXT, insurance NEXT, accept
   READY, `AutoRaid CMDLINE VERDICT PASS -- phase DEPLOYED` at 2:36-2:42. Every
   receiver came from its own `ui.show` event (items 1, 2 and 4 of the old
   list: the type RVAs, `GetComponent(Type)` from a Transform receiver, and the
   `ui.show` payload shape all held).
2. **`-aowl.raid` reaches the client** (old item 5): `cmdline: raw = ...
   -aowl.raid=Woods` on the host's first line.
3. **The raid EXIT, end to end** (old item 7), boot 6: ESC -> the game's own
   `MenuScreen::Show(5-arg)` 30 ms later -> DISCONNECT -> LEAVE -> four results
   NextButtons -> `MenuScreen::Show` with a real profile -> `AutoRaid exit
   VERDICT PASS` (an ACTIVE, pressable PlayButton) at 3:46 from launch.

What the exit needed, and what the offline map had wrong:

* **`MenuScreen::ShowInRaid()` does NOT open the in-raid menu.** Called on the
  re-validated pre-raid MenuScreen it returns and leaves nothing active; its
  body reads `_environment@0x108` and works on the EnvironmentUI. Site 7 never
  fires on a real ESC. The claim in section 2.1 and in AOWL_FACTS (2026-09-01,
  offline) that it is the opener is retracted; the OBJECT (`Common UI/
  MenuScreen`, DontDestroyOnLoad) was right.
* **A real ESC fires site 2 -- `MenuScreen::Show(5-arg)` with profile=NULL** --
  through `MenuScreen::Show(MainMenuBaseScreenController)` @0x1538760, its
  only direct caller, which forwards `Matchmaker@0x48 ModeDescriptor@0x50
  Profile@0x58 ExpansionsPlayerInfo@0x60 SeasonalRewardController@0x68` off
  the controller. The controller lives in the generic base's slot at +0x90
  (borrowed): it reads NULL on the hidden menu at exit time and a live object
  while the menu is shown, so `Show(controller)` has no argument when the mod
  needs it.
* **So the mod presses ESC.** `keybd_event` reaches only the foreground window
  (boot 5 refused correctly while the user was in another window);
  `PostMessageW(WM_KEYDOWN/WM_KEYUP, VK_ESCAPE)` to the `UnityWndClass` window
  opened the menu with the game NOT foreground, and is what ships. The readback
  is the site-2 epoch advancing after the post, never the post itself.
* **The three call targets the host itself hooks** (`Toggle::Set`,
  `SettingsScreen::Close`, `MenuScreen::ShowInRaid`) were refused by the SDK
  verifier as "first bytes are a JUMP" (boot 1, FAIL at SIDE). The host now
  answers `aowlspt.host::original_bytes` from its pre-detour prologue table and
  the verifier compares against that (commit 2b22617).
* **The host's `raid_phase` used to read LOADING at the rebuilt main menu**
  (its cached GameWorld outlived the raid). FIXED 2026-09-05 (host
  raidphase.nim: S1 now requires the cached GameWorld to be Unity-alive, the
  same fake-null test S2 applies to the player); boot 14:45 reads
  `AutoRaid EXIT VERDICT PASS ... the host reports phase MENU`. The outer
  verdict still keeps "still DEPLOYED" as the disagreement that yields
  INCONCLUSIVE, and prints the phase so a reader can tell an older host.

4. **The loadout handshake, end to end** (old item 6), boots 7 and 8 with
   `loadoutMode: spawned`: `autoraid.loadout.apply` emitted from INSIDE
   `tarkov.profile.listing` (cycle 2 of the boot), the kit minted into the
   document that /client/game/profile/list then served, and at match end the
   CLIENT posted every minted id back (29, then 31) -- which is the only proof
   that the kit reached it for THAT raid. Then `STRIPPED 31 of 31 ... and 4
   reference(s) ... (CheckedMagazines ...)` and `END VERDICT PASS -- none of
   31 minted id(s) occurs anywhere in the saved profile`. Two defects the
   verdicts caught on boot 7 and fixed for boot 8: the minter compared a
   magazine NAME against the weapon's filter of template ids (`resolveNamed`
   now resolves `magazine`/`ammo` names like `query`), and the strip left the
   minted ids as KEYS of `CheckedMagazines`, which the client posts back for
   magazines it inspected (`arPruneReferences` now prunes CheckedMagazines,
   fastPanel, favoriteItems and InsuredItems by the doomed set). MEASURED
   also: the client fetches profile/list again right after match end, so a
   FRESH kit is minted at that listing for the next raid, and the second
   listing of that menu answers "ALREADY ACTIVE" (idempotent, by design).

Still NOT verified:

7. **The map menu on a key** (flow B) and the region participant drawing:
   `hotkeys` has stayed off.

## 6. The lines a reviewer greps after a boot

```
AutoRaid client: loaded, DEFAULT INERT.
AutoRaid cmdline: -aowl.raid=
AutoRaid: the host's main-thread drain is BOUND
AutoRaid: call surface verified --
AutoRaid: subscribed to `ui.show`.
AutoRaid MENU: registered as region participant `autoraid.menu`
AutoRaid: ARMED (
AutoRaid WAIT-MENU: MenuScreen found=
AutoRaid: menu ready -- pressed PLAY
AutoRaid: READBACK -- MatchMakerSideSelectionScreen::Show fired
AutoRaid SIDE: pressed the
AutoRaid: READBACK -- MatchMakerSelectionLocationScreen::Show fired
AutoRaid SELECT-MAP: pressed the tile whose Label reads
AutoRaid: READBACK -- the offline raid screen announced itself
AutoRaid SCREEN-NEXT: the practice/offline toggle
AutoRaid: SCREEN-NEXT -- pressed the
AutoRaid CMDLINE VERDICT
AutoRaid MENU VERDICT
AutoRaid LOADOUT: emitted `autoraid.loadout.apply`
AutoRaid LOADOUT VERDICT
```

A run that reaches a raid shows the READBACK lines in order. A run that does not
shows exactly one refusal naming the step, the crumb and a census of what was
ACTIVE — read that line, not the screen.
