# Mod-to-mod capabilities

`aowl/src/aowlspt/capability.nim`. Server side. The module header carries the
design reasoning; this file is the user manual and the migration notes.

## Publishing one

```nim
import aowlspt
import aowlspt/capability

proc spawn(request: string): CapReply =
  if not strictObject(request): return capFail("the request is not an object")
  ...
  capOk("""{"ok":true,"spawned":3}""")

proc onLoad(): Status =
  provide("items.spawn", 1, spawn)
```

Three things, and only the first is enforced by code:

1. `provide(name, version, handler)`. From `onLoad` or any later point, on any
   thread.
2. Add the name to your `provides` array in `registry/mods.json`, versioned
   (`"items.spawn/1"`) or bare. This does **not** make the call work — it makes
   a consumer's refusal say *"aowl.tarkov declares it and the selection does
   not load it"* instead of *"not installed"*. That distinction is the reason
   the module exists; a stale selection override once disabled two mods for
   days while the roster still called them "enabled".
3. Document the request and response JSON next to the `provide` call. Bump the
   version for any incompatible change and keep the old version registered for
   as long as you mean to support it — `provide` takes both.

A handler that returns a body which is not strictly valid JSON is refused **at
the provider**, logged at `llError`, and reported to the consumer as
`coProviderError`. It is never forwarded as a success.

## Calling one

```nim
let r = invoke("items.spawn", 1, requestJson)
if r.isOk:
  useIt(r.body)
else:
  showThePlayer(r.message)       # always populated, always specific
```

or the two-line form:

```nim
var body = ""
let refusal = invokeOrRefuse("items.spawn", 1, requestJson, body)
if refusal.len > 0: showThePlayer(refusal)
```

`r.body` is populated on `coOk` and on nothing else. `describe(r)` gives one
line for a diagnostic block, and it says **INCONCLUSIVE** for the two outcomes
that are inconclusive rather than flattening them into a failure.

## Refusal taxonomy

| outcome | means | actionable by |
|---|---|---|
| `coOk` | a provider ran and its payload validated strictly | — |
| `coProviderError` | a provider ran and said no; `message` is its words | the provider |
| `coVersionMismatch` | a provider of this NAME is answering, at other versions (`r.versions`) | whoever picks the version |
| `coProviderNotLoaded` | the registry declares it; the selection does not load it | the player, in the mod manager |
| `coProviderSilent` | registry declares it AND the selection loads it, and nothing answered — loaded but never called `provide`, or its `onLoad` failed. **INCONCLUSIVE** | the provider's author, via the backend log |
| `coNoProvider` | nothing answered and no installed mod declares it | the player, by installing it |
| `coRosterUnknown` | nothing answered and the roster could not be read. **INCONCLUSIVE** — never collapsed into `coNoProvider` | whoever owns the broken registry/selection file |
| `coBadReply` | a reply arrived that is not strictly valid JSON | the provider |
| `coUnavailable` | client side, no reply channel, all in-flight slots taken, or *your own request* was not valid JSON | the caller |

## Resolution is lazy — the `loadAfter` answer

Nothing binds at load time and nothing is cached. Every `invoke` asks live.

`loadAfter` is ORDERING ONLY (SAIN declares `loadAfter aowl.morebots`), not a
dependency the host enforces, so a load-time bind would make "the provider
loaded second" a permanent silent failure. Measured instead, with the consumer
deliberately loaded first (`tools/capproof.py`, backend log):

```
info  capconsumer: items.spawn/1 at load time -> INCONCLUSIVE (provider-silent) ...
ok    capability: providing items.spawn/1
```

and the same call over the route, moments later, returns `outcome ok`. A
refusal at load time is correct and is not permanent.

## The boundary is structural, not policy

A mod that is not loaded holds no subscription, so it cannot answer. There is
no allow-list to keep in sync and no way for an unloaded mod to provide
anything. The roster files are read **only to explain a silence**, never to
decide whether a call happens.

## The proof

```
python tools/capproof.py
```

Builds a scratch install root, runs the standalone backend on plain HTTP
(no client, no TLS) and drives five worlds that differ by one fact each:
provider loaded / provider installed-but-deselected / provider uninstalled /
wrong version / malformed request. Every response is parsed with `json.loads`,
strictly — the route answers **200 for every refusal on purpose**, so status
code is not evidence. 5/5 PASS; the negative control (assert `no-provider`
while the provider is loaded) reports FAIL, so the harness is falsifiable.

## Per-consumer migration notes

Neither mod below is touched by this branch — both are owned by other agents
mid-flight. These are the diffs their owners would make.

### `mods/admin` — the measured victim

`adm/presets.nim` already emits exactly the right payload. `presetRequestJson(i)`
produces `{"preset":..,"lines":[{"q":..,"n":..,"c":..}]}`, which is byte-for-byte
what `examples/capprovider` accepts and what a `provide` on `mods/tarkov` would
take. The change is:

* `import aowlspt/capability`.
* Replace `presetApplyStatus()`'s prose refusal with a real call:
  `invokeOrRefuse("items.spawn", 1, presetRequestJson(i), body)`. Keep the
  refusal text as the fallback for `coNoProvider` only — every other outcome
  now has a *specific* message worth showing instead.
* `presetsDiag` keeps its INCONCLUSIVE verdict, but sourced from `describe(r)`
  rather than hard-coded, so it tells the truth in both directions.
* Nothing else. No spawner, no HTTP client, no route in this mod.

The other half — `provide("items.spawn", 1, ...)` wrapping `spawnInto()` in
`mods/tarkov/emu/spawn.nim`, plus `"items.spawn/1"` in aowl.tarkov's `provides`
— belongs to whoever owns `mods/tarkov`. Until it exists, admin's refusal
becomes `coNoProvider` with the registry named, which is strictly better than
today's static sentence.

### `mods/waypoints` — the second instance

It serves verified per-map patrol data and defines a consumption contract no
other mod can reach. The change is a `provide("nav.waypoints", 1, handler)`
where the handler takes `{"map":"<id>"}` and returns the data it already
computes, plus `"nav.waypoints/1"` in its registry `provides`. Consumers
(SAIN, morebots) then call `invoke("nav.waypoints", 1, ...)` and get
`coProviderNotLoaded` — naming waypoints and the selection file — instead of
silence, when the player has it switched off.

## What this is not

Not a network protocol. It never leaves the process, never chunks a request,
never negotiates an encoding, and never parses a `/aowlspt/settings` document,
so the measured wire traps around those cannot reach it. Server side only:
`invoke` on the client host returns `coUnavailable` saying so.
