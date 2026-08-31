## The settings READ LEDGER, and the one accessor every tunable in the loot and
## bot-gear pipelines is read through.
##
## ## Why this module exists
##
## The single most repeated defect in this repository is a setting that renders,
## accepts an edit, persists to `config.json` -- and is never read by anything.
## `mods/debug` shipped one for weeks. `mods/maps` still has a dead `markers`
## key. Nothing catches it, because every check that could catch it was written
## as "the row exists" or "the write landed", and both of those agree with
## themselves.
##
## The falsifiable property is the other one: **every key the settings page
## declares was CONSULTED by the generator during a real generation pass.** A
## key nobody read is a dead control, whatever the page shows.
##
## So `knob(key)` is `setting(key)` plus one side effect: it records the key.
## `emu/loot` and `emu/bots` read every one of their tunables through it, in a
## single unconditional block per pass (`lootConfig`, `botGearConfig`), so the
## ledger after a pass is exactly the set of keys the generator asked for --
## not the set this file hoped it would ask for.
##
## The ledger is a RECORD, not an assertion. It cannot say a key had an effect;
## it can only say the generator never looked at it, which is the one failure
## mode that is worth a gate. Saying more than that would be the confidently
## wrong diagnostic the house rules forbid.

import std/strutils
import aowlspt
import aowlspt/server

var gLedger: seq[string] = @[]
var gLedgerOn = false

proc ledgerBegin*() =
  ## Start recording. Idempotent, and it CLEARS -- a ledger that accumulated
  ## across passes would report a key as read because some earlier pass read
  ## it, which is precisely the stale evidence this exists to refuse.
  gLedgerOn = true
  gLedger = @[]

proc ledgerStop*() =
  gLedgerOn = false

proc noteRead*(key: string) =
  if not gLedgerOn:
    return
  for k in gLedger:
    if k == key:
      return
  gLedger.add key

proc knob*(key: string): ConfigValue =
  ## `setting`, with the read recorded. Every tunable in the loot and bot-gear
  ## pipelines goes through here; nothing else does, so the ledger stays about
  ## the generator rather than about the whole mod.
  noteRead(key)
  result = setting(key)

proc ledgerSaw*(key: string): bool =
  for k in gLedger:
    if k == key:
      return true
  result = false

proc ledgerCount*(): int =
  gLedger.len

proc ledgerKeys*(): seq[string] =
  result = gLedger

proc ledgerUnread*(declared: seq[string]): seq[string] =
  ## The answer that matters: which DECLARED keys the generator never asked
  ## for. Empty is the only good answer; anything in it names a dead control.
  result = @[]
  for d in declared:
    if not ledgerSaw(d):
      result.add d

proc ledgerLine*(declared: seq[string]): string =
  ## One line, three outcomes. "No generation ran" is INCONCLUSIVE and never a
  ## pass -- an empty ledger is indistinguishable from a pass that never
  ## happened, and flattening the two is how a check stops being able to fail.
  if not gLedgerOn and gLedger.len == 0:
    return "LEDGER INCONCLUSIVE: no generation pass was recorded (" &
           $declared.len & " keys declared, 0 reads seen)"
  if gLedger.len == 0:
    return "LEDGER INCONCLUSIVE: the ledger was armed but the generator read " &
           "nothing (" & $declared.len & " keys declared)"
  let missing = ledgerUnread(declared)
  if missing.len == 0:
    return "LEDGER PASS: " & $declared.len & "/" & $declared.len &
           " declared generator settings were read during the pass (" &
           $gLedger.len & " distinct reads)"
  var named = ""
  for m in missing:
    if named.len > 0:
      named = named & ", "
    named = named & m
  result = "LEDGER FAIL: " & $(declared.len - missing.len) & "/" &
           $declared.len & " declared generator settings were read; NEVER " &
           "READ: " & named

# ---------------------------------------------------------------------------
# The money-stack knobs -- shared by the WORLD loot pass and the BOT loot pass
# ---------------------------------------------------------------------------
#
# They live here rather than in either module because both need them and
# neither imports the other. The bug they are the control surface for is
# measured and named in `emu/bots.randomStackCount`: a scav's pocket pool holds
# currency template ids, the loot pass placed one item with no
# `StackObjectsCount`, and the client renders that as a stack of ONE -- the $1
# bill the player kept pulling off corpses.
#
# The three currency template ids and their declared ranges were read out of
# this install's own `db.json` (tools/bigjson.py, 2026-08-31), not taken from
# community lore:
#
#   Rubles  5449016a4bdc2d6f028b456f  StackMinRandom 5500 .. Max 13500, cap 1000000
#   Dollars 5696686a4bdc2da3298b456a  StackMinRandom   45 .. Max   100, cap   50000
#   Euro    569668774bdc2da2298b4568  StackMinRandom   35 .. Max    90, cap   50000
#
# All three have `_parent` = 543be5dd4bdc2deb348b4569 ("Money"), also measured.

const
  MoneyBaseId* = "543be5dd4bdc2deb348b4569"
  RoublesTpl* = "5449016a4bdc2d6f028b456f"
  DollarsTpl* = "5696686a4bdc2da3298b456a"
  EurosTpl* = "569668774bdc2da2298b4568"

type
  MoneyStackConfig* = object
    ## Every default here reproduces the previous behaviour exactly: a
    ## multiplier of 1.0 and a floor/ceiling of 0 mean "the item's own declared
    ## range, untouched", which is what `randomStackCount` did before.
    multiplier*: float   ## scales a rolled currency stack
    floorCount*: int     ## 0 = no floor; otherwise the smallest stack allowed
    ceilCount*: int      ## 0 = no ceiling; otherwise the largest allowed

proc isMoneyTpl*(tpl: string): bool =
  tpl == RoublesTpl or tpl == DollarsTpl or tpl == EurosTpl

proc moneyStackConfig*(): MoneyStackConfig =
  ## Read unconditionally, every pass, so the ledger sees all three whatever
  ## the values are. A conditional read would make the ledger report a key as
  ## dead purely because it was at its default.
  result = MoneyStackConfig(multiplier: 1.0, floorCount: 0, ceilCount: 0)
  result.multiplier = knob("moneyStackMultiplier").asFloat(1.0)
  result.floorCount = knob("moneyStackMin").asInt(0)
  result.ceilCount = knob("moneyStackMax").asInt(0)
  if result.multiplier < 0.0:
    result.multiplier = 0.0
  if result.multiplier > 50.0:
    result.multiplier = 50.0
  if result.floorCount < 0:
    result.floorCount = 0
  if result.ceilCount < 0:
    result.ceilCount = 0

proc applyMoneyStack*(cfg: MoneyStackConfig; rolled: int): int =
  ## Shape one rolled currency stack. Never returns below 1 for a stack that
  ## was rolled at all -- a currency item with `StackObjectsCount` 0 is the $1
  ## bug's worse cousin, an item the client draws as nothing.
  if rolled <= 0:
    return rolled
  var n = rolled
  if cfg.multiplier != 1.0:
    n = int(float(n) * cfg.multiplier + 0.5)
  if cfg.floorCount > 0 and n < cfg.floorCount:
    n = cfg.floorCount
  if cfg.ceilCount > 0 and n > cfg.ceilCount:
    n = cfg.ceilCount
  if n < 1:
    n = 1
  result = n
