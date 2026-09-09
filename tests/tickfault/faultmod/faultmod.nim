## The mod the tick-fault gate is about: `on_update` fails, every single time.
##
## Nothing in this repository does that -- every shipped mod returns `Ok` from
## every path of its `on_update`, which is *why* the host's honouring of the
## status went years without being noticed missing, and why a fixture has to
## exist for it. A gate whose subject never faults is a gate that passes
## because the thing it checks never happened.
##
## It says so on every tick, through the host's own `log`, and the harness
## counts those lines. That is how "the host stopped dispatching to it" is
## established as a fact rather than inferred from a log line the host wrote
## about itself: the count freezes because the mod is no longer running.
import aowlspt

var ticks = 0

proc onLoad(): Status =
  info "faultmod loaded; its on_update fails on every tick"
  Ok

proc onUpdate(elapsedMs: int64): Status =
  inc ticks
  # One line per tick, so the harness can count the calls that actually
  # happened. The marker is `TICK` and nothing else: the harness counts these
  # by prefix, and a prose sentence that happens to contain the word "tick"
  # -- which one of these fixtures did, in its load line -- is otherwise
  # indistinguishable from a tick that ran. `AOWLSPT_ERR_MOD_FAULT` rather
  # than a generic failure, because this is precisely the case the ABI named
  # it for.
  info "TICK " & $ticks
  ErrModFault

exportMod(
  guid = "aowl.test.faultmod",
  name = "Tick Fault Fixture",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
