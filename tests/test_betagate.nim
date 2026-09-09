## Unit tests for the beta-expiry decision core.
##
##   nim c -r tests/test_betagate.nim
##
## Every case is phrased as a property that CAN fail (CLAUDE.md 9b: a check that
## cannot fail is the bug). We assert the negatives -- a rolled-back clock does
## NOT extend life, a bad stamp is NEVER valid, "valid" NEVER appears at/after
## expiry -- because a self-comparison cannot be falsified and these can.

import ../tools/betagate

const
  Build  = 1_700_000_000'i64          # arbitrary build instant (s UTC)
  Week   = 7'i64 * 86_400
  Expiry = Build + Week

var failures = 0
proc check(name: string; ok: bool) =
  if ok: echo "ok   ", name
  else:
    echo "FAIL ", name
    inc failures

# --- basic window --------------------------------------------------------
check "valid just after build",
  gate([src(Build + 10)], Build, Expiry, true) == vValid

check "valid one second before expiry",
  gate([src(Expiry - 1)], Build, Expiry, true) == vValid

check "EXPIRED exactly at expiry (dead on day 7, not after)",
  gate([src(Expiry)], Build, Expiry, true) == vExpired

check "expired well past expiry",
  gate([src(Expiry + 999999)], Build, Expiry, true) == vExpired

# --- stamp is the first gate --------------------------------------------
check "bad stamp is expired even when the clock says day 1",
  gate([src(Build + 10)], Build, Expiry, false) == vExpired

check "bad stamp is expired even with all sources absent",
  gate([absent()], Build, Expiry, false) == vExpired

# --- anti-rollback ratchet ----------------------------------------------
# The ratchet already recorded a time PAST expiry (we ran on day 8 once). Now
# the attacker sets the wall clock back to day 1. Must stay dead.
check "rolled-back clock cannot revive once ratchet passed expiry",
  gate([src(Build + 10)], Expiry + 100, Expiry, true) == vExpired

# One source rolled back but another honest source is past expiry: max wins.
check "one honest source past expiry beats a rolled-back one",
  gate([src(Build + 10), src(Expiry + 5)], Build, Expiry, true) == vExpired

# reconcile takes the max of ratchet + present sources; absent ignored.
check "reconcile ignores absent, takes max",
  reconcile([absent(), src(Build + 5), absent(), src(Build + 50)], Build + 20) ==
    Build + 50

check "reconcile falls back to ratchet when everything absent",
  reconcile([absent(), absent()], Build + 77) == Build + 77

check "an absent source is not treated as epoch 0",
  reconcile([absent()], Build) == Build   # not 0, which would look pre-build

# --- monotonic ratchet advance ------------------------------------------
check "ratchet advances to a newer effectiveNow",
  nextRatchet(Build, Build + 500) == Build + 500

check "ratchet never regresses",
  nextRatchet(Build + 500, Build + 10) == Build + 500

# --- exhaustive: nothing yields valid at/after expiry -------------------
block:
  var anyBadValid = false
  for dt in [0'i64, 1, 2, Week, Week + 1, 10 * Week]:
    let now = Build + dt
    for ratchet in [Build - 100, Build, now, Expiry + 1]:
      let v = gate([src(now)], ratchet, Expiry, true)
      let effNow = reconcile([src(now)], ratchet)
      if effNow >= Expiry and v == vValid: anyBadValid = true
  check "NO combination is valid once effectiveNow >= expiry", not anyBadValid

if failures == 0:
  echo "\nall betagate properties hold"
  quit(0)
else:
  echo "\n", failures, " FAILED"
  quit(1)
