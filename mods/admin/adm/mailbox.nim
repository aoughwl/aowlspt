## The item-spawner mailbox -- the nimony face of `AowlSpawnShared` in
## `abi/aowlspt_admin.h`.
##
## ---------------------------------------------------------------------------
## WHY THIS EXISTS AT ALL
## ---------------------------------------------------------------------------
##
## The item spawner is one feature living in two processes, and the split is
## forced, not chosen:
##
##   * The SEARCH and the SPAWN belong to the emulator, server-side. The item
##     set is 4,673 templates and the English locale is 2.7 MB in one JSON
##     object; `mods/tarkov/emu/spawn.nim` already scans it in a single linear
##     pass and already writes items into a stash, proven over the wire. A
##     second spawner in this mod would be a second thing to keep correct, so
##     there is not one and must never be one.
##   * The MENU is client-side, drawn in the game's own `Present`. It is the
##     only place a player can press anything.
##
## The client cannot reach the server-side mod directly. Measured, not assumed:
## `provide()` in `aowl/src/aowlspt/capability.nim` returns `ErrUnsupported`
## when `side()` is `sideClient` -- there is no server-side mod set in the game
## process for a capability to resolve against -- and the SDK exposes no HTTP
## client (`grep -n "http" aowl/src/aowlspt.nim` finds exactly one hit, a
## docstring on `serve`). So a capability `invoke` issued from the client would
## answer `no-provider` FOREVER, and would do it while the provider was sitting
## there loaded in the other process. That is the confidently-wrong answer this
## project keeps paying for, so the client does not make that call.
##
## What the client does instead is post an intent into a named shared section,
## which is a cross-PROCESS object on Windows, and the mod's own SERVER-side
## instance -- the same mod guid, loaded by the backend, where `invoke` reaches
## a real provider -- picks it up and answers.
##
## ---------------------------------------------------------------------------
## WHAT THIS COSTS THE UNITY THREAD
## ---------------------------------------------------------------------------
##
## Per frame, with no request outstanding: one `LONG` compare (`isBusy`) and
## nothing else. No allocation, no string work, no scan of anything. The whole
## point of pushing the search over the mailbox is that the client never holds
## the item set; it holds at most ten 72-byte result lines that the server
## already formatted.
##
## Reading a result back DOES allocate (a nimony `string` per line), so it is
## done ONCE, on the tick the answer arrives, and never per frame -- `poll()`
## returns a result only when `served` has advanced.

## The header is emitted into THIS translation unit as well. `{.emit.}` is
## per-module in nimony -- importing `shared` does NOT carry its include across
## -- and without this every `importc` below compiles as an implicit
## declaration, which gcc accepts with a warning and links to nothing.
{.emit: """#include "aowlspt_admin.h" """.}

type
  SpawnRegion* = pointer   ## an `AowlSpawnShared*`, opaque on this side

const
  spwKindNone*   = 0'i32
  spwKindSearch* = 1'i32
  spwKindItem*   = 2'i32
  spwKindPreset* = 3'i32

  ## These mirror `CapOutcome` in the SDK one for one. The taxonomy is the
  ## deliverable -- "the mod is installed and switched off" and "the mod is not
  ## installed" are different sentences to a player and must not be flattened.
  spwOutNone*            = 0'i32   ## nobody has answered YET -- INCONCLUSIVE
  spwOutOk*              = 1'i32
  spwOutProviderError*   = 2'i32
  spwOutVersionMismatch* = 3'i32
  spwOutProviderNotLoaded* = 4'i32
  spwOutProviderSilent*  = 5'i32
  spwOutNoProvider*      = 6'i32
  spwOutRosterUnknown*   = 7'i32
  spwOutBadReply*        = 8'i32
  spwOutUnavailable*     = 9'i32
  spwOutLocalRefused*    = 10'i32

  spwMaxLines* = 10

# --------------------------------------------------------------- C surface

proc cSpwMap(): SpawnRegion {.importc: "aowl_spawn_map", nodecl.}
proc cSpwValid(s: SpawnRegion): int32 {.importc: "aowl_spw_valid", nodecl.}
proc cSpwBusy(s: SpawnRegion): int32 {.importc: "aowl_spw_busy", nodecl.}
proc cSpwPost(s: SpawnRegion; kind: int32; query: cstring;
              count, presetIdx, condition: int32): int32 {.
  importc: "aowl_spw_post", nodecl.}
proc cSpwTake(s: SpawnRegion; kind, count, presetIdx, condition: ptr int32): int32 {.
  importc: "aowl_spw_take", nodecl.}
proc cSpwQueryLen(s: SpawnRegion): int32 {.importc: "aowl_spw_query_len", nodecl.}
proc cSpwQueryCh(s: SpawnRegion; i: int32): int32 {.
  importc: "aowl_spw_query_ch", nodecl.}
proc cSpwLine(s: SpawnRegion; i: int32; text: cstring) {.
  importc: "aowl_spw_line", nodecl.}
proc cSpwAnswer(s: SpawnRegion; outcome: int32; message: cstring;
                matched, shown, spawned: int32) {.
  importc: "aowl_spw_answer", nodecl.}
proc cSpwOutcome(s: SpawnRegion): int32 {.importc: "aowl_spw_outcome", nodecl.}
proc cSpwPolls(s: SpawnRegion): int32 {.importc: "aowl_spw_polls", nodecl.}
proc cSpwServed(s: SpawnRegion): int32 {.importc: "aowl_spw_served", nodecl.}
proc cSpwMatched(s: SpawnRegion): int32 {.importc: "aowl_spw_matched", nodecl.}
proc cSpwSpawned(s: SpawnRegion): int32 {.importc: "aowl_spw_spawned", nodecl.}
proc cSpwShown(s: SpawnRegion): int32 {.importc: "aowl_spw_shown", nodecl.}
proc cSpwMsgLen(s: SpawnRegion): int32 {.importc: "aowl_spw_msg_len", nodecl.}
proc cSpwMsgCh(s: SpawnRegion; i: int32): int32 {.importc: "aowl_spw_msg_ch", nodecl.}
proc cSpwLineLen(s: SpawnRegion; li: int32): int32 {.
  importc: "aowl_spw_line_len", nodecl.}
proc cSpwLineCh(s: SpawnRegion; li, i: int32): int32 {.
  importc: "aowl_spw_line_ch", nodecl.}

# --------------------------------------------------------------- public

proc mailboxMap*(): SpawnRegion =
  ## Map (or open) the spawner mailbox. NULL only if the OS refused, which is a
  ## no-spawner outcome rather than an error: every caller here treats NULL as
  ## "the spawner is unavailable this session" and SAYS so.
  cSpwMap()

proc mailboxValid*(s: SpawnRegion): bool = s != nil and cSpwValid(s) != 0'i32
proc mailboxBusy*(s: SpawnRegion): bool = s != nil and cSpwBusy(s) != 0'i32

proc mailboxPolls*(s: SpawnRegion): int =
  if s == nil: 0 else: int(cSpwPolls(s))
proc mailboxServed*(s: SpawnRegion): int =
  if s == nil: 0 else: int(cSpwServed(s))

proc outcomeText*(o: int32): string =
  ## The refusal taxonomy in words. Kept here rather than only in C because the
  ## Nim side puts it in the log and in `adminDiag()`, and one spelling of a
  ## refusal is the difference between a diagnosis and a shrug.
  case o
  of spwOutOk:                "ok"
  of spwOutProviderError:     "provider-error"
  of spwOutVersionMismatch:   "version-mismatch"
  of spwOutProviderNotLoaded: "provider-not-loaded"
  of spwOutProviderSilent:    "provider-silent"
  of spwOutNoProvider:        "no-provider"
  of spwOutRosterUnknown:     "roster-unknown"
  of spwOutBadReply:          "bad-reply"
  of spwOutUnavailable:       "unavailable"
  of spwOutLocalRefused:      "local-refused"
  else:                       "never-answered"

proc outcomeIsRefusal*(o: int32): bool =
  ## `spwOutNone` is deliberately NOT a refusal: nothing has answered yet, and
  ## calling that a refusal would make a mailbox nobody is listening to read as
  ## "no such item". Three outcomes, never two.
  o != spwOutOk and o != spwOutNone

# ---- requester (the client) ----

proc postSearch*(s: SpawnRegion; query: string): bool =
  ## Ask the server to look `query` up and spawn NOTHING. Returns false when
  ## the mailbox is busy or absent -- never queues, never overwrites an
  ## outstanding request, because answering request N with N+1's result is
  ## exactly the false positive that looks like success.
  if not mailboxValid(s): return false
  var q = query
  cSpwPost(s, spwKindSearch, toCString(q), 0'i32, -1'i32, 100'i32) != 0'i32

proc postItem*(s: SpawnRegion; query: string; count, condition: int): bool =
  if not mailboxValid(s): return false
  var q = query
  var n = count
  if n < 1: n = 1
  if n > 5000: n = 5000          ## the emulator's own cap; refuse locally too
  var c = condition
  if c < 1: c = 1
  if c > 100: c = 100
  cSpwPost(s, spwKindItem, toCString(q), int32(n), -1'i32, int32(c)) != 0'i32

proc postPreset*(s: SpawnRegion; idx: int): bool =
  if not mailboxValid(s): return false
  var empty = ""
  cSpwPost(s, spwKindPreset, toCString(empty), 0'i32, int32(idx), 100'i32) != 0'i32

# ---- reading an answer (allocates; call once per answer, never per frame) ----

proc readMessage*(s: SpawnRegion): string =
  result = ""
  if not mailboxValid(s): return
  let n = int(cSpwMsgLen(s))
  var i = 0
  while i < n:
    let c = int(cSpwMsgCh(s, int32(i)))
    if c == 0: break
    result.add char(c)
    inc i

proc readLine*(s: SpawnRegion; li: int): string =
  result = ""
  if not mailboxValid(s): return
  if li < 0 or li >= spwMaxLines: return
  let n = int(cSpwLineLen(s, int32(li)))
  var i = 0
  while i < n:
    let c = int(cSpwLineCh(s, int32(li), int32(i)))
    if c == 0: break
    result.add char(c)
    inc i

proc readOutcome*(s: SpawnRegion): int32 =
  if s == nil: spwOutNone else: cSpwOutcome(s)
proc readMatched*(s: SpawnRegion): int =
  if s == nil: 0 else: int(cSpwMatched(s))
proc readSpawned*(s: SpawnRegion): int =
  if s == nil: 0 else: int(cSpwSpawned(s))
proc readShown*(s: SpawnRegion): int =
  if s == nil: 0 else: int(cSpwShown(s))

# ---- dispatcher (the backend) ----

type Request* = object
  present*: bool
  kind*: int32
  query*: string
  count*: int
  presetIdx*: int
  condition*: int

const QueryCap = 96

proc takeRequest*(s: SpawnRegion): Request =
  ## One poll. Bumps the liveness counter whether or not there was a request --
  ## that counter is what lets the client tell "nobody is listening" apart from
  ## "the answer was no", which are the same silence otherwise.
  result = Request(present: false, kind: spwKindNone, query: "", count: 0,
                   presetIdx: -1, condition: 100)
  if not mailboxValid(s): return
  var kind = 0'i32
  var count = 0'i32
  var idx = -1'i32
  var cond = 100'i32
  if cSpwTake(s, addr kind, addr count, addr idx, addr cond) == 0'i32:
    return
  result.present = true
  result.kind = kind
  result.count = int(count)
  result.presetIdx = int(idx)
  result.condition = int(cond)
  let n = int(cSpwQueryLen(s))
  var i = 0
  while i < n and i < QueryCap:
    let c = int(cSpwQueryCh(s, int32(i)))
    if c == 0: break
    result.query.add char(c)
    inc i

proc answer*(s: SpawnRegion; outcome: int32; message: string;
             matched, shown, spawned: int) =
  if not mailboxValid(s): return
  var m = message
  cSpwAnswer(s, outcome, toCString(m), int32(matched), int32(shown),
             int32(spawned))

proc setLine*(s: SpawnRegion; i: int; text: string) =
  if not mailboxValid(s): return
  var t = text
  cSpwLine(s, int32(i), toCString(t))
