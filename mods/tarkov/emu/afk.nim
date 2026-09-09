## The AFK kick, disabled at the data source.
##
## MEASURED 2026-09-04. The client idled ~9 h at the main menu and then raised
## an ERRORDIALOG `kind=critical`, header "AFK timeout", text "The game will be
## closed due to a long period of inactivity", after which it stopped calling
## `TarkovApplication::Update`. No crash. Single-player has no reason for an
## AFK kick.
##
## The mechanism, from the metadata (`tools/il2cpp_resolve.py`):
##
##   `EFT.AFKMonitor` (type 7945) -- fields `_afkTimeout`@0x10 (float),
##   `_cancellationSource`@0x18, `_errorWindowContext`@0x20, and the constants
##   `TIME_TO_CANCEL_SECONDS = 30`, `AFK_ERROR_HEADER`, `AFK_ERROR_TEXT`.
##   Methods `Start`@0x9e8450, `Stop`@0x9e87a0, `StartWaiting`@0x9e8910,
##   `TryQuitApplication`@0x9e8ac0, `QuitApplication`@0x9e8db0,
##   `AwaitInput`@0x9e8e00 -- all UNIQUE RVAs.
##
##   It is owned in two places: `EFT.MatchmakerOperation._afkMonitor`@0x68 and
##   `EFT.CreateProfileOperation`+0x48; both call `AFKMonitor::Start` directly
##   (`callers 0x9e8450`).
##
##   `Start` takes its threshold from a static singleton, NOT from its owner:
##
##       0x9e8513  call 0x9f70                    ; static-field getter thunk
##       0x9e8526  movss xmm6, [rax + 0x90]       ; the config value
##       0x9e852e  movss [rbx + 0x10], xmm6       ; this._afkTimeout = it
##       0x9e854a  comiss xmm6, [.rdata 0x65b55a0]; = 1.401e-45 (0x00000001)
##       0x9e8556  setb  al
##       0x9e855b  jne   0x9e8769                 ; -> Debug.LogError; RET
##
##   So a threshold of **0 (or any value <= 0) is the game's own disabled
##   path**: `Start` logs an error and returns before it ever builds the
##   cancellation source, the state machine or the error window. That is a
##   branch in BSG's code, not a patch of ours.
##
## Where the number comes from, and the timing that proves it:
##
##   `settings.config.AFKTimeoutSeconds` -- the document served at
##   `/client/settings`. Our live database holds **32000** (`bigjson.py find
##   --key AFKTimeoutSeconds D:/Aowlspt/aowlspt/db.json`). The dialog fired at
##   host-log elapsed **8:54:00 = 32040 s**; 32000 s is 8 h 53 m 20 s. The
##   captured stock value is 1800 (`data/capture/raid1/.../037.json`,
##   `data.config.AFKTimeoutSeconds`), i.e. BSG's own 30 min. The observed
##   fire time matching the served value to within the poll interval is the
##   measurement that ties this field to that dialog; the disassembly alone
##   could only show which field `Start` reads.
##
## So the fix is DATA, not a host patch: serve 0 and `AFKMonitor::Start`
## refuses to start. No flag, no detour, no code hop.

import aowlspt
import aowlspt/json

const AfkKey* = "AFKTimeoutSeconds"
  ## The member of the served `settings.config` that `AFKMonitor::Start` reads
  ## through the static singleton at +0x90.

const AfkDisabledValue* = "0"
  ## The value the CLIENT treats as disabled -- see the `comiss`/`setb` above.
  ## Not a large number: a large number still arms the monitor and still kicks,
  ## just later, which is precisely the bug that was observed.

var gWasStock = ""
  ## What the database held before we overrode it, for the load-time report.
  ## Empty means "the route has not been answered yet", which is a different
  ## thing from "the database held nothing" and is reported as such.
var gApplied = false

proc afkStockValue*(): string = gWasStock
proc afkApplied*(): bool = gApplied

proc disableAfkKick*(settingsText: string): string =
  ## The `/client/settings` document as the client should receive it.
  ##
  ## Rewrites exactly one member of `config` and carries every other member
  ## through as its own raw text. Returns its input unchanged -- and says
  ## nothing took -- if the document does not parse or has no `config`.
  var doc = parseObject(settingsText)
  if not doc.ok:
    return settingsText
  let cfgRaw = getRaw(doc, "config")
  if cfgRaw.len == 0 or cfgRaw[0] != '{':
    return settingsText
  var cfg = parseObject(cfgRaw)
  if not cfg.ok:
    return settingsText
  gWasStock = getRaw(cfg, AfkKey)
  if gWasStock == AfkDisabledValue:
    gApplied = true
    return settingsText
  setRaw(cfg, AfkKey, AfkDisabledValue)
  setRaw(doc, "config", text(cfg))
  gApplied = true
  result = text(doc)

proc selfCheckAfk*(into: var seq[string]): bool =
  ## Negative assertions about the FINISHED document (CLAUDE.md 9b). Each one
  ## names an input that makes it fail, and none of them re-reads this module's
  ## own write by comparing it to what it wrote -- they read the finished text
  ## back through the JSON reader.
  result = true

  # 1. The value the client sees is the DISABLED one. A stub that returned its
  #    input unchanged fails this.
  block:
    let src = """{"config":{"AFKTimeoutSeconds":32000,"Kept":7},"other":[1,2,3]}"""
    let outText = disableAfkKick(src)
    if field(outText, "config.AFKTimeoutSeconds").asInt(-1) != 0:
      into.add "afk: the served settings document still carries a non-zero " &
               "AFKTimeoutSeconds -- the client will still arm AFKMonitor"
      result = false
    # 2. Patching one member must not destroy its siblings, nor the document.
    if field(outText, "config.Kept").asInt(0) != 7:
      into.add "afk: disabling the AFK kick destroyed a sibling of config." &
               AfkKey
      result = false
    if not field(outText, "other").isArray:
      into.add "afk: a non-object member did not survive the settings rewrite"
      result = false
    if afkStockValue() != "32000":
      into.add "afk: the stock value was not reported as 32000, so the " &
               "load-time report cannot be trusted"
      result = false

  # 3. Idempotent: running it on its own output must not change it again, and
  #    must still read back as disabled.
  block:
    let once = disableAfkKick("""{"config":{"AFKTimeoutSeconds":1800}}""")
    let twice = disableAfkKick(once)
    if field(twice, "config.AFKTimeoutSeconds").asInt(-1) != 0:
      into.add "afk: the override is not idempotent"
      result = false

  # 4. A document with no `config` is carried through UNCHANGED rather than
  #    half-rewritten. The input that makes this fail is a patcher that
  #    invents the branch it was asked to edit.
  block:
    let src = """{"nothing":1}"""
    if disableAfkKick(src) != src:
      into.add "afk: a settings document without a `config` member was " &
               "rewritten anyway"
      result = false

  # 5. Unparseable input is returned as-is, never truncated. A client handed
  #    an unparseable settings body hangs rather than errors.
  block:
    let junk = "not json at all"
    if disableAfkKick(junk) != junk:
      into.add "afk: unparseable settings text was not carried through intact"
      result = false
