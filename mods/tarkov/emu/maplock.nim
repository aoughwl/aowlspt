## Which maps the player may load into.
##
## The request that started this was "shouldn't we not have all maps unlocked
## by default, that should be a setting". Today every map is unlocked, because
## `locations.<map>.base.Locked` is `false` in all nineteen database maps and
## `/client/locations` sends `base` out verbatim.
##
## ## Where this lives, and why not in a mod of its own
##
## `mods/tarkov/emu/raid.nim`, `mods/morebots` and `mods/sain` all carry
## comments referring to **`mods/icebreaker`** as the thing that writes per-map
## `Enabled`/`Locked`. That mod does not exist on disk -- the feature was
## referenced in three places and implemented in none. It is not resurrected
## here: `mods/tarkov` already owns `/client/locations`, already owns the
## `locations` table, and already has the one map-name resolver this needs.
## A separate mod would need its own copy of that resolver, which is precisely
## the fifth spelling this file exists to avoid.
##
## ## The wire shape, measured -- not assumed
##
## Newtonsoft throws on an object-where-a-scalar-was-expected, so the shape
## matters more than the value. Both fields are **plain JSON booleans**:
##
##   * `data/post1/locations.json` -- the real backend's own
##     `/client/locations` reply for this build (capture seq 134), 24 maps:
##     `Locked` is `bool` on all 24 and `false` on all 24; `Enabled` is `bool`
##     on all 24, **`true` on 15 and `false` on 9**. Measured with
##     `tools/bigjson.py find --key Locked` / `--key Enabled` (the `Enabled`
##     scan also hits `NonWaveGroupScenario.Enabled`, a different field, which
##     is why the count is 48 before filtering).
##   * `db.json` -- `locations.bigmap.base.Locked` is `false`,
##     `locations.bigmap.base.Enabled` is `true`.
##
## So BSG itself ships `Enabled=false` for nine maps. That is BSG's own "this
## map is not in the game right now" axis and it is left alone: this file
## writes **`Locked` only**. Locking is the player-facing gate the request
## asked for; flipping `Enabled` would additionally remove the map from the
## selection screen and would fight with whatever the database already says.
## Naming that distinction is the point -- the two are not synonyms and the
## phantom mod's comments treated them as one thing.
##
## ## The name trap (facts #183 and #185)
##
## The client sends `base.Id` -- "Woods", "Interchange", "RezervBase" -- while
## the database is keyed by directory name -- "woods", "interchange",
## "rezervbase". Only `bigmap`, `factory4_day`, `factory4_night` and
## `laboratory` spell the two alike, which is why four separate consumers had
## this confusion and three of them failed silently with a wrong value. Every
## name a human or the client hands this file goes through
## `canonicalLocation`, the one resolver in `raid.nim`, and a name it cannot
## resolve is REPORTED, never guessed at and never quietly skipped.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import raid

type
  LockConfig* = object
    unlockedByDefault*: bool
      ## The setting the request asked for. True is today's behaviour and the
      ## shipped default, so installing this changes nothing until it is
      ## turned off.
    lockList*: string
      ## Comma-separated maps to lock even when `unlockedByDefault` is true.
    unlockList*: string
      ## Comma-separated maps to leave unlocked when `unlockedByDefault` is
      ## false. The per-map half of "ideally per-map lock state".

  LockReport* = object
    ## What `applyMapLocks` actually did, in terms that can be checked against
    ## the served payload rather than against our own intent.
    locked*: seq[string]      ## database keys now Locked=true
    unlocked*: seq[string]    ## database keys now Locked=false
    unresolved*: seq[string]  ## names in a list that resolve to no map
    wrote*: int               ## db writes that reported Ok
    failed*: int              ## db writes that did not

proc splitNames(s: string): seq[string] =
  ## A comma list, trimmed, with empties dropped. Whitespace around a name is
  ## a typing artefact, not part of a map name.
  result = @[]
  for part in s.split(','):
    let t = strip(part)
    if t.len > 0:
      result.add t

proc contains(xs: seq[string]; want: string): bool =
  for x in xs:
    if x == want:
      return true
  result = false

proc resolveAll(names: seq[string]; into: var seq[string];
                unresolved: var seq[string]) =
  ## Every name in `names` as a DATABASE KEY, with the ones that resolve to no
  ## map collected separately.
  ##
  ## The separate `unresolved` bucket is the whole point. A misspelt map that
  ## is silently dropped leaves a setting that renders, saves, and locks
  ## nothing -- the failure mode CLAUDE.md §6 names, and the one the three
  ## broken `base.Id` consumers had.
  for n in names:
    let key = canonicalLocation(n)
    # `canonicalLocation` returns its input unchanged for a map it does not
    # know, so "did it resolve" is a question about the DATABASE, not about
    # the string it handed back.
    let probe = dbRead("locations." & key & ".base")
    if probe.ok and probe.raw.len > 0:
      if not contains(into, key):
        into.add key
    else:
      if not contains(unresolved, n):
        unresolved.add n

proc applyMapLocks*(cfg: LockConfig): LockReport =
  ## Resolve the player's two lists to database keys and install the policy.
  ##
  ## THIS DOES NOT WRITE THE DATABASE, and the first version did, which is the
  ## instructive part. Writing `Locked` into `locations.<map>.base` succeeded
  ## on all 19 maps and changed nothing the client ever saw, because
  ## `/client/locations` is answered out of the post-1.0 table by
  ## `raid.post1LocationsTuned`, not out of the database. `tools/realtest.nim`
  ## caught it -- "19 db write(s) ok" in the log beside "24 map(s) still
  ## unlocked" in the served payload -- precisely because the check reads the
  ## SERVED DOCUMENT and not our own write. A check that re-read the database
  ## would have passed.
  ##
  ## So the policy is handed to `raid`, which applies it to whichever document
  ## it is about to serve, and drops its cache when the policy changes.
  result = LockReport(locked: @[], unlocked: @[], unresolved: @[],
                      wrote: 0, failed: 0)

  var lockKeys: seq[string] = @[]
  var unlockKeys: seq[string] = @[]
  resolveAll(splitNames(cfg.lockList), lockKeys, result.unresolved)
  resolveAll(splitNames(cfg.unlockList), unlockKeys, result.unresolved)

  setMapLockPolicy(MapLockPolicy(unlockedByDefault: cfg.unlockedByDefault,
                                 lockKeys: lockKeys,
                                 unlockKeys: unlockKeys))

  # Report over the DATABASE's map list. It is the smaller of the two tables
  # (19 against the post-1.0 table's 24) and it is the one whose names a
  # player recognises, so it is the right thing to summarise -- but the count
  # is explicitly a summary of the policy, not a count of writes, and
  # `wrote`/`failed` stay 0 because nothing is written any more.
  let idx = liveLocationIndex()
  for name in idx.names:
    if lockedFor(name):
      result.locked.add name
    else:
      result.unlocked.add name

proc commaJoin(xs: seq[string]): string =
  ## `strutils.join` over a `seq[string]` is not available in nimony (measured:
  ## "undeclared identifier: 'join'" on this toolchain), and the alternative --
  ## importing something for it -- would be a dependency for six lines.
  result = ""
  var i = 0
  while i < xs.len:
    if i > 0:
      result.add ", "
    result.add xs[i]
    inc i

proc lockSummary*(r: LockReport): string =
  ## One line for the log, and the rows the settings page shows back.
  ##
  ## `unresolved` is named first when it is non-empty, because a setting that
  ## did something to 19 maps and nothing to the one the player typed is a
  ## failure that reads as a success.
  result = ""
  if r.unresolved.len > 0:
    result.add "UNRESOLVED map name(s), locked/unlocked NOTHING for them: " &
               commaJoin(r.unresolved) & ". "
  result.add $r.locked.len & " map(s) locked, " & $r.unlocked.len &
             " unlocked, of the " & $(r.locked.len + r.unlocked.len) &
             " the database lists"
  if r.locked.len > 0:
    result.add "; locked: " & commaJoin(r.locked)
