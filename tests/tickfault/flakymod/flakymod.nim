## The mod that must **not** be disabled: it fails often and never twice in a
## row.
##
## This is the half of the threshold that a counter of *total* failures would
## get wrong, and it would get it wrong quietly -- a mod that works would go
## dark partway through a session because it had accumulated enough bad ticks.
## Every fourth tick here answers a failure, so over a long run it fails far
## more times than the threshold, and its run of consecutive failures is never
## longer than one.
import aowlspt

var ticks = 0

proc onLoad(): Status =
  info "flakymod loaded; every fourth call to on_update fails, never two in a row"
  Ok

proc onUpdate(elapsedMs: int64): Status =
  inc ticks
  info "TICK " & $ticks
  if ticks mod 4 == 0:
    return ErrGeneric
  Ok

exportMod(
  guid = "aowl.test.flakymod",
  name = "Tick Flake Fixture",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
