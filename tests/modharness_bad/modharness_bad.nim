## The NEGATIVE CONTROL for `tools/modharness.py`.
##
## A harness whose failing case has never fired is a harness that cannot fail
## (CLAUDE.md 9b). This mod exists so that one has. It is deliberately broken,
## it is never in `mods/`, it is never in `mods/aowlspt-selection.json`, and it
## must never be deployed.
##
## What it does: it loads cleanly, declares a real two-row schema, and answers
## the FIRST `aowlspt.settings.pageQuery` correctly. On the SECOND delivery it
## writes through a pointer of `0xdfdfdfdfdfdfdfdf` -- mimalloc's
## `MI_DEBUG_FREED` fill, and the literal value read out of the minidump of the
## 2026-09-02 03:00 client crash this whole harness was built to catch offline.
##
## The shape is chosen on purpose: a fault on the second delivery is invisible
## to any check that only looks at the first one, so it proves the harness's
## delivery-twice rule AND its out-of-process fault guard at the same time. A
## `try/except` around a ctypes call cannot catch this; only the child process
## dying can, and the harness must turn that into
## `FAIL ... faulted during 'deliver pageQuery #2'` rather than a traceback.
##
##     python tools/buildlock.py build-mod tests/modharness_bad
##     python tools/modharness.py tests/modharness_bad/bin/modharness_bad.dll
##     # expected: exit 1

import aowlspt
import aowlspt/settings

const
  ModGuid = "aowl.modharness_bad"
  ModName = "Harness negative control"
  ModAuthor = "aowlspt"
  ModVersion = "1.0.0"

  FreedFill = 0xdfdfdfdfdfdfdfdf'u64
    ## MI_DEBUG_FREED. Guaranteed unmapped; the write below is an access
    ## violation on every Windows build there has ever been.

var gPageDeliveries = 0

proc badSchema(): seq[Setting] =
  result = @[
    boolSetting("enabled", "Enabled", true,
                category = "Harness",
                description = "Present so the schema is not empty; a schema " &
                              "with no rows would make the harness report " &
                              "INCONCLUSIVE instead of exercising the page."),
    boolSetting("faultOnSecondPageQuery", "Fault on the second page query", true,
                category = "Harness",
                description = "This mod always does. The row is here so the " &
                              "reason is visible in the served schema itself.")
  ]

proc onSecondPageQuery(payload: string): string =
  ## Subscribed AFTER `declareSettings`, so the real settings handler has
  ## already emitted its announce by the time this runs -- delivery 1 therefore
  ## produces a correct, strict-JSON reply, and only delivery 2 dies. Any check
  ## that stopped after one delivery would pass this mod.
  if payload != ModGuid: return ""
  inc gPageDeliveries
  if gPageDeliveries >= 2:
    error "modharness_bad: second pageQuery -- writing through " &
          "0xdfdfdfdfdfdfdfdf now. If you are reading this line in a live " &
          "client, the wrong DLL was deployed."
    cast[ptr uint64](FreedFill)[] = 1'u64
  result = ""

proc onLoad(): Status =
  declareSettings(badSchema())
  discard on("aowlspt.settings.pageQuery", onSecondPageQuery)
  info "modharness_bad: loaded. This mod is a negative control and WILL fault " &
       "on the second settings page query."
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad)
