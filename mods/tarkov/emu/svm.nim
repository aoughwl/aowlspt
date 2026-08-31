## The SVM rows that are NOT `globals.config` -- and the read ledger over them.
##
## What already existed, and why this file is small
## ------------------------------------------------
## Most of ServerValueModifier's surface is already here. `emu/tuning` +
## `emu/globaltunedata` expose **770 rows** of `globals.config` -- stamina,
## inertia, malfunction, overheat, aiming, armour materials, the flea market,
## the experience tables, the skill settings -- as one setting each, and the
## schema and the patcher read the same table, so none of them can be
## decorative. Insurance, scav cooldown, trader prices, repair price, hideout
## rates, quest XP, flea fees, loot multipliers, map locks, boss chances and
## item spawning already have their own rows in `tarkov.nim`.
##
## Four SVM/profile-manager things had no row anywhere, and they are the four
## that do not live in the globals document:
##
##   * stash size            -- `templates.items.<stash>._props.Grids[0]._props`
##   * exact experience      -- the profile's `Info.Experience` (emu/progression)
##   * raid time limit       -- `locations.<map>.base.EscapeTimeLimit*` (emu/raid)
##   * extract availability  -- `locations.<map>.base.exits[]`      (emu/raid)
##
## Money grant is deliberately NOT re-implemented: the Spawn Items rows already
## put any template, including roubles/euros/dollars, into the stash with a
## working grid placement. A second money path would be a second thing to keep
## true.
##
## The read ledger
## ---------------
## `svmLedger` names every key this file declares and counts how often the
## server READ it. `svmLedgerNeverRead` is the falsifiable half: declare a key
## and never consult it and it is named, which is the one defect shape this
## repository repeats. Note what that proves and what it does not -- it proves
## CONSULTATION. Effect is a separate claim, made only where this file can point
## at a value the server now serves differently (`stashReport`, and `emu/raid`'s
## `raidTuneApplies`).

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import aowlspt/settings
import raid
import progression

const
  StashParent* = "566abbb64bdc2d144c8b457d"
    ## The `_parent` every stash template carries. Measured with
    ## `tools/bigjson.py get --path templates.items.<id>._parent` on all five
    ## ids below: identical on all five.

  StashTemplates* = [
    "566abbc34bdc2d92178b4576",   # Standard,          cellsV 30
    "5811ce572459770cba1a34ea",   # Left Behind,       cellsV 40
    "5811ce662459770f6f490f32",   # Prepare for Escape,cellsV 50
    "5811ce772459770e9e5f9532",   # Edge of Darkness,  cellsV 68
    "6602bcf19cc643f44a04274b"]   # Unheard,           cellsV 72
    ## Every edition's stash, so the row works whichever edition the profile
    ## was made with. Each is CHECKED against `StashParent` before it is
    ## written: an id that is not a stash on this database is reported, never
    ## written to. That check is what stops a stale id from resizing some
    ## unrelated item's grid.

  SvmKeys* = [
    "stashRows", "stashCols", "stashResult",
    "progressionExperience",
    "raidTimeMultiplier", "raidTimeMinutes",
    "extractsAlwaysAvailable", "extractsNoRequirements",
    "extractsNoTimeWindow", "raidTuneResult"]

# ---------------------------------------------------------------------------
# The read ledger
# ---------------------------------------------------------------------------

var gLedgerKey: seq[string] = @[]
var gLedgerHits: seq[int] = @[]
var gLedgerRuns = 0

proc ledgerInit() =
  if gLedgerKey.len > 0:
    return
  for k in SvmKeys:
    gLedgerKey.add k
    gLedgerHits.add 0

proc noteRead(key: string) =
  ledgerInit()
  var i = 0
  while i < gLedgerKey.len:
    if gLedgerKey[i] == key:
      gLedgerHits[i] = gLedgerHits[i] + 1
      return
    inc i
  # A key read but never declared is as much a bug as one declared and never
  # read -- it is a value with no control and no config path. Recorded rather
  # than ignored so the ledger can name it.
  gLedgerKey.add key
  gLedgerHits.add -1

proc svmRead*(key: string): ConfigValue =
  ## Every read of an SVM key goes through here. That is the only reason the
  ## ledger can be trusted: a read that bypassed it would not be counted, and
  ## the ledger would report a key as unread while the server was using it.
  noteRead(key)
  result = setting(key)

proc svmLedgerRuns*(): int = gLedgerRuns

proc svmLedgerNeverRead*(): seq[string] =
  ## Declared and never consulted. Empty is the only passing answer -- but
  ## ONLY once `svmLedgerRuns` is above zero: before the first apply, every
  ## count is legitimately zero and the honest verdict is INCONCLUSIVE, not
  ## PASS. Callers must check `svmLedgerRuns` first.
  ledgerInit()
  result = @[]
  var i = 0
  while i < gLedgerKey.len:
    if gLedgerHits[i] == 0:
      result.add gLedgerKey[i]
    inc i

proc svmLedgerUndeclared*(): seq[string] =
  ledgerInit()
  result = @[]
  var i = 0
  while i < gLedgerKey.len:
    if gLedgerHits[i] < 0:
      result.add gLedgerKey[i]
    inc i

proc svmLedgerLine*(): string =
  ledgerInit()
  var read = 0
  for h in gLedgerHits:
    if h > 0:
      inc read
  result = "svm ledger: " & $read & "/" & $gLedgerKey.len &
           " declared key(s) READ over " & $gLedgerRuns & " apply run(s)"
  let never = svmLedgerNeverRead()
  if gLedgerRuns == 0:
    result.add "; INCONCLUSIVE -- no apply has run yet"
  elif never.len > 0:
    result.add "; NEVER READ:"
    for k in never:
      result.add " " & k

# ---------------------------------------------------------------------------
# Stash size
# ---------------------------------------------------------------------------

var gStashReport = ""

proc stashReport*(): string = gStashReport

proc gridsWith(rawGrids: string; rows, cols: int; touched: var int): string =
  ## The stash's `Grids` array with the FIRST grid resized. Only the first:
  ## a stash template has exactly one grid on this database, and resizing an
  ## unknown number of them would be a guess about what the extra ones are.
  let list = parseArray(rawGrids)
  if not list.ok or list.len == 0:
    return ""
  var rebuilt = parseArray("[]")
  var i = 0
  while i < list.len:
    if i != 0:
      rebuilt.add list.items[i]
      inc i
      continue
    var g = parseObject(list.items[i])
    if not g.ok:
      return ""
    var props = parseObject(getRaw(g, "_props"))
    if not props.ok:
      return ""
    if rows > 0 and props.has("cellsV"):
      setNumber(props, "cellsV", rows)
      inc touched
    if cols > 0 and props.has("cellsH"):
      setNumber(props, "cellsH", cols)
      inc touched
    setRaw(g, "_props", text(props))
    rebuilt.add text(g)
    inc i
  result = text(rebuilt)

proc applyStashSize*(rows, cols: int) =
  ## Resize every edition's stash, and then say what the DATABASE now holds --
  ## not what was written.
  ##
  ## The read-back is the point (CLAUDE.md 9b). It re-reads
  ## `templates.items.<id>._props.Grids.0._props.cellsV` through the same path
  ## `emu/grid.stashGrid` and `/client/items` use, and the report names any
  ## template whose value is NOT the requested one. A template that refused the
  ## write reads back at its stock size and is named; a report built from the
  ## write itself could not tell those apart.
  gStashReport = ""
  if rows <= 0 and cols <= 0:
    return
  var wrongV: seq[string] = @[]
  var notStash: seq[string] = @[]
  var noGrids: seq[string] = @[]
  var ok = 0
  for tpl in StashTemplates:
    let parent = dbRead("templates.items." & tpl & "._parent")
    if not parent.ok or parent.raw.find(StashParent) < 0:
      notStash.add tpl
      continue
    let grids = dbRead("templates.items." & tpl & "._props.Grids")
    if not grids.ok or grids.raw.len == 0:
      noGrids.add tpl
      continue
    var touched = 0
    let rebuilt = gridsWith(grids.raw, rows, cols, touched)
    if rebuilt.len == 0 or touched == 0:
      noGrids.add tpl
      continue
    var patch = newDoc()
    setRaw(patch, "Grids", rebuilt)
    discard dbWrite("templates.items." & tpl & "._props", text(patch))
    # READ BACK, through the path the served document is built from.
    let back = dbRead("templates.items." & tpl & "._props.Grids")
    let first = at(whole(back.raw), 0)
    let gotV = first.field("_props.cellsV").asInt(-1)
    let gotH = first.field("_props.cellsH").asInt(-1)
    if (rows > 0 and gotV != rows) or (cols > 0 and gotH != cols):
      wrongV.add tpl & " (cellsH=" & $gotH & " cellsV=" & $gotV & ")"
    else:
      inc ok

  gStashReport = $ok & " of " & $StashTemplates.len &
                 " stash template(s) now read back at the requested size"
  if wrongV.len > 0:
    gStashReport.add "; STILL WRONG after the write:"
    for t in wrongV:
      gStashReport.add " " & t
  if notStash.len > 0:
    gStashReport.add "; NOT a stash on this database, skipped:"
    for t in notStash:
      gStashReport.add " " & t
  if noGrids.len > 0:
    gStashReport.add "; no usable Grids, skipped:"
    for t in noGrids:
      gStashReport.add " " & t

# ---------------------------------------------------------------------------
# The one apply
# ---------------------------------------------------------------------------

var gRaidReport = ""

proc raidTuneReport*(): string = gRaidReport

proc applySvmSettings*() =
  ## Read every declared key, once, and install what each one controls.
  ## Called from `onTarkovApply` and at load, exactly like the other groups.
  inc gLedgerRuns
  ledgerInit()

  let rows = svmRead("stashRows").asInt(0)
  let cols = svmRead("stashCols").asInt(0)
  applyStashSize(rows, cols)
  # `stashResult` is written BY the server, the same way `spawnResult` and
  # `mapsLockResult` are. It is READ here so that the ledger counts it and so
  # that an unchanged report is not rewritten on every apply.
  if svmRead("stashResult").asText("") != gStashReport:
    discard applySetting("stashResult", jstr(gStashReport).text)

  configureExperienceFloor(svmRead("progressionExperience").asInt(0))

  var pol = RaidTunePolicy(
    timeMultiplier: svmRead("raidTimeMultiplier").asFloat(1.0),
    timeMinutes: svmRead("raidTimeMinutes").asInt(0),
    extractsAlwaysAvailable: svmRead("extractsAlwaysAvailable").asBool(false),
    extractsNoRequirements: svmRead("extractsNoRequirements").asBool(false),
    extractsNoTimeWindow: svmRead("extractsNoTimeWindow").asBool(false))
  setRaidTunePolicy(pol)

  gRaidReport = ""
  if raidTuneTimeActive() or raidTuneExitsActive():
    gRaidReport = "raid tune armed:"
    if pol.timeMinutes > 0:
      gRaidReport.add " every raid " & $pol.timeMinutes & " min"
    elif pol.timeMultiplier != 1.0:
      gRaidReport.add " raid time x" & $pol.timeMultiplier
    if pol.extractsAlwaysAvailable:
      gRaidReport.add "; all exit chances -> 100"
    if pol.extractsNoRequirements:
      gRaidReport.add "; passage requirements -> None"
    if pol.extractsNoTimeWindow:
      gRaidReport.add "; exit time windows opened"
    # Counted from the SERVED document, not from this call: `raidTuneApplies`
    # only moves when a location document is actually built.
    gRaidReport.add " (" & $raidTuneApplies() & " map base(s) tuned so far, " &
                    $raidTuneExitsTouched() & " exit(s))"
  else:
    gRaidReport = "raid tune: nothing configured, no location document touched"
  if svmRead("raidTuneResult").asText("") != gRaidReport:
    discard applySetting("raidTuneResult", jstr(gRaidReport).text)

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc selfCheckSvm*(failures: var seq[string]) =
  ## Falsifiable without a database, a profile or a client.

  # The ledger's own negative. Injecting a declared key that nothing reads makes
  # this fire -- that is the input that makes it fail.
  applySvmSettings()
  if gLedgerRuns == 0:
    failures.add "svm: the ledger recorded no apply run -- INCONCLUSIVE, " &
                 "not a pass"
  else:
    let never = svmLedgerNeverRead()
    if never.len > 0:
      var msg = "svm ledger: declared key(s) NEVER READ:"
      for k in never:
        msg.add " " & k
      failures.add msg
    let extra = svmLedgerUndeclared()
    if extra.len > 0:
      var msg = "svm ledger: key(s) read but not declared in SvmKeys:"
      for k in extra:
        msg.add " " & k
      failures.add msg

  # The grid rewrite, checked by READING BACK the finished array rather than by
  # comparing against what was written. Fails on a rewrite that loses a sibling
  # member, which is the one bug this rebuild can have.
  block:
    let src = """[{"_name":"main","_props":{"cellsH":10,"cellsV":30,
                  "filters":[],"maxWeight":0}}]"""
    var touched = 0
    let outText = gridsWith(src, 99, 0, touched)
    if touched != 1:
      failures.add "svm stash: the grid rewrite touched " & $touched &
                   " member(s), expected 1"
    let first = at(whole(outText), 0)
    if first.field("_props.cellsV").asInt(0) != 99:
      failures.add "svm stash: cellsV did not land in the finished array"
    if first.field("_props.cellsH").asInt(0) != 10:
      failures.add "svm stash: resizing cellsV destroyed cellsH"
    if first.field("_name").asText("") != "main":
      failures.add "svm stash: the grid rewrite lost a sibling member"
    if not first.field("_props.filters").isArray:
      failures.add "svm stash: a non-scalar member did not survive the rewrite"

  # An empty request must do nothing at all, so the row is safe to leave at its
  # default. Fails if `applyStashSize` ever writes on a zero.
  block:
    applyStashSize(0, 0)
    if stashReport().len != 0:
      failures.add "svm stash: a request of 0 rows / 0 cols still reported " &
                   "a write"
