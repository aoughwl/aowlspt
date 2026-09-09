## The bystander. It shares the tick loop with a mod that fails on every pass,
## and the whole point of it is that nothing about that reaches it.
##
## The failure this guards against is the tempting over-correction: a host that
## reacts to a bad mod by stopping the tick, or by taking the loop down, or by
## skipping the rest of the sequence after the one that failed. This mod is
## loaded *after* the faulting one, so it is the one a `break` would silence.
import aowlspt

var ticks = 0

proc onLoad(): Status =
  info "goodmod loaded"
  Ok

proc onUpdate(elapsedMs: int64): Status =
  inc ticks
  info "TICK " & $ticks
  Ok

exportMod(
  guid = "aowl.test.goodmod",
  name = "Tick Bystander Fixture",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
