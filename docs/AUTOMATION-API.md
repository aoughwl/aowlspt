# The automation library — complete API reference

A test in this repo is a **nimony script**. The script *declares* what it wants
to go into a raid with; running it launches the whole stack, mints the gear,
drives menu entry, actuates the player, and prints a three-valued verdict.

```
.\installer\build\aowl.exe script scripts\ammoloading_e2e.nim
```

That one command builds the script and runs it. It **launches the game**. To
type-check a script without launching anything:

```
.\installer\build\aowl.exe script scripts\ammoloading_e2e.nim --build-only
```

The pieces:

| Layer | Lives in | Runs in |
|---|---|---|
| the script | `scripts\*.nim` | its own process |
| the library | `tools\autoscript.nim` | its own process |
| gear minting | `mods\tarkov\emu\loadout.nim` | the **backend** process |
| player actuation (`pact`) | `host\Aowlspt.Host.Il2Cpp\pact.nim` | **inside the game** |
| the channel between them | `aowlspt-inspect.txt` + the host log | the filesystem |

Three processes, so nothing here is a function call. Every request crosses a
process boundary and every answer is a **readback**, which is why the failure
modes below are as detailed as they are.

---

## 0. The contract: three outcomes, never two

Every step returns `bool` and records one of:

| Verdict | Exit | Means |
|---|---|---|
| `PASS` | 0 | the finished state was READ BACK and it is what was asked for |
| `FAIL` | 1 | something measurable did not happen |
| `INCONCLUSIVE` | 2 | **the question was never asked** |

`INCONCLUSIVE` is deliberately *worse* than `FAIL` in `worse()`, and exit 2 is
never folded into exit 1. "I could not look" is not a pass, and it is also not
a fault report — those are differently actionable and collapsing them is how a
broken instrument reads as a broken feature.

Two rules are enforced **centrally, in `finish`**, rather than trusted to every
step:

* `steps == 0` → INCONCLUSIVE. Nothing ran, so nothing was measured.
* `raidAttempted and not entered` → INCONCLUSIVE, whatever else passed. A script
  that tried to enter a raid and never saw the latch say DEPLOYED has not
  demonstrated anything about a raid.

A script that never attempts a raid (a gear-only test) is **not** failed for
never deploying — it made no claim about deployment. `raidAttempted` is what
tells those apart; collapsing them would be a check that cannot pass.

---

## 1. Declaring a script

### `newScript(name: string): Script`

A script with nothing declared. Defaults:

| Field | Default | Note |
|---|---|---|
| `root` | `D:\Aowlspt` | overridden by `$AOWLSPT_ROOT`, then by `atRoot` |
| `map` | `Woods` | |
| `side` | `pmc` | |
| `clear` | **true** | strip the character before minting |
| `launch` | true | start the stack if nothing is running |

`clear` defaults **true** on purpose. A test that runs against whatever the
character happened to be wearing is a test whose result depends on the last run,
and "the slot is already occupied" is the most common way a loadout silently
does not arrive.

Precedence for the install root is `atRoot` > `$AOWLSPT_ROOT` > `D:\Aowlspt`.

### `atRoot(s, root)`

The install to drive.

### `onMap(s, map)`

The map, **by the name the SELECT LOCATION screen displays**: `Woods`,
`Customs`, `Factory`, `Interchange`, `Reserve`, `Shoreline`, `Lighthouse`,
`Streets of Tarkov`, `Ground Zero`, `The Lab`.

### `asSide(s, side)`

`"pmc"` or `"scav"`. Anything else is refused at `run` time **with a reason**
rather than folded into pmc — a scav test that quietly ran as a PMC is a result
that means nothing.

### `keepGear(s)`

Do not strip the character first. For testing what a raid did to an existing
loadout.

### `attachOnly(s)`

Do not launch anything; drive whatever is already running.

**Consequence, and it is announced in the transcript, not hidden:** host flags
and mod configuration are read at **boot**. Attaching to a client that is already
up cannot arm `playerActuation`, the inspector, or an ammoloading rung. Writing
them at that point would produce a file that says "on" over a process that is
off — the exact shape of a check that cannot fail. `launchStack` says so
explicitly when it attaches.

### `withEntryDriver(s, path)`

Where `tools\enterraid.py` is. Default: relative to the working directory.

---

## 2. Declaring gear

Requests are applied **in declaration order**. Equip a container *before* the
things that go inside it; otherwise the refusal is "nothing is worn in
TacticalVest", which is named, not silent.

### `equip(s, slot, tpl)`

Wear one item in one of the 14 equipment slots. A slot holds **one** thing;
`count > 1` on a worn slot is refused by name rather than silently placing the
first.

### `equipLoaded(s, slot, tpl, ammo)`

Wear it and fill **its own** `_props.Cartridges` to the capacity the template
declares.

> **This is for MAGAZINES and other cartridge-bearing containers, not weapons.**
> See `equipWeapon`. Pointing it at a weapon is refused, with a reason stating
> that the template is a *chambered item* and that no `magazine` was named.

Refused, with a reason, when the template's cartridge filter does not accept the
round — a magazine "filled" with ammo the filter omits is a gun that spawns
empty.

### `equipWeapon(s, slot, weapon, magazine, ammo)`

**Wear a weapon with a magazine mounted in it and a round in the chamber.**

The reason this is a separate verb is a measured fact about the database, not a
preference:

| Template | `_props.Cartridges` | `_props.Chambers` | `_props.Slots` |
|---|---|---|---|
| `5447a9cd4bdc2dbd208b4567` (M4A1) | **absent** | `[0]._name = "patron_in_weapon"` | 6, incl. `mod_magazine` |
| `55d4887d4bdc2d962f8b4570` (STANAG) | `[0]._max_count = 30` | absent | 0 |

A weapon **holds no rounds directly**. `equipLoaded(s, slot, m4, ammo)` asked the
backend for a cartridge capacity the M4A1 does not have, was refused with *"the
database declares no `_props.Cartridges[0]._max_count`"*, and — even had it
succeeded — would still have mounted nothing in `mod_magazine`. That is why
`GetCurrentMagazine()` read null in raid and why `pactMagCycle` had nothing to
cycle.

The magazine is **named, never guessed**. The M4A1's `mod_magazine` filter admits
20 templates, and "the first match" is an arbitrary document order — the same
guess `byName` already refuses. A magazine the filter excludes is refused
**before minting**, because a magazine the client drops on load still saves to
the profile and still reads back.

**The acceptance is a walk of the finished state.** The server re-reads the saved
profile, finds the item actually worn in `slot`, and counts *its* `mod_magazine`
children and *their* cartridges. Three separate numbers come back, and two of
them are independent FAILs:

| Number | Zero means |
|---|---|
| `magPlaced` | no magazine is in the weapon. `GetCurrentMagazine()` will be null. |
| `roundsPlaced` | the magazine is mounted and **empty**. A reload test against it proves nothing. |
| `chambered` | nothing in `patron_in_weapon`. Reported, not failed. |

"No magazine" and "an empty magazine" break a raid differently, so they are never
collapsed into one boolean.

**The input that makes this check fail is nameable**: pass a `magazine` the
weapon's filter excludes (an IFAK, say) and `magPlaced` stays 0.

### `carry(s, container, tpl, count)`

`count` items in **real cells** of the container worn in that equipment slot —
`TacticalVest`, `Backpack`, `Pockets`, `SecuredContainer`.

Refused, never placed at 0,0, when there is no room: an overlapping item is drawn
on top of what is already there and cannot be picked up, which looks exactly like
never having been given it.

### `carryLoaded(s, container, tpl, count, ammo)`

`count` magazines in the container, each loaded. The "magazines = 3, ammo =
M855A1" case.

### `stock(s, tpl, count)`

`count` loose in the stash, stack-limit aware and merged into stacks already
there.

### `byName(s, query, count)`

Stash `count` of whatever the English item name names. **An ambiguous name is
REFUSED and the candidates are listed** — a test that equipped the wrong rifle
proves nothing.

### `wear(s, slot, tpl, condition)`

`equip` with a durability/resource percentage, applied only to the properties the
template actually declares.

---

## 3. The loadout wire format

The script process and the backend are different processes, so the spec is plain
JSON, POSTed to `/aowlspt/tarkov/autoscript/loadout` on the backend's control
port.

```json
{"profileId": "<24 hex>",
 "clear": true,
 "gear": [
   {"tpl": "5ab8dced86f774646209ec87", "slot": "TacticalVest"},
   {"tpl": "5447a9cd4bdc2dbd208b4567", "slot": "FirstPrimaryWeapon",
    "magazine": "55d4887d4bdc2d962f8b4570",
    "ammo": "54527ac44bdc2d36668b4567"},
   {"tpl": "55d4887d4bdc2d962f8b4570", "count": 3,
    "inside": "TacticalVest", "ammo": "54527ac44bdc2d36668b4567"},
   {"query": "m855a1", "count": 180}
 ]}
```

| Field | Meaning | Refusal |
|---|---|---|
| `tpl` | a 24-hex template id | not in the database → named |
| `query` | an English item name | **ambiguous → REFUSED**, candidates listed |
| `slot` | one of the 14 equipment slots | not one of the 14 → named |
| `inside` | the equipment slot of a **worn container** | nothing worn there → named |
| `count` | how many; capped at `MaxCountPerRequest` | over the cap → refusal states the cap |
| `ammo` | the round to load | filter excludes it → named |
| `magazine` | mounted in `mod_magazine` | filter excludes it → refused **before** minting |
| `chamber` | put one round in the chamber | defaults **true** when `ammo` is given |
| `condition` | durability/resource % | |

Hard rules:

* `slot` **and** `inside` together is refused — they are different placements.
* `magazine` **without** `ammo` is refused by the parser. A magazine mounted
  empty is indistinguishable in raid from no magazine at all.
* `chamber` defaults true but is only *acted on* when the template really
  declares `_props.Chambers`, so asking for a chamber on a magazine is a no-op
  rather than a fabricated slot.

### The report

```json
{"verdict": "FAIL", "reason": "...",
 "requested": 5, "minted": 5, "placed": 4,
 "rejected": ["..."], "observations": ["..."],
 "gear": [{"query":"...", "tpl":"...", "name":"...", "where":"...",
           "requested":1, "baseline":0, "minted":1, "placed":1,
           "magazine":"55d4887d...", "magPlaced":1, "roundsPlaced":30,
           "chambered":1, "why":""}]}
```

The numbers are separate because collapsing them destroys the failure this whole
feature exists to catch:

* `baseline` — how many were **already** there, read *before* anything was
  minted. `placed` is `after − baseline`. Without it, a script asking for 180
  rounds into a stash that already held 180 read back 360 and "passed" on gear
  it was already carrying.
* `minted` — what this module wrote.
* `placed` — what the **re-read profile** actually contains.

`rejected` fails the spec; `observations` does not. `auditStacks` runs over the
whole inventory and reports pre-existing oddities no script asked for — folding
those into `rejected` made a perfectly good loadout FAIL, which is the mirror
image of a check that cannot fail.

---

## 4. Arming — everything here happens BEFORE the client boots

### `withActuation(s)`

Declare that this script drives the player. Arms three host flags in
`aowlspt-host.json`:

| Flag | Why |
|---|---|
| `playerActuation` | `pact` itself; without it every request is refused by name |
| `liveInspector` | the file channel the request travels on |
| `liveInspectorWrite` | the write gate — `pact` **calls into game code** |

Opt-in because those three are default-OFF by rule. If a key is missing from the
config, `armActuation` returns false and **says which** — and the run continues,
because the actuation steps then refuse *by name*, which is a better outcome than
a run that silently never actuated and still passed.

### `withAmmoLoading(s, mode)`

Put `mods/ammoloading` on a rung: `off` / `probe` / `read` / `spawn` / `animate`.
`probe` proves the trigger fires with zero dereferences and no bundle. The two
rungs above need a bundle riding a vanilla key via `mods/textures`, which this
library does not set up and does not pretend to.

### `armPhaseReporting` (automatic)

Writes `debugEsp`, `natEsp` and `natEspDiag`, because the raid-phase latch's only
out-of-process observable is a host log line gated behind all three.

---

## 5. The steps

Each returns `bool`; each that returns false has already written its reason. None
of them throw.

| Step | PASS | FAIL | INCONCLUSIVE |
|---|---|---|---|
| `launchStack(s)` | backend control port answers | — | no install, `attachOnly` with nothing running, or 240s with no answer |
| `pickProfile(s)` | a profile was chosen | — | no profile on the install |
| `applyGear(s)` | every item read back | `placed < requested`, or a refusal | no backend/profile, route 404, non-200 |
| `verifyGear(s)` | read-back only; mints nothing | same | same |
| `enterRaid(s)` | the entry driver drove the menu | driver refused | driver missing or never ran |
| `waitDeployed(s, secs)` | the **latch** said DEPLOYED | latch reported another phase | no `raid phase =` line at all |
| `finish(s)` | returns the exit code | | |
| `run(s)` | all of the above in order, stopping at the first non-PASS | | |
| `runToRaid(s)` | everything up to and including DEPLOYED | | |

Readiness in `launchStack` is `aowlsession.answers` — the tarkov mod's own
selfcheck route — not a sleep. The budget is **240s, not 60**: the client takes
over 60s to reach profile-select and then waits for a human, and a 60s budget is
the false crash in runner form.

**`waitDeployed` never treats a raid-ENTRY signal as raid STATE.** `enterraid.py`
exiting 0, a `RegisterPlayer` line and a scene-load marker are all *not* proof of
deployment; that mistake invalidated four experiments in one week. It waits for
the latch. If no `raid phase =` line ever appears the verdict is INCONCLUSIVE
**naming the three flags** — not "you did not deploy". Those are different facts.

---

## 6. Player actuation

Every request goes to `pact` through the inspector command file as

```
#<serial>
allow write
pact <verb> <args>
```

The serial is not decoration: **the channel triggers on a content change**, so
two identical batches would run once and the second call would wait out its whole
budget on the first one's answer.

### `pactDo(s, request, seconds = 20)`

The primitive. Sends one raw request and waits for the host to say it arrived.

| Verdict | Host log line |
|---|---|
| PASS | `pact-rpc: QUEUED "<request>"` |
| FAIL | `pact-rpc: REFUSED …` — the host looked at it and declined; its own line says why |
| INCONCLUSIVE | **neither** — the request never reached pact |

**ACCEPTED IS NOT DONE**, and the PASS message says so. INCONCLUSIVE here means
the inspector is off, the write gate is off, or the client is not draining — an
instrument that did not run, not an actuation that failed.

### The typed verbs

| Verb | pact request | Game method | Strength |
|---|---|---|---|
| `walk(s, strafe, forward, frames)` | `move X Y N` | `Player::Move(Vector2)` | issue-only |
| `walkAndSee(s, strafe, forward, frames, settle=6)` | `move` + readback | + `get_Position` | **VERIFIED** |
| `look(s, dx, dy)` | `look DX DY` | `Player::Rotate` | issue-only |
| `fire(s, on)` | `fire on\|off` | `FirearmController::SetTriggerPressed` | issue-only |
| `aim(s, on)` | `aim on\|off` | `FirearmController::SetAiming` | issue-only |
| `sprint(s, on)` | `sprint on\|off` | `Player::EnableSprint` | issue-only |
| `jump(s)` | `jump` | `Player::Jump` | issue-only |
| `prone(s)` | `prone` | `Player::ToggleProne` | issue-only |
| `pose(s, delta)` | `pose D` | `Player::ChangePose` | issue-only |
| `lean(s, dir)` | `lean D` | `Player::ToggleLean` | issue-only |
| `command(s, code)` | `command N` | `ECommand` via `GamePlayerOwner` | issue-only |
| `reload(s)` | `reload` | `ECommand` 16 | issue-only |
| `pactWait(s, frames)` | `wait N` | queue hold | — |
| `magCycle(s, seconds=60)` | `magcycle` | unload + load | **VERIFIED** |

Argument conventions, each taken from the game's own call sites:

* `strafe` is +right / −left; `forward` is +forward / −back. Magnitude is clamped
  by the game, so 1.0 is full input.
* `frames` is **frames, not seconds**. `Move` is an input *sample*; pact
  re-applies the held vector once per drain tick, so one call is one frame of
  walking.
* `look` takes a **delta** in degrees, not an absolute heading. +dx right,
  +dy down.
* `pose` is negative to crouch, positive to stand. The magnitude is a pose-level
  delta, **not metres**.
* `lean` is −1 left, 0 centre, +1 right.
* `prone` is a **toggle**, not a set. Calling it twice returns the player to
  where they started, which is a real way to write a test that proves nothing.
* Floats are formatted with `formatFloat(v, ffDecimal, 3)`. `$` on a float is not
  used anywhere in this repo, and scientific notation reaching pact would be
  refused as a malformed number — correctly, but confusingly.
* Numeric arguments **never** silently coerce. A malformed number is REFUSED,
  because `move 0 0` is a legal request and a coercion would make a typo look
  like a command that worked.

### `actuated(s, request, settleSeconds = 6)` — the effect assertion

Issues a request and then asserts it **took effect**, by reading pact's own
readback counters before and after. Those counters are computed from
`EFT.Player::get_Position` — the game's number, which this library never writes.

| Verdict | Condition |
|---|---|
| PASS | `took` rose — real metres travelled past `PactMinMoveM` |
| FAIL | `never` rose — pact dropped it with a stated reason |
| FAIL | `noeffect` rose — the call was made and the world did not move |
| INCONCLUSIVE | pact never answered a status request, or **no counter moved** |

`settleSeconds` exists because pact only compares positions after
`PactSettleFrames`. Asking immediately would read the mark against itself, which
is a comparison of a value with itself — the check that cannot fail, in its
purest form.

> **Only movement has a readback in pact today.** `actuated(s, "look 15 0")`
> reports INCONCLUSIVE, "no readback counter moved". That is the correct answer —
> nothing was measured — and it must not be read as a look that happened.

### `magCycle(s, seconds = 60)` — the user's own example

Unload the magazine in the weapon and load the same ammunition back, with nobody
at the keyboard. Four outcomes, each naming its stage:

| Verdict | Meaning |
|---|---|
| INCONCLUSIVE | the request never reached pact |
| FAIL | pact REFUSED it — no firearm in hands, not deployed, a hop that did not validate. **Nothing was issued.** |
| FAIL | issued and did not complete. A **partial** load counts here, on purpose. |
| PASS | `pact magcycle: COMPLETE` — the game's own `Magazine.Count` came back |

The PASS is a number the game maintains and this library never writes.

### `assertAmmoLoadingFired(s, seconds = 40)`

Asks whether `mods/ammoloading` **observed** the cycle, asserting on the mod's own
announcement rather than on ours:

| Verdict | Line |
|---|---|
| PASS | `ammoloading FIRST FIRING`, or an `ARMED and FIRING` heartbeat |
| **FAIL** | `ARMED but NEVER FIRED` — installed, watching, and the detour did not fire. **This is the verdict the whole script exists to be able to produce.** |
| INCONCLUSIVE | `NOT ARMED`, or nothing at all — no hook is installed, so a zero counter says nothing |

### `pactStatusLine(s, seconds = 15)` / `pactStatusNote(s)`

pact's counter line. `pactStatusNote` puts it in the transcript and **changes no
verdict** — a counter line is what you read once a verdict has been reached, not
the verdict itself.

```
pact armed=31/31 rejected=0 raid=DEPLOYED player=ok owner=corroborated
 | asked=12 took=9 noeffect=2 never=1 qdrop=0
 | magcycles=1 magok=1 magfail=0 (ok)
```

`asked` / `took` / `noeffect` / `never` are **four outcomes, not two**, and a run
with `asked=0` is INCONCLUSIVE — neither a pass nor a failure. `counterOf`
returns **−1** for an absent key rather than 0, because "the counter says none"
and "there is no counter" are different observations.

### Refusals pact issues before touching anything

`pact` answers *every* request even when it cannot act, because silence is the
one reply an outside process cannot interpret — it is indistinguishable from "the
host never received it".

| Refusal | Meaning |
|---|---|
| `flag playerActuation is OFF` | a **configuration** refusal, not a failed actuation |
| `pact SELF-DISABLED after N faults` | the whole-file fault budget tripped |
| `pact is NOT BOUND yet (N drain frames)` | inconclusive — nothing verified, nothing called |
| `the raid-phase latch does not read DEPLOYED` | actuation is refused outside a live raid |
| `the actuation ring is FULL` | nothing was enqueued |
| `unknown pact verb "..."` | |
| `usage: ...` | a malformed argument, never coerced |

Two traps worth stating explicitly:

* `fire` and `aim` are refused unless `Player::HasFirearmInHands()` is true. On a
  knife or empty hands the hands-controller pointer is the **abstract base**, and
  calling a `FirearmController` method on it is type confusion that no nil check
  catches.
* The `ECommand` channel (`command`, `reload`) needs the
  `GamePlayerOwner::LateUpdate` capture detour to have attached. It can be
  unavailable **on its own** — pact warns after 600 drain frames. Movement, look,
  fire, aim and the magazine cycle are unaffected, so a failure there is about
  that channel and must not be read as pact being broken.

---

## 7. Verdict plumbing

| Proc | Does |
|---|---|
| `note(s, line)` | a script's own commentary into the transcript |
| `finish(s): int` | prints the conclusion, returns the exit code |
| `verdictOf(s)` / `reasonOf(s)` | the verdict and its reason |
| `quitWith(code)` | exit with it |
| `runAndQuit(s)` | `run` + `finish` + `quitWith` — the whole runner |

---

## 8. Writing a script

```nim
import autoscript

proc main() =
  var s = newScript("my-test")
  onMap(s, "Factory")
  asSide(s, "pmc")
  withActuation(s)

  equip(s, "TacticalVest", "5ab8dced86f774646209ec87")
  equipWeapon(s, "FirstPrimaryWeapon", "5447a9cd4bdc2dbd208b4567",
              "55d4887d4bdc2d962f8b4570", "54527ac44bdc2d36668b4567")

  if runToRaid(s):
    discard pactWait(s, 300)      # let the deploy animation finish
    discard walkAndSee(s, 0.0, 1.0, 90)
    discard magCycle(s, 60)

  quitWith(finish(s))

main()
```

Notes that have cost time before:

* **`pactWait(s, 300)` before the first verb.** A request issued while the weapon
  is still being drawn refuses at `HasFirearmInHands` — a *timing* answer wearing
  a *capability* answer's clothes.
* **Always pair `fire(s, true)` with `fire(s, false)`.** An unmatched trigger hold
  stays down for the rest of the raid and corrupts every later verb.
* **No `continue` inside a `for` over an array literal.** Measured on this nimony
  (2026-08-31): it compiles to `[Error] unreachable: (continue@…)` at the final
  build step, naming no line of yours. Use flag-shaped control flow.
* Every argument to the spawn shim must be a **named local** — `toCString` takes
  a `var string`, so passing an expression is a compile error.

### The reference scripts

| Script | Demonstrates |
|---|---|
| `scripts\woods_pmc_m4.nim` | a full PMC loadout, gear only |
| `scripts\gear_must_fail.nim` | **a check that CAN fail** — a rifle into `Headwear` |
| `scripts\ammoloading_e2e.nim` | the whole spine: gear → raid → magazine cycle → did the mod see it |
| `scripts\actuation_tour.nim` | every actuation verb, with its strength labelled |
| `scripts\weapon_swap_e2e.nim` | **weapon swap, proved by what is really in hands** — plus look, sprint and the magazine cycle |

`gear_must_fail.nim` is not decoration. If it ever passes, the gear acceptance has
stopped being able to fail and everything above it is worthless.

---

## 9. Related documents

| Document | Covers |
|---|---|
| `docs/PLAYER_ACTUATION.md` | the host side of `pact` — RVAs, the guard, why `GamePlayerOwner` is a detour |
| `docs/INSPECTOR-VERBS.md` | the live inspector's own verb set, including `assert` |
| `docs/HEADLESS.md` | driving the client with no human |
| `CLAUDE.md` §9b | why every check here is shaped as a falsifiable negative |

---

## 10. THE VERSION HANDSHAKE

A green run used to be able to mean nothing. Deploy a `tarkov.dll` built before
`equipWeapon`'s `magazine` field existed and run `woods_pmc_m4.nim`: the old
route is PRESENT so there is no 404, it parses the spec, never looks at
`magazine`, mints the rifle alone and answers `requested=1 minted=1 placed=1
verdict=PASS`. The raid starts with an unloaded rifle and the feature under test
was never exercised. `applyGear`'s only staleness signal was HTTP 404, which
tells "no route" from "a route" — not "a current route" from "an old one".

So both halves of the install now say what they can do, and every declaration
verb records what it needs.

| Half | Asked | Answers |
|---|---|---|
| backend (`tarkov.dll`) | `GET /aowlspt/tarkov/autoscript/capabilities` | `{"api":2,"caps":[...]}` — `LoadoutApi` / `LoadoutCaps` in `mods/tarkov/emu/loadout.nim`, beside the code that implements every token |
| host (`aowlspt-host-il2cpp.dll`) | `pact caps` over the inspector channel | `caps api=2 verbs=... readback=... issueonly=...` — `PactCapsLine` in `host/Aowlspt.Host.Il2Cpp/pact.nim` |

Two halves, not one, because they are deployed separately and go stale
separately; a half-stale install reported as wholly stale is a worse diagnosis
than none. `pact caps` is answered ABOVE every gate — flag, bind, raid phase —
so "this host is too old" stays distinguishable from "playerActuation is off".

`checkVersion` and `checkPactVersion` run in `run`/`runToRaid` BEFORE the gear,
so a refusal leaves the profile alone rather than half-minted. Membership is an
exact TOKEN test, never `contains`: a substring test would let `magazine` be
satisfied by a build declaring only `magazines`.

Declare extra needs by hand with `needsBackend(s, tok)` / `needsPact(s, verb)`.

**Three outcomes.** FAIL — the install answered and a needed token is absent
(the 404 case is a FAIL, not INCONCLUSIVE: "this build has no autoscript routes
at all" is a measured answer). INCONCLUSIVE — nothing answered; no control port,
a transport error, or no `pact-rpc: caps` line in 25s, so nothing was learned
about the install's age. PASS — every declared token present.

---

## 11. Verb strength, as of this build

| Verified against a value the GAME maintains | Readback |
|---|---|
| `walkAndSee` | `EFT.Player::get_Position` — metres travelled |
| `lookAndSee` | `EFT.MovementContext::get_Rotation` — degrees, yaw wrapped across 0 |
| `sprintAndSee` | `EFT.Player::get_IsSprintEnabled` |
| `aimAndSee` | `FirearmController::get_IsAiming` |
| `swapWeaponAndSee` | `FirearmController::get_Item` — a DIFFERENT weapon object in hands |
| `magCycle` | `EFT.InventoryLogic.Magazine::get_Count` |

Issue-only, and labelled so everywhere: `fire`, `jump`, `prone`, `pose`, `lean`,
`toggleInventory`, `examineWeapon`, `command`, `reload`. pact has no readback for
the trigger or for stance. Saying so is better than upgrading an INCONCLUSIVE.

### Weapon swap and inventory needed NO new RVA rows

Measured, and worth stating because the opposite was assumed: weapon selection
is not a method call, it is `EFT.InputSystem.ECommand` through the
`GamePlayerOwner::TranslateCommand` row pact already carries. The ordinals come
from `il2cpp_resolve.py ... fields ECommand` — `ExamineWeapon=36`,
`ToggleInventory=37`, `SelectKnife=38`, `SelectFirstPrimaryWeapon=41`,
`SelectSecondPrimaryWeapon=42`, `SelectSecondaryWeapon=43` — not from a name.

The one row genuinely added is the rotation readback,
`EFT.MovementContext::get_Rotation` @ `0x8947A0`, `UNIQUE owners=1`, prologue
`40 53 48 83 EC 20 80 3D E6 41 82 06 00 48 8B D9` — a real body, not the
`C2 00 00` universal empty stub. Vector2 is 8 bytes so it returns PACKED IN RAX,
not by sret. Nothing new is DETOURED: the only detour pact owns is still the
`GamePlayerOwner::LateUpdate` capture.

---

## 12. Running one mod's suite alone

`aowl test --mod NAME` builds and runs that mod's `core/selftest` and nothing
else — `aowl test --mod sain` is **~6s and prints `PASS -- 125 checks`**, where
`aowl test` ran forty minutes with its output buffered and emitted nothing.
(`modclient.exe` never had a `--mod` flag at all; it is the manager's report
reader and has no notion of choosing a mod.)

It works because `core/` is pure by construction, so a generated seventeen-line
main is a complete harness. Exit **0** pass, **1** fail, **3 INCONCLUSIVE** — no
such mod, or no `core/selftest.nim`. A missing suite must not exit 0.
