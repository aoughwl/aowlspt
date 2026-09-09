## Run the boss-roll self-check on its own and print what it says.
##
## `emu/raid.selfCheckRaid` runs at mod load and a failure REFUSES the load,
## which is the right gate and a terrible way to read a result: the only way to
## see it is to start a backend. This prints the same lists directly.
##
## It also does the thing a self-check must be able to do and usually cannot be
## made to do on demand -- run the assertions against a DELIBERATELY BROKEN
## generator. `--forced` reproduces the measured defect (every boss emitted
## unconditionally, no exclusive map-boss slot) and must print failures. A run
## with no failures under `--forced` means the check cannot fail and is not a
## check.

import std/os
import std/syncio
import ../mods/tarkov/emu/raid

proc main() =
  var forced = false
  var i = 1
  while i <= paramCount():
    if paramStr(i) == "--forced": forced = true
    inc i
  var fails: seq[string] = @[]
  bossRollReport(forced, fails)
  echo (if forced: "FORCED (unconditional emission, no exclusive slot)"
        else: "AS SHIPPED (rolls each BossChance, exclusive map-boss slot)")
  if fails.len == 0:
    echo "  no failures"
  else:
    for f in fails:
      echo "  " & f
  echo "  " & $fails.len & " failure(s)"

main()
