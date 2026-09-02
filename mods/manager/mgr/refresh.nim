## Refreshing the registry from a URL — metadata only, opt-in, and unable to
## make anything worse.
##
## The registry wants to live in a repository of its own (`registry/README.md`).
## Once it does, the copy on a player's disk is a snapshot of somebody else's
## git history, and the only way to move it forward today is to ship a new
## build. This module is the other way: fetch `mods.json`, check it, and adopt
## it if — and only if — it survives every check the publisher's own gate makes.
##
## ## What this deliberately does not do
##
## **It never downloads a mod binary, and it refuses a registry that carries
## one.** A `download` block with a URL and a hash is in the schema, and it is
## in the schema on purpose: the shape has to exist before anything can be built
## on it. But *acting* on it means pulling a DLL off the internet and loading it
## into a process injected into a running game, and that is a decision about
## what this project is, not a feature to add on the way past. So a fetched
## registry whose entries carry `download` blocks is refused whole, by name,
## with that sentence — `registry/README.md` keeps it as an open question
## addressed to the person whose call it is.
##
## The refusal is on the *fetch* path only. A `download` in the registry that
## shipped with the build is fine; it came in with a build somebody chose to
## install. It is the combination — a document from the network, describing a
## binary from the network — that is refused.
##
## And the claim is "nothing *fetches* it", not "nothing reads it": the block is
## parsed by `mgr/registry.nim`, checked by `registry/validate.nim`, and served
## straight back by `/aowlspt/mods/describe/<id>` as `downloadUrl` and
## `downloadHash`. Reading it and printing it is how somebody decides what to go
## and get; what nothing here does is go and get it.
##
## ## Off unless asked
##
## `registryFetchEnabled` is `false` in `config.json` and there is no default
## URL. With no URL there is nothing to fetch, and with `enabled` false the
## route answers what it would have done and does nothing. Two switches rather
## than one because "I configured a URL to try later" and "fetch from it" are
## different intentions, and a URL that starts fetching the moment it is typed
## is a surprise.
##
## ## Newer is not better
##
## Every one of these leaves the current registry exactly where it is and says
## so:
##
##  * the fetch is off, or no URL is set;
##  * `registryPath` in config points at a checkout you manage — then the file
##    this would write is not the file the manager reads, and "adopted" would
##    be a lie; `git pull` and `/aowlspt/mods/reload` is the honest answer;
##  * the transport failed, timed out, was refused, or answered anything but
##    200;
##  * the body was longer than `registryFetchMaxBytes` and was cut short. A
##    truncated registry parses — it just has fewer mods in it than the
##    publisher wrote, and looks complete;
##  * the document is not JSON, or not an object;
##  * `schema` is a string this build does not implement;
##  * `registry/validate.nim` reported any failure at all — the same rules, the
##    same code, that `aowl-regcheck --file` runs for the publisher;
##  * any entry carries a `download` block (above);
##  * it declares a `revision` lower than the one in effect. Going backwards is
##    a rollback, which is a thing somebody might well want, so
##    `/aowlspt/mods/registry/fetch/force` does it — but not by accident, and
##    not silently.
##
## ## What a refresh does to your own lists
##
## Nothing. They are in the selection store, not in the manifest
## (`mgr/selection.nim`), and `withLocalLists` merges them back in after the new
## file is read. What a refresh *can* do is leave one of them naming a mod that
## no longer exists, and that is reported: the answer names every id in your
## active lists, your overrides and your own lists that the new registry does
## not define. Reported, never repaired — editing somebody's list to make it
## resolve is the silent edit this is all arranged against.

import std/[syncio, dirs, paths]
import std/errorcodes/errorcodes
import aowlspt
import aowlspt/server
import aowlspt/json
import aowlspt/sync
import registry
import selection
import httpfetch
import aowlspt/regvalidate

const
  AdoptedName = "mods.json"
  ## `dataDir()/mods.json` is the *first* place `registryCandidates()` looks
  ## after an explicit `registryPath`. Writing the adopted copy there is what
  ## makes a refresh survive a restart, and deleting it is what reverts — so
  ## "undo" is a file operation a person can also do by hand, rather than a
  ## second piece of state that can disagree with the first.

type
  PathFn* = nil proc (): string
    ## `nil proc` because nimony's proc types are non-nil by default, and this
    ## has to be nil until `refreshInit` runs. Same reason and same spelling as
    ## `host/common/modcontrol.nim`'s function table.
  AdoptFn* = nil proc ()

  Outcome* = enum
    ocNever      ## nothing has been attempted
    ocFetching
    ocAdopted
    ocRefused

var gEnabled = false
var gUrl = ""
var gTimeoutMs = 8000
var gMaxBytes = 4000000
var gPinnedPath = false     ## `registryPath` is set, so nothing here can apply
var gFetch: Fetch = Fetch(state: fsIdle, job: nil, url: "", ok: false,
                          status: 0, error: "", truncated: false, body: "")
var gForce = false
var gOutcome = ocNever
var gMessage = "no refresh has been attempted"
var gWhenMs: int64 = 0
var gReasons: seq[string] = @[]
var gAdded: seq[string] = @[]
var gRemoved: seq[string] = @[]
var gBumped: seq[string] = @[]
var gOrphans: seq[string] = @[]
var gFromRevision = -1
var gToRevision = -1
var gPathOf: PathFn = nil
var gAdopt: AdoptFn = nil
var gRunning = false
  ## The guarded mirror of `gFetch.state == fsRunning`, for the threads that are
  ## not the one doing the work. `gFetch` itself carries a body of up to four
  ## megabytes and is assigned wholesale by whoever owns the claim; reading it
  ## from a route to find out whether a fetch is out would be reading a struct
  ## mid-assignment to answer a question one bool can answer.
var gBusy = false
  ## One thread is inside the fetch: polling it, validating a candidate, or
  ## writing it out. Claimed under the mod lock and held for the whole of that
  ## work, which is the only reason `gFetch` and the fields below can be touched
  ## without it -- exactly one thread is entitled to them at a time, and the
  ## claim is what says which.

## ## Threading
##
## The rule from `manager.nim` applies here with one addition of its own: **the
## lock is never held across the fetch**. A fetch is seconds -- eight by
## default, and measurably two against a port that refuses -- and the panel
## polls `/aowlspt/mods/panel` once a second throughout. A lock held across it
## would stop the whole mod answering for the duration, which is the failure
## the timeout exists to prevent, moved inside the process.
##
## So: take the lock to claim the work and copy what is needed, drop it, fetch
## and validate and write, take it again to publish the result. `gBusy` is the
## claim, and it is tested and set in one guarded region because a flag checked
## on one thread and set on another is not a claim at all.

proc outcomeName*(o: Outcome): string =
  if o == ocFetching: return "fetching"
  if o == ocAdopted: return "adopted"
  if o == ocRefused: return "refused"
  result = "never"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

proc cfgText(key, default: string): string =
  ## `setting()` hands back the raw token, so every string setting arrives with
  ## its JSON quotes still on and an empty one arrives as two characters rather
  ## than zero. The third copy of this workaround in the tree; it belongs in
  ## `aowlspt/server`, and until it is there every mod reading a string setting
  ## has to know it.
  var raw = setting(key).asText(default)
  if raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"':
    raw = raw.substr(1, raw.len - 2)
  result = raw

proc adoptedPath(): string =
  let d = dataDir()
  if d.len == 0: return ""
  result = d & "/" & AdoptedName

# ---------------------------------------------------------------------------
# Reading what is in effect
# ---------------------------------------------------------------------------

proc currentText(): string =
  if gPathOf == nil: return ""
  let p = gPathOf()
  if p.len == 0: return ""
  result = readTextFile(p)

proc revisionOf(text: string): int =
  ## `registry.revision`, or -1 when the file does not carry one. Read out of
  ## the text rather than off a parsed `Registry`, because the candidate is not
  ## a `Registry` yet and must not become one before it has been checked.
  result = -1
  if text.len == 0: return
  let j = field(text, "registry.revision")
  if j.exists and not j.isNull:
    result = j.asInt(-1)

proc idsAndVersions(text: string; ids: var seq[string];
                    versions: var seq[string]) =
  ids = @[]
  versions = @[]
  if text.len == 0: return
  let root = whole(text)
  for m in each(root.child("mods")):
    let id = m.child("id").asText("")
    if id.len == 0: continue
    ids.add id
    versions.add m.child("version").asText("")

proc contains(s: seq[string]; v: string): bool =
  for x in s:
    if x == v: return true
  result = false

proc indexOf(s: seq[string]; v: string): int =
  result = -1
  for i in 0 ..< s.len:
    if s[i] == v: return i

# ---------------------------------------------------------------------------
# The diff, and what it costs you
# ---------------------------------------------------------------------------

proc computeDiff(oldText, newText: string) =
  ## Added, removed and version-bumped, by id. Computed from the two texts
  ## rather than from two parsed registries: this runs before the new file is
  ## adopted, and parsing it into the manager's live `Registry` first would be
  ## adopting it.
  gAdded = @[]
  gRemoved = @[]
  gBumped = @[]
  var oldIds: seq[string] = @[]
  var oldVers: seq[string] = @[]
  var newIds: seq[string] = @[]
  var newVers: seq[string] = @[]
  idsAndVersions(oldText, oldIds, oldVers)
  idsAndVersions(newText, newIds, newVers)
  for i in 0 ..< newIds.len:
    let at = indexOf(oldIds, newIds[i])
    if at < 0:
      gAdded.add newIds[i]
    elif oldVers[at] != newVers[i]:
      gBumped.add newIds[i] & " " & oldVers[at] & " -> " & newVers[i]
  for i in 0 ..< oldIds.len:
    if not contains(newIds, oldIds[i]):
      gRemoved.add oldIds[i]

proc computeOrphans(v: Validation) =
  ## Assumes the lock: it reads the selection and your own lists.
  ##
  ## Everything *you* have said that the new registry cannot honour.
  ##
  ## Three sources, because there are three places a name of yours can be: the
  ## lists you have active, the per-mod overrides you set, and the entries
  ## inside your own lists. A refresh that dropped a mod out from under any of
  ## them is a change to what loads, and it has to be visible in the answer that
  ## made it rather than in a log line at the next restart.
  gOrphans = @[]
  let active = activeLists()
  let locals = localLists()
  var localIds: seq[string] = @[]
  for i in 0 ..< locals.len:
    localIds.add locals[i].id
  for id in active:
    if not contains(v.listIds, id) and not contains(localIds, id):
      gOrphans.add "the active list " & id & " is not in the new registry"
  let overrides = allOverrides()
  for ov in overrides:
    if not contains(v.modIds, ov.id):
      gOrphans.add "your override on " & ov.id &
                   " names a mod the new registry does not have"
  for i in 0 ..< locals.len:
    let ll = locals[i]
    let entries = ll.entries
    let inherits = ll.inherits
    for e in entries:
      if not contains(v.modIds, e.id):
        gOrphans.add "your list " & ll.id & " names " & e.id &
                     ", which the new registry does not have"
    for p in inherits:
      if not contains(v.listIds, p) and not contains(localIds, p):
        gOrphans.add "your list " & ll.id & " inherits " & p &
                     ", which the new registry does not have"

# ---------------------------------------------------------------------------
# Adopting
# ---------------------------------------------------------------------------

proc refuse(message: string; reasons: seq[string] = @[]) =
  ## The detail is passed in rather than accumulated in a global, because the
  ## first version accumulated it and a transport failure then answered with the
  ## *previous* attempt's validation errors still attached -- a refusal
  ## explained by a reason that had nothing to do with it.
  ##
  ## Called by the thread holding the fetch claim and **not** holding the lock;
  ## it takes it for the publish, so that a route reading the status never sees
  ## a message from this attempt beside a diff from the last one.
  withModLock:
    gOutcome = ocRefused
    gMessage = message
    gReasons = reasons
    gWhenMs = nowMs()
    # The diff belongs to an adoption. Leaving the last successful one attached
    # to a refusal reads as "this is what it changed", about an attempt that
    # changed nothing.
    gAdded = @[]
    gRemoved = @[]
    gBumped = @[]
    gOrphans = @[]
  warn "manager: registry refresh refused -- " & message

proc removeAdopted(): bool =
  let p = adoptedPath()
  if p.len == 0: return false
  try:
    removeFile(path(p))
  except:
    return false
  result = true

proc adoptCandidate(text: string; forced: bool) =
  ## Everything between "we have some bytes" and "the manager is running them".
  ##
  ## The order matters and is the order below: check the file *before* touching
  ## anything on disk, write, read the write back, and only then ask the manager
  ## to re-read. A validated document that failed to reach the disk intact would
  ## otherwise be adopted on the strength of the copy in memory and be a broken
  ## file at the next start, which is the worst possible time to find out.
  ## Runs on the thread holding the fetch claim, holding **no lock**: it reads
  ## a file, validates up to four megabytes of JSON, writes a file and reads it
  ## back. Each result is published into the guarded globals in one step, at the
  ## point it becomes true.
  var reasons: seq[string] = @[]
  let before = currentText()
  let fromRevision = revisionOf(before)
  let toRevision = revisionOf(text)
  withModLock:
    gFromRevision = fromRevision
    gToRevision = toRevision

  let v = validateRegistry(text)
  for f in v.findings:
    if f.severity == svFail:
      reasons.add f.what & (if f.detail.len > 0: " -- " & f.detail else: "")
  if not v.ok:
    refuse("the fetched registry failed validation in " & $v.failures &
           " place(s); the registry in effect is unchanged", reasons)
    return

  if v.withDownload.len > 0:
    var named = ""
    for id in v.withDownload:
      if named.len > 0: named.add ", "
      named.add id
    reasons.add "entries with a `download` block: " & named
    refuse("this registry describes mod binaries to download (" & named &
           "), and nothing here downloads or loads a mod binary from a URL. " &
           "That is arbitrary code from the network into a process injected " &
           "into a running game, and it is not a decision this fetch path " &
           "gets to make on its own. The registry in effect is unchanged.",
           reasons)
    return

  if not forced and fromRevision >= 0 and toRevision >= 0 and
     toRevision < fromRevision:
    refuse("the fetched registry is revision " & $toRevision &
           " and the one in effect is revision " & $fromRevision &
           ". Going backwards is a rollback, which is a real thing to want " &
           "and not a thing to do by accident: ask for it with /aowlspt/mods/registry/fetch/force.")
    return

  let target = adoptedPath()
  if target.len == 0:
    refuse("this host gave the mod no data directory, so there is nowhere to " &
           "put an adopted registry")
    return

  # Both of these read the selection and write the diff globals, so both are
  # under the lock -- and both are string arithmetic over documents already in
  # hand, so nothing blocks inside it.
  withModLock:
    computeDiff(before, text)
    computeOrphans(v)

  # The data directory may not exist: it is empty in the source tree, and an
  # empty directory is the kind of thing a zip or a payload stage drops without
  # anyone noticing. Created here rather than assumed, because the symptom of
  # assuming is a refusal that reads like a permissions problem.
  #
  # `tryCreateFinalDir` and not `createDir`: nimony's `createDir` walks
  # `parentDirs(..., fromRoot=true)` and calls `CreateDirectoryW` on every
  # component including `C:`, which fails with access-denied rather than
  # already-exists, so it raises for *every* absolute path on Windows. Only the
  # leaf needs creating here -- the mod's own directory is already there or the
  # mod would not be running.
  let d = dataDir()
  if d.len > 0:
    let made = tryCreateFinalDir(path(d))
    if made != Success and made != NameExists:
      warn "manager: could not create " & d
  var wrote = true
  try:
    writeFile(target, text)
  except:
    wrote = false
  if not wrote:
    refuse("could not write " & target & "; the registry in effect is unchanged")
    return

  # Read back and re-validate. A short write, a full disk or an antivirus
  # holding the file open all produce a file that is not what was checked, and
  # the next start would read *that* one.
  let readBack = readTextFile(target)
  if readBack.len != text.len or not validateRegistry(readBack).ok:
    var restored = false
    if before.len > 0:
      try:
        writeFile(target, before)
        restored = true
      except:
        restored = false
    if not restored:
      discard removeAdopted()
    refuse(target & " did not read back as what was written; it has been put " &
           "back the way it was and nothing was adopted")
    return

  var message = ""
  var added: seq[string] = @[]
  var removed: seq[string] = @[]
  var bumped: seq[string] = @[]
  var orphans: seq[string] = @[]
  withModLock:
    gOutcome = ocAdopted
    gReasons = reasons
    gWhenMs = nowMs()
    gMessage = "adopted " & (if v.registryId.len > 0: v.registryId else: "the " &
               "fetched registry") & " (" & $v.modIds.len & " mods, " &
               $v.listIds.len & " lists" &
               (if toRevision >= 0: ", revision " & $toRevision else: "") &
               ") from " & gUrl
    message = gMessage
    added = gAdded
    removed = gRemoved
    bumped = gBumped
    orphans = gOrphans
  success "manager: " & message
  for a in added: info "manager:   + " & a
  for r in removed: info "manager:   - " & r
  for b in bumped: info "manager:   ~ " & b
  for o in orphans: warn "manager:   ! " & o
  # Outside the lock, and it takes its own: adopting re-reads the registry from
  # disk, recomputes and broadcasts.
  if gAdopt != nil:
    gAdopt()

# ---------------------------------------------------------------------------
# Driving the fetch
# ---------------------------------------------------------------------------

proc claimWork(): bool =
  ## Take the right to touch `gFetch` and the status globals. One thread at a
  ## time, and the test and the set are in the same guarded region: a claim
  ## checked on one thread and taken on another is not a claim.
  var mine = false
  withModLock:
    if not gBusy:
      gBusy = true
      mine = true
  result = mine

proc dropWork() =
  withModLock:
    gBusy = false

proc beginFetch(): bool =
  ## Preconditions, then start. Returns false when it refused; `gMessage` says
  ## why in every case.
  ##
  ## Called without the lock and takes the claim rather than the lock, because
  ## `start` reaches a network and a local source finishes inside it.
  if not claimWork():
    return false
  if not gEnabled:
    refuse("fetching the registry is off. Set \"registryFetchEnabled\": true " &
           "and \"registryUrl\" in the manager's config.json. It is off by " &
           "default because a mod that reaches the network on its own, " &
           "without anyone having asked, is not a thing to opt out of.")
    dropWork()
    return false
  if gUrl.len == 0:
    refuse("no \"registryUrl\" is configured, so there is nothing to fetch")
    dropWork()
    return false
  if gPinnedPath:
    refuse("\"registryPath\" in config.json points this manager at a registry " &
           "you keep yourself, so an adopted copy would be written somewhere " &
           "nothing reads. Update that checkout and call " &
           "/aowlspt/mods/reload instead.")
    dropWork()
    return false
  var forced = false
  withModLock:
    forced = gForce
  gFetch = start(gUrl, gTimeoutMs, gMaxBytes)
  if gFetch.state == fsRunning:
    withModLock:
      gRunning = true
      gOutcome = ocFetching
      gMessage = "fetching " & gUrl
    # The claim goes back: the fetch is out on its own thread now, and whichever
    # thread reaches `pump` first is the one that finishes it.
    dropWork()
    return true
  # A local source answers immediately, and so does an immediate failure.
  if gFetch.ok:
    adoptCandidate(gFetch.body, forced)
  else:
    refuse(gFetch.error & "; the registry in effect is unchanged")
  gFetch = idleFetch()
  var adopted = false
  withModLock:
    gRunning = false
    gForce = false
    adopted = gOutcome == ocAdopted
  dropWork()
  result = adopted

proc pump*() =
  ## Take a finished fetch, if there is one. Cheap enough to call on every tick
  ## and on every request: with no fetch out it is one comparison.
  ##
  ## The *adopt* runs here too, which means one JSON parse, one validation and
  ## one file write happen on whichever thread got here first — the backend's
  ## serve loop, in practice. It is bounded by `registryFetchMaxBytes`, it
  ## happens once per fetch, and it is the reason that limit is a real limit
  ## rather than a formality.
  ##
  ## Called **without** the lock, and it takes the claim instead: two routes can
  ## reach this at the same moment and only one may own the fetch. The other
  ## returns immediately rather than waiting, because it has an answer to give
  ## and the status it reads a line later is the truth either way.
  var mine = false
  var forced = false
  withModLock:
    if gRunning and not gBusy:
      gBusy = true
      mine = true
      forced = gForce
  if not mine:
    return
  poll(gFetch)
  if gFetch.state == fsRunning:
    dropWork()
    return
  if gFetch.ok:
    adoptCandidate(gFetch.body, forced)
  else:
    refuse(gFetch.error & "; the registry in effect is unchanged")
  gFetch = idleFetch()
  withModLock:
    gRunning = false
    # One `force` is one attempt. Cleared *here*, where the attempt ends, and
    # not in the route that asked for it: an HTTP source finishes on a later
    # tick, so clearing it when the route returned cleared it before the thing
    # it applied to had happened -- which made `force` do nothing at all.
    gForce = false
  dropWork()

# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------

proc strings(items: seq[string]): JsonArray =
  var a = arr()
  for s in items:
    a.add s
  result = a

proc statusJson(): JsonObject =
  var o = obj()
  put(o, "ok", true)
  put(o, "enabled", gEnabled)
  put(o, "url", gUrl)
  put(o, "pinnedPath", gPinnedPath)
  put(o, "timeoutMs", gTimeoutMs)
  put(o, "maxBytes", gMaxBytes)
  put(o, "adoptedFile", adoptedPath())
  put(o, "state", outcomeName(gOutcome))
  put(o, "message", gMessage)
  put(o, "atMs", gWhenMs)
  put(o, "fromRevision", gFromRevision)
  put(o, "toRevision", gToRevision)
  put(o, "reasons", strings(gReasons))
  put(o, "added", strings(gAdded))
  put(o, "removed", strings(gRemoved))
  put(o, "versionChanged", strings(gBumped))
  put(o, "orphaned", strings(gOrphans))
  # Said on every answer, not only when it bites. The one thing a person is
  # most likely to assume this does is the one thing it does not do.
  put(o, "downloadsBinaries", false)
  put(o, "note", "this fetches registry metadata only; a fetched registry " &
                 "that describes mod binaries to download is refused")
  result = o

proc localListsJson(): JsonArray =
  var a = arr()
  let locals = localLists()
  for i in 0 ..< locals.len:
    let ll = locals[i]
    let inherits = ll.inherits
    let entries = ll.entries
    var inh = arr()
    for p in inherits:
      inh.add p
    var ents = arr()
    for e in entries:
      var eo = obj()
      put(eo, "id", e.id)
      put(eo, "enabled", e.enabled)
      if e.note.len > 0:
        put(eo, "note", e.note)
      ents.add eo
    var o = obj()
    put(o, "id", ll.id)
    put(o, "name", ll.name)
    put(o, "description", ll.description)
    put(o, "inherits", inh)
    put(o, "entries", ents)
    a.add o
  result = a

proc errorBody(message: string): string =
  var o = obj()
  put(o, "ok", false)
  put(o, "error", message)
  result = done(o).text

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc hasForce(url, body: string): bool =
  ## `/aowlspt/mods/registry/fetch/force`, or `{"force":true}` in the body.
  ##
  ## A path segment rather than `?force=1`, and that is not a style choice: the
  ## backend matches a static route by **exact** string
  ## (`matchRoute` in `backend/aowlbackend.nim`), so a URL with a query string
  ## on it matches nothing and the route is never called at all. A flag spelled
  ## in a way the router silently drops is worse than no flag -- it reads as
  ## "forced" and behaves as "not forced", which for a rollback is the wrong
  ## way round.
  if field(body, "force").asBool(false):
    return true
  result = pathAfter(url, "/aowlspt/mods/registry/fetch/") == "force"

proc routeRegistry(url, body, session: string): string =
  pump()                      # outside the lock: it can finish a fetch
  var text = ""
  withModLock:
    text = done(statusJson()).text
  result = text

proc routeFetch(url, body, session: string): string =
  ## Start a refresh, or report the one that is running. Returns immediately in
  ## every case — the answer is what happened so far, and the caller polls this
  ## same route or `/aowlspt/mods/registry` for the rest.
  pump()
  var running = false
  var text = ""
  withModLock:
    running = gRunning
    if running:
      var o = statusJson()
      put(o, "started", false)
      put(o, "note", "a fetch is already out; poll /aowlspt/mods/registry")
      text = done(o).text
  if running:
    return text
  let wantForce = hasForce(url, body)
  withModLock:
    gForce = wantForce
  discard beginFetch()
  pump()                      # a local source is already finished
  withModLock:
    var o = statusJson()
    put(o, "started", true)
    put(o, "forced", wantForce)
    text = done(o).text
  result = text

proc routeRevert(url, body, session: string): string =
  ## Throw away the adopted copy and go back to whatever the build shipped.
  ##
  ## This is the reason the adopted registry is a *file in one known place*
  ## rather than a blob in the store: reverting is deleting it, and a person can
  ## do the same thing with the file manager if this route is unreachable.
  let p = adoptedPath()
  var o = obj()
  if p.len == 0:
    return errorBody("this host gave the mod no data directory")
  # Deleting the file is disk work and is done with nothing held.
  if not removeAdopted():
    put(o, "ok", false)
    put(o, "error", "there was nothing at " & p & " to remove, or it could " &
                    "not be removed")
    put(o, "file", p)
    return done(o).text
  var message = ""
  withModLock:
    gOutcome = ocNever
    gMessage = "the adopted registry was removed; back to the one this build " &
               "shipped with"
    message = gMessage
    gAdded = @[]
    gRemoved = @[]
    gBumped = @[]
    gOrphans = @[]
    gReasons = @[]
  if gAdopt != nil:
    gAdopt()
  put(o, "ok", true)
  put(o, "reverted", true)
  put(o, "file", p)
  put(o, "message", message)
  result = done(o).text

proc localListsLocked(body: string; outId: var string;
                      outErr: var string; outStored: var bool): bool =
  ## GET: your own lists. POST with a list document: create or replace one.
  ##
  ##     {"id":"my.raidnight","name":"Raid night",
  ##      "inherits":["aowl.list.vanillaplus"],
  ##      "entries":[{"id":"aowl.sain","enabled":false,"note":"not tonight"}]}
  ##
  ## The same shape a registry list has, minus the fields that only mean
  ## something once a list is published.
  ##
  ## Assumes the lock: reading your lists and writing one are the same state,
  ## and a list read while another request is replacing it is a list with one
  ## foot in each version. `outStored` is false when the store would not take
  ## it, which the route says out loud rather than reporting a save that did
  ## not happen. `outErr` carries the whole answer on the paths that have one
  ## already -- a GET, or a refusal.
  outId = ""
  outErr = ""
  outStored = false
  let id = field(body, "id").asText("")
  if id.len == 0:
    var o = obj()
    put(o, "ok", true)
    put(o, "lists", localListsJson())
    put(o, "note", "POST a list document with an \"id\" to create or replace " &
                   "one; these live in the manager's store and a registry " &
                   "refresh cannot touch them")
    outErr = done(o).text
    return false

  # Every id is checked before anything is stored, and a bad one refuses the
  # whole document rather than being dropped out of it. A list saved minus the
  # entry that was mistyped is a list that looks right and is not, and it is
  # saved into the one file here that holds something a person wrote by hand.
  let badId = idFault(id)
  if badId.len > 0:
    outErr = errorBody("that is not a list id: " & badId)
    return false
  if not selectionUsable():
    outErr = errorBody(selectionFault() & ". Your lists live in that same " &
                       "file and nothing will be written over it until it " &
                       "can be read; fix or delete it and restart.")
    return false

  let entriesField = field(body, "entries")
  if entriesField.exists and not entriesField.isNull and
     not entriesField.isArray:
    outErr = errorBody("\"entries\" has to be an array " &
                       "of {\"id\",\"enabled\"} objects; nothing was saved")
    return false
  var entries: seq[ListEntry] = @[]
  let ents = each(entriesField)
  for e in ents:
    let eid = e.field("id").asText("")
    let badEntry = idFault(eid)
    if badEntry.len > 0:
      outErr = errorBody("an entry in that list is not a mod id: " &
                         badEntry & ". Nothing was saved.")
      return false
    entries.add ListEntry(id: eid, enabled: e.field("enabled").asBool(true),
                          note: e.field("note").asText(""))
  let inheritsField = field(body, "inherits")
  if inheritsField.exists and not inheritsField.isNull and
     not inheritsField.isArray:
    outErr = errorBody("\"inherits\" has to be an array of list " &
                       "ids; nothing was saved")
    return false
  var inherits: seq[string] = @[]
  let inh = each(inheritsField)
  for p in inh:
    let s = p.asText("")
    let badParent = idFault(s)
    if badParent.len > 0:
      outErr = errorBody("that list inherits something that is not a list " &
                         "id: " & badParent & ". Nothing was saved.")
      return false
    inherits.add s

  let l = LocalList(id: id, name: field(body, "name").asText(id),
                    description: field(body, "description").asText(""),
                    inherits: inherits, entries: entries)
  outStored = putLocalList(l)
  outId = id
  result = true

proc routeLocalLists(url, body, session: string): string =
  ## GET: your own lists. POST with a list document: create or replace one.
  ##
  ##     {"id":"my.raidnight","name":"Raid night",
  ##      "inherits":["aowl.list.vanillaplus"],
  ##      "entries":[{"id":"aowl.sain","enabled":false,"note":"not tonight"}]}
  ##
  ## The same shape a registry list has, minus the fields that only mean
  ## something once a list is published.
  var id = ""
  var text = ""
  var stored = false
  var saved = false
  withModLock:
    saved = localListsLocked(body, id, text, stored)
  if not saved:
    return text
  # An entry point of its own, and it takes the lock itself: your new list has
  # to be merged into the registry before anything can select it.
  if gAdopt != nil:
    gAdopt()
  withModLock:
    var o = obj()
    put(o, "ok", true)
    put(o, "saved", id)
    put(o, "persisted", stored)
    if not stored:
      put(o, "warning", "the store would not take it, so this list is in " &
                        "effect for this run only")
    put(o, "lists", localListsJson())
    text = done(o).text
  result = text

proc localDeleteLocked(url, body: string; outId: var string;
                       outErr: var string): bool =
  outId = ""
  outErr = ""
  var id = pathAfter(url, "/aowlspt/mods/lists/local/delete/")
  if id.len == 0:
    id = field(body, "id").asText("")
  if id.len == 0:
    outErr = "name a list: /aowlspt/mods/lists/local/delete/<id>"
    return false
  let badId = idFault(id)
  if badId.len > 0:
    outErr = "that is not a list id: " & badId
    return false
  if not selectionUsable():
    outErr = selectionFault() & ". Nothing is written over it until it can " &
             "be read."
    return false
  if not deleteLocalList(id):
    outErr = "you have no list called " & id
    return false
  outId = id
  result = true

proc routeLocalDelete(url, body, session: string): string =
  var id = ""
  var why = ""
  var deleted = false
  withModLock:
    deleted = localDeleteLocked(url, body, id, why)
  if not deleted:
    return errorBody(why)
  if gAdopt != nil:
    gAdopt()
  var text = ""
  withModLock:
    var o = obj()
    put(o, "ok", true)
    put(o, "deleted", id)
    put(o, "note", "your selection was left alone; if this list was active " &
                   "it now names a list nothing defines, which the resolver " &
                   "reports rather than quietly fixing")
    put(o, "lists", localListsJson())
    text = done(o).text
  result = text

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc refreshTick(payload: string): string =
  ## `TickHandler` is `proc (payload: string): string`; the payload is the
  ## timer's and there is nothing to say back.
  pump()
  result = ""

proc refreshInit*(pathOf: PathFn; adopt: AdoptFn) =
  ## `pathOf` says which registry file is in effect and `adopt` re-reads it.
  ## Both are the manager's, passed in rather than reached for, so that this
  ## module owns the network and the manager keeps owning the registry — and so
  ## that neither has to be touched to change the other.
  gPathOf = pathOf
  gAdopt = adopt
  gEnabled = setting("registryFetchEnabled").asBool(false)
  gUrl = cfgText("registryUrl", "")
  gTimeoutMs = setting("registryFetchTimeoutMs").asInt(8000)
  gMaxBytes = setting("registryFetchMaxBytes").asInt(4000000)
  gPinnedPath = cfgText("registryPath", "").len > 0

  discard serve("/aowlspt/mods/registry", routeRegistry)
  discard serve("/aowlspt/mods/registry/fetch", routeFetch)
  discard servePrefix("/aowlspt/mods/registry/fetch/", routeFetch)
  discard serve("/aowlspt/mods/registry/revert", routeRevert)
  discard serve("/aowlspt/mods/lists/local", routeLocalLists)
  discard servePrefix("/aowlspt/mods/lists/local/delete/", routeLocalDelete)

  if gEnabled and gUrl.len > 0 and not gPinnedPath:
    # The tick is what lets an unattended fetch finish. Half a second: a fetch
    # is a once-in-a-session thing, and a tighter poll would only make the
    # cheapest possible comparison happen more often.
    discard every(500, refreshTick)
    if setting("registryFetchOnStart").asBool(false):
      discard beginFetch()
      var said = ""
      withModLock:
        said = gMessage
      info "manager: " & said
  elif gUrl.len > 0 and not gEnabled:
    info "manager: \"registryUrl\" is set and \"registryFetchEnabled\" is " &
         "false; nothing will be fetched until you turn it on"

proc refreshShutdown*() =
  ## Let go of any fetch still out. See `httpfetch`'s module comment: the worker
  ## keeps the buffer alive and frees it itself, because the alternative is the
  ## manager being unloaded out from under a thread that is still writing.
  release(gFetch)
