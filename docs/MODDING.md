# Writing a mod

The whole API, top to bottom, in one page.

```nim
import aowlspt
import aowlspt/game

var Player = gameType("EFT.Player")
var world = whenReady("EFT.GameWorld")

proc onUpdate(elapsedMs: int64): Status =
  if world.ready():                      # true once, when the game exists
    let hp = Player.get("Health")        # a C# property
    info "health is " & $hp.asFloat()
    discard Player.invoke("Heal", 50)    # a method, with arguments

    discard hookArgs("EFT.Player::ApplyDamage",
      proc (target, args: string): HookResult =
        info "damage: " & args           # what the game passed
        carryOn())                       # and let it run
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient},
          onUpdate = onUpdate)
```

Build it:

```
aowl doctor                          # once, before anything else
aowl build-mod examples/highlevel
```

That is the **client** half — a mod reaching into the running game. If what you
want is a **server** mod — a new trader, a new quest, changed item stats, a new
route — read `mods/admintrader/` first. It is a complete, commented, working
example (a trader who sells everything for free and gives out one quest), its
`README.md` is a tutorial rather than a reference, and it is short because the
server-side mechanism is small: `mods/tarkov` serves traders and quests straight
out of the loaded database, so a mod adds one by writing JSON at
`traders.<id>` / `templates.quests.<id>` with `dbWrite`. There is no trader API
to learn, and there is not meant to be one.

`aowl doctor` checks the toolchain, and every check in it is there because
something actually went wrong and pointed somewhere else when it did: nimony
present, ucrt64 gcc present, `ld.lld` present (nimony passes `-fuse-ld=lld` on
Windows), the ABI headers present, and the build caches still matching those
headers. The one worth knowing about is **PATH order** — gcc finds `cc1` and its
libraries relative to PATH, so a Git-for-Windows `mingw64` ahead of ucrt64 gives
you a `cc1` that loads the wrong libgcc and **dies with no message at all**. The
build simply stops. A check that has never caught anything is not in that list.

**`examples/lesson` is the worked version of everything on this page**, in this
order, with each section saying why the API is shaped the way it is — and it
measures the numbers it quotes in its own process before printing them --
with the exception of the two costs quoted at the arm site in section 11, which
name the section-13 rows that measure them. It runs
under `aowl run examples/lesson` with no game and no server, where it names each
facility it cannot exercise and why, and against `tests/mockil2cpp` in a stage of
its own. That is the sample to copy from.

`examples/highlevel` is **not**. It is the client host's regression test:
**eighteen** of the harness's twenty-four verdicts are greps for exact strings
that file prints, so
every line it prints is load-bearing for somebody else's red gate and it is
organised around covering the host rather than around teaching anyone. Read it to
find out what the host is asserted to do. `examples/clientprobe` is the same mod
written against the raw interface, worth reading once to see what the layer above
is doing.

(This said "seventeen gate assertions" and took the figure from
`examples/highlevel/highlevel.nim`'s own header, which still says twenty-three
assertions and seventeen. Derived afresh 2026-08-19 by matching every
`find(l, "...")` in `tools/hostharness.nim` against what each mod actually
prints: twenty-four verdicts, of which fifteen are satisfied only by lines
`highlevel` prints, three by lines it shares with `clientprobe`, two by
`clientprobe` alone — "resolved " and the Unity version — and four by the host's
own log. So eighteen involve `highlevel`. The stale seventeen in
`highlevel.nim` is a source comment and wants moving with the rest.)

Every snippet on this page was compiled against the current library before it
was written down. Where something has *not* been verified, it says so.

**Check a binding once against a value you can predict.** Everything below this
line that infers a signature from the runtime's metadata can be wrong in the one
way that does not announce itself: a float argument placed in a general-purpose
register, or a result read out of the wrong register file, answers *a number*
rather than crashing. `examples/lesson` calls one method with a known answer
right after binding it, before trusting the binding in a loop, and prints the
binding's own `why` beside the result when they disagree. That is four lines and
it is the difference between an afternoon and a fortnight.

## The four things underneath

Everything reaches the game through these, and the high-level API is these with
the boilerplate gone. When something behaves oddly, this is the level to think
at.

| | what it does | appeared at |
|---|---|---|
| `resolve(name, handle)` | find a type by name, across every loaded assembly | rev 1 |
| `call(target, argsJson, out)` | invoke `Type::Member` with a JSON argument array | rev 1 |
| `patch(target, kind, handler)` | detour a compiled method and be told when it runs — before it (`pkPrefix`) or after it, with what it returned (`pkPostfix`) | rev 1 |
| `patchTyped(target, kind, handler)` | the same detour, delivered as saved registers rather than JSON | rev 4 |
| `pointerOf(handle, address)` | the address of the object behind a handle, for the fast path | rev 3 |

`patch` and `patchTyped` take a raw `PatchHandler` / `TypedPatchHandler` and
answer with `patchContinue()` / `patchReplace(json)` and `frameContinue()` /
`frameReplace()`. The `hook*` family in `aowlspt/game` is a thin dispatcher over
them and is what a mod should use; these are named because a log line or an error
will name them.

There is a fifth way in that does not go through the host at all — see
"Per-frame code" at the bottom. Reach for it when you have measured, not before.

`pointerOf` is what joins the two halves: the host tells you *which* object
something happened to, and the address is what your own bindings act on without
paying for a round trip through `call`. It is revision 3 of the ABI and only the
IL2CPP client host has it — a server-side handle names a .NET object with no
address to give — so `livePointersReady()` before you rely on it.

## Where am I, and what can this host do

The first thing a mod should do is find out where it is, and the second is find
out what that place can do. Both matter more here than in a managed plugin
system, because the same compiled `.dll` loads into three hosts that genuinely
differ: the backend has no game to reflect into, the client host has no database
to read, and the simulator has neither.

```nim
side()            # sideServer, sideClient, sideSim
hostName()        # "aowlspt-host-il2cpp", "aowlspt-backend", "aowlspt-sim"
hostVersion()
sptVersion()      # "" where the host does not report one
gameVersion()
modDir()          # this mod's own directory
dataDir()         # modDir()/data
nowMs()           # milliseconds since the host started
hostApiSize()     # what the host filled in
expectedApiSize() # what this mod's header declares
```

`hostApiSize()` and `expectedApiSize()` are two different questions and both are
worth logging once. A mod built against a newer ABI than the host it lands in
should find that out from a number rather than from a call through a null
function pointer.

Every capability test is a **size test** against the revision that capability
appeared at:

| test | boundary | true on |
|---|---|---|
| `storeReady()` | rev 2 | every host |
| `livePointersReady()` | rev 3 | the client host (filled-and-refusing elsewhere) |
| `typedPatchesReady()` | rev 4 | the client host (filled-and-refusing elsewhere) |
| `notifyReady()` | rev 5 | the backend only |

A size test rather than a null check because **nimony will not `cast` a proc
field to a pointer to compare it against null**, so there is no null check
available. `size` says how much of the struct the host filled, and a host that
reports a size has filled everything up to it. Testing against `sizeof(HostApi)`
instead is right exactly once: the day the struct next grows, every older host
starts answering "no store" when it has one.

**So a size test means "there is a function here that will answer", not "this
works."** The backend and `aowlspt-sim` fill the revision-3 and revision-4 entries
with the refusal they already owed, precisely so that one integer can say "the
fourth and not the fifth" — which means `typedPatchesReady()` is *true* on the
simulator and `hookTyped` there answers `ErrUnsupported`. Check the status of the
call as well as the capability. Every arm site in `examples/lesson` does.

`side()` guards are the ordinary way to write a mod that ships everywhere, and a
capability a host does not have returns `AOWLSPT_ERR_UNSUPPORTED` rather than
misbehaving.

### Logging

`trace`, `debug`, `info`, `success`, `warn`, `error` — one string each, no format
strings, and the host prefixes your guid. `success` is for a positive *verified*
fact ("fired 3 times"), `warn` for armed-but-never-applied and for a degraded
fallback, `error` only for something the person running it must act on. A mod
that logs a refusal at `info` and a success at `success` reads correctly in a log
somebody else is scanning.

## Config

`config.json` next to the library, read through the host rather than off the
disk: the host knows where the mod's directory is, and a mod that opens the file
itself breaks the first time somebody stages it somewhere else.

```nim
var whole = ""
discard configGet("", whole)          # an empty key returns the whole document
let ceiling = asFloat(field(whole, "tiltCeiling"), 4.0)

discard configSet("someKey", "1")     # usually refused, and that is correct
```

Read it once and keep it. `configGet` is a host round trip and a buffer copy,
which is nothing at load and is a frame tax in `onUpdate`. `configSet` is refused
by the hosts that treat `config.json` as the operator's file rather than the
mod's — ask, and log which kind of host you got, rather than assuming.

## Game data: traders, stock and quests — `aowlspt/trader`

`mods/tarkov` IS the game server, and it has no trader type and no quest type.
It reads `traders.<id>` and `templates.quests.<id>` straight out of the loaded
database and serves whatever is there. So the mechanism is `dbWrite` — and the
difficulty is entirely the *shape*: a trader's `base` has 33 fields, a quest
template 30, and a missing field hangs the client rather than erroring.

`aowlspt/trader` is those shapes with a working default for every field. It is
not a framework: each proc either builds JSON or performs one named `dbWrite`,
and says which path it wrote.

```nim
import aowlspt/trader

var t = newTrader(traderId("ad0000000000000000000001"), "Admin Trader")
t.description = "Everything, free."
discard t.stockWholeHandbook()               # ~4,300 items, free
if install(t) != Ok: warn whyNot(t)          # dbWrite("traders.<id>", …)

var q = newQuest(questId("ad0000000000000000000101"), t, "Admin Induction")
q.requireLevel(1)
q.requireHandover("544fb37f4bdc2dee738b4567", 1)
q.rewardExperience(500)
q.rewardStanding(0.1)
discard install(q)                           # dbWrite("templates.quests.<id>", …)
```

The full worked example is `mods/admintrader` — 199 lines for a trader stocking
4,288 items plus a quest, with a status route and a settings page. Its
`tools/acceptance_admintrader.py` asserts the result against a real `db.json`.

| you want | you call |
|---|---|
| a checked id | `traderId(hex)` / `questId(hex)` — refuses non-24-hex, loudly |
| a trader | `newTrader(id, nickname)`, then set the fields that differ |
| the 33-field `base` | `traderBase(t)` (called for you by `install`) |
| an item on the shelf | `sell(t, freeOffer(tpl))` / `pricedOffer` / `barterOffer` |
| everything, in stock | `stockWholeHandbook(t, maxOffers, price)` |
| the three keyed collections | `traderAssort(t)` |
| a quest | `newQuest(id, giver, name)` + `requireLevel` / `requireHandover` |
| rewards | `rewardExperience(q, xp)` / `rewardStanding(q, n)` |
| readable names | `localeText(loc, key, value)`; `traderNames` / `questWords` |
| write it | `install(t)` / `install(q)` / `install(loc)` |
| assert it worked | `auditTrader(t, o)` / `auditQuest(q, o)` |

### What this module makes impossible, rather than documented

Each of these was a real way to produce data that looks written and is silently
broken. Knowing them still matters for debugging, but you can no longer spell
them:

* **An offer with no price.** An assort is three collections keyed to each other
  (`items`, `barter_scheme`, `loyal_level_items`); an offer in the first and
  missing from the second is drawn and unpriceable. An `Offer` carries its own
  cost and all three collections come out of one loop over `t.offers`.
* **"Free" as a price of zero.** There is no price field — a price IS a barter
  requirement. `freeOffer` is a requirement for `count: 0` roubles.
* **A locale name as a dotted path.** The text lives in `locales.global.en`
  under `"<id> Nickname"`, with a SPACE, so a dotted path writes a key nobody
  reads. `localeText` takes a key and a value; there is no path argument.
* **Stock from `templates.items`.** That table is 4,673 raw templates including
  hideout nodes and stashes, tens of megabytes, wrong for a shop.
  `stockWholeHandbook` names `templates.handbook.Items` and takes no argument.
* **A malformed id.** `traderId` / `questId` warn at construction and make
  `install` return `ErrBadArg` rather than write something unreachable. An id
  is never pasted into a db path unchecked — `dbRead("traders." & "")` reads the
  *whole table*, whose every field then comes back empty rather than missing,
  which reads as a trader that exists and is blank.
* **An unstartable quest.** `install(q)` refuses a quest with no start
  condition or no finish condition, and says which.
* **A sibling's shape on the wrong field.** `traderBase` owns every
  collection-shaped field; none is settable on `Trader`. This is the fix for a
  real escape: `items_sell` was written in the `{category, id_list}` shape that
  `items_buy` legitimately uses, and the client answered
  `JSON parsing error in response to traderSettings at line 1 position 101170`
  on a document that was perfectly valid JSON. Stock `items_sell` is a dict
  keyed by loyalty level (8 of 12 traders) or a bare `[]` (the other 4).

### Validate SHAPE, not just syntax

That escape is worth generalising, because it will happen again to any mod that
writes db documents. A `json.loads` that succeeds proves nothing: the client
deserializes into typed objects, so a document can be flawless JSON and still be
rejected on a field whose *shape* is wrong. A test that only asserts "the
payload parses" cannot fail, which makes it the bug.

`auditTrader` therefore also emits `storedBase` — the whole stored `base`, read
back — so a test outside the mod can compare it, field by field and into nested
collections, against **stock traders you did not write**. That is what
`tools/acceptance_admintrader.py`'s `check_shape` does; it accepts a field if it
matches *any* stock trader, because stock data is genuinely polymorphic in
places, and fails if it matches none. Copy the pattern for any db document your
mod writes.

Two things it deliberately does not hide, because they are not shapes: getting
a mod to load at all (`docs/MOD-ENABLE-PATH.md` — the DLL, `registry/mods.json`,
and the manager-owned selection, enabled via
`GET /aowlspt/mods/enable/<guid>`), and `regcheck` comparing `sides` and
`author` to your source verbatim.

### Auditing, not self-congratulation

`auditTrader` / `auditQuest` fill a `JsonObject` with counters read back out of
the database — never out of your mod. Serve them from a status route and assert
on them. Two are deliberately negative (`offersNotFree`, `offersUnpriced`)
because "we wrote 4,288 free offers" cannot fail while "no offer in the
database costs anything" can. And `listedInTradersTable` has three outcomes:
`"yes"`, `"no"`, or `"unknown: …"` on a host that cannot enumerate keys —
`aowlspt-sim` is such a host, and reporting `false` there would be a check that
says the trader is missing whenever you were unable to look.

## Types

```nim
var Player = gameType("EFT.Player")
```

Declared at the top of the file, resolved on first use. That split matters:
when a mod loads, the process has an IL2CPP runtime but the game has not
finished loading its own assemblies, so resolving `EFT.Player` at load time is a
false negative. `GameType` closes the gap — name it early, resolve it late.

`gameType` is a **template**, not a proc, and that is load-bearing. In a nimony
`--app:lib` build a global initialised by a *call* is never initialised: literal
initialisers are folded at compile time, anything needing runtime evaluation is
skipped, and the global is left zeroed. As a template it expands to an object
literal at the declaration, which does get folded. If you write your own
helper that returns a `GameType`, make it a template too — or `resolveNow` will
warn you that a `GameType` has no name, which is what that warning means.

The same trap catches `aowlspt/fast`'s bindings, which cannot be templates. The
rule there is the mirror image: declare the global bare and assign to it from
inside a proc.

## Calls

```nim
Player.invoke("Add", 17, 25)      # ints
Player.invoke("Scale", 2.5)       # float
Player.invoke("Greet", "operator")# string
Player.invoke("SetFlag", true)    # bool
Player.get("Health")              # property getter -> get_Health
Player.set("Health", v(100.0))    # property setter -> set_Health
```

Arguments are bound to the **declared** parameter types, read off the method
itself — not guessed from the shape of the value you passed. IL2CPP will not
check for you: hand `il2cpp_runtime_invoke` an object pointer where it wanted a
pointer-to-int and it reads the object header as an integer, with no error
anywhere. A mismatch is refused instead:

```
argument 0 is declared System.Int32 but a string was given
```

**Enums count as numbers, both ways.** Most of what this game's methods take is
an enum -- every state, condition, damage kind and body part -- and an enum is
declared by its own name (`EFT.EPhysicalCondition`), so it matches none of the
primitive branches above. It is bound from a plain number, at the payload width
the runtime reports for it rather than at an assumed four bytes:

```nim
discard context.invoke("ApplyCondition", v(2))
let c = context.get("Condition")     # comes back as 2, not as a handle
```

The same holds for fields: `field("Condition")` reads a number and
`setField("Condition", v(2))` writes one. Before this, an enum argument was
refused outright and an enum *return* came back as
`{"handle":6,"type":"System.Int32"}`, so `asInt()` answered 0 with `ok` true --
a wrong value that reads like a right one -- and the handle behind it was never
released.

A value type wider than eight bytes is still refused from a number, because
there is no number that describes one. `Vector3` and friends go through the
shaped-call path, below.

Results are typed:

```nim
let r = Player.invoke("Add", 17, 25)
if r.ok:
  echo r.asInt()          # 42
else:
  echo r.error
```

`asInt`, `asFloat`, `asBool`, `asText`, `isNull`, `failed`. Each takes a default
for the case where the value is not what you expected, so a bad read is a
default rather than a crash.

`CallResult` is a record rather than a bare string on purpose: a failed call
would otherwise hand back `""`, which is a perfectly plausible value for plenty
of methods, and the failure would read as data.

## Live objects

A `GameType` is the static half of the game. Almost everything a mod wants is on
the other half — *this* player's health, *this* weapon's animation:

```nim
var GameWorld = gameType("EFT.GameWorld")

let world  = GameWorld.instanceOf()          # get_Instance
let player = world.child("MainPlayer")       # get_MainPlayer, on that world
info $player.get("Health").asFloat()
discard player.invoke("Damage", 25.0)
player.release()
world.release()
```

`instanceOf`, `child` and any call that returns a reference type hand back a
`GameObj`. It holds an IL2CPP GC handle, not a pointer, so keeping one across
frames is safe — the collector moves objects, and a raw pointer that was right
last frame is not right this one. The price is `release()`: a handle held for
the session pins its object. That is a leak rather than a crash, which is the
right way round for a mistake to fall.

`alive()` answers whether the object is still there, so a mod can ask before it
tries. `ok` is false for "the call did not return one", which is an ordinary
answer rather than a failure — `get_Instance` before the world exists returns
null.

### Fields

`get`/`set` reach a C# **property**, which compiles to `get_X`/`set_X`. A
**field** has no method behind it and is unreachable that way — and a great deal
of what a mod wants on this game is a field, often a private one:

```nim
let hp = player.field("Health").asFloat()
discard player.setField("Level", v(7))
```

Underneath, `field` is an ordinary `call` with an `@` in front of the member
name: `EFT.Player::@Health` reads one, and the same target with an argument
writes it. That spelling is what you will see in a log line or in
`examples/clientprobe`, and it is the escape hatch you drop to if you are
building the target string yourself.

Reading a field is not a trick; reflection is what the runtime provides for it.
Values are read and written by the field's **declared** type, so writing a float
into an int field is refused rather than reinterpreted — the bytes for `1` and
`1.0` are different bytes, and nothing downstream would notice until the game
did.

It is also not fast. The `@` path costs more than the property getter it exists
to replace, for reasons [PERF.md](PERF.md) measures. It exists because a great
deal of the game has no property at all.

## Hooks

Three, plus a typed pair below them. The first two are prefixes and differ in
whether you need to know *what* the method was called with; the third runs after
the original and is the only one that can see what it returned. All three
deliver a firing as JSON, which is the right answer until it is not — see "The
typed pair" at the end of this section.

**`hook` — the cheap one.** It costs a name comparison and nothing else, and the
handler is told only that the method fired:

```nim
discard hook("EFT.Player::OnDead",
  proc (target: string) =
    info "someone died")
```

**`hookArgs` — the full Harmony prefix.** The handler is told what the method was
called with, and may stop it running:

```nim
discard hookArgs("EFT.Player::Hurt",
  proc (target, args: string): HookResult =
    info "hurt with " & args        # e.g. [12.5,2]
    carryOn())                      # or stopWith("0.0"), or stopVoid()
```

`args` is a JSON array in the same shape `call` takes, so it is read with
`aowlspt/json` exactly like a request body on the server side. A reference
argument arrives as `{"handle":n,"type":"..."}` — a live object you can call
methods on, which is usually the whole reason to want the arguments.

**Those handles die when your handler returns.** The host frees them for you,
and that is not a convenience: every reference argument costs a GC handle, so a
per-frame per-bot hook whose author forgot to release one pins objects at
several per second. Expecting a mod to remember on that path is a trap rather
than a contract. Handles your handler acquired itself — from `resolve`, or from
a call that returned an object — are yours and are left alone. Do not keep an
argument handle past the end of the call; copy out what you need.

**`thisPointer(args)` is how you actually use `this`.** A handle addresses the
object through `call`, which is about a microsecond; the *address* is what
`aowlspt/fast` binds against, at tens of nanoseconds. Measured against the
stand-in in the gate run: 35 ns against 1070 for the boxed property read it
replaces (`hostharness.exe <stage> --runtime tests\mockil2cpp\GameAssembly.dll
--seconds 8`, the line `an address out of a handle costs`; re-run 2026-08-19,
where this page had 34 and 1146). The absolute numbers
move between runs; the two orders of magnitude between them do not.
`examples/lesson` re-measures both, on one object in one hook firing, in its own
process, and prints the pair — because a performance claim that is not re-checked
is a performance claim that has quietly stopped being true.

```nim
proc onTilt(target, args: string): HookResult =
  let p = thisPointer(args)
  if p != 0'u64:
    if not fTilt.ok:
      fTilt = bindField(rt, "EFT.MovementContext", "Tilt")
    info "tilt is " & $readFloat(fTilt, cast[Il2CppPtr](p))
  carryOn()
```

The same lifetime rule, and it is sharper here because an address cannot defend
itself. Asking the host for one *after* your handler has returned is refused —
`ErrDisposed`, with a sentence saying it was a patch argument — but an address
you wrote down and used next frame is just a number, and the collector has moved
the object underneath it. If you must keep an object, `pinHandle` gives you a
pinned handle whose address does not move, and pins that object until you
release it. Pin the local player; do not pin what a hook hands you.

**`hookReturn` — the postfix.** The handler runs *after* the original and is
told what it returned:

```nim
discard hookReturn("EFT.Player.FirearmController::get_AimingSensitivity",
  proc (target, payload: string): HookResult =
    let r = hookResult(payload)
    if not r.ok: return keepResult()
    replaceResult($(r.asFloat() * 0.5)))
```

This is the shape for anything that *adjusts* the game's own answer. The prefix
alternative is `stopWith`, which means reimplementing the method — and a
reimplementation of a method you cannot read is a guess. The payload is the
`hookArgs` payload with a `result` member added; `hookResult(payload)` reads it
as a `CallResult`, so `asFloat()`, `asInt()` and `asObject()` all work.
`withArgs = false` drops `this` and the arguments and keeps `result`, which is
about five times cheaper — 439 ns a call against 2326 ns, from the same gate run
(the lines `a postfix that only watches costs` and `with a postfix that reads the
arguments and replaces the result`; re-run 2026-08-19, where this page had 461
and 2249 — the ratio is unchanged at 5.3).

Two method shapes cannot carry a postfix and the host refuses them at
registration, with a sentence saying which: a return type wider than eight bytes
(returned through a buffer the host cannot read the layout of, so a postfix
could neither report nor replace it) and a compiled call needing more than four
register slots — the declared arguments, `this`, and IL2CPP's trailing
`MethodInfo*` — because the fifth is on the stack and a postfix must *call* the
original rather than jump to it. Check the status and read `lastError()`. A
prefix on the same method is unaffected. An exception thrown out of the original
does not reach a postfix handler: it means "after it returned", not "after it
finished".

`stopWith(json)` suppresses the original and hands the caller that value
instead. `stopVoid()` is the same for a method that returns nothing.
`carryOn()` lets it run.

Four things about this are worth holding on to, because each of them is a
refusal that could have been a guess:

- **An argument past the register window is named, not dropped.** Win64 passes
  four arguments in registers and the thunk saves those four; on an *instance*
  method `this` occupies the first, so **three** declared arguments fit there
  and a static method's four do. The rest arrived on the stack and the host
  cannot report their values -- but it does not fall silent about them either.
  The `args` array is always `argc` long and the slot holds

  ```json
  {"onStack":true,"type":"System.Single"}
  ```

  so argument *n* is always declared parameter *n*, and *"the host did not
  report this argument"* can never read the same as *"this argument was
  empty"*. The payload also carries `argc`, the declared parameter count, and
  `stackArgs`, how many of them are in that state -- so a handler that wants
  nothing to do with a truncated firing checks one number before it reads
  anything. This is the same rule the typed path has always held to with
  `akStack`; until now the two paths described the same method differently, and
  the JSON one did it by silently stopping early.
- **A suppression whose replacement does not match the declared return type is
  refused**, and the original runs. Skipping the method with garbage in the
  return register is the worst outcome available, so it is the one thing the
  host will not do.
- **`patchReplace` from a handler that did not ask for arguments is refused
  too.** A mod that believes it is suppressing when it is not would be debugging
  the game instead of its own registration.
- **Arguments are opt-in** because decoding them builds a JSON array inside a
  method the game may call thousands of times a frame. `hookArgs` on a per-bot,
  per-frame method is the wrong tool; `hook` is the right one.

When two mods hook the same method, every handler runs and the *first* one that
asks to stop wins. Running the rest is deliberate: two mods hooking one method
are not in a race, and one of them deciding to suppress is not a reason the
other should stop being told the method fired. Only the decision is first-wins,
because there is one original and it either runs or does not.

Some methods cannot be patched at all, and you will be told which and why:

```
the prologue of EFT.Player::Tick could not be relocated (it holds a relative
branch, or an instruction this decoder does not know)
```

That happens when the first instructions of the function cannot be safely moved
into a trampoline — see [IL2CPP.md](IL2CPP.md). A function shorter than the
14-byte jump (`AOWL_JMP_SIZE`) is refused for the same reason. Refusing is
deliberate: the alternative is overwriting whatever the linker put next.

There are **256** patch slots (`AOWL_MAX_HOOKS`, `abi/aowlspt_detour.h`), and on
the client host the main-thread drain takes one of them for itself — so 255 is
the number a mod should plan against, and the 257th patch is refused with a
message about slots rather than silently sharing one.

**This paragraph said 16, 15 and a seventeenth patch until 2026-08-19**, which
was true while every slot needed its own hand-written `aowl_thunk_N` and sixteen
of those fitted on a screen. `hostharness --churn 120` exhausting it with two
example mods is what moved it. With one common thunk a slot costs 25 bytes of
tables, so the number is now a bound against a mod stuck in an install loop
rather than a budget anybody has to plan around.

**One detour per method**, too. Two hooks on the same target — yours and another
mod's, or a prefix and a postfix you armed separately — is a refusal in whichever
arms second. That is why `examples/lesson` stages itself in its own directory
rather than into `installer\build\hoststage`, where `examples/highlevel` is
already on most of the stand-in's compiled methods, and why a refusal that looks
like a bug in your mod is often a collision in the stage.

### Reading a payload by hand

`hookResult(payload)` is the one you normally want. Underneath it and available:

| | |
|---|---|
| `memberRaw(payload, key)` | the raw JSON of one **top-level** member — `"this"`, `"args"`, `"result"` |
| `thisHandle(payload)` | the handle for `__instance`, or 0 for a static method |
| `handleIn(json)` | the handle in a `{"handle":n,"type":"..."}`, or 0 |

The payload is a flat object whose only producer is the host, so `memberRaw` is a
scanner over that shape rather than a parser: it balances braces and brackets so
a nested object comes back whole, and it only matches a key at depth 1 — a
`"result"` inside a nested object is skipped rather than mistaken for the one you
asked for. Worth the extra state, because a game string in an argument can
contain anything at all.

For the arguments themselves, `aowlspt/json` reads the payload exactly like a
request body: `asFloat(field(payload, "args[0]"), 0.0)`.

### The typed pair, for a hook on the per-frame path

`hookTyped` and `hookReturnTyped` are the same three hooks with none of the
payload. The handler is given a `PatchFrame` instead of a string — a borrowed
view of the registers the thunk already saved, plus the declared kind of every
slot, worked out once when the patch was registered:

```nim
proc onTilt(f: PatchFrame): TypedResult =
  let obj = cast[Il2CppPtr](f.selfPointer())    # `this`, straight out of RCX
  var ok = false
  let a = f.argFloat(0, ok)                     # declared parameter 0, by kind
  if not ok or obj == nil: return frameContinue()
  ...
  if f.setResultVoid(): frameReplace() else: frameContinue()

discard hookReturnTyped("EFT.MovementContext::InertiaSmoothTilt", onTilt)
```

Re-derived with `installer\build\perfbench.exe --runtime
tests\mockil2cpp\GameAssembly.dll`, median of three runs, 2026-08-19: **24.3 ns**
for a typed prefix and **38.6 ns** for a typed postfix that replaces a result,
against **643** and **1614 ns** for the same two as JSON, and **3.33 ns** for the
unpatched call.

This page carried 21.9 / 35.6 / 587 / 1483 / 3.3, and the two JSON figures had
drifted by about a tenth — enough to matter to the arithmetic in the next
paragraph, which was derived from them. [ARCHITECTURE.md](ARCHITECTURE.md)'s
copy of the same table was already at the current numbers, which is exactly why
two documents agreeing is not evidence.

**Do not reach for it by default.** JSON is self-describing, survives an argument
the host cannot classify, reads a `System.String` for you, and a 1.6 µs hook at
10 Hz is 16 µs a second — under two thousandths of one percent of the machine.
This is for the hook that fires forty times a frame, where those same numbers are
**65 µs a frame** for the JSON postfix against **1.5 µs** for the typed one:
about **1/260th** of a 60 fps frame budget against about **1/11000th** of it.

(The old wording — "59 µs a frame against 1.4 µs" — followed correctly from the
old 1483 ns and 35.6 ns above. The two fractions after it did not follow from
anything: 59 µs is not a fortieth of 16.67 ms and 1.4 µs is not a thousandth of
it, they are 1/280th and 1/12000th. Recomputed 2026-08-19. The conclusion is
unchanged and the margin is larger than it was claimed to be.)

Three things to hold on to:

- **`typedPatchesReady()` first, and check what `hookTyped` returns.** The
  test is a `size` test, so it says "there is a function here that will answer"
  rather than "this works": on the backend and on `aowlspt-sim` the entry is
  filled with a refusal (see `aowlspt_notify.h` and `aowl_hostapi_arm_sim`), so
  the test passes and `hookTyped` answers `ErrUnsupported`. On a client host
  whose detour engine came up refusing, the test itself is false. Arm the JSON form as the fallback
  and say in your log which one you got — they differ by roughly a hundredfold,
  and "armed" alone would hide that. `mods/classicmovement` is the worked
  conversion.
- **Reads are by index *and* by declared kind.** `argFloat` on a slot the
  runtime says is an integer is refused rather than reinterpreted; a
  `System.Single` sits in the low 32 bits of its XMM register and reading it as
  a double gives a number unrelated to the argument. Arguments past the fourth
  register position report as stack slots and cannot be read — named rather than
  omitted, so argument *n* is always declared parameter *n*.
- **The frame dies with your handler, and that is enforced.** Frames come from a
  fixed pool rather than the stack, so a stored one reads as cleared and
  `frameWhyText()` returns a sentence naming that exact mistake instead of
  handing you undefined behaviour.

`AOWLSPT_PATCH_ARGS` is not consulted — the arguments are in the frame either
way — and a typed prefix may always suppress, because the misregistration the
"no arguments, no suppression" rule exists to catch cannot be made. The two
postfix refusals are unchanged. [PERF.md](PERF.md) has the full table and
[ABI.md](ABI.md) the mechanism.

#### The whole frame

Everything a `PatchFrame` will answer. Every read takes an `ok: var bool` and
answers `false` rather than reinterpreting, which is the point of the whole
module: a reinterpretation answers a number.

| what it is | |
|---|---|
| `f.argCount()` | declared parameters |
| `f.kindOf(i)` | the declared kind of parameter `i` — `akInt`, `akFloat`, `akDouble`, `akObject`, `akValue`, `akBigValue`, `akVoid`, `akStack`, `akUnknown` |
| `f.retKindOf()` | the same for the return |
| `f.frameStatic()` | whether the method is static (so whether slot 0 is `this`) |
| `f.framePostfix()` | whether the original has run — a handler armed the wrong way round finds out here |
| `f.selfPointer()` | `this`, straight out of RCX. 0 on a static method or an expired frame |
| `f.argInt(i, ok)` / `f.argFloat(i, ok)` / `f.argPointer(i, ok)` | one argument, by index **and** by declared kind |
| `f.resultInt(ok)` / `f.resultFloat(ok)` / `f.resultPointer(ok)` | what the original returned; refused on a prefix frame |
| `f.setResultInt(v)` / `setResultFloat` / `setResultPointer` / `setResultVoid()` | change it — then return `frameReplace()` |
| `f.frameLive()` | whether this frame is still the one that was published |
| `f.frameSerial()` | which firing it belongs to |
| `f.frameSize()` / `expectedFrameSize()` | the host's struct against this mod's header |
| `frameWhy()` / `frameWhyText()` | why the last accessor refused, as a code and as a sentence |

`setResultVoid()` is how a **typed prefix** suppresses: it says "there is nothing
to return", and it answers `false` when the declared return is not `void` — at
which point the only honest answer is `frameContinue()`, because suppressing a
non-void method with garbage in the return register is the worst outcome
available.

Keeping a frame is the mistake this design exists to refuse, and it refuses it
out loud. `examples/lesson` makes it on purpose and prints what comes back:

```
inside the handler frameLive() was true; afterwards it is false
this patch frame belongs to a firing whose handler has already returned. A
frame is borrowed for the length of the handler and must not be stored: the
registers it views are gone, and the next firing reuses the frame. Read what
you need inside the handler, or take an address and pin it
```

## What a client mod does not get

| | |
|---|---|
| `dbGet` / `dbPatch` | server-side; returns `ErrUnsupported` |
| `route` / `serve` / `servePrefix` | server-side; returns `ErrUnsupported` |
| `notifyPush` | backend only — it pushes down the game's notifier websocket, and there is no socket in the client host. ABI revision 5; `notifyReady()` answers, and it is false on the client and in the simulator |

**Outbound HTTP is no longer on that list.** It is not `route`/`serve` -- a mod
still cannot *listen* in the client -- but it can now *ask*, through the generic
verb `aowlspt.host::http`. See "Talking to the backend, and making a sound"
below.

And one that is conditional rather than absent:

**`onMainThread` gets you Unity's main thread when the host could detour a
per-frame method, and its own thread when it could not.** There is no API that
hands a native DLL the player loop, so the host hooks something Unity runs every
frame — `EFT.MainApplication::Update` for preference, down to
`UnityEngine.Time::get_deltaTime` as a last resort — and drains the queue from
inside it. If none of them binds, it warns at boot and falls back, and a
callback that touches a Unity object from there is the crash the warning is
about. Ask outright with `call("aowlspt.host::main_thread")` rather than
assuming; the mechanism is in [IL2CPP.md](IL2CPP.md), and it has never been run
against BSG's client.

On this host `schedule` — `after` and `every` — happens to run on the same queue
and the same thread as `invoke_main`, so a delayed callback does reach the game's
thread here. **Do not build on that.** The ABI only ever promised the main thread
for `invoke_main`; the backend keeps its timers on its own thread and is within
its rights to. If you want the game's thread, say so: `onMainThread` for once,
`everyMain` for every frame. Both are in [Timers](#timers-and-talking-to-other-mods).

## Talking to the backend, and making a sound -- the generic host verbs

Two things the client host could not do at all until 2026-09-06, and that a mod
still cannot do for itself: **reach the network**, and **play audio**. Both are
now `aowlspt_nim_call` verbs, both are **flag-gated and default OFF**, and both
are deliberately **feature-agnostic** -- they know nothing about routes, schemas
or what the sound is for.

Measured, so the gap is on the record: a grep of the whole client host for
`WinHttp` / `InternetOpen` / `WinINet` / `curl` found nothing but the image-CDN
`ws2_32` redirect hook. A client mod could serve a settings page and read the
command line, and could not ask `aowlspt-backend` a single question.

### `aowlspt.host::http` -- async HTTP, off the game's thread

Args `{"id":"<your token>","method":"GET|POST","url":"http://127.0.0.1:6969/...",
"body":"...","timeoutMs":25000}`. Answers, **immediately**, either
`{"accepted":true,"id":".."}` or `{"accepted":false,"why":".."}`.

It returns on whatever thread you called it from. The request runs on a **host
worker thread** -- never Unity's main thread, never inside a detour.

The completion arrives as the mod event **`host.http.done`**:

```json
{"id":"myMod-1","status":200,"body":"...","bytes":12,"ms":41,"error":""}
```

**That event is emitted from the host's own tick loop, not from the worker.**
This matters if you are writing host code: `aowlspt_nim_event_emit` delivers
*synchronously on the emitting thread*, so emitting from a worker would run your
handler on a thread your mod has never seen, possibly concurrently with its own
ops tick, and on a thread mimalloc did not watch your mod initialise on -- the
shape that `__fastfail`s with no Unity crash report at all.

If you would rather not subscribe, poll `aowlspt.host::http_poll` with
`{"id":".."}`. **Three outcomes, not two.** `known:false` means *no such id* --
never submitted, or the result aged out after 120 s. `done:false, known:true`
means still in flight. Flattening those two is how a poller waits forever on a
typo.

Calling `http` with **no arguments** returns the state of the service --
`enabled`, `winhttp`, the allowlist, `inflight`, the caps, the counters -- so a
mod can find out whether asking is worth it instead of discovering the flag is
off one refusal at a time.

Everything it refuses, it refuses **by name**, and every cap is a **refusal, not
a truncation** -- a prefix of a JSON document is worse than no document, because
every reader rejects it as a schema error and the size never appears anywhere.

| flag | default | what it does |
|---|---|---|
| `hostHttp` | `false` | off => `{"accepted":false,"why":"flag hostHttp is off"}` |
| `hostHttpAllow` | `["127.0.0.1","localhost"]` | hosts that may be dialled; **an empty array refuses everything** |
| `hostHttpMaxInflight` | `4` | each in-flight request holds one thread in the game process |
| `hostHttpMaxBody` | `1048576` | caps **both** directions; over it, refused |

`https://` is refused by name rather than silently downgraded: the allowlist is
loopback, and TLS to `127.0.0.1` buys nothing while adding a certificate surface
inside a game process.

### `aowlspt.host::play_wav` -- a sound, and only that

Args `{"path":"<absolute path>.wav","volume":0.0-1.0}`. Answers `{"ok":true,...}`
or `{"ok":false,"why":".."}`.

**NON-SPATIAL, and `volume` is IGNORED.** Both are stated in the answer, not
only in a header. `PlaySoundW` mixes into the process's default output device:
no position, no distance falloff, no relation to the game's audio listener. The
only volume knob winmm offers without an open stream is `waveOutSetVolume`,
which moves the whole **output device** -- the game's own volume -- and leaves
it moved if we die between setting and restoring. Real per-sound volume and
position need a Unity `AudioSource` driven at byte-verified RVAs; that
groundwork is in [VOICE_RVA.md](VOICE_RVA.md).

| flag | default | what it does |
|---|---|---|
| `hostPlayWav` | `false` | off => `{"ok":false,"why":"flag hostPlayWav is off"}` |
| `hostPlayWavRoots` | `["%TEMP%","D:\\Aowlspt"]` | the path must sit under one of these (env vars expanded); a `..` anywhere is refused outright rather than resolved |

winmm decodes **PCM `.wav` only**. An mp3 or ogg is refused with that reason,
not played as a system ding -- `SND_NODEFAULT` is set precisely so a file winmm
cannot decode cannot be mistaken for success.

Both verbs are answered **above the runtime gate**, like `cmdline` and
`raid_phase`: the answer is meaningful with no IL2CPP at all. Neither touches
game memory, resolves a name, calls an RVA or installs a detour.

Tested by `python tools/test_hosthttp.py`, which compiles
`abi/aowlspt_hostnet.h` + `abi/aowlspt_playwav.h` into
`tests/hostnet/hostnet_drive.c` and drives them against a real loopback HTTP
server. It does **not** cover the Nim verb layer or the event bus -- see its
docstring, which says which half is executed and which half is only read.

## Keeping things: JSON, and a store of your own

Two facilities every non-trivial mod needs, on either side.

**Reading and editing JSON** — `aowlspt/json`:

```nim
import aowlspt/json

let name  = body.field("Info.Nickname").asText
let first = body.field("items[0]._id").asText
for it in each(body.field("items")):
  info it.field("_tpl").asText
```

It scans; it does not build a tree. A `JsonRef` is a pair of offsets into text
somebody else owns, so `field` costs one walk and no allocation.

For *editing*, take a document apart member-wise and put it back:

```nim
var d = parseObject(itemText)
setNumber(d, "StackObjectsCount", 42)
let updated = text(d)          # every field you did not touch is byte-identical
```

That is not a style preference. Rebuilding a document from a builder silently
drops every field your mod does not model, and the game's documents are full of
them. Member-wise editing keeps what it does not know about.

**More of the reader than the two lines above.** All of it costs one walk and no
allocation, and none of it builds a tree:

| | |
|---|---|
| `field(j, "a.b[0].c")` | a path. `child(j, key)` and `at(j, i)` are the single steps |
| `exists`, `isNull`, `isText`, `isObject`, `isArray` | what is there — `exists` is false for absent, which is not the same as `isNull` |
| `asText`, `asInt`, `asFloat`, `asBool` | each takes a default, so a bad read is a default rather than a crash |
| `count(j)`, `each(j)`, `keys(j)`, `members(j)` | length, elements, member names, name/value pairs |
| `raw(j)` | the bytes verbatim, for handing a subtree on untouched |

And the editing half, `Doc` and `List`: `parseObject`, `newDoc`, `has`, `get`,
`getRaw`, `setText`, `setNumber`, `setBool`, `setRaw`, `remove`, `text`;
`parseArray`, `newList`, `len`, `at`, `add`, `replaceAt`, `removeAt`, `text`.
`quoted(s)` and `escapeText(s)` are there for building a value by hand.

**A store of your own** — ABI revision 2, and it lives in `aowlspt/server`
despite the name, so a client mod importing it for `save`/`load` is doing the
expected thing:

```nim
import aowlspt/server

discard save("profile." & id, profileJson)
let stored = load("profile." & id)
for key in savedKeys("profile."):
  info key
```

`load` answers a `Stored`, and **`missing` is the field with teeth**. It is true
for "there is no such key" and false for "there is one and it could not be
read", and those want opposite reactions. A mod that keeps a player's progress
answers "nothing saved yet" by making a new one, which is right on a first run
and is the worst possible answer to "your save is on disk and the host could not
read it": it writes a new character over a file that a copy out of the store's
history would very likely have recovered. Anything that creates on a failed
`load` must check `missing` first and refuse loudly when it is false.

`saved(key)` is the cheap existence test.

One file per key, held by the host under `store/<your-guid>/`. Use it for what
your mod owns; `dbGet`/`dbPatch` is the *shared* game database and is the wrong
place for your save state. Keys are flat `[A-Za-z0-9._-]`, and an invalid key is
refused rather than mangled into a filename that might collide with another one.

Check `storeReady()` before you rely on it — a host older than revision 2 does
not have it, and finding that out from a `false` is better than from a null
function pointer. It is the host's reported `AowlHostApi.size` that answers,
because nimony will not cast a proc field to a pointer to compare it against
null.

Every host implements it, the simulator included: `aowlspt-sim` answers
`store_*` out of the same `host/common/modstore.nim` the backend does, rooted
in a scratch directory under `%TEMP%\aowlspt-sim\<mod>` (`--store DIR` moves
it). So a mod whose whole job needs persistence — `mods/tarkov` — can be run
and tested with no server and no game, which it could not while the simulator
was C# and stopped at revision 1.

## Timers, and talking to other mods

```nim
discard on("someone.else.event", proc (payload: string): string =
  info "heard it"
  "")

discard emit("my.mod.event", "{\"id\":\"...\"}")
```

Delivered synchronously, in subscription order, to everyone **but** the emitter —
a mod that owns an event usually subscribes to it too, and delivering it back
would be a loop nobody wrote. Every host implements this, which is what the mod
manager's control protocol is built on — see
[MODMANAGER.md](MODMANAGER.md), and note that "synchronously" is exactly why a
host queues a control request instead of unloading a mod inside the emit.

`aowlspt/server` spells the same three as `onEvent`, `broadcast`, `afterMs` and
`everyMs`, which is what a server mod already importing that module will reach
for; they are the same calls.

`after(delayMs, handler)` runs something once, later; `every(intervalMs,
handler)` runs it repeatedly. A repeating timer re-arms itself with the same
cookie rather than registering a new handler per firing — the alternative leaks
one entry per tick, which only shows up in a server left running for a week.

`onMainThread(handler)` runs one callback on the host's main thread, which is
how a mod touches Unity from a worker. All three take a slot in the scheduler's
table and **give it back once they have fired**, so queueing work every frame --
the documented way to reach Unity's thread -- costs one slot at a time rather
than one per frame. `scheduledSlots()` reports the size of that table if you
want to prove that of your own mod; `examples/highlevel` does exactly that.

### `everyMain` — a repeat on the game's thread

`everyMain(handler)` runs the handler **once per drain** on the thread the host
drains its main-thread queue on — which on a host whose drain is per-frame is
once per frame. `stopMainRepeats()` stops every chain this mod started and
returns how many it stopped.

```nim
discard everyMain(proc (payload: string): string =
  sampleTheFrame()
  "")
...
discard stopMainRepeats()
```

**The distinction against `every` is not the one that has been written down.**
The version in circulation — `docs/BACKLOG.md` and `mods/perf/README.md` still
carry it — is that "`every` repeats on the host's thread; `onMainThread` reaches
Unity's and does not repeat." On the IL2CPP client host the first half is false:
`hostSchedule` and `hostInvokeMain` share one queue and one thread there, so
`every(16, ...)` does already land on the game's thread. This page's own version
of the mistake was quieter — it said `after` and `every` share the queue with
`invoke_main` and left that sounding like a property of the ABI. Two real
differences survive, and they are the reasons `everyMain` exists:

* **A deadline is not a frame.** `every(16, ...)` fires when 16 ms have elapsed.
  At 144 fps that is every third frame; at 30 fps it is once a frame and
  drifting. Neither is "once per frame", which is what a mod sampling frame
  times or writing a value the game reads every frame actually needs.
* **The ABI only ever promised the main thread for `invoke_main`.** That the two
  queues coincide is one host's implementation detail. The backend's `every`
  already runs on the backend's own timer. A mod that reaches Unity through
  `every` is relying on something nothing owes it.

**It holds one slot, not one per firing.** The re-arm reuses the same cookie and
the same scheduler slot, exactly as `every` does. The hand-written version — a
one-shot that calls `onMainThread` again before it returns, which is what
`mods/perf` carried for a long time — claims a slot per firing and releases it at
the end of the same firing. Correct, but it churns the pool and leaves
`scheduledSlots()` unable to tell a working chain from a leaking one.

**It does not spin inside one frame**, because the host's `takeDue` takes the
due callbacks out of its queue under a lock and `runDue` runs them *outside* it:
a callback queued from inside a firing lands after the snapshot the current
drain is walking, and is picked up by the next drain. That is a property of the
host, and `everyMain` is the single place that depends on it instead of every
mod that wants a frame. (This named `drainDue`, which still exists and still
calls both; the snapshot moved into `takeDue` when the pair was split, and the
property is unchanged. What the drain itself costs per frame is measured in
[PERF.md](PERF.md), "What the host costs per frame" — read it there rather than
from a figure copied into this page.)

**The stop is deferred by exactly one firing, on purpose.** `stopMainRepeats`
clears the marker; the firing already queued runs one more time and then releases
its slot instead of re-arming. That is the correct behaviour rather than a
limitation — the chain is queued on the game's thread and the stop is usually
called from another one, and yanking the slot out from under a callback that is
about to run is the one way a stop could turn into a crash. Assert for one
further firing, not for zero.

`everyMain` refuses on a host with no main thread to reach: the status is the
host's own answer to the first queue attempt, so a server-side mod is told
`ErrUnsupported` rather than left with a handler that never fires.

### `currentThreadId()` — checking where a callback ran

```nim
import aowlspt/fast

let t = currentThreadId()      # Windows' thread id, as an int64
```

For a mod that wants to check *where* a callback ran rather than merely that it
ran. Touching a Unity object from a worker thread does not fail: it usually
works, until the frame it does not, and the crash is nowhere near the call.
Comparing this id between `onLoad` and a firing is how "this reached the game's
thread" becomes a claim instead of a hope. `examples/lesson` prints both ids in
section 5, and the harness's `everyMain` verdict is that comparison made against
the runtime's own frame-loop thread.

## One lock, for your own state — `aowlspt/sync`

A mod's globals are not touched by one thread, and nothing in the ABI was
guarding them. The backend serves requests on sixteen workers, so two route
handlers in the same mod run at once; the client host calls `on_update` on its
own thread while a detour fires on the game's; a timer or an event subscriber may
arrive on either. Anything a mod keeps between calls — a resolved selection, a
cache, a counter — is shared mutable state.

That is not hypothetical. Two concurrent `/toggle` requests to the mod manager
mutate its registry with no exclusion at all, and two concurrent purchases
against one profile silently lost updates until the backend grew per-session
serialisation. The server can only serialise what it can *see* — a session id —
and it cannot know which of a mod's globals a route touches.

```nim
import aowlspt/sync

withModLock:
  gCache.add s
```

`lockMod()` / `unlockMod()` are the same thing with the chance of forgetting the
second line.

**It needs no ABI call and no host support.** `abi/aowlspt_lock.h` is a
one-time-initialised `CRITICAL_SECTION` whose contents are `static`, and nimony
emits one translation unit per module — so the lock belongs to *that module in
your library*. Every mod that links `aowlspt` gets exactly one of its own, and
two mods can never contend with each other. It is not the host's lock: the host's
guards the host's lists, and the host has never heard of this one.

Hold it for the shortest span that keeps the state consistent, and **never across
a call that can block** — an HTTP fetch, a sleep, a route that waits on something
else. It is not reentrant: taking it twice on one thread deadlocks. Windows'
`CRITICAL_SECTION` is in fact recursive, so that happens to work today; do not
rely on it, because the guarantee is the one written down.

**Not inside a hook handler on the per-frame path.** A lock in a method the game
calls forty times a frame is a contention point in the game's own thread. State
touched only from a detour is written by exactly one thread and wants no lock at
all.

## Surviving a rebuild

```nim
proc stateSave(): string = "{\"runs\":" & $gRuns & "}"

proc stateLoad(state: string): Status =
  gRuns = asInt(field(state, "runs"), gRuns)
  Ok

exportMod(..., stateSave = stateSave, stateLoad = stateLoad,
          flags = {mfHotReloadable})
```

`stateSave` runs just before the library is freed and `stateLoad` on the next
incarnation, so rebuilding a mod mid-session does not visibly reset it.
`mfHotReloadable` is what tells the host both exist; `mfThreadSafe` is the other
flag, and it declares that your callbacks are safe off the main thread.

Try it with `aowlspt-sim examples/lesson --watch --ticks 0` and rebuild the mod
in another window; the simulator is the only host that reloads on a file change.

The state is a string and it crosses a `FreeLibrary`. Keep it small, keep it
JSON, and **do not put a pointer, a handle or a binding in it**: every one of
those names something in the address space that is about to stop existing.

`onUnload` is the other half and it is not for unregistering. Everything a mod
registered is a function pointer into its library — a route, a subscription, a
timer, a detour — and the *host* drops all of them after `on_unload` returns and
before it frees the library; `unloadOne` refuses outright when no teardown has
been registered. So `onUnload` is for putting the game back the way you found it,
and for saying what happened. **Do not queue work onto the main thread from there
and return**: the teardown removes the queued callback before it ever runs, and
the log line saying "queued a restore" would be the only trace that nothing
happened.

## Per-frame code

`aowlspt/game` is the pleasant API and it is also the general one, which is why
it costs about a microsecond a call. If you are doing something once per frame
per entity, that is the wrong budget, and `aowlspt/fast` is the other shape: bind
a method or a field once, then call through the binding.

```nim
import aowlspt/il2cpp
import aowlspt/fast

var rt: Il2Cpp
var bWorld, bMainPlayer: Binding
var fHealth: FieldBinding

proc bindOnce(): bool =
  ## From onUpdate, on the first frame the type resolves -- never from onLoad,
  ## and never as a global initialiser.
  rt = openIl2Cpp()
  if not rt.loaded: return false
  bWorld = bindMethod(rt, "EFT.GameWorld", "get_Instance", 0)
  if not bWorld.ok:
    warn bWorld.why
    return false
  bMainPlayer = bindMethod(rt, "EFT.GameWorld", "get_MainPlayer", 0)
  fHealth = bindField(rt, "EFT.Player", "Health")
  result = bMainPlayer.ok and fHealth.ok

proc perFrame() =
  var a = noArgs()
  let w = callPtr(bWorld, nullPtr(), a)
  if w == nil: return
  a.reset()
  let player = callPtr(bMainPlayer, w, a)
  if player == nil: return
  let hp = readFloat(fHealth, player)      # a load from player + offset
  writeFloat(fHealth, player, hp + 1.0)
```

A bound call is 6.0–10.2 ns and a bound field read 1.87 ns, against 956–1217 ns
for the boxed path (re-derived 2026-08-19, median of three runs; this page had
6–10, 1.7 and 940–1110) — re-derived on this machine with

```
installer\build\perfbench.exe --runtime tests\mockil2cpp\GameAssembly.dll
```

(msys2 ucrt64 gcc 15.2.0; the spread on the bound call is void/1-float/2-int, the
boxed one is class-in-hand/resolved-by-name). `openIl2Cpp()` binds the already-loaded
`GameAssembly.dll` directly, so the host is not on this path at all — a mod DLL
is in the same process as the runtime.

Three rules, none of them negotiable, all of them in
`aowl/src/aowlspt/fast.nim`:

1. **Bind from inside a proc, never as a global initialiser** — the zeroed-global
   trap again. A zeroed `Binding` has `ok = false`, so it fails safe; it also
   never becomes true.
2. **A bound call takes a raw pointer, not a `Handle`.** Resolve it fresh each
   frame, as above, and do not store it. The collector moves objects.
3. **A binding that cannot express a signature refuses**, with a `why` that names
   it: a `double` argument, a `Vector3`, a fifth argument, a generic
   instantiation, an array. Log the `why` once. A refused binding is a mod that
   quietly does nothing otherwise.

   **An enum is no longer on that list.** An enum passes as its underlying
   integer, nothing in the C API names which one, and guessing `Int32` is wrong
   for the `long` enums that exist — so it used to be refused. The width is not a
   guess: it is the runtime's instance size minus the object header, and the
   header is *measured* rather than assumed (`boxHeaderBytes`, calibrated on
   `System.Int32` whose payload is four bytes by definition and cross-checked
   against `System.Double`). So an enum, and any other value type small enough to
   travel in a register, binds. A value type too wide for one is still refused,
   and must be: Win64 passes it by hidden pointer, which is a different call
   *shape* rather than a different register.
4. **Check one call against a value you can predict before trusting the
   binding.** Inference reads the runtime's own metadata, and the failure it can
   have is the quiet one — an argument in the wrong register file, or a result
   read out of the wrong one, answers a plausible number. `examples/lesson` calls
   a method whose answer it knows immediately after binding it and prints the
   binding's `why` beside the result when they disagree; `bindMethodAs` is where
   you go when they do.

### The call and read surface

```nim
var a = noArgs()          # or argsI(1), argsF(2.5), argsP(p), argsII(1,2), argsFF(1.0,2.0)
addInt(a, 7); addFloat(a, 2.5); addBool(a, true); addPtr(a, obj)
a.reset()                 # reuse rather than rebuild, on a per-frame path
```

`MaxArgs` is 4 and `MaxSlots` is 5 — `this` plus four arguments, which is what
Win64 puts in registers before it starts using the stack.

| call it | read a field | write a field |
|---|---|---|
| `callVoid(b, self, a)` | `readInt(f, obj)` | `writeInt(f, obj, v)` |
| `callInt(b, self, a)` → `int64` | `readInt32(f, obj)` | `writeFloat(f, obj, v)` |
| `callInt32(b, self, a)` | `readBool(f, obj)` | `writeBool(f, obj, v)` |
| `callBool(b, self, a)` | `readFloat(f, obj)` | `writePtr(f, obj, v)` |
| `callFloat(b, self, a)` → `float` | `readPtr(f, obj)` | `writePtrRaw(f, obj, v)` |
| `callPtr(b, self, a)` → `Il2CppPtr` | | |

`self` is `nullPtr()` for a static. An enum field reads as a plain number through
`readInt`, at the width the runtime reports for it.

**`writePtr` goes through the collector's write barrier.** IL2CPP has to be told
when one object starts referring to another; `il2cpp_gc_wbarrier_set_field` is
what tells it, and storing the pointer directly instead can get a young object
collected while an old one still references it. The crash then arrives at the
next collection, far from the write, with nothing on the stack connecting the
two — the worst failure shape this module can produce, which is why it is the
default rather than the option. It used to be the plain store, documented as a
hazard the caller should reason about; a documented hazard is still a hazard.

`barrierReady(f)` says whether this binding found the runtime's barrier entry at
bind time. On a runtime that exports none, `writePtr` still stores — unbarriered,
because the alternative is a field that silently does not get written — and
`barrierReady` is how you find out which you are getting.

`writePtrRaw(f, obj, v)` is the deliberate opt-out, for the one case that is
genuinely safe: writing back a pointer the object already reachably holds —
clearing a field to nil, or restoring a value read out of the same object a
moment ago. Nothing in this repository needs it.

### Static fields — `bindStaticField`

```nim
var fSpawn: StaticFieldBinding
fSpawn = bindStaticField(rt, "EFT.Player", "SpawnCount")
let n = readInt(fSpawn)              # no object argument
writeInt(fSpawn, n + 1)
```

`bindField` binds an **instance** field and refuses a static one by name;
`bindStaticField` binds a static one and refuses an instance one. They produce
**different types**, and the static readers and writers **take no object at
all** — `readInt(f)`, not `readInt(f, obj)`.

That is the design, not a convenience. A static field's offset is into the
class's static data block; an instance field's is into the object, and **the two
ranges overlap completely**, because neither number knows about the other. In
`tests/mockil2cpp`, `EFT.Player::SpawnCount` (static `Int32`) and
`EFT.Player::Health` (instance `Single`) are both at offset 16 — deliberately
there, but only because that is what independent numbering does anyway.

So the failure mode of confusing them is not a crash and not a refusal: it is a
number. An instance read of a static field's offset reads a `float`'s bits as an
integer and hands back something like `1091567616` — that is a health of 9.0;
`examples/lesson` catches it at 100.0 and prints `1120403456` — with `ok` true,
and a mod acts on it. A `bool` flag on one shared type could not have prevented
that, because the wrong flag reads exactly like the right one. Two types means
the **compiler** refuses, at every call site, for nothing.

**Staticness is asked of the runtime** (`il2cpp_field_get_flags`), never inferred
from the offset — inferring it is precisely the thing the overlapping ranges make
impossible. A runtime that does not export the flag is refused rather than
guessed at, and so is one that does not export
`il2cpp_class_get_static_field_data`, since adding an offset to a null block is
how a mod reads address 16. `bindStaticField` also runs
`il2cpp_runtime_class_init` before reading the block, because a field that is
zero *because nothing has initialised it yet* is otherwise indistinguishable from
one that is zero.

The readers and writers mirror the instance ones with the object dropped:
`readInt(f)`, `readInt32(f)`, `readBool(f)`, `readFloat(f)`, `readPtr(f)`,
`writeInt(f, v)`, `writeBool(f, v)`, `writeFloat(f, v)` — and **`writePtrRaw(f,
v)`, which is the only pointer store a static field gets.**
`il2cpp_gc_wbarrier_set_field` wants the *owning object*, so the collector can
mark that object's card. A static field has no owner: the storage is a GC root in
its own right, scanned on every collection rather than reached through an owner.
Passing the static block where an object header is expected is not a conservative
choice, it is a wrong pointer handed to the collector. So there is no barriered
form to reach for and the name does not let you believe there was one.

The address of the static block is asked for once, at bind time, and does not
move for the life of the class — so a static read is the same single load an
instance read is, from a base that is a constant instead of an object.
`examples/lesson` times both side by side (both 1 ns on this machine) and prints
them, because the reason for two types was never the cost.

### Asking what a type is

```nim
classifyType(rt, "System.Single")   # by qualified name
classifyDeclared(rt, someIl2CppType)  # from the declared type itself
classifyClass(rt, someClass)
describe(fkF32)                    # "a float", for a log line
```

`FastKind` is `fkNone, fkVoid, fkBool, fkI32, fkI64, fkF32, fkF64, fkPtr` —
the register class of one slot, which is all Win64 cares about. `fkPtr` is every
reference type; `fkNone` is "this module will not classify it", which is a
refusal rather than a kind. Prefer `classifyDeclared` wherever the type itself is
in hand: it works on a generic instantiation, an array or a nested type, where
the printed name is not always a name `findClass` accepts.

**`classifyType` no longer answers `fkPtr` for everything it can resolve.** An
unconditional `result = fkPtr` used to stand at the end of it, which made every
resolvable non-primitive a reference — and silently disarmed the
`classifyType(...) == fkNone` gate that `mods/classicmovement` and `mods/fov` use
to refuse a value type too wide for a register. It now hands the class to
`classifyClass`, `fkNone` and all. Two other things follow from that same
routine: a value type is checked *by name* before it is measured by width, so
`System.Single`, `System.Double` and `System.Boolean` are not mistaken for
integers of the same width (a `float` bound as `fkI32` travels in RCX instead of
XMM0 and `Boost(4.0)` answers `0.0` rather than `24.0`); and
`classifyDeclared` answers `fkNone`, not `fkPtr`, when the runtime can name no
class for a type. Both of those are `bindMethod`'s inference, so a `float` or
`bool` parameter now infers correctly rather than needing `bindMethodAs`.

### Binding against the object, not the name

**A bound call is non-virtual by construction.** It jumps to a compiled body. So
a binding taken by name against `EFT.Player` calls `EFT.Player`'s implementation
even when the object in your hand is a bot subclass that overrides it — and it
does so silently, returning a plausible number.

```nim
let b = bindOnObject(rt, player, "Move", [fkF32], fkVoid)
```

`bindOnObject` binds against the class the object actually is, walking its base
chain until it finds the method. `bindInClass` is the same for a class you
already hold. Between them they are also the only way to reach a **generic
instantiation** such as `List<Player>`: it has no name `findClass` accepts, but
any instance of one can hand its class over.

Use `bindMethod` when you are calling a static or a method nothing overrides.
Use `bindOnObject` the moment a subclass is possible.

### Stating the call shape outright

`bindMethod` infers register classes from the declared signature and refuses
what it cannot classify. `bindMethodAs` lets you assert those classes. Neither
can express a method whose *native shape* differs from its signature — and on
Win64 the two most wanted methods in this game are exactly those.

A `Vector3` is twelve bytes. Win64 passes anything larger than eight bytes and
not a power of two **by hidden pointer**, and returns it the same way. So

```
Vector3 Player::get_Position()        is really
void*   get_Position(void* sret, void* this, MethodInfo*)
```

Every slot there is a plain pointer, which the trampolines already pass.
`bindRaw` is how you say "this method has two pointer slots" when its signature
says it takes no arguments, and `ShapedArgs` + `callShapedPtr` /
`callShapedVoid` / `callShapedFloat` fill and make the call:

```nim
let cls = findClass(rt, "EFT.Player")
# get_Position takes 0 declared arguments and 2 native slots: the hidden
# return pointer, then `this`. No slot is a float, so the mask is 0.
let pos = bindRaw(rt, cls, "EFT.Player", "get_Position", 0, 2, 0'u32, fkPtr)
if pos.ok:
  var out3: array[3, float32] = [0.0'f32, 0.0'f32, 0.0'f32]
  var s = shaped()
  addSlotPtr(s, cast[Il2CppPtr](addr out3[0]))   # sret
  addSlotPtr(s, player)                          # this
  discard callShapedPtr(pos, s)                  # out3 now holds x, y, z
```

This is the sharpest tool in the module and it is the last resort, not the
first. **You are asserting a calling convention.** A wrong slot count reads an
uninitialised register as an argument — a plausible number rather than a crash,
which is the failure mode with the longest time-to-diagnosis available. Every
use of it should carry a comment saying why the shape is what it claims. It
exists because the alternative is the reflective path, which costs about a
hundred times as much and allocates a managed object per call, on something that
runs per bot per frame.

### Measuring it

`perfCounter()`, `perfFreq()` and `nanosBetween(a, b)` come from
`aowlspt/fast` — the same clock the bindings report their own cost on, and the
right resolution for a hot loop where `nowMs()` is off by three orders of
magnitude. `Binding.bindNs`, `FieldBinding.bindNs` and
`StaticFieldBinding.bindNs` carry what each binding itself cost, so the one-off
price is in the log beside the `why`. `currentThreadId()` is in the same module
and answers the other question a per-frame mod has — not how long it took, but
which thread it ran on.

For the other claim — that a path allocates nothing — there are four more:

| | |
|---|---|
| `allocationCount()` | blocks this binary's allocator has **ever** handed out, or -1 |
| `allocatedBytes()` | the same in bytes |
| `liveBytes()` | what it is holding right now |
| `allocProbeOk()` | whether those counters are actually reading the allocator |

`allocationCount` is monotone — a free does not lower it — and that is the whole
reason it can prove anything: take it, run a loop, take it again, and an
unchanged number means the loop allocated **nothing at all** rather than nothing
net. A live-bytes figure cannot say that, because a string built and freed once
per firing leaves it exactly where it was; `liveBytes` is the one to watch over
time instead, since a heap the same size after ten thousand cycles as after ten
is a heap nothing is accumulating in.

`allocProbeOk()` is not optional politeness. A build where the counters are
compiled out reports a constant, and a constant is indistinguishable from "your
loop allocated nothing" — the one answer this must never give by accident. The
first version of it read a figure only maintained in a debug build and reported a
confident zero for a loop allocating at frame rate. If the probe is false, say so
and do not make the claim. `examples/lesson` prints
`2000 typed firings allocated 0 blocks in this mod` and says why 0 means what it
means.

The counters are **per binary**, because the allocator is: a mod DLL and the host
DLL each link their own. That is the shape of the question rather than a
limitation — "does the mod side allocate" and "does the host side allocate" are
two claims, and the host answers its own through
`call("aowlspt.host::patch_stats")`. They used to be `importc`/`nodecl` declarations against a header only
`fast.nim` itself included, so calling them from an importing mod produced an
implicit-declaration error out of the C compiler rather than anything nimony
could explain. Two mods gave up and used milliseconds. They are ordinary procs
now.

### Worked examples

`examples/lesson` is the guided one: it binds a static method, an object-bound
instance method, an enum parameter, two instance fields, a reference field it
writes through the barrier and back with `writePtrRaw`, two static fields, and
one shaped `Vector3` return; it refuses one binding on purpose so the `why` is in
the log, shows `bindField` and `bindStaticField` each refusing the other's field
at the same offset, prints the plausible integer the confusion would have
produced, and prints what each binding cost. Section 5 does the same for
`everyMain`, `stopMainRepeats` and `currentThreadId`.

`mods/classicmovement` binds a four-step chain and checks every signature
against the runtime's own metadata before hooking anything, falling back to a
property getter where a field is a property on some builds. `mods/fov` is a
Harmony-shaped port that uses live objects, private fields, `hookArgs` +
`stopWith`, and the fast path for the per-frame write; `mods/sway` pushes five
summed sway sources into the game's rotation springs every frame. Each module
comment states exactly what its port does and does not do, and those comments
are the accurate source.

The numbers, how they were measured and what they do not prove are in
[PERF.md](PERF.md). Read it before porting anything for speed: a naive native
port that stays on the boxed path loses to the C# it replaced.

## Testing without the game

```
aowl test
```

builds a stand-in IL2CPP runtime (`tests/mockil2cpp`) that exports the same C
API as `GameAssembly.dll`, loads the host against it, and runs
`examples/highlevel` through resolve, call-with-arguments, live objects, fields
and patching:

```
ok    the host booted and reached its tick loop
ok    a mod was loaded through the ABI
ok    the host bound the runtime and attached a thread
ok    4 types resolved by name through the runtime
ok    a method was invoked and its string return marshalled back
ok    arguments were bound by declared type and came back correct
ok    a compiled method was detoured and the patch fired
ok    a live object was reached and an instance call changed it
ok    a field was read by declared type and agreed with its property
```

That is a subset; the harness makes **twenty-four** verdicts and prints them all,
including the main-thread handoff, the three enum checks, the write barrier, the
four static-field checks and the `everyMain` pair. What each one greps for is
`checkLog` in `tools/hostharness.nim`, and the mod whose log it greps is
`examples/highlevel` — fifteen of the twenty-four are satisfied only by lines
that file prints, and three more by lines it shares with `examples/clientprobe`.
That is why it is not the file to copy from and not the file to edit.

Count it yourself rather than trusting this paragraph:

```
installer\build\hostharness.exe installer\build\hoststage ^
    --runtime tests\mockil2cpp\GameAssembly.dll --seconds 8
```

and count the `ok`/`error` lines **under `Result`**, which is the whole of the
instruction. A bare `grep -c '^ok'` over that output answers **27**, and the
three extra are not verdicts about the host at all: `loaded, not yet started`
under "Mock runtime", and `host loaded; the constructor should have started its
thread` and `mock runtime started; the host should pick it up on its next poll`
under "Loading". They are the harness reporting that its own staging worked,
before it has read a line of the host's log. Twenty-seven has been miscounted
this way once already, on 2026-08-19, and read as three assertions having just
landed; they had not.

Stage it with the **current** builds, too. A stage carrying an older
`aowlspt-host-il2cpp.dll` fails at `the host never reached 'host running'`,
which reads as a broken host and is a stale copy.

The field check is stronger than it looks: it passes only when the field and the
property getter for the same storage *agree*. Either alone can be plausibly
wrong; agreeing is what makes the offset right rather than lucky.

**A caveat that used to live here has gone.** This page said that on msys2 ucrt64
gcc 15.2 the stand-in's `Tick` and `Hurt` compile to prologues the detour engine
refuses to relocate, so `a compiled method was detoured and the patch fired` came
out as `error no patch fired` and the gate went red. On msys2 ucrt64 gcc 15.2.0
today, with `GameAssembly.dll` rebuilt from `mockil2cpp.c` by that compiler, all
twenty-four verdicts are green and that one is among them. If it goes red on your
toolchain it is still a stand-in and toolchain artefact rather than a hole in the
detour engine — but it is no longer the expected outcome, so treat it as
something to look into rather than as something already known about.

To iterate on a mod against the stand-in, **stage it in a directory of its
own**. A stage is a host DLL, an optional `aowlspt-host.json`, and
`mods/<name>/<name>.dll`:

```
aowl build-mod examples/lesson
mkdir installer\build\lessonstage\mods\lesson
copy host\Aowlspt.Host.Il2Cpp\bin\aowlspt-host-il2cpp.dll installer\build\lessonstage
copy examples\lesson\bin\lesson.dll     installer\build\lessonstage\mods\lesson
copy examples\lesson\config.json       installer\build\lessonstage\mods\lesson
installer\build\hostharness.exe installer\build\lessonstage ^
    --runtime tests\mockil2cpp\GameAssembly.dll --seconds 8
```

Not `installer\build\hoststage`: the detour engine allows one hook per method,
`hoststage` already holds `examples/highlevel` on most of the stand-in's compiled
methods, and a collision there is refused in whichever mod arms second — which
reads as a bug in your mod rather than as a crowded stage. `installer\build\churnstage`
exists for the same reason.

The simulator is the faster loop for everything that does not need a runtime:

```
aowl run examples/lesson
aowlspt-sim examples/lesson --emit lesson.ping,{"n":1}
aowlspt-sim examples/lesson --watch --ticks 0
```

Add types and methods to `mockil2cpp.c` as you need them. It is a few hundred
lines and deliberately shaped like the type universe a real mod meets — including
a pair of methods written with the signature a *compiled* IL2CPP method has,
because that is the one the detour path sees.

None of this establishes that BSG's client behaves the same way. It exports the
same C API and that is what is being exercised; the last step is still to launch
and read `aowlspt/aowlspt-host.log`.
