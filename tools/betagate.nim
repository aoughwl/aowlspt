## betagate -- the fail-closed decision core for the free-beta 7-day expiry.
##
## This is the toolchain-independent HEART of the beta gate designed in
## `docs/BETA-DISTRIBUTION.md`: given several untrusted clocks, a persisted
## anti-rollback ratchet, and whether the signed build stamp verified, decide
## whether the beta is still allowed to run.
##
## It contains NO crypto and NO OS calls on purpose -- Ed25519 verification of
## the stamp and the reads/writes of each time source and ratchet copy are the
## host/backend/launcher port around this. Keeping the decision pure is what
## lets it be unit-tested with the stock `nim` compiler today
## (`tests/test_betagate.nim`), which is exactly where CLAUDE.md's "a
## verification that cannot fail is the bug" says the danger lives.
##
## The whole module is deliberately a Nimony-compatible subset (int64, seq,
## openArray, enums -- no closures, no fancy stdlib), so the host port is a copy,
## not a rewrite.
##
## Design invariants, each also asserted as a NEGATIVE in the tests so it can
## actually fail:
##  * every time source is an UPPER BOUND on "now"; we take the MAX, so a source
##    can only ever move the verdict toward expiry -- rolling one back is inert
##    unless every other source and every ratchet copy is rolled back too.
##  * the stamp failing to verify is ALWAYS expired, at any clock value.
##  * exactly at expiryEpoch it is expired (dead ON day 7, not the instant after).
##  * "could not check" is never "allowed": there is no third permissive verdict.

type
  TimeSource* = object
    ## One untrusted upper-bound-on-now. `present == false` means the source
    ## could not be read this run (offline, missing file, unreadable ADS) and it
    ## is simply ignored -- never treated as time 0, which would wrongly drag the
    ## max backward.
    present*: bool
    epoch*:   int64      ## seconds UTC; meaningful only when present

  Verdict* = enum
    vExpired,            ## dead. ALSO the value for every inconclusive case.
    vValid               ## still inside the 7-day window and the stamp verified.

proc src*(epoch: int64): TimeSource =
  ## a present source.
  result.present = true
  result.epoch = epoch

proc absent*(): TimeSource =
  ## a source that could not be read.
  result.present = false
  result.epoch = 0

proc reconcile*(sources: openArray[TimeSource]; ratchet: int64): int64 =
  ## effectiveNow = max(ratchet, every PRESENT source). Absent sources are
  ## skipped. The ratchet is always in the running max (it is our own
  ## highest-ever-seen watermark, so it is trusted as a lower bound on the truth
  ## and can only push the answer later).
  result = ratchet
  for s in sources:
    if s.present and s.epoch > result:
      result = s.epoch

proc decide*(effectiveNow, expiryEpoch: int64; stampOk: bool): Verdict =
  ## The fail-closed gate. Order matters: the stamp is checked FIRST, so a
  ## missing/forged/tampered stamp is expired no matter what the clocks say.
  if not stampOk:
    return vExpired
  ## dead ON day 7: `>=`, not `>`. expiryEpoch is the first dead instant.
  if effectiveNow >= expiryEpoch:
    return vExpired
  return vValid

proc nextRatchet*(current, effectiveNow: int64): int64 =
  ## The value to persist back to every ratchet location: monotonic, never
  ## regresses. A source that read later than we have ever seen advances it;
  ## nothing lowers it.
  if effectiveNow > current: effectiveNow else: current

proc gate*(sources: openArray[TimeSource]; ratchet, expiryEpoch: int64;
           stampOk: bool): Verdict =
  ## Convenience: reconcile then decide. The host also calls `nextRatchet` with
  ## the same `reconcile` result to persist the watermark forward.
  decide(reconcile(sources, ratchet), expiryEpoch, stampOk)
