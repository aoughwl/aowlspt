## The mod manager — the registry, your lists, and what is actually running.
##
##     aowl build-mod mods/manager
##     aowl run mods/manager
##
## A backend mod on the same public API as any other: `aowlspt`,
## `aowlspt/server`, `aowlspt/json` and nothing else. It has no private door
## into the host, which is the same constraint the emulator is written under and
## for the same reason — a manager that needed privileged access would prove the
## plugin API is not enough to manage plugins with.
##
## What it does:
##
##  * reads `registry/mods.json` (one git repository, every mod, and the named
##    lists that select them),
##  * resolves it against your own selection — active lists plus your per-mod
##    overrides — and can say, for every mod in the registry, whether it is
##    loading and *why*,
##  * serves that under `/aowlspt/mods/...` so it can be driven from a second
##    window while the game is up,
##  * persists your selection with `save`/`load`, so it survives a restart,
##  * `broadcast`s when the selection changes, so anything else in the system
##    can react without polling.
##
## ## The honest part
##
## Enabling and disabling a mod *while the game runs* needs the host to be able
## to tear one down. `host/common/modhost.nim` can do it — `unloadOne` drops
## the mod's registrations through the teardown the host installs and then frees
## the library — and `host/common/modcontrol.nim` is the host half that answers
## this mod's control events.
##
## **Both hosts do it now, by two different routes, and the difference is a
## process boundary.**
##
## On the server, `backend/aowlbackend.nim` installs the teardown and drives
## `modcontrol`, so `/apply` and `/toggle` answer `requested` and then
## `applied`, and `live` on the panel is a fact. That conversation is events,
## and it works because the manager and the host are the same process.
##
## Inside the game they are not. `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` drives
## `modcontrol` too — it answers the probe, loads and unloads on its own tick
## — but no event this mod broadcasts will ever reach it. So the client host
## asks instead: it polls `/aowlspt/mods/client` every few seconds, which is
## this same resolution computed with `client` as the side, and makes itself
## match.
##
## **And it now says what came of it.** The answer rides back on the query
## string of that same poll — `?hs=<process>&sq=<n>&r=<guid>~<want><outcome>…`
## — one row per guid the backend named, carrying the last thing that host
## actually did about it. `mgr/clientreport.nim` reads it; the wire is written
## out in full there and in `host/common/modcontrol.nim`, which produces it.
##
## What that means for what this mod *says*:
##
##  * `control` and `liveKnown` still describe the **server's** host only. They
##    are about the event channel, and the client host is not on it.
##  * The panel's `live` column is no longer the server's alone. It is
##    `clientreport.liveVerdict`: running when either host says so, not running
##    when every host that could be running it has said so, and **null**
##    otherwise. Which hosts could be running it is the registry's `sides`.
##  * The `*` (restart) marker on a client-side row is a fact from the game
##    where the client host has sent one, and the baseline comparison only
##    where it has not.
##  * A client-only mod still reads as `wrong-side` on `/list` and `/panel` —
##    correctly: that is the *server's* resolution and it is not loading there.
##    What the game was told is on `/client`; what the game did is on
##    `/clientreport` and in the row's `clientLive` / `clientOutcome`.
##
## The one rule the whole client half turns on: **there is no encoding for "no
## answer yet"**. A guid with no record is unknown — a truncated report, an
## older host and a host that has not polled all converge on absence — and
## unknown is never rendered as "no", "off" or "not running". Every accessor in
## `mgr/clientreport.nim` is shaped to make that hard to get wrong.
##
## Routes report the truth, per change, in `outcome`. Nothing here claims to
## have enabled a mod that is not running.
##
## ## Layout
##
##     mgr/semver.nim     versions and ranges
##     mgr/registry.nim   reading mods.json
##     mgr/selection.nim  the user's lists and overrides, persisted
##     mgr/resolve.nim    the resolution rules, as written in registry/README.md
##     mgr/writeguard.nim whether the resolved order may be written down
##     mgr/control.nim    the host-side load/unload facade (this process)
##     mgr/clientreport.nim  what the client host says came of it (the game)
##     mgr/httpfetch.nim  one HTTP GET, on a worker thread, blocking nothing
##     mgr/refresh.nim    fetching a newer mods.json, and refusing to
##     mgr/cfgscan.nim    which *other* mods are running on defaults because
##                        their own config.json did not parse
##
## ## The routes
##
##     GET  /aowlspt/mods                what this is, and a one-line summary
##     GET  /aowlspt/mods/status         the same route under a second name
##     GET  /aowlspt/mods/list           every mod, its verdict and the reason
##     GET  /aowlspt/mods/panel          the same, flattened for the in-game overlay
##     GET  /aowlspt/mods/client         the desired set, resolved for the client side
##     GET  /aowlspt/mods/client/<ver>   the same, against that client host's version
##     GET  /aowlspt/mods/clientreport   what the client host said came of it
##     POST /aowlspt/mods/toggle/<id>    {"enabled":true} -- set it and apply it
##     GET  /aowlspt/mods/lists          the lists in the registry
##     GET  /aowlspt/mods/conflicts      only the problems
##     GET  /aowlspt/mods/describe/<id>  one mod, in full
##     GET  /aowlspt/mods/enable/<id>    override it on
##     GET  /aowlspt/mods/disable/<id>   override it off
##     GET  /aowlspt/mods/clear/<id>     drop the override; the lists decide
##     GET  /aowlspt/mods/select/<id>    make one list the active list
##     POST /aowlspt/mods/select         {"lists":["a","b"]}
##     GET  /aowlspt/mods/reload         re-read the registry from disk
##     GET  /aowlspt/mods/apply          push the current selection at the host
##     GET  /aowlspt/mods/registry       the refresh: is it on, what happened last
##     GET  /aowlspt/mods/registry/fetch fetch mods.json from the configured URL
##     GET  /aowlspt/mods/registry/fetch/force  ... and accept an older revision
##     GET  /aowlspt/mods/registry/revert drop the fetched copy, back to the build's
##     POST /aowlspt/mods/lists/local    create or replace one of *your* lists
##
## The last four are `mgr/refresh.nim`'s and are registered by it. The fetch is
## **off by default**, fetches *metadata only*, and refuses a registry that
## describes mod binaries to download -- see that module's header for the whole
## list of what it refuses and why "newer" is not "better".
##
## Every route also accepts `{"id":"..."}` in the body, because a browser can
## reach a path and a script would rather send a document.
##
## ## The panel route
##
## `/aowlspt/mods/panel` and `/aowlspt/mods/toggle/<id>` are the two the in-game
## overlay speaks, and they exist because the overlay's JSON reader is 60 lines
## of C running on a worker thread inside `EscapeFromTarkov.exe` — see the note
## at the top of `abi/aowlspt_overlay.h`. The alternative was to grow that reader
## until it could walk `/aowlspt/mods/list`'s decision objects and cross-index
## them against `/describe` for a version string, and the rule the overlay is
## written under is that if the shapes do not fit, the *server* flattens them.
## So the panel route answers exactly one flat array of rows, with the four
## fields the reader already knew and two it now needs (`live`, `restart`), and
## nothing about it is load-bearing for any other consumer.
##
## The rows are the registry's view — the mods this manager resolves, on the
## side it is running on. A client-side mod the backend has never heard of is not
## in it, and must not be: the client host pushes those into the overlay itself
## through `overlaySetMod`, and the overlay merges the two by guid. That is why
## `live` is `null` rather than `false` when nobody who could answer has
## answered — an unknown rendered as "not loaded" would grey out every row the
## client host had just told the truth about.
##
## Two of the six fields are now three-valued in that sense. `live` is the
## arbitration in `mgr/clientreport.liveVerdict`, and `clientLive` /
## `clientOutcome` / `clientCode` are **absent from the row entirely** when the
## client host has said nothing about that guid. Absent rather than false: the
## overlay's reader leaves a field it cannot find alone, absence is what this
## protocol uses to mean "no answer yet", and the rows that have nothing to say
## are the overwhelming majority of a body with 32 KB to fit into.

## ## Threads, and the one lock
##
## Routes run on the backend's worker pool: two of them are in this mod at once
## whenever two requests are, and the host's own threads arrive as well through
## the control events and the refresh timer. Everything this mod keeps between
## calls -- the registry, the resolution, the selection, the control table, the
## refresh state -- is therefore shared mutable state, and until it was guarded
## two concurrent `/toggle`s could interleave a read of the resolution with a
## rebuild of it. The backend cannot fix that from outside: it serialises what
## it can see, which is a session id, and it cannot know which of a mod's
## globals a route touches. This mod can.
##
## So there is one lock, `aowlspt/sync`, private to this library, and one
## discipline:
##
##  1. **It is taken at entry points and nowhere else.** A route, an event
##     handler, a timer callback. Everything below them assumes it is held and
##     never takes it -- it is documented non-reentrant, and the Windows
##     accident that `CRITICAL_SECTION` is recursive is not something to build
##     on.
##  2. **It is never held across anything that can block or re-enter.** Three
##     things qualify and all three are arranged around it: `broadcast`, which
##     the host answers *synchronously* into this mod's own event handlers; the
##     registry fetch, which is seconds against an unreachable host; and the
##     file writes. Each is done between guarded regions, from a snapshot taken
##     inside one.
##  3. **A guarded region is left the way it was entered.** No `return` inside
##     `withModLock`, which is why the routes that refuse things are written as
##     a `...Locked` worker returning a reason and a thin route around it.
##
## What that buys is not "no interleaving" -- two toggles still race, and one of
## them still wins. It is that the loser's answer describes a state that
## actually existed. A resolution read while another thread is rebuilding it is
## the same bug as two writes, and it is the one that produces a panel showing
## a mod as loaded and excluded at once.

import std/syncio
import aowlspt
import aowlspt/server
import aowlspt/json
import aowlspt/sync
import mgr/registry
import mgr/resolve
import mgr/selection
import mgr/writeguard
import mgr/control
import mgr/clientreport
import mgr/refresh
import mgr/cfgscan

const
  ModGuid = "aowl.manager"
  ModName = "Mod Manager"
  ModVersion = "1.0.0"
  SelectionFile = "aowlspt-selection.json"

# Globals with literal initialisers only: in an `--app:lib` build a global that
# needs a *call* to initialise is silently left zeroed, so `emptyRegistry()`
# here would produce a registry that looks loaded and is not.
var gRegistry: Registry = Registry(ok: false, path: "", error: "not loaded",
                                   name: "", warnings: @[], mods: @[],
                                   lists: @[])
var gRes: Resolution = Resolution(order: @[], decisions: @[], problems: @[],
                                  pipelineChecked: false, hostVersion: "",
                                  side: "")
## The SAME selection resolved with `client` as the side, kept beside `gRes`.
##
## `routeClient` already had to resolve twice and says why in its header: on the
## server resolution every client-only mod is `wrong-side`, "which reads as
## `enabled:false`". That sentence was written about the client host and is just
## as true of the panel -- and the panel is what the player presses. A row for
## `aowl.fovfix` was drawn from `gRes` alone, so it read `enabled:false` while
## the selection store said `enabled:true` and the game had the mod loaded and
## running. Pressing that row did not "enable" it: `toggleLocked` flips the
## stored override, so the gesture that looks like switching FOV on is the one
## that switches it off.
##
## So the second resolution is computed once per `recompute` rather than once
## per request, and `effectiveWant` below reads it. Same registry, same
## selection, same rules, one argument different -- the property that made
## asking twice honest in `routeClient` is the reason it is honest here.
var gResClient: Resolution = Resolution(order: @[], decisions: @[],
                                        problems: @[], pipelineChecked: false,
                                        hostVersion: "", side: "")
var gDefaultLists: seq[string] = @[]
var gProbeMs = 750
var gWriteSelectionFile = true
var gRegistryPath = ""
var gPending = false

# ---------------------------------------------------------------------------
# What the config actually said, as opposed to what it failed to say
# ---------------------------------------------------------------------------
#
# A UTF-8 byte-order mark on `config.json` cost an install ten mods out of ten.
# The chain was: the host's per-key lookup could not find `activeLists` in a
# document that did not parse, so `readConfig` saw the same empty string it
# would have seen for `"activeLists": []`; nothing was seeded; nothing resolved;
# and `selectionDocument` wrote a `load` array naming this manager and nothing
# else, beside the mods, where the next start honoured it to the letter.
#
# The BOM itself is now dropped by the host's reader. That closes one door. It
# does not close the one that mattered: **the manager could not tell "the config
# named no lists" from "the config did not parse", and wrote a destructive
# document on the strength of not knowing.** Any other way of making that file
# unreadable -- a truncated write, a stray comma, an editor that saved UTF-16 --
# walks the identical path.
#
# So the config's state is a value now, not an absence, and every degenerate
# selection document is checked against it before it can be written.
#
# **Where that value comes from is the part that changed.** It used to come from
# a structural check this mod carried itself (`registry.wholeJsonObject`, a
# bracket counter) run over the bytes of `setting("")`. The host now answers the
# question directly -- `ErrConfigParse`, surfaced by the SDK as
# `ConfigValue.faulted` -- so the local check is gone, and with it the disagree-
# ment nobody had noticed: the bracket counter accepted a trailing comma that
# the host rejected, so on a config ending `"writeSelectionFile": true,}` the
# host read *no* settings while this mod believed it had read them all. Two
# readers with different opinions about one file is the bug underneath the bug,
# and the fix is not a better local parser, it is not having one.
type
  ConfigState = enum
    cfgOk          ## it parses, and `activeLists` is a list of ids or absent
    cfgAbsent      ## there is no readable config.json for this mod at all
    cfgUnreadable  ## there is one and it is not one complete JSON object
    cfgListsBad    ## it parses and its `activeLists` is not an array

var gCfgState = cfgOk
var gCfgFault = ""
# Whether `activeLists` named at least one id. The whole point of separating it
# from `gDefaultLists.len` is that the two can disagree, and when they do it is
# because something went wrong between the file and this mod.
var gCfgNamedLists = false

# The *other* mods' configs. See `mgr/cfgscan.nim` for why this manager is the
# only thing in the install that can say this, and `scanModConfigs` for when it
# is read. Three parallel seqs rather than a seq of `ModConfigFault`, for the
# same reason `captureBaseline` keeps two: it is the shape that survives
# nimony's handling of nested seqs in loop variables without a workaround.
var gModCfgIds: seq[string] = @[]
var gModCfgPaths: seq[string] = @[]
var gModCfgWhy: seq[string] = @[]
# The summary sentence, or "" when every loaded mod's config was readable.
var gModCfgReport = ""

# Why the last resolved selection document was not written beside the mods, or
# "" when it was. Computed under the lock by `selectionWriteFault` and read by
# the status route; the write itself happens outside the lock and is handed the
# sentence rather than recomputing it, so the file on disk and the reason on the
# panel can never describe two different resolutions.
var gWriteFault = ""
# What was already in `aowlspt-selection.json` when this manager loaded, when
# that is something somebody has to know about.
var gForeignSelection = ""
# An apply is out. `adoptRegistry` defers to it, and a second apply coalesces
# into it rather than interleaving host requests with it: see `applySelection`.
# All three are read and written only under the lock, which is the whole point
# of them -- a flag tested on one thread and set on another is the race it was
# added to prevent.
var gApplying = false
var gApplyAgain = false
var gAdoptQueued = false

# What the selection resolved to when this manager loaded. It is the only
# baseline available on a host with no live control: "does this row need a
# restart" is *does your selection differ from the one the host started with*,
# and without a remembered starting point the honest answer would have to be
# "everything might" — which is a `*` on every row, which is no information.
#
# Two parallel seqs rather than a seq of a two-field object, for the same reason
# `recompute` builds its overrides that way: it is the shape that survives
# nimony's handling of nested seqs in loop variables without a workaround.
var gBaseIds: seq[string] = @[]
var gBaseOn: seq[bool] = @[]

# ---------------------------------------------------------------------------
# Finding the registry
# ---------------------------------------------------------------------------

proc parentOf(path: string): string =
  ## The same rule as `mgr/control.nim`: a name with no separator lives in the
  ## current directory, so its parent is ".". `aowl run` hands the simulator a
  ## relative mod path and the registry sits two levels above it.
  var cut = -1
  for i in 0 ..< path.len:
    if path[i] == '/' or path[i] == '\\':
      cut = i
  if path.len == 0: return ""
  if cut < 0: return "."
  if cut == 0: return path.substr(0, 0)
  result = path.substr(0, cut - 1)

proc cfgText(key, default: string): string =
  ## A config *string*, with its JSON quotes off.
  ##
  ## `setting()` hands back the raw token so a caller can tell `"1"` from `1`,
  ## which means every string setting arrives as `"value"` and an empty one
  ## arrives as two quote characters — length two, not zero. Read as a path that
  ## is a directory nobody named; read as an "is it set" test it is always true.
  ## `mods/fov` carries the identical helper, which is the second copy of a
  ## workaround that belongs in `aowlspt/server` -- `ConfigValue.asText` should
  ## unquote a JSON string, and until it does every mod reading a string setting
  ## has to know this.
  var raw = setting(key).asText(default)
  if raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"':
    raw = raw.substr(1, raw.len - 2)
  result = raw

proc registryCandidates(): seq[string] =
  ## Where a checkout of the registry repository plausibly is, most specific
  ## first. Searched rather than hard-coded because the same binary runs from a
  ## source tree (`aowl run`) and from an install, and those are different
  ## trees — and because the registry is a *separate* repository that a player
  ## may have cloned anywhere, which is what `registryPath` in config is for.
  result = @[]
  let cfg = cfgText("registryPath", "")
  if cfg.len > 0:
    result.add cfg
    return                       # an explicit path is not a hint to search past
  let data = dataDir()
  if data.len > 0:
    result.add data & "/mods.json"
    result.add data & "/registry/mods.json"
  let mods = modsRoot()
  if mods.len > 0:
    result.add mods & "/registry/mods.json"
    let root = parentOf(mods)
    if root.len > 0:
      result.add root & "/registry/mods.json"
      let up = parentOf(root)
      if up.len > 0:
        result.add up & "/registry/mods.json"

proc readRegistrySource(outPath, outText, outLooked: var string) =
  ## The **disk half** of finding the registry, and it holds no lock.
  ##
  ## Split out for that reason alone: reading a file is the one thing here that
  ## can take arbitrarily long -- a network drive, an antivirus scanner, a
  ## laptop waking a disk -- and every route that reads the resolution would be
  ## waiting behind it. Nothing global is touched; the caller installs the
  ## result under the lock.
  outPath = ""
  outText = ""
  outLooked = ""
  let candidates = registryCandidates()
  for path in candidates:
    if outLooked.len > 0: outLooked.add ", "
    outLooked.add path
  for path in candidates:
    let text = readTextFile(path)
    if text.len == 0:
      continue
    # The first file that *exists* wins, even if it fails to parse. Falling
    # through to the next candidate on a parse error would silently resolve
    # against a stale copy while the one you are editing is broken.
    outPath = path
    outText = text
    return

proc installRegistry(path, text, looked: string) =
  ## The **decision half**: parse what was read and make it the one in effect.
  ## Assumes the lock is held. Parsing is arithmetic over a string in hand, so
  ## this is bounded work and no file is touched.
  ##
  ## The merge with your own lists is here, at the one point where `gRegistry`
  ## is assigned, so that everything downstream -- resolution,
  ## `/aowlspt/mods/lists`, `findList`, the panel -- sees a single set of lists.
  ## A local list that only some of those knew about would be a list you could
  ## select and could not resolve. Your lists come out of the selection store,
  ## not out of the manifest, so a registry refresh replaces everything the file
  ## has to say and cannot touch a list you wrote (`mgr/selection.nim`).
  if path.len == 0:
    gRegistryPath = ""
    # The paths are in the message, not just "not found". Which directories
    # were searched is the entire content of this failure -- without them the
    # answer to "why can it not see my registry" is a guess about where the
    # host thinks the mod lives.
    gRegistry = Registry(ok: false, path: "",
                         error: "no registry found. Looked at: " & looked &
                                " (mod dir " & modDir() & "). Set " &
                                "\"registryPath\" in config.json to point at " &
                                "a checkout of the registry.",
                         name: "", warnings: @[], mods: @[], lists: @[])
  else:
    gRegistryPath = path
    gRegistry = parseRegistry(text, path)
  gRegistry = withLocalLists(gRegistry)

proc discoverRegistry() =
  ## An entry point: called **without** the lock, and takes it for the install.
  var path = ""
  var text = ""
  var looked = ""
  readRegistrySource(path, text, looked)
  withModLock:
    installRegistry(path, text, looked)

# ---------------------------------------------------------------------------
# Resolving
# ---------------------------------------------------------------------------

proc recompute() =
  var ids: seq[string] = @[]
  var flags: seq[bool] = @[]
  let overrides = allOverrides()
  for ov in overrides:
    ids.add ov.id
    flags.add ov.enabled
  gRes = resolve(gRegistry, activeLists(), ids, flags, sideName(), hostVersion())
  # Both sides, from the one selection, in the one place the selection changes.
  # If this manager IS the client host there is nothing to ask twice.
  if sideName() == "client":
    gResClient = gRes
  else:
    gResClient = resolve(gRegistry, activeLists(), ids, flags, "client",
                         hostVersion())

proc isProtected(id: string): bool =
  ## Mods that may not be switched off from inside the game.
  ##
  ## Exactly one today, and it is this one. Switching the manager off is
  ## honoured all the way down: it drops itself, a host with live control
  ## unloads it, and every `/aowlspt/mods/*` route goes with it -- so nothing
  ## running can undo it. The selection on disk then says it is off, so a
  ## restart does not help either, and the only recovery is hand-editing
  ## `aowlspt-selection.json`. That happened for real: a test host pressed the
  ## toggle on row zero and the install had to be re-staged.
  ##
  ## `registry/README.md` already said `aowl.manager` is "never off". This is
  ## that sentence becoming a rule instead of a note.
  result = id == ModGuid

proc isInternal(id: string): bool =
  ## PRESENTATION ONLY -- `internal` in `registry/mods.json`.
  ##
  ## Infrastructure the player has no business being offered: the settings
  ## index every settings UI reads, the fallback browser page, a one-shot ABI
  ## experiment. It is a category, not four special cases, and it is a
  ## different question from `shipped`: `aowl.settingshub` ships in every
  ## install and must be invisible; `aowl.textures` is not shipped yet and is
  ## an ordinary player mod.
  ##
  ## Nothing here reaches resolution. `resolve`, the load order, `requires`,
  ## the selection file and `/aowlspt/mods/client` never consult it, so an
  ## internal mod is still resolved and still LOADED -- it is only absent from
  ## the player-facing panel. A mod the registry does not know is not internal:
  ## an unknown id is already a problem row, and calling it infrastructure
  ## would make an unrecognised stray disappear, which is the one outcome this
  ## must not produce.
  var idx = -1
  if not findMod(gRegistry, id, idx): return false
  result = gRegistry.mods[idx].internal

proc registryParent(id: string): string =
  ## PRESENTATION ONLY -- `parent` in `registry/mods.json`. The mod this one
  ## is drawn UNDER in the player-facing tree. Empty for a root-level mod AND
  ## for an id the registry does not know: the same answer for two different
  ## reasons, which is why the route carries the field only when it is
  ## non-empty. An absent field means "claims no parent", never "the tree is
  ## unknown". Nothing here reaches resolution -- a child is resolved,
  ## ordered and loaded exactly as before, and its guid, path, dll, routes
  ## and config.json are untouched, so nesting moves no stored value.
  ## (Named `registryParent`, not `parentOf`: `parentOf` in this module is
  ## the filesystem path helper and shadowing it would be a live bug.)
  var idx = -1
  if not findMod(gRegistry, id, idx): return ""
  result = gRegistry.mods[idx].parent

proc selectionDocument(): string =
  ## The resolved order, as the host would need it at startup.
  ##
  ## Written beside the mods so a host *can* read it, and documented as inert
  ## until one does. It is not a claim that anything reads it — `startupHonoured`
  ## in `/aowlspt/mods` says whether a host has ever said it does.
  ##
  ## **A protected mod is always in it, whatever the resolution said.** This is
  ## the same rule `applySelection` keeps -- it will not ask a host to unload
  ## this mod -- applied to the other half of the same decision, and it was
  ## missing there. A resolution can leave this manager out without any route
  ## having allowed it: select a local list that does not inherit
  ## `aowl.list.core`, or adopt a registry whose lists stop naming it, and
  ## `managerContradiction` says so on the panel while this mod keeps running
  ## and keeps serving. But the document written beside the mods decided the
  ## *next* start, and the mod it left out was the one that owns every route
  ## that could put it back: the host honours the file, the manager does not
  ## come up, and the only way in is to edit the file by hand. `modhost`
  ## refuses an empty `load` for exactly that argument; a `load` that names ten
  ## mods and not this one is the same install with the same no way in, and
  ## refusing it there is not possible because the host cannot know which id is
  ## the manager. So it is written here, where that is known.
  ##
  ## It goes at the front. It has no `loadAfter` and nothing requires it, so no
  ## edge in the registry can be broken by it; and the manager coming up before
  ## the mods it manages is the order every resolution produces anyway.
  var a = arr()
  var haveProtected = false
  for id in gRes.order:
    if isProtected(id):
      haveProtected = true
  if not haveProtected:
    a.add ModGuid
  for id in gRes.order:
    a.add id
  var o = obj()
  put(o, "schema", "aowlspt.selection/1")
  put(o, "writtenBy", ModGuid)
  put(o, "side", gRes.side)
  put(o, "registry", gRegistryPath)
  put(o, "load", a)
  result = done(o).text

proc writeFacts(): WriteFacts =
  ## Everything `mgr/writeguard.selectionWriteFault` decides on, gathered from
  ## the globals in one place. Assumes the lock.
  ##
  ## The decision itself lives in that module, taking these as an argument and
  ## reading nothing else, because the version that read the globals directly
  ## could not be driven from a test — and a refusal nobody has watched fire is
  ## a refusal nobody knows is wired up. That is this project's recurring bug:
  ## a check that passes because the thing it checks never happened.
  var known: seq[string] = @[]
  for i in 0 ..< gRegistry.lists.len:
    known.add gRegistry.lists[i].id
  result = WriteFacts(
    protectedId: ModGuid,
    order: gRes.order,
    configFault: gCfgFault,
    configNamedLists: gCfgNamedLists,
    selectionFault: (if selectionUsable(): "" else: selectionFault()),
    selectionSeeded: selectionSeeded(),
    registryOk: gRegistry.ok,
    registryError: gRegistry.error,
    registryPath: gRegistryPath,
    registryMods: gRegistry.mods.len,
    activeLists: activeLists(),
    knownLists: known,
    problems: gRes.problems,
    pipelineChecked: gRes.pipelineChecked,
    hostVersion: gRes.hostVersion)

proc currentWriteFault(): string =
  ## "" when this run's resolved load order may be written beside the mods, and
  ## the sentence to say out loud when it may not. Assumes the lock. The whole
  ## argument is in the header of `mgr/writeguard.nim`.
  result = selectionWriteFault(writeFacts())

proc writeSelectionFileText(document, fault: string) =
  ## Called without the lock, with a document *and its verdict*, both built
  ## under it. The file write is the blocking part and the document is the part
  ## that has to be consistent, so they are separated: this can take as long as
  ## the disk wants to without a single route waiting on it.
  ##
  ## `fault` is passed rather than recomputed here for the same reason: it was
  ## decided about this resolution, and a second look would be a look at
  ## whatever the state had become by then.
  if not gWriteSelectionFile:
    return
  if document.len == 0:
    return
  let root = modsRoot()
  if root.len == 0:
    return
  let path = root & "/" & SelectionFile
  if fault.len > 0:
    error "manager: refusing to write " & path & ": " & fault &
          ". That file decides what loads at the next start, and this one " &
          "would have named " & ModGuid & " and nothing else. Whatever is " &
          "there now is left exactly as it is -- delete it to go back to " &
          "loading everything that is installed. Nothing here is lost: your " &
          "lists and overrides are in this mod's own store and are untouched."
    return
  try:
    writeFile(path, document)
  except:
    warn "manager: could not write " & path

proc inspectSelectionFile() =
  ## What is *already* beside the mods, before this manager writes over it.
  ##
  ## Read once, at load, and holds no lock -- it is a file read and nothing
  ## global is touched but the one string the caller installs.
  ##
  ## Three things are worth saying and none of them was being said:
  ##
  ##  * a document written for another **side**. `modhost.readSelection` refuses
  ##    one, correctly, and falls back to loading everything -- so the symptom
  ##    is "my selection is being ignored" with the reason in a host log the
  ##    player is not reading. This mod knows which side it is and can say it.
  ##  * a document written by something that is not this manager. Same symptom,
  ##    different cause, and overwriting it silently is how somebody's
  ##    hand-edited recovery file disappears.
  ##  * a file in the **install root**, which is where `modhost.readSelection`
  ##    looks *first* and where this mod does not write. A stale one there wins
  ##    over every document this manager produces, for ever, silently.
  gForeignSelection = ""
  let root = modsRoot()
  if root.len == 0:
    return
  let above = parentOf(root)
  if above.len > 0:
    let shadow = above & "/" & SelectionFile
    if readTextFile(shadow).len > 0:
      gForeignSelection = shadow & " exists, and a host reads that one before " &
                          "the copy this mod writes (" & root & "/" &
                          SelectionFile & "). Until it is deleted, nothing " &
                          "you change here decides what loads at the next start."
      return
  let raw = readTextFile(root & "/" & SelectionFile)
  if raw.len == 0:
    return
  if not wholeJsonObject(raw):
    gForeignSelection = root & "/" & SelectionFile & " is there and is not one " &
                        "complete JSON object. It is about to be replaced by " &
                        "this run's resolution; if it was a hand-edited " &
                        "recovery file, take a copy now."
    return
  let doc = whole(raw)
  let docSide = doc.field("side").asText("")
  if docSide.len > 0 and docSide != gRes.side:
    gForeignSelection = root & "/" & SelectionFile & " was written for the " &
                        docSide & " side and this manager is the " & gRes.side &
                        " one. A host refuses a document written for another " &
                        "side and loads everything instead."
    return
  let by = doc.field("writtenBy").asText("")
  if by.len > 0 and by != ModGuid:
    gForeignSelection = root & "/" & SelectionFile & " says it was written by " &
                        by & " rather than by " & ModGuid & "."

proc scanModConfigs() =
  ## Which of the mods this run loads are running on defaults because their
  ## `config.json` did not parse.
  ##
  ## Read once, at load, and holds no lock -- like `inspectSelectionFile`, it is
  ## a set of file reads, and it runs before the routes exist and before any
  ## other thread can be in this mod. It touches only the four globals it
  ## installs.
  ##
  ## Once rather than on every refresh, because it is a statement about the mods
  ## that are *running*: a host reads a mod's config when it loads it, so a
  ## config repaired mid-session has not been re-read by the mod it belongs to
  ## either. Re-scanning would produce a panel that says the problem is gone
  ## while every setting in that mod is still its default.
  ##
  ## Only the resolved order is scanned. A mod the selection does not load is
  ## not running on defaults; it is not running.
  ##
  ## This manager's own config is deliberately not in here. Its answer comes
  ## from the host itself (`readConfig`, via `ConfigValue.faulted`), which is
  ## the better source, and it is reported separately as `gCfgFault` -- naming
  ## it twice would read as two mods with two problems.
  gModCfgIds = @[]
  gModCfgPaths = @[]
  gModCfgWhy = @[]
  gModCfgReport = ""
  let root = modsRoot()
  if root.len == 0:
    return
  var faults: seq[ModConfigFault] = @[]
  for id in gRes.order:
    if isProtected(id):
      continue
    var idx = -1
    if not findMod(gRegistry, id, idx):
      continue
    let dir = gRegistry.mods[idx].artifactDir
    if dir.len == 0:
      continue
    var f = emptyConfigFault()
    if configFaultAt(root & "/" & dir, id, f):
      faults.add f
      gModCfgIds.add f.id
      gModCfgPaths.add f.path
      gModCfgWhy.add f.fault
  gModCfgReport = configFaultReport(faults, gRes.order.len)

proc modConfigFaultOf(id: string): string =
  ## The fault in that mod's `config.json`, or "" -- which is also the answer
  ## for a mod with no config file and for one that was never scanned. Assumes
  ## the lock.
  for i in 0 ..< gModCfgIds.len:
    if gModCfgIds[i] == id:
      return gModCfgWhy[i]
  result = ""

proc summaryLine(): string =
  result = $gRes.order.len & " of " & $gRegistry.mods.len &
           " registry mods resolve on the " & gRes.side & " side"

proc announceText(): string =
  ## The "the selection changed" payload, as text. Assumes the lock.
  var o = obj()
  put(o, "side", gRes.side)
  put(o, "loaded", gRes.order.len)
  var a = arr()
  for id in gRes.order:
    a.add id
  put(o, "order", a)
  put(o, "control", stateName(controlState()))
  put(o, "pending", gPending)
  result = done(o).text

proc afterChange() =
  ## An entry point: called **without** the lock, and takes it for the recompute
  ## only.
  ##
  ## The two side effects are deliberately outside it. `writeSelectionFile` is a
  ## disk write, and `broadcast` is delivered synchronously to every other mod's
  ## subscriber -- on this thread, running code this mod has never seen. Holding
  ## a lock across somebody else's handler is how a mod that does nothing wrong
  ## becomes the reason the server stopped answering.
  var document = ""
  var payload = ""
  var fault = ""
  withModLock:
    recompute()
    document = selectionDocument()
    gWriteFault = currentWriteFault()
    fault = gWriteFault
    payload = announceText()
  writeSelectionFileText(document, fault)
  discard broadcast("aowlspt.mods.selection", payload)

# ---------------------------------------------------------------------------
# JSON views
# ---------------------------------------------------------------------------

proc modSides(id: string; onServer, onClient: var bool) =
  ## Which hosts could ever run this mod, from the registry's own `sides`.
  ##
  ## It decides which host is *entitled* to answer "is it running" — see
  ## `clientreport.liveVerdict` — so a mod the registry does not carry answers
  ## "neither", which is what it is: nothing can load a mod nobody describes.
  ## `sim` counts as the server, because that is the host `mgr/control` talks
  ## to when this manager is running under `aowl run`.
  onServer = false
  onClient = false
  var idx = -1
  if not findMod(gRegistry, id, idx):
    return
  let m = gRegistry.mods[idx]
  onServer = hasSide(m, "server") or hasSide(m, "sim")
  onClient = hasSide(m, "client")

proc effectiveWant(d: Decision): bool =
  ## What the switch on this row is actually set to, on the side that can run
  ## this mod. NOT `d.verdict == vLoaded`, which is the server's answer and is
  ## `false` for every client-only mod whether or not you asked for it.
  ##
  ## `rowRestart` already had to make exactly this distinction and says so in
  ## step 3 -- "`want`, which is this row's server-side answer and is `false`
  ## for every client-only mod". That reasoning stopped one field short: the
  ## `restart` marker was corrected and `enabled` was left reading the server.
  ## For `aowl.fovfix`, `aowl.graphics` and `aowl.debug` -- the three mods in
  ## this registry that declare a client side and no server side -- the panel
  ## therefore drew an OFF switch over a mod the game had loaded and reported
  ## `running` on the very same row (`clientLive:true` beside `enabled:false`).
  ##
  ## `managerContradiction` calls that shape out by name for `aowl.manager`:
  ## "a row that reads `enabled:false` about a mod that is running is exactly
  ## the kind of quiet disagreement that sends somebody looking in the wrong
  ## place". It was true of three more rows, every session, and nothing said it.
  ##
  ## Only `wrong-side` defers. Every other verdict is a real decision about this
  ## mod that the server was entitled to make -- `not-selected`, `conflict`,
  ## `unknown`, a failed `pipeline` range -- and substituting the client's
  ## answer for one of those would hide a genuine exclusion behind a switch that
  ## looks live. This can move a row from `false` to `true` only where the
  ## server had no opinion to give.
  if d.verdict != vWrongSide:
    return d.verdict == vLoaded
  var onServer = false
  var onClient = false
  modSides(d.id, onServer, onClient)
  if not onClient:
    return false
  var ci = -1
  if not decisionFor(gResClient, d.id, ci):
    return false
  result = gResClient.decisions[ci].verdict == vLoaded

proc clientRowShown(id: string): bool =
  ## Whether a row on `/panel` or `/list` carries the client host's answer at
  ## all.
  ##
  ## Only where it means something. The client host reports one row per guid the
  ## backend named, and that includes every server-only mod — for which its
  ## answer is always the same "not mine, not running", which is true, useless,
  ## and sixty bytes a row out of the 32 KB the overlay reads a body into. So it
  ## is carried for the mods that can actually run over there, and for anything
  ## the client host contradicts wherever it happens to be.
  ##
  ## This can only ever *withhold* a fact, never invent one: a row without the
  ## keys is a row that says nothing about the client, which is what every
  ## reader of this protocol already has to treat as unknown. The whole ledger,
  ## including the dull rows, is on `/aowlspt/mods/clientreport`.
  if not clientKnows(id):
    return false
  var onServer = false
  var onClient = false
  modSides(id, onServer, onClient)
  result = onClient or clientDisagrees(id) or clientRunning(id)

proc decisionJson(d: Decision): JsonObject =
  var o = obj()
  put(o, "id", d.id)
  put(o, "name", d.name)
  put(o, "verdict", verdictName(d.verdict))
  put(o, "reason", d.reason)
  put(o, "from", d.fromList)
  put(o, "explicit", d.explicit)
  put(o, "order", d.order)
  # Present on the DIAGNOSTIC route only, and always -- `/aowlspt/mods/list`
  # is the route that must never hide anything, so it names the rows the
  # player-facing panel omits rather than omitting them too.
  put(o, "internal", isInternal(d.id))

  # The nesting the settings page renders, stated as data on the route that
  # must never hide anything. Present only when non-empty -- see above.
  let par = registryParent(d.id)
  if par.len > 0:
    put(o, "parent", par)

  # The switch position, same rule as the panel's -- see `effectiveWant`. The
  # `verdict`/`reason` beside it stay the SERVER's, unaltered: this route is the
  # diagnostic one and must keep saying that the server is not loading this mod
  # and why. `enabled` is the other question -- what you asked for -- and the
  # two genuinely differ for a client-only mod.
  put(o, "enabled", effectiveWant(d))

  # Same rule as the panel row: present only when the client host has actually
  # answered about this guid, so that absence stays the one way of saying "no
  # answer yet" on every route that carries it.
  if clientRowShown(d.id):
    put(o, "clientLive", clientRunning(d.id))
    put(o, "clientWant", clientWants(d.id))
    put(o, "clientOutcome", clientOutcomeName(clientOutcomeOf(d.id)))
    if clientCodeOf(d.id).len > 0:
      put(o, "clientCode", clientCodeOf(d.id))
    if clientMessage(d.id).len > 0:
      put(o, "clientMessage", clientMessage(d.id))
  result = o

proc baselineOf(id: string; outEnabled: var bool): bool =
  for i in 0 ..< gBaseIds.len:
    if gBaseIds[i] == id:
      outEnabled = gBaseOn[i]
      return true
  result = false

proc captureBaseline() =
  ## Taken once, at load, from the first resolution. Not refreshed by
  ## `afterChange`: the point of it is to remember what the *host* started with,
  ## and a baseline that moved with the selection would say "no restart needed"
  ## about every change ever made.
  gBaseIds = @[]
  gBaseOn = @[]
  for d in gRes.decisions:
    gBaseIds.add d.id
    gBaseOn.add d.verdict == vLoaded

proc rowLive(id: string; live: var bool): bool =
  ## Whether this manager may say anything at all about the mod running, and if
  ## so what. False means *unknown*, and the caller must render null.
  ##
  ## Two hosts can answer and neither of them is the panel's `side`: the server
  ## is `mgr/control`, in this process, and the client is the ledger the game's
  ## host now sends up on its poll (`mgr/clientreport`). The arbitration is
  ## `liveVerdict`, which is where the "absence is never off" rule is actually
  ## enforced and where every case of it is written out.
  var onServer = false
  var onClient = false
  modSides(id, onServer, onClient)
  let v = liveVerdict(id, liveKnown(), isLive(id), onServer, onClient)
  if v == lvUnknown:
    live = false
    return false
  live = v == lvRunning
  result = true

proc rowRestart(id: string; want: bool): bool =
  ## Whether this one row is not, right now, what you asked for. Five sources,
  ## in the order they are allowed to answer:
  ##
  ##  1. the host said so about this mod (`deferred`, or a failure) — that is a
  ##     fact about this mod and beats everything below,
  ##  2. a request is out and unanswered — briefly, what is running differs from
  ##     what was asked for, and flagging that would put a `*` on every row you
  ##     click for the second it takes the host to answer,
  ##  3. **the client host said so.** A record of its own — `s`, `r` or `d` —
  ##     is a fact about the game process, compared against the want *the client
  ##     resolution* carried rather than against `want`, which is this row's
  ##     server-side answer and is `false` for every client-only mod. Before
  ##     this existed the `*` on a client row was step 5, a comparison against
  ##     the selection this manager started with, which could say "restart"
  ##     about a change the game applied three seconds later,
  ##  4. the host has listed what it has — then it is simply whether the running
  ##     state differs from the wanted one,
  ##  5. nothing answered at all — then the only thing that can be compared is
  ##     this selection against the one the manager loaded with.
  ##
  ## Step 3 can only ever *raise* the flag, and only on a record: a mod the
  ## client host has not mentioned is left to the steps below it, exactly as it
  ## was before the client could speak.
  if needsRestart(id):
    return true
  if isPending(id):
    return false
  if clientDisagrees(id):
    return true
  if liveKnown():
    return isLive(id) != want
  var was = false
  if baselineOf(id, was):
    return was != want
  result = false

proc panelRow(d: Decision): JsonObject =
  ## One row of the in-game panel. Flat, six fields, no nesting: the reader on
  ## the other end is `aowl_ov_ingest` in `abi/aowlspt_overlay.h`, which scans
  ## for `{`..`}` and pulls named scalars out of it. Anything nested here would
  ## be read as another row.
  var version = ""
  var name = d.name
  var idx = -1
  if findMod(gRegistry, d.id, idx):
    let m = gRegistry.mods[idx]
    version = m.version
    if name.len == 0:
      name = m.name
  # The switch position, on the side that can run this mod -- see
  # `effectiveWant`. Feeding it to `rowRestart` too, because comparing what is
  # running against the *server's* answer is what put a spurious `*` on a
  # client-only row before the client host learned to report for itself.
  let want = effectiveWant(d)
  var o = obj()
  # Both spellings. `id` is what the registry and every other route call it;
  # `guid` is what the host, the ABI and the overlay call the same string, and
  # the two are required to be equal (registry/README.md). Emitting both costs
  # twenty bytes a row and means neither side has to translate.
  put(o, "guid", d.id)
  put(o, "id", d.id)
  # So the panel can draw the row as un-switchable without knowing which guid
  # that is. A header that hardcodes the manager's name is a header that has to
  # be edited when the manager is renamed.
  put(o, "protected", isProtected(d.id))
  put(o, "name", name)
  put(o, "version", version)
  put(o, "enabled", want)
  # WHICH HOST this switch is an instruction to, straight from the registry's
  # `sides`. The panel had no way to say "this one is applied by the game, not
  # by the backend", so a client-only row was indistinguishable from a
  # server-side row that had failed to apply -- and `control`/`live` on the
  # status object describe the *server's* host only. Present on every row so a
  # reader never has to infer it from which optional client keys turned up.
  var rowServer = false
  var rowClient = false
  modSides(d.id, rowServer, rowClient)
  put(o, "appliesOn", (if rowServer and rowClient: "both"
                       elif rowClient: "client"
                       elif rowServer: "server"
                       else: "none"))
  var live = false
  if rowLive(d.id, live):
    put(o, "live", live)
  else:
    # Not `false`. Nobody who could answer has answered — see `rowLive` — and
    # the overlay treats a null as "leave the row's own value alone", which
    # preserves what the client host pushed in about its own process, the one
    # source that cannot be stale.
    put(o, "live", jnull())
  put(o, "restart", rowRestart(d.id, want))
  # The client host's own answer about this guid, and **only when it has one**.
  # The keys are absent otherwise, deliberately: absence is how this whole
  # protocol says "no answer yet", a `false` here would be read as "not
  # running", and a reader that has to be told twice not to make that mistake
  # will make it once. It also costs nothing per row in the ordinary case,
  # which matters — the overlay reads this body into a 32 KB buffer and drops
  # it whole if it does not fit.
  if clientRowShown(d.id):
    put(o, "clientLive", clientRunning(d.id))
    put(o, "clientWant", clientWants(d.id))
    put(o, "clientOutcome", clientOutcomeName(clientOutcomeOf(d.id)))
    if clientCodeOf(d.id).len > 0:
      put(o, "clientCode", clientCodeOf(d.id))
  # Only when there is one, like the client keys above: absence is the
  # ordinary case and a `false` on every row is noise the overlay pays for
  # in a 32 KB buffer. A row carrying this is a mod whose settings are all
  # its own defaults -- see `mgr/cfgscan.nim`.
  if modConfigFaultOf(d.id).len > 0:
    put(o, "configFault", true)
  put(o, "verdict", verdictName(d.verdict))
  # Three sources for one sentence, most specific first: what the server's host
  # said about this mod, then what the client host said, then why the resolver
  # decided what it decided. The client's is appended rather than substituted
  # when both are silent about each other — the resolver's reason explains the
  # switch, the client's explains why the game does not match it, and a row
  # showing only one of the two sends somebody looking in the wrong process.
  var why = (if hostMessage(d.id).len > 0: hostMessage(d.id) else: d.reason)
  let saidClient = clientMessage(d.id)
  if saidClient.len > 0:
    why = why & " -- " & saidClient
  put(o, "reason", why)
  result = o

proc managerContradiction(): string =
  ## The one disagreement the panel cannot show on a row: the selection says
  ## this manager is off, and it is plainly not, because it is answering.
  ##
  ## Reachable without any route having allowed it -- a hand-edited selection
  ## store, or a registry whose lists simply stop naming it. `applySelection`
  ## refuses to unload it and the panel marks the row `protected`, so nothing
  ## breaks; but a row that reads `enabled:false` about a mod that is running
  ## is exactly the kind of quiet disagreement that sends somebody looking in
  ## the wrong place. Said out loud instead, once, in `problems`.
  var di = -1
  if not decisionFor(gRes, ModGuid, di):
    return ""
  if gRes.decisions[di].verdict == vLoaded:
    return ""
  result = "your selection says " & ModGuid & " (" & ModName & ") is " &
           verdictName(gRes.decisions[di].verdict) & " -- " &
           gRes.decisions[di].reason & ". It is protected and is still " &
           "running: it is never unloaded, because every /aowlspt/mods route " &
           "goes with it and nothing running could switch it back on. Enable " &
           "it again to make the panel agree with the process."

proc problemsJson(): JsonArray =
  var a = arr()
  for p in gRes.problems:
    a.add p
  for w in gRegistry.warnings:
    a.add w
  if not gRegistry.ok and gRegistry.error.len > 0:
    a.add gRegistry.error
  if not selectionUsable():
    a.add selectionFault()
  if gCfgState != cfgOk:
    a.add gCfgFault
  # The other mods' configs, which nothing else in this install can see.
  if gModCfgReport.len > 0:
    a.add gModCfgReport
  if gWriteFault.len > 0:
    a.add "the resolved load order was not written beside the mods: " & gWriteFault
  if gForeignSelection.len > 0:
    a.add gForeignSelection
  let contradiction = managerContradiction()
  if contradiction.len > 0:
    a.add contradiction
  result = a

proc statusJson(): JsonObject =
  var lists = arr()
  let act = activeLists()
  for l in act:
    lists.add l
  var o = obj()
  put(o, "ok", gRegistry.ok)
  put(o, "mod", ModName)
  put(o, "version", ModVersion)
  put(o, "registry", gRegistryPath)
  put(o, "registryName", gRegistry.name)
  put(o, "mods", gRegistry.mods.len)
  put(o, "lists", gRegistry.lists.len)
  put(o, "side", gRes.side)
  put(o, "host", hostName() & " " & hostVersion())
  put(o, "pipelineChecked", gRes.pipelineChecked)
  put(o, "activeLists", lists)
  put(o, "loaded", gRes.order.len)
  put(o, "control", stateName(controlState()))
  put(o, "controlHost", controlHost())
  put(o, "liveChanges", controlState() == csPresent)
  # The *other* host, which `control` says nothing about: it is a different
  # process and everything this manager knows about it arrived on the poll it
  # makes. `clientHost:false` is "nothing has reported", which is not "nothing
  # is running" — see `/aowlspt/mods/clientreport`.
  put(o, "clientHost", clientReporting())
  put(o, "clientRows", clientRows())
  put(o, "selectionPersisted", storeWorks())
  # Three states, not two. `selectionOk:false` means there is a stored
  # selection this manager would not read, and that nothing will be written
  # over it -- which is a different thing from "nothing has been saved yet",
  # and the only one of the two that a person has to act on.
  put(o, "selectionOk", selectionUsable())
  put(o, "selectionError", selectionFault())
  put(o, "selectionFile", (if gWriteSelectionFile: modsRoot() & "/" & SelectionFile else: ""))
  # Two more three-state answers, and for the same reason as `selectionOk`
  # above: "the load order beside the mods is this run's" and "it is the
  # previous run's because this run's would have unloaded the manager" are
  # different facts, and the second one is the only one anybody has to act on.
  put(o, "selectionFileWritten", gWriteFault.len == 0)
  put(o, "selectionFileRefused", gWriteFault)
  put(o, "configOk", gCfgState == cfgOk)
  put(o, "configError", gCfgFault)
  # And the same two facts about every *other* loaded mod. Zero is a real
  # answer here -- the scan ran and found nothing -- which is why it is a
  # count rather than an array that is usually empty.
  put(o, "modConfigFaults", gModCfgIds.len)
  put(o, "modConfigFaultText", gModCfgReport)
  put(o, "pendingRestart", gPending)
  put(o, "problems", problemsJson())
  result = o

# ---------------------------------------------------------------------------
# Reading a request
# ---------------------------------------------------------------------------

proc idFrom(url, prefix, body: string): string =
  ## The path tail, or `{"id":"..."}` from the body. Both, because a browser can
  ## only reach a path and a script would rather send a document.
  result = pathAfter(url, prefix)
  if result.len == 0:
    result = field(body, "id").asText("")

proc selectionBlocked(): string =
  ## "" when a change may be saved, and the reason when it may not.
  ##
  ## Every route that writes asks this first. The manager keeps serving with an
  ## unreadable selection -- it can still say what it knows and why -- but it
  ## will not take a change it cannot store, because taking one means the
  ## session and the disk now disagree and the disagreement is invisible.
  if selectionUsable():
    return ""
  result = selectionFault() & ". Nothing will be changed or saved until that " &
           "file is readable: fix it or delete it and restart. The manager is " &
           "still answering, and still says why."

proc errorBody(message: string): string =
  var o = obj()
  put(o, "ok", false)
  put(o, "error", message)
  result = done(o).text

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

proc doAdoptRegistry() =
  ## Re-read whatever registry is now on disk and recompute against it. The
  ## same two steps `/aowlspt/mods/reload` takes -- adopting a fetched registry
  ## is a reload, not a second way of loading one.
  discoverRegistry()
  afterChange()

proc applyPlan(loadIds, loadDirs, loadLibs, unloadIds: var seq[string]) =
  ## What the host would have to be asked, given the resolution as it stands.
  ## Assumes the lock, touches no host and takes no time: it is a copy, so that
  ## everything after it can run with nothing held.
  loadIds = @[]
  loadDirs = @[]
  loadLibs = @[]
  unloadIds = @[]
  let order = gRes.order
  let decisions = gRes.decisions
  for id in order:
    var idx = -1
    if not findMod(gRegistry, id, idx):
      continue
    let m = gRegistry.mods[idx]
    loadIds.add m.id
    loadDirs.add m.artifactDir
    loadLibs.add m.artifactLib
  # Anything the registry knows, that a list had switched on at some point, and
  # that is not in the resolved order, is asked to go away. Mods the registry
  # never mentions are left alone: they are somebody else's, and unloading a mod
  # this manager does not manage would be overreach.
  for d in decisions:
    if d.verdict == vLoaded or d.verdict == vNotSelected or d.verdict == vUnknown:
      continue
    # `wrong-side` is not an unload: the host skips a mod that does not declare
    # its side before it ever calls `on_load`, so asking for one back would be a
    # request that can only ever answer "there was nothing there".
    if d.verdict == vWrongSide:
      continue
    if isProtected(d.id):
      # Reachable even with the routes above refusing: a hand-edited selection
      # store, or a registry whose lists simply stop naming this mod. Refusing
      # here is what makes the rule a property of the manager rather than of
      # the three doors into it.
      continue
    unloadIds.add d.id

proc applySelection(): JsonObject =
  ## Ask the host to make the resolved selection true. Every mod gets an
  ## outcome, and `aoDeferred` is a perfectly ordinary one today.
  ##
  ## An entry point, called **without** the lock, and it takes it three times:
  ## once to claim the apply and copy the plan, once per pass to re-copy it, and
  ## once at the end to publish the result. Between those it holds nothing,
  ## because every request in the middle is a `broadcast` the host answers on
  ## this thread.
  ##
  ## Two things it will not do:
  ##
  ##  * **Run twice at once.** A second apply arriving while one is out does not
  ##    interleave its loads and unloads with the first's -- it raises a flag,
  ##    and the apply already running states the whole desired set once more
  ##    before it finishes. Both callers get an answer describing a set the host
  ##    was actually asked for.
  ##  * **Let a registry refresh land in the middle.** `adoptRegistry` sees the
  ##    claim and queues itself, so the loads are never from one document and
  ##    the unloads from another. The adopt is not dropped; it is taken here,
  ##    the moment the last pass is done.
  var claimed = false
  withModLock:
    if gApplying:
      gApplyAgain = true
    else:
      gApplying = true
      gApplyAgain = false
      claimed = true

  if not claimed:
    var busy = obj()
    put(busy, "ok", true)
    put(busy, "requested", 0)
    put(busy, "deferred", 0)
    put(busy, "restartRequired", false)
    put(busy, "results", arr())
    put(busy, "note", "an apply was already running. It states the whole " &
                      "desired set rather than a diff, and it has been asked " &
                      "to state it once more before it finishes, so this " &
                      "change is included in it.")
    withModLock:
      put(busy, "control", stateName(controlState()))
      put(busy, "coalesced", true)
    return busy

  var results = arr()
  var deferredCount = 0
  var requested = 0
  var passes = 0
  var again = true
  while again:
    inc passes
    var loadIds: seq[string] = @[]
    var loadDirs: seq[string] = @[]
    var loadLibs: seq[string] = @[]
    var unloadIds: seq[string] = @[]
    withModLock:
      applyPlan(loadIds, loadDirs, loadLibs, unloadIds)

    # Nothing held from here to the bottom of the loop. `requestLoad` and
    # `requestUnload` broadcast, and the host answers by emitting into this
    # mod's own `onResult` -- on this thread, wanting this lock.
    for i in 0 ..< loadIds.len:
      let r = requestLoad(loadIds[i], loadDirs[i], loadLibs[i])
      if r.outcome == aoDeferred: inc deferredCount
      if r.outcome == aoRequested: inc requested
      var e = obj()
      put(e, "id", loadIds[i])
      put(e, "action", "load")
      put(e, "outcome", outcomeName(r.outcome))
      put(e, "message", r.message)
      results.add e

    for i in 0 ..< unloadIds.len:
      let r = requestUnload(unloadIds[i])
      if r.outcome == aoDeferred: inc deferredCount
      if r.outcome == aoRequested: inc requested
      var e = obj()
      put(e, "id", unloadIds[i])
      put(e, "action", "unload")
      put(e, "outcome", outcomeName(r.outcome))
      put(e, "message", r.message)
      results.add e

    withModLock:
      # Tested and cleared in the same guarded region as it is set. A check on
      # one thread and a set on another, either side of an unlocked gap, is
      # exactly the lost update this flag exists to prevent.
      again = gApplyAgain
      gApplyAgain = false
      if not again:
        gApplying = false

  var queued = false
  var control = ""
  var pending = false
  withModLock:
    gPending = deferredCount > 0
    pending = gPending
    control = stateName(controlState())
    queued = gAdoptQueued
    gAdoptQueued = false

  if queued:
    # A refresh landed while this was running. Taken now, with no request out
    # and nothing walking the old resolution -- and outside the lock, because
    # adopting re-reads a file and broadcasts.
    doAdoptRegistry()

  var o = obj()
  put(o, "ok", true)
  put(o, "requested", requested)
  put(o, "deferred", deferredCount)
  put(o, "restartRequired", pending)
  put(o, "control", control)
  if passes > 1:
    # Said rather than hidden: a second pass means another request changed the
    # selection while this one was out, and the set finally stated is the later
    # one. Somebody reading two answers that both say `ok` deserves to know
    # which of them described the last word.
    put(o, "passes", passes)
  put(o, "results", results)
  if deferredCount > 0:
    put(o, "note", "the selection is saved; " & $deferredCount & " change(s) " &
                   "cannot take effect until the host restarts")
  result = o

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc routeStatus(url, body, session: string): string =
  var text = ""
  withModLock:
    var o = statusJson()
    put(o, "summary", summaryLine())
    text = done(o).text
  result = text

proc routeList(url, body, session: string): string =
  ## Read-only, and guarded anyway. A read while another thread rebuilds the
  ## resolution is the same bug as two writes: `gRes.order` and
  ## `gRes.decisions` are two seqs that are replaced one after the other, and a
  ## list assembled across that moment shows an order from before the change
  ## against verdicts from after it.
  var text = ""
  withModLock:
    var a = arr()
    for d in gRes.decisions:
      a.add decisionJson(d)
    var order = arr()
    for id in gRes.order:
      order.add id
    var o = obj()
    put(o, "ok", true)
    put(o, "side", gRes.side)
    put(o, "order", order)
    put(o, "mods", a)
    put(o, "problems", problemsJson())
    text = done(o).text
  result = text

proc routePanel(url, body, session: string): string =
  ## What the in-game overlay polls, once a second, from a worker thread inside
  ## the game process.
  ##
  ## The scalar fields come first and the `mods` array last, deliberately: the
  ## overlay's reader finds the `"mods"` key and starts scanning objects from
  ## there, and a wrapper key placed after the array would be read as part of the
  ## last row. It costs nothing to keep the order and it is the difference
  ## between a tolerant reader and a lucky one.
  ##
  ## Guarded whole. This one is polled once a second by the overlay while
  ## somebody is clicking switches in it, so it is the read most likely to be in
  ## flight when the resolution is replaced -- and a panel that draws half of
  ## one selection and half of the next is the exact symptom nobody would think
  ## to report as a race.
  var text = ""
  withModLock:
    var a = arr()
    for d in gRes.decisions:
      # `unknown` is a list naming a mod the registry does not have. It has no
      # version, no artifact and nothing to toggle, so it is a problem rather
      # than a row -- it is already in `problems` and on `/conflicts`.
      # Internal mods are omitted from the PANEL and from nowhere else. The
      # row is gone; the mod is not. See `isInternal`.
      if d.verdict != vUnknown and not isInternal(d.id):
        a.add panelRow(d)
    var o = obj()
    put(o, "ok", true)
    put(o, "schema", "aowlspt.panel/1")
    put(o, "side", gRes.side)
    put(o, "control", stateName(controlState()))
    put(o, "liveKnown", liveKnown())
    # The other host, in one line. `clientHost` is the only one of these the
    # panel needs to draw anything; the rest are here because "the client host
    # has never polled", "it polls and says nothing" and "it is saying it in
    # instalments" are three different reasons for a row to read unknown, and a
    # panel that cannot tell them apart makes the person looking at it guess.
    put(o, "clientHost", clientReporting())
    put(o, "clientSession", clientSession())
    put(o, "clientSeq", clientSeq())
    put(o, "clientRows", clientRows())
    put(o, "clientMore", clientMore())
    put(o, "summary", summaryLine())
    put(o, "mods", a)
    text = done(o).text
  result = text

proc routeClient(url, body, session: string): string =
  ## What the *client* host polls, from inside the game, so that it can make
  ## itself match this manager's decisions while the game runs.
  ##
  ## It exists because the panel route cannot answer this question. The panel is
  ## `gRes`, which is this manager's resolution **on the side it is running on**
  ## -- the server. On that resolution every client-only mod is `wrong-side`,
  ## which reads as `enabled:false`, and a client host obeying it would unload
  ## every mod it has. So this route resolves again, with `client` as the side,
  ## and answers that instead. Same registry, same selection, same rules, one
  ## argument different: the resolution is a function, which is what makes
  ## asking it twice honest rather than a second implementation.
  ##
  ## The path tail, if there is one, is the client host's own version, used for
  ## the `pipeline` range check. Without it the range would be matched against
  ## the *backend's* version, which is a different program that is allowed to be
  ## at a different version -- and a client mod excluded because the server is
  ## too old is a wrong answer that looks like a correct one.
  ##
  ## The shape is what `parseDesired` in `host/common/modcontrol.nim` reads:
  ##
  ##   {"ok":true,"schema":"aowlspt.clientset/1","side":"client","count":3,
  ##    "mods":[{"guid":"aowl.fovfix","enabled":true,"dir":"fov",
  ##             "lib":"fov.dll","name":"FOV Fix","verdict":"loaded",
  ##             "reason":"enabled by aowl.list.vanillaplus"}],
  ##    "complete":true}
  ##
  ## `count` and the trailing `complete` are not decoration. The reader on the
  ## other end is fed by a fixed buffer inside the game process, and a body that
  ## overflowed it would parse perfectly and say that the mods which did not fit
  ## should be unloaded. Two independent ways to notice a short body cost eleven
  ## bytes and remove the only way this route can do damage.
  ##
  ## `dir` and `lib` are the artifact's *relative* location, never a path. The
  ## server's mods directory and the client's are two directories on two
  ## machines and the client is the only one that knows where its own is.
  ##
  ## Resolved under the lock and answered from a string. The client host
  ## polls this every few seconds and unloads whatever it says to unload, so
  ## a body assembled while the registry was being replaced is not a display
  ## bug over there -- it is mods coming out of the running game.
  var text = ""
  withModLock:
    # The tail is split at the `?` before anything reads it. Everything to the
    # right is the host's *report* -- see `mgr/clientreport.nim` -- and
    # everything to the left is the version. They were one string until the
    # report existed, and leaving them one would have `1.2.3?hs=ab&sq=4` go into
    # `parseVersion`, fail, and take every `pipeline` range with it.
    var clientVersion = pathAfter(url, "/aowlspt/mods/client/")
    var query = ""
    for i in 0 ..< clientVersion.len:
      if clientVersion[i] == '?':
        query = clientVersion.substr(i + 1)
        clientVersion = clientVersion.substr(0, i - 1)
        break
    # Read, and then *nothing else changes*. The query is a report, not a
    # filter: the body below is the same body the bare route serves, because a
    # manager that answered a filtered set to a reporting host would have the
    # report change the thing it reports on -- and the host would then act on
    # the filtered answer, unload what it had just told the truth about, and
    # report that too.
    discard ingestClientReport(query)
    var ids: seq[string] = @[]
    var flags: seq[bool] = @[]
    let overrides = allOverrides()
    for ov in overrides:
      ids.add ov.id
      flags.add ov.enabled
    let res = resolve(gRegistry, activeLists(), ids, flags, "client",
                      (if clientVersion.len > 0: clientVersion else: hostVersion()))

    var a = arr()
    var n = 0
    for d in res.decisions:
      # `unknown` is a list naming a mod the registry does not have: no artifact,
      # nothing to load, and already reported as a problem. Everything else is a
      # row, `wrong-side` included -- a server-only mod resolves to
      # `enabled:false` on the client, which is precisely the instruction the
      # client host should be given about it.
      if d.verdict == vUnknown:
        continue
      var dir = ""
      var lib = ""
      var name = d.name
      var idx = -1
      if findMod(gRegistry, d.id, idx):
        let m = gRegistry.mods[idx]
        dir = m.artifactDir
        lib = m.artifactLib
        if name.len == 0:
          name = m.name
      var o = obj()
      put(o, "guid", d.id)
      put(o, "enabled", d.verdict == vLoaded)
      put(o, "dir", dir)
      put(o, "lib", lib)
      put(o, "name", name)
      put(o, "verdict", verdictName(d.verdict))
      put(o, "reason", d.reason)
      a.add o
      n = n + 1

    var out1 = obj()
    # `ok` is the registry's, not the resolution's: a resolution with conflicts is
    # still a usable answer and the excluded mods are excluded on purpose. A
    # registry that could not be read is not, and the client host must do nothing
    # rather than unload everything the manager cannot currently name.
    put(out1, "ok", gRegistry.ok)
    put(out1, "schema", "aowlspt.clientset/1")
    put(out1, "side", "client")
    put(out1, "hostVersion", (if clientVersion.len > 0: clientVersion
                              else: hostVersion()))
    if not gRegistry.ok:
      put(out1, "error", gRegistry.error)
    put(out1, "count", n)
    put(out1, "mods", a)
    # Whether a raid is in progress, for the client host's graphics post-process
    # gate. Sourced from the tarkov mod's raid start/end events (see
    # mgr/control.nim). An older host ignores the field; a newer one reads it.
    put(out1, "inRaid", raidActive())
    # What the main menu's bottom-right corner label should say (stock: "PVE
    # ZONE"). Empty means "nothing to say", and the host then leaves the stock
    # label alone. A mod's `setMenuModeText` override wins over the logged-in
    # character's name; see mgr/control.nim. Older hosts ignore the field.
    put(out1, "menuModeText", menuModeText())
    # Bot navigation commands for the client host's nav API, as a flat scalar
    # ("7|213.5|1.4|-58.2|2|1|30000;all|stop"). Empty means "no commands" and
    # the host leaves every bot to its own brain. A flat string rather than an
    # array so the host can gate its length and charset in one place before its
    # grammar ever sees it -- see `parseBotNav`. Older hosts ignore the field.
    put(out1, "botNav", botNavSpec())
    # Last, always. This is the terminator the reader checks for.
    put(out1, "complete", true)
    text = done(out1).text
  # OUTSIDE the lock, on purpose: this runs subscribers' handlers on this thread,
  # and a mod's census handler running under the mod lock could deadlock the very
  # route the client host depends on. It is also a no-op unless a new census
  # actually arrived on this poll.
  emitBotCensusIfChanged(clientBotNavCount(), clientBotNav())
  result = text

proc routeClientReport(url, body, session: string): string =
  ## The ledger the client host has sent up, exactly as this manager holds it.
  ##
  ## Not needed to draw the panel — `/panel` carries the same facts per row —
  ## and here for the two questions the panel cannot be asked: *which* guids
  ## this manager has an answer for, and what it thinks the answer means. A row
  ## that reads "unknown" in the game is either a mod the host has not got to
  ## yet or a mod this manager threw the record away for, and there is no other
  ## way to tell those apart from outside the process.
  ##
  ## Only rows there are records for. A guid that is absent is absent
  ## everywhere, which is the same statement this route exists to make legible.
  var text = ""
  withModLock:
    var a = arr()
    for d in gRes.decisions:
      if not clientKnows(d.id):
        continue
      var o = obj()
      put(o, "id", d.id)
      put(o, "guid", d.id)
      put(o, "outcome", clientOutcomeName(clientOutcomeOf(d.id)))
      put(o, "letter", clientOutcomeLetter(clientOutcomeOf(d.id)))
      put(o, "want", clientWants(d.id))
      put(o, "running", clientRunning(d.id))
      put(o, "settled", clientSettled(d.id))
      put(o, "restart", clientNeedsRestart(d.id))
      put(o, "code", clientCodeOf(d.id))
      put(o, "message", clientMessage(d.id))
      a.add o
    var o = obj()
    put(o, "ok", true)
    put(o, "schema", "aowlspt.clientreport/1")
    # `reporting:false` is the state that matters and the one worth reading
    # first: no client host has said anything, so every mod is unknown, and a
    # reader that skipped to `mods` and found it empty would have to guess
    # whether that meant "nothing to say" or "nothing running".
    put(o, "reporting", clientReporting())
    put(o, "session", clientSession())
    put(o, "seq", clientSeq())
    put(o, "seqKnown", clientSeqKnown())
    # True when the last report left rows out. They arrive on later polls: the
    # host rotates rather than prioritises, and nothing here acknowledges
    # anything.
    put(o, "more", clientMore())
    put(o, "rows", clientRows())
    put(o, "reports", clientReports())
    # Polls that carried no usable report at all: an older host, or one with no
    # session. Counted because "the client host is not there" and "the client
    # host is there and silent" look identical in `rows` and are not the same
    # problem.
    put(o, "silentPolls", clientBarePolls())
    put(o, "sessions", clientSessions())
    # The client host's live bot registry, verbatim as it reported it:
    # `id,role,difficulty,alive,x,y,z,lastNavStatus` per bot, `!`-separated.
    # `botNavPolls` is 0 until a host with the nav API on has reported at least
    # once, which is how a reader tells "no bots in the raid" from "no host has
    # ever said anything about bots".
    put(o, "botNav", clientBotNav())
    put(o, "botNavPolls", clientBotNavCount())
    put(o, "mods", a)
    text = done(o).text
  result = text

proc routeLists(url, body, session: string): string =
  ## Guarded: `gRegistry.lists` is replaced wholesale by a reload or an
  ## adopted refresh, and this walks it entry by entry.
  var text = ""
  withModLock:
    var active = arr()
    let act = activeLists()
    for l in act:
      active.add l
    var a = arr()
    for li in 0 ..< gRegistry.lists.len:
      # Bound to locals, and the nested seqs copied out, one field at a time.
      # `for p in l.inherits` where `l` is itself a loop variable over a seq of
      # objects miscompiles in nimony -- the generated C names a field the struct
      # does not have. It fails at the C compiler rather than silently, but it
      # costs an hour if you do not know to look for it.
      let l = gRegistry.lists[li]
      let inherits = l.inherits
      let listEntries = l.entries
      var inh = arr()
      for p in inherits:
        inh.add p
      var entries = arr()
      for e in listEntries:
        var eo = obj()
        put(eo, "id", e.id)
        put(eo, "enabled", e.enabled)
        if e.note.len > 0:
          put(eo, "note", e.note)
        entries.add eo
      var o = obj()
      put(o, "id", l.id)
      put(o, "name", l.name)
      put(o, "author", l.author)
      put(o, "version", l.version)
      put(o, "description", l.description)
      put(o, "inherits", inh)
      put(o, "entries", entries)
      # Yours or the registry's. It is the difference between a list a refresh
      # can replace and one it cannot touch, which is the thing a person most
      # needs to know before they edit one.
      put(o, "local", l.local)
      a.add o
    var out1 = obj()
    put(out1, "ok", true)
    put(out1, "active", active)
    put(out1, "lists", a)
    text = done(out1).text
  result = text

proc routeConflicts(url, body, session: string): string =
  ## Only what is wrong. The list route answers "what is loading"; this one
  ## answers "what did I do that did not work", which is a different question
  ## and the one asked at two in the morning.
  var text = ""
  withModLock:
    var a = arr()
    for d in gRes.decisions:
      let interesting = not (d.verdict == vLoaded or d.verdict == vNotSelected or
                             d.verdict == vDisabled or d.verdict == vWrongSide)
      if interesting:
        a.add decisionJson(d)
    var o = obj()
    put(o, "ok", a.len == 0 and gRes.problems.len == 0)
    put(o, "excluded", a)
    put(o, "problems", problemsJson())
    text = done(o).text
  result = text

proc describeLocked(url, body: string): string =
  ## Assumes the lock. A worker rather than the route itself, because it
  ## refuses in three places and a `return` out of a guarded region is a lock
  ## that is never given back.
  let id = idFrom(url, "/aowlspt/mods/describe/", body)
  if id.len == 0:
    return errorBody("name a mod: /aowlspt/mods/describe/<id>")
  let bad = idFault(id)
  if bad.len > 0:
    return errorBody(bad)
  var idx = -1
  if not findMod(gRegistry, id, idx):
    return errorBody("no mod called " & id & " in " & gRegistryPath)
  let m = gRegistry.mods[idx]
  var sides = arr()
  for s in m.sides:
    sides.add s
  var reqs = arr()
  for r in m.requires:
    var ro = obj()
    put(ro, "id", r.id)
    put(ro, "version", r.versionRange)
    reqs.add ro
  var cons = arr()
  for c in m.conflicts:
    var co = obj()
    put(co, "id", c.id)
    put(co, "reason", c.reason)
    cons.add co
  var provides = arr()
  for p in m.provides:
    provides.add p
  var after = arr()
  for a in m.loadAfter:
    after.add a
  var o = obj()
  put(o, "ok", true)
  put(o, "id", m.id)
  put(o, "name", m.name)
  put(o, "author", m.author)
  put(o, "version", m.version)
  put(o, "description", m.description)
  put(o, "pipeline", m.pipeline)
  put(o, "sides", sides)
  put(o, "license", m.license)
  put(o, "sourceKind", m.sourceKind)
  put(o, "sourcePath", m.sourcePath)
  put(o, "sourceUrl", m.sourceUrl)
  put(o, "downloadUrl", m.downloadUrl)
  put(o, "downloadHash", m.downloadHash)
  put(o, "library", libraryPath(m.artifactDir, m.artifactLib))
  put(o, "requires", reqs)
  put(o, "conflicts", cons)
  put(o, "provides", provides)
  put(o, "loadAfter", after)
  # Empty for a mod with a readable config and for one with none at all --
  # the per-mod half of the summary in `problems`, so a panel showing one
  # row's detail can name the file and the byte.
  put(o, "configFault", modConfigFaultOf(m.id))
  var di = -1
  if decisionFor(gRes, m.id, di):
    put(o, "decision", decisionJson(gRes.decisions[di]))
  result = done(o).text

proc routeDescribe(url, body, session: string): string =
  var text = ""
  withModLock:
    text = describeLocked(url, body)
  result = text

proc changeReply(id: string; what: string): string =
  ## The answer to enable/disable/clear: what changed, what it resolves to now,
  ## and — the part that has to be honest — whether that is in effect.
  var o = obj()
  put(o, "ok", true)
  put(o, "id", id)
  put(o, "action", what)
  var di = -1
  if decisionFor(gRes, id, di):
    put(o, "decision", decisionJson(gRes.decisions[di]))
  put(o, "loaded", gRes.order.len)
  put(o, "control", stateName(controlState()))
  # Whether the change is on disk, said on the change rather than only on
  # `/aowlspt/mods`. `afterChange` recomputes and announces whether or not the
  # write landed, so without this the answer to "did that stick" is the same
  # `ok:true` either way, and the difference only shows up at the next start.
  put(o, "persisted", storeWorks())
  if not storeWorks():
    put(o, "persistWarning", "the store would not take it, so this change is " &
                             "in effect for this run only")
  if controlState() == csPresent:
    put(o, "inEffect", "apply it with /aowlspt/mods/apply")
  else:
    put(o, "inEffect", "saved, but this host cannot load or unload a mod " &
                       "while it runs; it takes effect on the next start")
  put(o, "problems", problemsJson())
  result = done(o).text

proc overrideLocked(url, prefix, body: string; on: bool; outId: var string;
                    outErr: var string): bool =
  ## Set one override, under the lock. True when it was set and the caller owes
  ## an `afterChange`; false with `outErr` filled in when it was refused.
  ##
  ## Everything from the lookup to the write is inside one guarded region on
  ## purpose. "Is this mod in the registry", "may the store be written" and
  ## "write it" are one decision: another thread adopting a fetched registry
  ## between the first and the third turns a check that passed into a write
  ## that should not have happened.
  outId = ""
  outErr = ""
  let id = idFrom(url, prefix, body)
  if id.len == 0:
    outErr = "name a mod: " & prefix & "<id>"
    return false
  let bad = idFault(id)
  if bad.len > 0:
    outErr = bad
    return false
  var idx = -1
  if not findMod(gRegistry, id, idx):
    outErr = "no mod called " & id & " in " & gRegistryPath &
             ". This manager can only change mods its registry knows."
    return false
  let blocked = selectionBlocked()
  if blocked.len > 0:
    outErr = blocked
    return false
  if not setOverride(id, on):
    outErr = "the override on " & id & " could not be saved; nothing was changed"
    return false
  outId = id
  result = true

proc routeEnable(url, body, session: string): string =
  var id = ""
  var why = ""
  var changed = false
  withModLock:
    changed = overrideLocked(url, "/aowlspt/mods/enable/", body, true, id, why)
  if not changed:
    return errorBody(why)
  # Outside the lock: it writes a file and broadcasts to every other mod.
  afterChange()
  var text = ""
  withModLock:
    text = changeReply(id, "enable")
  result = text

proc disableLocked(url, body: string; outId: var string;
                   outErr: var string): bool =
  outId = ""
  outErr = ""
  let id = idFrom(url, "/aowlspt/mods/disable/", body)
  if id.len == 0:
    outErr = "name a mod: /aowlspt/mods/disable/<id>"
    return false
  let bad = idFault(id)
  if bad.len > 0:
    outErr = bad
    return false
  if isProtected(id):
    outErr = id & " is what you are using to ask. Switching it off takes " &
             "every /aowlspt/mods route with it, and nothing running could " &
             "switch it back on -- not even a restart, because the selection " &
             "would be on disk. Remove it from the install if you want it gone."
    return false
  # The lookup that was missing. Without it `/disable/<anything>` wrote an
  # override for a mod that does not exist -- so a typo, or a click on a panel
  # row the *client* host pushed in, left a permanent entry naming nothing in
  # the player's selection store, one per attempt, and it stayed there. `enable`
  # and `clear` both refused an unknown id and this one did not.
  var idx = -1
  if not findMod(gRegistry, id, idx):
    outErr = "no mod called " & id & " in " & gRegistryPath &
             ". This manager can only change mods its registry knows."
    return false
  let blocked = selectionBlocked()
  if blocked.len > 0:
    outErr = blocked
    return false
  if not setOverride(id, false):
    outErr = "the override on " & id & " could not be saved; nothing was changed"
    return false
  outId = id
  result = true

proc routeDisable(url, body, session: string): string =
  var id = ""
  var why = ""
  var changed = false
  withModLock:
    changed = disableLocked(url, body, id, why)
  if not changed:
    return errorBody(why)
  afterChange()
  var text = ""
  withModLock:
    text = changeReply(id, "disable")
  result = text

proc clearLocked(url, body: string; outId: var string;
                 outErr: var string): bool =
  outId = ""
  outErr = ""
  let id = idFrom(url, "/aowlspt/mods/clear/", body)
  if id.len == 0:
    outErr = "name a mod: /aowlspt/mods/clear/<id>"
    return false
  let bad = idFault(id)
  if bad.len > 0:
    outErr = bad
    return false
  let blocked = selectionBlocked()
  if blocked.len > 0:
    outErr = blocked
    return false
  if not clearOverride(id):
    outErr = id & " has no override to clear; the active lists decide it"
    return false
  outId = id
  result = true

proc routeClear(url, body, session: string): string =
  var id = ""
  var why = ""
  var changed = false
  withModLock:
    changed = clearLocked(url, body, id, why)
  if not changed:
    return errorBody(why)
  afterChange()
  var text = ""
  withModLock:
    text = changeReply(id, "clear")
  result = text

proc selectOneLocked(url: string; outId: var string;
                     outErr: var string): bool =
  outId = ""
  outErr = ""
  let id = pathAfter(url, "/aowlspt/mods/select/")
  if id.len == 0:
    outErr = "name a list: /aowlspt/mods/select/<list-id>"
    return false
  let bad = idFault(id)
  if bad.len > 0:
    outErr = bad
    return false
  var idx = -1
  if not findList(gRegistry, id, idx):
    outErr = "no list called " & id & " in " & gRegistryPath
    return false
  let blocked = selectionBlocked()
  if blocked.len > 0:
    outErr = blocked
    return false
  var one: seq[string] = @[]
  one.add id
  if not setLists(one):
    outErr = "the selection could not be saved; your active lists are unchanged"
    return false
  outId = id
  result = true

proc routeSelectOne(url, body, session: string): string =
  var id = ""
  var why = ""
  var changed = false
  withModLock:
    changed = selectOneLocked(url, id, why)
  if not changed:
    return errorBody(why)
  afterChange()
  var text = ""
  withModLock:
    var o = obj()
    put(o, "ok", true)
    put(o, "active", id)
    put(o, "loaded", gRes.order.len)
    put(o, "problems", problemsJson())
    text = done(o).text
  result = text

proc selectLocked(body: string; outErr: var string): bool =
  ## `{"lists":["a","b"]}` — the ordered set of active lists. Order matters:
  ## a later list's entries override an earlier one's for the same mod.
  ##
  ## The shape is checked before anything is set, and that is the whole of what
  ## makes this route safe. `{"lists":"vanilla"}`, `{"lists":{}}` and
  ## `{"lists":[1,2]}` all used to read as "an empty set of lists", because
  ## `each` over a non-array yields nothing and a non-string entry was skipped
  ## -- so a malformed request *emptied the player's selection* and answered
  ## `ok:true`. An empty array still means "nothing", because somebody typed it.
  outErr = ""
  let lists = field(body, "lists")
  if not lists.exists or lists.isNull:
    outErr = "send {\"lists\":[\"<list-id>\",...]}; an array of list ids, " &
             "empty if you mean none"
    return false
  if not lists.isArray:
    outErr = "\"lists\" has to be an array of list ids. It is not one here, " &
             "and a body this manager cannot read is never taken as \"turn " &
             "everything off\"."
    return false
  let given = each(lists)
  var wanted: seq[string] = @[]
  for g in given:
    let id = g.asText("")
    if id.len == 0:
      outErr = "every entry in \"lists\" has to be a non-empty list id; one " &
               "of them is not, and the selection is unchanged"
      return false
    let bad = idFault(id)
    if bad.len > 0:
      outErr = bad
      return false
    var idx = -1
    if not findList(gRegistry, id, idx):
      outErr = "no list called " & id & " in " & gRegistryPath
      return false
    wanted.add id
  let blocked = selectionBlocked()
  if blocked.len > 0:
    outErr = blocked
    return false
  if not setLists(wanted):
    outErr = "the selection could not be saved; your active lists are unchanged"
    return false
  result = true

proc routeSelect(url, body, session: string): string =
  var why = ""
  var changed = false
  withModLock:
    changed = selectLocked(body, why)
  if not changed:
    return errorBody(why)
  afterChange()
  var text = ""
  withModLock:
    var active = arr()
    let act = activeLists()
    for l in act:
      active.add l
    var o = obj()
    put(o, "ok", true)
    put(o, "active", active)
    put(o, "loaded", gRes.order.len)
    put(o, "problems", problemsJson())
    text = done(o).text
  result = text

proc routeReload(url, body, session: string): string =
  ## Re-read the registry from disk. This is what makes `git pull` in the
  ## registry checkout visible without restarting anything.
  ##
  ## Both steps are entry points that take the lock themselves, and neither is
  ## called from inside a guarded region: the read is disk and the change ends
  ## in a broadcast.
  discoverRegistry()
  afterChange()
  var text = ""
  withModLock:
    var o = statusJson()
    put(o, "reloaded", true)
    text = done(o).text
  result = text

proc routeApply(url, body, session: string): string =
  let o = applySelection()
  result = done(o).text

proc toggleLocked(url, body: string; outId: var string; outWant: var bool;
                  outErr: var string): bool =
  ## The decision half of a toggle, under the lock: what is it, what is it now,
  ## what should it be, may it be that, and write it. Reading the current
  ## verdict and writing the override in one guarded region is what makes two
  ## simultaneous toggles of the same mod end at one of the two states somebody
  ## asked for, rather than at a flip computed from a verdict the other one had
  ## already replaced.
  outId = ""
  outWant = false
  outErr = ""
  var id = pathAfter(url, "/aowlspt/mods/toggle/")
  if id.len == 0:
    id = field(body, "id").asText("")
  if id.len == 0:
    outErr = "name a mod: /aowlspt/mods/toggle/<id> with {\"enabled\":true}"
    return false
  let bad = idFault(id)
  if bad.len > 0:
    outErr = bad
    return false
  var idx = -1
  if not findMod(gRegistry, id, idx):
    # Said in full, because the overlay's panel also carries rows the *client*
    # host pushed in for mods loaded on the other side of the wire, and clicking
    # one of those lands here. That is a real situation and not a typo.
    outErr = "no mod called " & id & " in " & gRegistryPath &
             ". This manager can only change mods its registry knows; a mod " &
             "the client host loaded but the registry does not list has to be " &
             "added to the registry first."
    return false
  var want = false
  var di = -1
  if decisionFor(gRes, id, di):
    want = gRes.decisions[di].verdict == vLoaded
  want = not want
  if field(body, "enabled").exists:
    want = field(body, "enabled").asBool(want)
  if isProtected(id) and not want:
    outErr = id & " is what you are using to ask. Switching it off takes " &
             "every /aowlspt/mods route with it, and nothing running could " &
             "switch it back on -- not even a restart, because the selection " &
             "would be on disk. Remove it from the install if you want it gone."
    return false
  let blocked = selectionBlocked()
  if blocked.len > 0:
    outErr = blocked
    return false
  if not setOverride(id, want):
    outErr = "the override on " & id & " could not be saved; nothing was " &
             "changed and nothing was asked of the host"
    return false
  outId = id
  outWant = want
  result = true

proc routeToggle(url, body, session: string): string =
  ## Set one mod's override and immediately try to make it true. The overlay has
  ## one button per row and no `apply`, so a toggle that only recorded an
  ## intention would need a second gesture that the panel does not have -- and a
  ## panel with a button that does nothing you can see is worse than a panel
  ## with no button.
  ##
  ## `{"enabled":true|false}` in the body; with no `enabled` at all it flips,
  ## which is what a browser hitting the path can do.
  var id = ""
  var want = false
  var why = ""
  var changed = false
  withModLock:
    changed = toggleLocked(url, body, id, want, why)
  if not changed:
    return errorBody(why)
  afterChange()
  # Outside the lock, and it takes and drops it several times itself: every
  # request in it is a `broadcast` the host answers on this thread.
  let ap = applySelection()

  var text = ""
  withModLock:
    var o = obj()
    put(o, "ok", true)
    put(o, "id", id)
    put(o, "guid", id)
    put(o, "action", (if want: "enable" else: "disable"))
    put(o, "control", stateName(controlState()))
    var di2 = -1
    if decisionFor(gRes, id, di2):
      put(o, "row", panelRow(gRes.decisions[di2]))
    put(o, "apply", ap)
    text = done(o).text
  result = text

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc readConfig() =
  ## Reads `config.json`, and -- the part this was missing -- records *which
  ## kind of silence* it got when a key was not there.
  ##
  ## The whole document is fetched in one call (`setting("")` is documented by
  ## `aowlspt.nim` as the whole file, and every host implements it), and the
  ## **host** says whether it parsed. That is the fix for the class of bug
  ## rather than for the BOM: a per-key lookup can only ever answer "found" or
  ## "not found", and every way of making a config unparseable answers "not
  ## found" for every key in it. `ConfigValue.faulted` is the third answer, and
  ## a file that says nothing wants the opposite response to a file that says
  ## nothing *readable* -- the first is a default, the second is a refusal.
  ##
  ## The document is still parsed here, because a `activeLists` array is what
  ## this mod actually needs out of it -- but it is only parsed once the host
  ## has said it parses, and there is no longer any circumstance in which this
  ## mod's opinion of the file's readability can differ from the host's. It used
  ## to, and neither of them knew.
  let cfg = setting("")
  if cfg.faulted:
    # The bytes come back beside the fault, so the size is real even though the
    # document is not. `lastError()` is the host's sentence: the file it read
    # and the byte offset it stopped at.
    gCfgState = cfgUnreadable
    gCfgFault = "config.json in " & modDir() & " did not parse, so no setting " &
                "in it was read -- not `activeLists`, and not any of the " &
                "others either. The host says: " & lastError() &
                " Fix the file and restart; nothing of yours is lost, and " &
                "nothing will be written down on the strength of a file that " &
                "did not parse"
    return
  if cfg.raw.len == 0:
    gCfgState = cfgAbsent
    gCfgFault = "there is no readable config.json for this mod in " & modDir() &
                ", so nothing it would have said was read"
    return
  gCfgState = cfgOk
  gCfgFault = ""
  # No BOM strip and no structural check before this: the host drops the mark
  # in its own reader and has already validated what it handed over, so a
  # second pass here could only ever *disagree* with it.
  let doc = whole(cfg.raw)
  gProbeMs = doc.field("controlProbeMs").asInt(750)
  gWriteSelectionFile = doc.field("writeSelectionFile").asBool(true)
  let lists = doc.field("activeLists")
  if lists.exists and not lists.isNull and not lists.isArray:
    gCfgState = cfgListsBad
    gCfgFault = "config.json's \"activeLists\" is not an array of list ids"
    return
  let entries = each(lists)
  for e in entries:
    let id = e.asText("")
    if id.len > 0:
      gDefaultLists.add id
  gCfgNamedLists = gDefaultLists.len > 0

proc logSummary() =
  if not gRegistry.ok:
    warn "manager: " & gRegistry.error
  else:
    success "manager: " & gRegistryPath & " -- " & $gRegistry.mods.len &
            " mods, " & $gRegistry.lists.len & " lists"
  var activeText = ""
  let act = activeLists()
  for l in act:
    if activeText.len > 0: activeText.add ", "
    activeText.add l
  if activeText.len == 0:
    activeText = "(none)"
  info "manager: active lists: " & activeText
  info "manager: " & summaryLine()
  var pos = 1
  for id in gRes.order:
    info "manager:   " & $pos & ". " & id
    inc pos
  for d in gRes.decisions:
    if d.verdict == vLoaded or d.verdict == vNotSelected:
      continue
    info "manager:   - " & d.id & ": " & verdictName(d.verdict) & " -- " & d.reason
  for p in gRes.problems:
    warn "manager: " & p
  for w in gRegistry.warnings:
    warn "manager: " & w
  if gCfgState != cfgOk:
    error "manager: " & gCfgFault
  if gModCfgReport.len > 0:
    error "manager: " & gModCfgReport
    for i in 0 ..< gModCfgIds.len:
      error "manager:   - " & gModCfgIds[i] & ": " & gModCfgPaths[i] &
            " -- " & gModCfgWhy[i]
  if gForeignSelection.len > 0:
    warn "manager: " & gForeignSelection
  if not storeWorks():
    info "manager: nothing has been persisted yet; the selection is stored " &
         "on the first change"

proc registerRoutes() =
  discard serve("/aowlspt/mods", routeStatus)
  discard serve("/aowlspt/mods/status", routeStatus)
  discard serve("/aowlspt/mods/list", routeList)
  discard serve("/aowlspt/mods/panel", routePanel)
  discard serve("/aowlspt/mods/client", routeClient)
  discard serve("/aowlspt/mods/clientreport", routeClientReport)
  discard serve("/aowlspt/mods/toggle", routeToggle)
  discard serve("/aowlspt/mods/lists", routeLists)
  discard serve("/aowlspt/mods/conflicts", routeConflicts)
  discard serve("/aowlspt/mods/reload", routeReload)
  discard serve("/aowlspt/mods/apply", routeApply)
  discard serve("/aowlspt/mods/select", routeSelect)
  discard servePrefix("/aowlspt/mods/client/", routeClient)
  discard servePrefix("/aowlspt/mods/describe/", routeDescribe)
  discard servePrefix("/aowlspt/mods/enable/", routeEnable)
  discard servePrefix("/aowlspt/mods/disable/", routeDisable)
  discard servePrefix("/aowlspt/mods/clear/", routeClear)
  discard servePrefix("/aowlspt/mods/toggle/", routeToggle)
  discard servePrefix("/aowlspt/mods/select/", routeSelectOne)

proc currentRegistryPath(): string =
  ## Handed to `mgr/refresh` rather than reached for: the refresh module owns
  ## the network and this one keeps owning the registry, and neither has to be
  ## edited to change the other.
  result = gRegistryPath

proc adoptRegistry() =
  ## What `mgr/refresh` calls when it has a new registry to put in effect.
  ##
  ## Deferred while an apply is in flight. A refresh finishing in the middle of
  ## one would replace the registry and the resolution that apply is reading --
  ## the loads would be from one document and the unloads from another, and a
  ## mod the two disagree about would be left neither loaded nor unloaded with
  ## nothing in the answer to say so. `applySelection` takes the queued adopt
  ## the moment it is done, so nothing is lost, only ordered.
  ##
  ## An entry point -- it is called from the fetch's own path, which holds
  ## nothing -- so the test and the flag are both inside one guarded region.
  ## Testing `gApplying` outside the lock and setting `gAdoptQueued` after it is
  ## the check-then-act this exists to close: the apply can finish in between,
  ## and the queued adopt is then picked up by nobody.
  var deferred = false
  withModLock:
    if gApplying:
      gAdoptQueued = true
      deferred = true
  if deferred:
    info "manager: a registry refresh landed during an apply; it is adopted " &
         "as soon as the apply is done"
    return
  doAdoptRegistry()

proc onLoad(): Status =
  ## The one place that runs before any other thread can be in this mod: the
  ## host calls it once, and the routes below are not reachable until they are
  ## registered at the end of it. It still goes through the same entry points,
  ## because a lock taken on an uncontended critical section costs about twenty
  ## nanoseconds and a second, "startup only" path is a second thing to keep
  ## correct.
  readConfig()
  var document = ""
  var fault = ""
  withModLock:
    ensureLoaded(gDefaultLists)
  discoverRegistry()
  withModLock:
    recompute()
    captureBaseline()
    document = selectionDocument()
    gWriteFault = currentWriteFault()
    fault = gWriteFault
  # Before anything is written over it, and outside the lock: it is a file
  # read, and `gRes.side` is the only thing it needs, which is settled above.
  inspectSelectionFile()
  # Same shape, same reason, and after the resolution: it walks the mods this
  # run loads and reads a `config.json` in each of their directories.
  scanModConfigs()
  registerRoutes()
  # The probe goes out after the routes exist: a host that answers instantly
  # would otherwise be answered by a mod that cannot yet be asked anything.
  controlInit(gProbeMs)
  # After the routes and after the registry: `refreshInit` registers its own
  # routes and may start a fetch on the spot, and a fetch that landed before
  # there was a registry to compare against would have nothing to diff.
  refreshInit(currentRegistryPath, adoptRegistry)
  writeSelectionFileText(document, fault)
  var payload = ""
  withModLock:
    logSummary()
    payload = announceText()
  discard broadcast("aowlspt.mods.selection", payload)
  Ok

proc onUnload(): Status =
  var loaded = 0
  withModLock:
    loaded = gRes.order.len
  info "manager: unloading with " & $loaded & " mods resolved"
  refreshShutdown()
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = "aowlspt",
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
