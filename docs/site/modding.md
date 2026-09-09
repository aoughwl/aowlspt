# For mod authors

Mods are written in [nimony](https://github.com/nim-lang/nimony) and compile to
a native DLL. The same compiled mod runs on every host: the client host inside
Tarkov, the backend, and `aowlspt-sim`, which runs a mod with no game and no
server behind it so you can debug without launching anything.

## A whole mod

```nim
import aowlspt
import aowlspt/game

var Player = gameType("EFT.Player")
var world = whenReady("EFT.GameWorld")

proc onUpdate(elapsedMs: int64): Status =
  if world.ready():                      # true once, when the game exists
    info "health " & $Player.get("Health").asFloat()
    discard Player.invoke("Heal", 50)

    discard hookArgs("EFT.Player::ApplyDamage",
      proc (target, args: string): HookResult =
        info "damage: " & args           # the arguments the game passed
        stopWith("0.0"))                 # and the original never runs
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient}, onUpdate = onUpdate)
```

Build it:

```
aowl doctor                     # once, before anything else
aowl build-mod examples/lesson
```

`aowl doctor` checks the toolchain, and every check in it is there because
something went wrong once and pointed somewhere else when it did. The one worth
knowing about is **PATH order**: gcc finds `cc1` relative to PATH, so a
Git-for-Windows `mingw64` ahead of msys2's `ucrt64` gives you a `cc1` that loads
the wrong libgcc and dies with no message at all.

`examples/lesson` is the worked version of the whole API, in order, each section
saying why it is shaped the way it is. That is the sample to copy from.

## The ABI

One narrow C ABI (`abi/aowlspt_abi.h`) that both sides know and neither side's
language leaks through. It is small on purpose and it names **no** game or
server types: the database is addressed by dotted path and the game is reached
by string target. What churns underneath is data, not a header — which is why a
mod does not break every time a type is renamed upstream.

Beside the general reflection path there is a **fast path** — bind once, then
call — for anything that runs per frame.

## Server routes

```nim
proc onKeepAlive(url, body, session: string): string =
  var o = obj()
  put(o, "msg", "OK")
  put(o, "utc_time", nowSeconds())
  result = envelope(o)

discard serve("/client/game/keepalive", onKeepAlive)
```

`envelope` is not optional for `/client/*`. Every such endpoint answers
`{"err":0,"errmsg":null,"data":...}`, and the client reads `err` before it looks
at anything else. A route returning bare data gets a client that treats a
perfectly good response as a failure, with a 200 on both sides and nothing in
either log.

`aowlspt/json` reads and edits a document without rebuilding it — `field`,
`each`, `count`, `arr`, `objOf`, `envelope`, `failure`, and member-wise editing
of a `Doc`, so a profile keeps fields your mod does not model.

Other facilities worth knowing: `save` / `load` / `savedKeys` for a persistent
per-mod store; `broadcast` / `onEvent` for mod-to-mod events; `everyMs` for work
that must happen whether or not a request arrives; `dbWrite`, which creates a
path rather than refusing when your mod adds a table the database has never
held.

## Settings

Declare your settings and they appear in the [F12 overlay](settings.md),
persist to your `config.json`, and apply live.

```nim
import aowlspt/settings

declareSettings(@[
  boolSetting("enabled", "Enabled", default = true,
              category = "General",
              description = "Turn the whole thing off."),
  floatSetting("strength", "Strength", default = 1.0,
               min = 0.0, max = 2.0, step = 0.05,
               category = "Tuning"),
  enumSetting("preset", "Preset", default = "neutral",
              options = @["neutral", "filmic", "night-owl"]),
  keybindSetting("toggleKey", "Toggle key", default = 114),
])

discard serve("/aowlspt/settings/" & ModGuid, settingsHandler)
```

Control kinds: `stBool`, `stInt`, `stFloat`, `stEnum`, `stString`, `stKeybind`,
and `stSelect` for an enumeration too large to draw as a dropdown — a
`selectSetting` may ship its choices inline or name an `optionsUrl` the UI
queries as the user types, which is what makes "pick one of several thousand
item ids" a declarable setting rather than a bespoke screen.

Every row carries `category` and one level of `subcategory`, so a large mod
draws as nested pages rather than one long list.

**Declare `implemented = false` for anything you carry but do not yet act on.**
The overlay draws it greyed and marked. See
[the honesty convention](settings.md#the-honesty-convention) — a setting that
looks live and does nothing is the worst thing you can ship.

The wire is plain:

```
GET  /aowlspt/settings/index        every mod that has settings
GET  /aowlspt/settings/<guid>       one mod's schema, with current values
POST /aowlspt/settings/<guid>       {"key":"...","value":<literal>}
```

## Capabilities: calling another mod

A capability is a named, versioned function one mod publishes and another calls.

```nim
import aowlspt/capability

proc spawn(request: string): CapReply =
  if not strictObject(request): return capFail("the request is not an object")
  capOk("""{"ok":true,"spawned":3}""")

proc onLoad(): Status =
  provide("items.spawn", 1, spawn)
```

Then add the name to your `provides` array in `registry/mods.json`, versioned
(`"items.spawn/1"`) or bare. That does not make the call work — it makes a
consumer's refusal say *"aowl.tarkov declares it and the selection does not load
it"* instead of *"not installed"*.

Calling one:

```nim
let r = invoke("items.spawn", 1, requestJson)
if r.isOk: useIt(r.body)
else:      showThePlayer(r.message)   # always populated, always specific
```

A handler whose body is not strictly valid JSON is refused **at the provider**
and reported as an error. It is never forwarded as a success.

### Refusal taxonomy

| outcome | means | who can fix it |
|---|---|---|
| `coOk` | a provider ran and its payload validated | — |
| `coProviderError` | a provider ran and said no; `message` is its words | the provider |
| `coVersionMismatch` | that name answers, at other versions | whoever picks the version |
| `coProviderNotLoaded` | the registry declares it; your selection does not load it | the player, in the mod manager |
| `coProviderSilent` | loaded, and nothing answered. **INCONCLUSIVE** | the provider's author |
| `coNoProvider` | nothing answers and nothing installed declares it | the player, by installing it |

`describe(r)` gives one line for a diagnostic block, and it says
**INCONCLUSIVE** for the two outcomes that are inconclusive rather than
flattening them into a failure.

## The rule the whole project runs on

Three outcomes, never two: **PASS / FAIL / INCONCLUSIVE**. "I could not look" is
not a pass. Assert a property of the finished state, never of your own write —
prefer the negative, because a negative can be falsified and a self-comparison
cannot. If you cannot describe the input that would make your check fail, you
have not written a check.
