# The automation library — a test is a Nimony script

**Goal: testing is 100% automated.** Nobody should have to unload a magazine by
hand to trigger a feature we want to watch. A test states the loadout, the map
and the side it needs; running it launches the whole stack, mints the gear,
drives entry, and prints a verdict.

```powershell
.\installer\build\aowl.exe script scripts\woods_pmc_m4.nim
```

That one command compiles the script and runs it. The exit code **is** the
verdict: `0` PASS, `1` FAIL, `2` INCONCLUSIVE.

---

## 1. The pieces, and where they live

| piece | file | what it is |
|---|---|---|
| the script API | `tools/autoscript.nim` | what a script imports |
| the gear minter | `mods/tarkov/emu/loadout.nim` | mints + **reads back** the profile |
| the routes | `mods/tarkov/tarkov.nim` | `/aowlspt/tarkov/autoscript/{loadout,verify}` |
| the driver verb | `tools/aowl.nim` | `aowl script PATH.nim` |
| worked example | `scripts/woods_pmc_m4.nim` | the full raid case |
| the library's own acceptance | `scripts/gear_must_fail.nim` | must FAIL, and exits 0 when it does |

`mods/tarkov` **is** the SPT emulator and owns the profile, so the minting lives
there. A client-side mod could not do it: `serve()` inside the game process
registers into nothing, so a mod that reports over HTTP reports nowhere. The
backend's plain-HTTP control port is the only channel a separate process has.

---

## 2. The script API

```nim
import autoscript

proc main() =
  var s = newScript("woods-pmc-m4")

  onMap(s, "Woods")            # the name SELECT LOCATION displays
  asSide(s, "pmc")             # or "scav" (see §6 — not yet drivable)

  equip(s, "Headwear",           "5aa7e276e5b5b000171d0647")
  equip(s, "TacticalVest",       "5ab8dced86f774646209ec87")
  equip(s, "FirstPrimaryWeapon", "5447a9cd4bdc2dbd208b4567")

  carryLoaded(s, "TacticalVest", "55d4887d4bdc2d962f8b4570", 3,
              "54527ac44bdc2d36668b4567")     # 3 mags, filled with M855A1
  carry(s, "TacticalVest", "590c678286f77426c9660122", 2)   # 2 IFAKs
  stock(s, "54527ac44bdc2d36668b4567", 180)                 # spare, in the stash

  runAndQuit(s)

main()
```

### Declaring

| call | meaning |
|---|---|
| `newScript(name)` | a script. Defaults: `D:\Aowlspt`, Woods, PMC, `clear` on, launch on |
| `atRoot(s, path)` | drive a different install (wins over `AOWLSPT_ROOT`) |
| `onMap(s, "Woods")` | the map |
| `asSide(s, "pmc"\|"scav")` | the side |
| `keepGear(s)` | do **not** strip the character first |
| `attachOnly(s)` | drive whatever is already running; never launch |
| `withEntryDriver(s, path)` | where `enterraid.py` is |
| `equip(s, slot, tpl)` | wear one item in one of the 14 equipment slots |
| `equipLoaded(s, slot, tpl, ammo)` | wear it and fill its cartridges |
| `carry(s, container, tpl, n)` | `n` in real cells of the worn container |
| `carryLoaded(s, container, tpl, n, ammo)` | `n` magazines, each loaded |
| `stock(s, tpl, n)` | `n` loose in the stash |
| `byName(s, query, n)` | stash by English name; **ambiguity is refused** |
| `wear(s, slot, tpl, condition)` | `equip` with a durability percentage |

The 14 slots: `Headwear Earpiece FaceCover ArmorVest Eyewear ArmBand
TacticalVest Backpack FirstPrimaryWeapon SecondPrimaryWeapon Holster Scabbard
Pockets SecuredContainer`. Names are case-folded; anything else is refused **by
name**, never folded into the stash.

**Order matters.** Requests are applied in declaration order, so equip the rig
*before* the magazines that go in it. Otherwise you get
`nothing is worn in TacticalVest, so there is no container to put … inside` —
named, but still a FAIL.

`clear` defaults **true**: the character is stripped first, exempting `Pockets`
and `SecuredContainer`. A character with no Pockets item does not spawn at all.
A consequence, measured: pocket cells stay occupied, so `carry(s, "Pockets", …)`
can legitimately come back *no free cell*.

### Running

| call | does |
|---|---|
| `launchStack(s)` | attach, or start `aowlspt-launch.exe` and wait for the control port |
| `pickProfile(s)` | the profile played last, else the most recent |
| `applyGear(s)` | POST the loadout; take the server's **read-back** verdict |
| `verifyGear(s)` | the read-back alone — mints nothing |
| `enterRaid(s)` | drive the menu into an offline raid on the declared map |
| `waitDeployed(s, secs)` | wait for the **raid-phase latch** |
| `finish(s)` | print the conclusion, return the exit code |
| `run(s)` / `runAndQuit(s)` | all of it, stopping at the first non-PASS |
| `note(s, text)` | your own commentary into the transcript |
| `verdictOf(s)` / `reasonOf(s)` / `quitWith(code)` | for scripts that branch |

Every step returns `bool`, every failing step has already written its reason,
and none of them throw.

---

## 3. What the runner prints

```
[woods-pmc-m4] flags  debugEsp/natEsp/natEspDiag armed in D:\Aowlspt\aowlspt\aowlspt-host.json
[woods-pmc-m4] STACK   PASS  backend up after ~34s -- the backend's plain-HTTP control port is 127.0.0.1:80
[woods-pmc-m4] PROFILE PASS  Savant (00000000000a00000000004f, Usec, level 2) -- the profile you played last
[woods-pmc-m4] GEAR    requested=188 minted=188 placed=188 slotDropped=0 flatStacks=2
[woods-pmc-m4]   . flat stack: 5737201124597760fc4431f1 in hideout count=1
[woods-pmc-m4] GEAR    PASS  all 188 requested item(s) were read back off the profile
[woods-pmc-m4] ENTER   PASS  the entry driver finished after ~96s. This is NOT proof of deployment -- see DEPLOY.
[woods-pmc-m4] DEPLOY  PASS  the raid-phase latch reported DEPLOYED after ~74s

=== woods-pmc-m4: PASS ===
    gear read back 188/188 and the raid-phase latch said DEPLOYED
    map=Woods side=pmc profile=Savant gear requested/minted/placed=188/188/188 phase=DEPLOYED
```

`!` is a refusal **this spec caused** and fails it. `.` is an observation about
the profile it did not cause and does not.

---

## 4. How the gear check proves itself — §9b

**A script that asks for gear must be able to FAIL because the gear did not
arrive.** So `applyGear` never reports its own write. The server saves the
profile and then **re-reads it off the store** with a fresh `loadProfile`, and
counts, per request, how many items of that template are parented where the
request asked. Five numbers come back and they are five different numbers:

| | |
|---|---|
| `requested` | what the script asked for |
| `baseline` | how many were **already** there, read before anything was minted |
| `minted` | items the server constructed |
| `placed` | **after − baseline** in the re-read profile |
| `rejected` | one line each, with the reason |

`placed` is a delta on purpose. `clear` does not empty the stash, so a script
asking for 180 rounds into a stash already holding 180 read back **360** and
"passed" on gear it was already carrying. Two independent reads of the finished
state, subtracted, still cannot be satisfied by the server asserting its own
write.

### The input that makes it fail

Measured 2026-08-31 against the live `db.json`, on a real profile:

```
=== MUST FAIL: rifle in Headwear -> HTTP 200  FAIL
    reason: asked for 1, minted 1, read back 0; 1 refusal(s)
    requested=1 minted=1 placed=0 slotDropped=1
    ! validateSlots: slot refused: 5447a9cd4bdc2dbd208b4567 -> Headwear
                     on 55d7217a4bdc2d86028b456d
```

and the *same code path*, same session, on a correct spec:

```
=== GOOD loadout -> HTTP 200  PASS
    requested=188 minted=188 placed=188 slotDropped=0
```

A PASS and a FAIL from one code path is the whole claim. `scripts/gear_must_fail.nim`
is that case as a runnable test; it **inverts** the verdict and exits 0 only when
the gear check said FAIL, so a regression that makes the check unfalsifiable
turns into a failing test rather than a paragraph nobody reads.

Three real defects were found by writing that test, in this module's own first
draft. All three would have shipped as "the gear did not arrive" bug reports:

* **Multi-grid containers.** `emu/grid.markOccupied` filters on `parentId`
  alone — correct for a stash (one container, one grid), wrong for an ANA M2,
  which declares **nine** grids each with its own `(0,0)`. Three magazines
  minted exactly one. `emu/loadout.markGrid` filters on parent **and** grid name.
* **The baseline was read before `clear`.** It counted the gear `clear` was
  about to strip, so the *second* run of the same script read `base=1 placed=0`
  for every worn slot and reported a correct loadout as lost between the mint
  and the store. The baseline must be the state the mint actually starts from.
  Only visible because the runner prints the **per-request** breakdown; the
  aggregate said `requested=188 minted=188 placed=184` with zero refusals, which
  is truthful and points nowhere.
* **Pre-existing profile facts failing a good loadout.** `auditStacks` runs over
  the whole inventory and reported the two rouble stacks a real character has
  held at `count=1` since it was made. Folding those into `rejected` is a check
  that cannot *pass*, which is the same defect as one that cannot fail; they now
  go in `observations`, which is reported and is not part of the verdict.

### What is reused, not reinvented

`emu/spawn.searchItemsCounted` (name→template, with its ambiguity refusal),
`emu/trading.giveItem` (stash placement, stack-limit aware, merging),
`emu/grid` (real cells), **`emu/bots.validateSlots`** (the ancestry-aware slot
validator — every minted item goes through it before the save) and
**`emu/bots.auditStacks`**.

---

## 5. How "am I deployed" is decided — and how it is not

The only trustworthy signal is the host's **raid-phase latch**
(`host/…/raidphase.nim`). It arms on GameWorld cached + MainPlayer Unity-alive +
MainPlayer in `AllAlivePlayersList` + `Camera.main` non-null, survives the
MainPlayer null flicker (~3 frames in 4), and clears on `SessionEndUIScene`.

**A raid-ENTRY log line is not proof of raid STATE.** That mistake invalidated
four experiments in one week. `enterRaid` passing means only "the entry driver
ran"; `waitDeployed` is what decides.

The latch lives in the game process and the runner does not. Its one
out-of-process observable is the host-log line
`natesp: raid phase = DEPLOYED …`, printed every 5s by `natesp.nim` and gated by
`gNeDiag = gNeOn and readBoolKey("natEspDiag")` — so **both** `natEsp` and
`natEspDiag` are required, and `debugEsp` is what populates the GameWorld cache.
`armPhaseReporting` writes those three into `aowlspt-host.json` **before** the
launch, because host flags are read at boot, and says that it did.

Three outcomes:

* **PASS** — the log carried `raid phase = DEPLOYED`.
* **FAIL** — it carried some other phase and never DEPLOYED in budget.
* **INCONCLUSIVE** — it carried **no** `raid phase =` line at all. That is an
  instrument that did not run, not a raid that did not happen.

`finish` enforces the rule once, centrally: a script whose latch never said
DEPLOYED **cannot** report PASS, whatever else went right.

---

## 6. Known limits — stated, not worked around

* **Scav-side entry is not implemented.** `enterraid.py` presses PLAY, which is
  the PMC path. `asSide(s, "scav")` **refuses** with that reason rather than
  entering as a PMC and calling it a scav run.
* **`enterRaid` shells out to `tools/enterraid.py`**, so a script must be run
  from the repo root (or name the driver with `withEntryDriver`) and needs
  `python` on PATH.
* **Map selection is by UI**, not by `natraid.nim`'s measured native path
  (`set_SelectedLocation@0x6D7FF0`, `TryGetLocationById@0x987350`, Woods =
  `5704e3c2d2720bac5b8b4567`). That path currently hardcodes Woods/PMC, and
  `host/**` is not this library's surface to change. Making it take a map and a
  side is the obvious next step and would remove the python dependency, the
  ~90s of menu driving and the scav limitation in one go.
* **In-raid actuation** — walking, looking, firing, opening containers,
  unloading a magazine — is a separate layer being built on top of this one.
  This library gets you *into* the raid with exactly the right gear.
* **`carry` into `Pockets`** usually has no room, because `clear` deliberately
  exempts Pockets. That is a correct, named refusal, not a bug.

---

## 7. The routes

Both are outside the client's `{err, errmsg, data}` envelope on purpose: nothing
in the client asks for them, and an envelope would invite something to treat
them as game routes.

```
POST /aowlspt/tarkov/autoscript/loadout   mint, then read the profile back
POST /aowlspt/tarkov/autoscript/verify    read back only; mints nothing
```

Request:

```json
{"profileId": "<24 hex>", "clear": true,
 "gear": [
   {"tpl": "5447a9cd4bdc2dbd208b4567", "slot": "FirstPrimaryWeapon"},
   {"tpl": "55d4887d4bdc2d962f8b4570", "inside": "TacticalVest",
    "count": 3, "ammo": "54527ac44bdc2d36668b4567"},
   {"query": "m855a1", "count": 180, "condition": 100}
 ]}
```

`slot` → worn. `inside` → in that worn container's grid. Neither → stash.
**Both → refused and named**, rather than one silently winning.

Response: `verdict` (`PASS`/`FAIL`/`INCONCLUSIVE`), `reason`, `requested`,
`minted`, `placed`, `slotDropped`, `flatStacks`, `rejected[]`,
`observations[]`, and `gear[]` with the per-request `baseline/minted/placed/why`.

`emu/loadout.selfCheckLoadout` runs inside `/aowlspt/tarkov/selfcheck`. It
asserts only what it can prove with no database and no profile — that every
declining path names a reason, that a spec which could not be looked at answers
INCONCLUSIVE rather than PASS, and that the report carries requested/minted/placed
as three separate numbers. It deliberately does **not** assert that gear arrived;
a check written to pass without a profile is the check that cannot fail.

---

## 8. Pointing a script at a scratch install

`AOWLSPT_ROOT` overrides the `D:\Aowlspt` default without editing the script, so
the same file runs against a throwaway install. Precedence:
**`atRoot` > `AOWLSPT_ROOT` > `D:\Aowlspt`.**

```powershell
$env:AOWLSPT_ROOT = "$env:TEMP\as-install"    # backend --root is <this>\aowlspt
.\backend\bin\aowlspt-backend.exe --root "$env:TEMP\as-install\aowlspt" --port 6975
.\installer\build\aowl.exe script scripts\gear_must_fail.nim
```

A scratch install needs `aowlspt/db.json`, `aowlspt/mods/tarkov/tarkov.dll`,
`aowlspt/mods/tarkov/data/post1/{globalsgaps,itemsgaps,itemsadd}.json`,
`aowlspt/mods/aowlspt-selection.json` and
`aowlspt/store/aowl.tarkov/profile.<id>`.

**Without those three `post1` data files the tarkov mod fails its own self-check
and registers ONLY its selfcheck route** — every other route 404s, including
this library's, which reads exactly like the feature being missing. Measured
2026-08-31; it cost half an hour.

**Windows paths in a script need a raw string.** `atRoot(s, "C:\Users\...")` is a
lexer error (`expected a hex digit, but found: s`); write `r"C:\Users\..."`.

---

## 9. Building

```powershell
.\installer\build\aowl.exe build-mod mods\tarkov      # the gear minter + routes
.\installer\build\aowl.exe bootstrap                  # after touching tools\aowl.nim
.\installer\build\aowl.exe script scripts\<x>.nim     # build AND run one script
```

Script binaries land in `installer\build\scripts\`. PowerShell only — `gcc`
under Git Bash exits 1 with no diagnostic. Never hand-invoke `nimony`: outside
the paths `aowl` sets up it exits 0 and writes **nothing**.

The route string `/aowlspt/tarkov/autoscript/loadout` is a **deploy marker** in
`tools/deploy.json`, so a rebuild from the wrong base cannot silently drop this
feature. Verify with:

```powershell
python tools\markers.py --for tarkov --artifact mods\tarkov\bin\tarkov.dll
```
