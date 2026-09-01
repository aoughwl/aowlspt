## reactivedemo -- the smallest mod that proves reactive settings work.
##
## It exists to be COMPILED and to be READ. Compiled, it is the check that
## `aowlspt/reactive` actually builds into a mod on this toolchain -- a library
## nothing links is a library nobody knows is broken. Read, it is the whole
## API, and the contrast with the pattern it replaces is the point:
##
##   BEFORE, per setting: a global, a line in `loadConfig()`, and a `loadConfig()`
##   call somebody has to remember to make when the value changes. Three places,
##   and nothing happens when the player moves a slider.
##
##   AFTER: one line. `.value` is already current on every read.
##
## Nothing here calls a tick. That is not an omission -- `aowlspt/reactive`
## registers its pump with the library's own update shim at module init, so
## importing it is the whole wiring.

import aowlspt
import aowlspt/reactive

# ---- the entire settings surface of this mod --------------------------------
#
# Declared once, at module scope. No `loadConfig()`, no globals to refresh.
var enabled: ReactiveBool
var strength: ReactiveFloat
var label: ReactiveText
var budget: ReactiveInt

var gApplied = 0

proc onLoad(): Status =
  enabled  = reactiveBool("demoEnabled", true)
  strength = reactiveFloat("demoStrength", 1.0)
  label    = reactiveText("demoLabel", "unnamed")
  budget   = reactiveInt("demoBudget", 100)
  reactiveLoad()          # fill them now; the load hook already ran

  # A handler is OPTIONAL. A mod that only reads `.value` gets reactivity with
  # no handler at all; this one has something to re-apply, so it says so.
  strength.onChange = proc(old, now: float) =
    inc gApplied
    info "reactivedemo: strength " & $old & " -> " & $now & ", re-applied"

  enabled.onChange = proc(old, now: bool) =
    info "reactivedemo: enabled " & $old & " -> " & $now

  # Run the apply step once against the value already loaded, instead of
  # duplicating it here and in the handler.
  strength.fireNow()

  info "reactivedemo loaded. " & reactiveReport()
  Ok

proc onUpdate(elapsedMs: int64): Status =
  # THE POINT: no reload call, no polling, no staleness check. If the player
  # edits demoStrength in the settings screen, the next read here is the new
  # value and the handler has already run.
  if enabled.value:
    discard strength.value * float(budget.value)
  Ok

proc onUnload(): Status =
  info "reactivedemo unloading. " & reactiveReport() &
       "; applies=" & $gApplied
  Ok

exportMod(
  guid = "aowl.reactivedemo",
  name = "Reactive Settings Demo",
  author = "aowlspt",
  version = "0.1.0",
  sptRange = "~4.1.0",
  sides = {sideClient, sideServer, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
