## Frame-time distribution.
##
## ---------------------------------------------------------------------------
## Why a mean is the wrong statistic, and why this module exists
## ---------------------------------------------------------------------------
##
## The readout in `frame.nim` closes a window every second and divides frames
## by wall clock. That is a **mean**, and the mean is the one statistic that
## cannot see the thing this mod exists to change.
##
## A second containing sixty even 16.7 ms frames and a second containing
## fifty-five 14 ms frames and one 200 ms freeze both report about sixty frames
## per second. The first is what the player wants; the second is the stutter
## they came to a performance mod to get rid of. `best` and `worst` do not help,
## because they are the best and worst *of the one-second means* — a hitch has
## to last most of a second before it moves either of them.
##
## So this is the distribution: every frame interval, into a fixed histogram,
## reported as p50/p99/p99.9 and a count of frames over a hitch threshold. Those
## are the numbers that change when a setting helps, and they are the numbers
## that stay flat when it does not.
##
## ---------------------------------------------------------------------------
## The layout, and what it costs
## ---------------------------------------------------------------------------
##
## 1024 buckets of 64 microseconds, covering 0 .. 65.536 ms, plus an overflow
## tail. Recording one sample is a compare, a shift and an increment into a
## fixed array — no allocation, no branch on a data structure that could grow,
## and nothing that can fail. That matters because this runs on the game's
## thread once a frame: `recordUs` is measured by the self-test rather than
## asserted about, both in nanoseconds and against mimalloc's cumulative
## allocation count.
##
## 64 microseconds is 0.4 percent of a 16.7 ms frame, which is finer than the
## difference any of `knobs.nim`'s settings will make, and 1024 of them fit in
## 4 KB — one page, so the whole histogram stays in L1 and the increment never
## misses.
##
## **The tail is exact where the histogram is not.** A 300 ms hitch does not fit
## in a 65 ms histogram, and clamping it into the top bucket would lose the only
## sample anyone cares about. Samples past the top are counted separately, their
## sum is kept, and `maxUs` is the true maximum whatever bucket it would have
## fallen in — so "the worst frame this session" is an exact number even though
## "the 99th percentile" is a bucket edge. A percentile whose rank lands in that
## tail says so (`fromTail`) rather than reporting the top edge as though the
## histogram had contained it.
##
## Hitches are counted with their own comparison rather than derived from the
## buckets, because a threshold that does not fall on a bucket edge would
## otherwise be answered to the nearest 64 microseconds, and "over 50 ms" is a
## claim about 50 ms.
##
## ---------------------------------------------------------------------------
## Cumulative, and reset when the thing being measured changes
## ---------------------------------------------------------------------------
##
## The histogram accumulates rather than resetting per window. Sixty samples is
## not enough to have a 99th percentile — p99 of sixty samples is the maximum
## wearing a different name — so a per-window distribution would be noise
## printed to three decimal places.
##
## What it resets on is a **change to what is being measured**: applying or
## restoring a setting clears it, because a distribution that straddles the
## change describes neither configuration. That is also what makes an A/B
## possible at all: apply, let it fill, read p99; restore, let it fill, read p99
## again. `aowl.perf.resetFrameTimes` does it by hand.
##
## Nothing here has ever run against BSG's client.

const
  HistBuckets* = 1024
    ## Buckets below the tail. 4 KB of `int32`, which is one page.
  HistBucketUs* = 64
    ## Microseconds per bucket.
  HistTopUs* = HistBuckets * HistBucketUs
    ## 65536 us. A sample at or above this goes in the tail.

# Bare declarations, zero-initialised. A global initialised by a *call* is left
# zeroed in a nimony `--app:lib` build, so anything needing computation is done
# in `resetHist` and called from a proc.
var gBucket: array[HistBuckets, int32]
var gCount: int64 = 0
var gSumUs: int64 = 0
var gMinUs: int64 = 0
var gMaxUs: int64 = 0
var gTail: int64 = 0          ## samples at or above HistTopUs
var gTailSumUs: int64 = 0
var gHitches: int64 = 0
var gHitchUs: int64 = 50000   ## 50 ms, overridden from config
var gEpoch: int64 = 0         ## incremented by every reset; names the run

proc setHitchUs*(us: int64) =
  ## The threshold a frame has to exceed to be called a hitch. Set once from
  ## config, before anything is recorded.
  if us > 0:
    gHitchUs = us

proc hitchUs*(): int64 = gHitchUs

proc resetHist*() =
  ## Clears the distribution and starts a new epoch.
  ##
  ## Called when the configuration being measured changes, so that no reported
  ## percentile ever describes a mixture of two configurations.
  var i = 0
  while i < HistBuckets:
    gBucket[i] = 0'i32
    inc i
  gCount = 0
  gSumUs = 0
  gMinUs = 0
  gMaxUs = 0
  gTail = 0
  gTailSumUs = 0
  gHitches = 0
  gEpoch = gEpoch + 1

proc recordUs*(us: int64) =
  ## One frame interval. **This is the hot path** — once per frame, on the
  ## game's thread.
  ##
  ## Everything here is integer arithmetic on scalar globals and one store into
  ## a fixed array. No allocation, no call, and no way to fail: a negative
  ## interval (which a clock that went backwards would produce) is dropped
  ## rather than folded into the statistics, because one bogus sample in the
  ## tail moves p99.9 and nothing else would ever explain it.
  if us < 0:
    return
  gCount = gCount + 1
  gSumUs = gSumUs + us
  if gCount == 1 or us < gMinUs:
    gMinUs = us
  if us > gMaxUs:
    gMaxUs = us
  if us >= gHitchUs:
    gHitches = gHitches + 1
  let b = us div HistBucketUs
  if b >= HistBuckets:
    gTail = gTail + 1
    gTailSumUs = gTailSumUs + us
  else:
    gBucket[int(b)] = gBucket[int(b)] + 1'i32

proc histCount*(): int64 = gCount
proc histMinUs*(): int64 = gMinUs
proc histMaxUs*(): int64 = gMaxUs
proc histTail*(): int64 = gTail
proc histHitches*(): int64 = gHitches
proc histEpoch*(): int64 = gEpoch

proc histMeanUs*(): int64 =
  if gCount <= 0: return 0
  result = gSumUs div gCount

type
  Pct* = object
    ## One percentile, and how much to believe it.
    ok*: bool        ## there were samples at all
    us*: int64       ## the bucket's upper edge, or `HistTopUs` from the tail
    fromTail*: bool  ## the rank landed past the histogram's top

proc percentile*(pMilli: int64): Pct =
  ## The `pMilli`/1000-th percentile, `pMilli` being percent x1000 — so 50000
  ## is the median, 99000 is p99 and 99900 is p99.9. Integer throughout, since
  ## this is read on the same thread the samples are taken on.
  ##
  ## The value is the **upper edge** of the bucket the ranked sample fell in,
  ## which is the conservative direction: a reported p99 of 24.6 ms means 99
  ## percent of frames took *at most* that, never less than it.
  ##
  ## A rank landing in the tail cannot be answered from the buckets, and this
  ## says so rather than returning the top edge — reporting "p99 = 65.5 ms" for
  ## a distribution whose 99th percentile is really 300 ms is the plausible
  ## wrong number this whole mod is arranged not to produce. `histMaxUs` is
  ## still exact and is what the readout prints beside it.
  result = Pct(ok: false, us: 0'i64, fromTail: false)
  if gCount <= 0:
    return
  result.ok = true
  # Rank is 1-based and rounded up: the smallest sample count that covers the
  # requested fraction. Rounding down would make p100 of an even count the
  # second-largest sample.
  var rank = (gCount * pMilli + 99999'i64) div 100000'i64
  if rank < 1: rank = 1
  if rank > gCount: rank = gCount
  var seen = 0'i64
  var i = 0
  while i < HistBuckets:
    seen = seen + int64(gBucket[i])
    if seen >= rank:
      result.us = int64(i + 1) * int64(HistBucketUs)
      return
    inc i
  result.us = int64(HistTopUs)
  result.fromTail = true

# ---------------------------------------------------------------------------
# Save and restore
# ---------------------------------------------------------------------------
#
# A second copy of the whole histogram, so that *measuring* the recording path
# does not destroy the distribution being recorded.
#
# This exists because it was got wrong the obvious way first. `benchPumpBody`
# reset the histogram before and after timing itself, on the reasoning that the
# intervals between two adjacent clock reads are not frames and must not be
# reported as any -- which is true, and which threw away every frame collected
# before the self-test ran. The symptom was mild and would have been permanent:
# a distribution that silently restarted a few seconds into every session, so
# the "worst frame this session" was really the worst frame since the self-test.
#
# 4 KB of shadow, copied twice per benchmark run and never per frame.

var gSaveBucket: array[HistBuckets, int32]
var gSaveCount: int64 = 0
var gSaveSumUs: int64 = 0
var gSaveMinUs: int64 = 0
var gSaveMaxUs: int64 = 0
var gSaveTail: int64 = 0
var gSaveTailSumUs: int64 = 0
var gSaveHitches: int64 = 0
var gSaveEpoch: int64 = 0

proc saveHist*() =
  ## Snapshots the distribution. One snapshot at a time; a second call
  ## overwrites the first.
  var i = 0
  while i < HistBuckets:
    gSaveBucket[i] = gBucket[i]
    inc i
  gSaveCount = gCount
  gSaveSumUs = gSumUs
  gSaveMinUs = gMinUs
  gSaveMaxUs = gMaxUs
  gSaveTail = gTail
  gSaveTailSumUs = gTailSumUs
  gSaveHitches = gHitches
  gSaveEpoch = gEpoch

proc restoreSavedHist*() =
  ## Puts the snapshot back, **epoch included**.
  ##
  ## The epoch is restored rather than advanced on purpose: nothing about the
  ## configuration being measured changed, so a consumer watching `epoch` for
  ## "these numbers describe something new" must not be told that it did.
  var i = 0
  while i < HistBuckets:
    gBucket[i] = gSaveBucket[i]
    inc i
  gCount = gSaveCount
  gSumUs = gSaveSumUs
  gMinUs = gSaveMinUs
  gMaxUs = gSaveMaxUs
  gTail = gSaveTail
  gTailSumUs = gSaveTailSumUs
  gHitches = gSaveHitches
  gEpoch = gSaveEpoch

proc stutterRatioMilli*(): int64 =
  ## p99 divided by p50, x1000.
  ##
  ## The one number here that is about *smoothness* rather than speed, and the
  ## only one comparable between two machines: 1000 is a perfectly even frame
  ## pacing, 2000 means one frame in a hundred takes twice as long as the
  ## median. A setting can raise the mean and make this worse, and that trade is
  ## invisible in a frames-per-second readout.
  let p50 = percentile(50000'i64)
  let p99 = percentile(99000'i64)
  if not p50.ok or not p99.ok or p50.us <= 0:
    return 0
  result = (p99.us * 1000'i64) div p50.us
