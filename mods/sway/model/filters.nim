## The two filters the model runs everything through.

import std/math
import vec

type
  OnePole* = object
    ## One-pole low-pass, frame-rate independent.
    ##
    ## The coefficient is derived from the real elapsed time rather than being a
    ## fixed lerp factor, so the same cutoff behaves identically at 60 and at
    ## 240 fps. A plain `lerp(a, b, 0.2)` would silently become a different
    ## filter every time the frame rate moved.
    state*: Vec3
    primed*: bool

  OnePole1* = object
    ## Scalar form of `OnePole`.
    state*: float
    primed*: bool

  DcBlocker* = object
    ## Removes the DC offset from a signal so a source can never drag the point
    ## of aim off centre over time, however asymmetric its waveform is.
    mean*: float
    primed*: bool

proc filter*(f: var OnePole; value: Vec3; dt, cutoffHz: float): Vec3 =
  if cutoffHz <= 0.0:
    f.state = value
    f.primed = true
    return value
  if not f.primed:
    f.state = value
    f.primed = true
    return value
  let a = clamp01(1.0 - exp(-2.0 * PI * cutoffHz * dt))
  f.state = f.state + (value - f.state) * a
  result = f.state

proc reset*(f: var OnePole) =
  f.state = Zero3
  f.primed = false

proc filter*(f: var OnePole1; value, dt, cutoffHz: float): float =
  if cutoffHz <= 0.0:
    f.state = value
    f.primed = true
    return value
  if not f.primed:
    f.state = value
    f.primed = true
    return value
  let a = clamp01(1.0 - exp(-2.0 * PI * cutoffHz * dt))
  f.state = f.state + (value - f.state) * a
  result = f.state

proc reset*(f: var OnePole1) =
  f.state = 0.0
  f.primed = false

proc track*(d: var DcBlocker; value, dt, timeConstant: float): float =
  ## Advances the running mean and returns it, for callers centring several
  ## axes on one signal.
  if not d.primed:
    d.mean = value
    d.primed = true
  let k = 1.0 - exp(-dt / fmax(0.01, timeConstant))
  d.mean = d.mean + (value - d.mean) * k
  result = d.mean

proc apply*(d: var DcBlocker; value, dt, timeConstant: float): float =
  value - track(d, value, dt, timeConstant)

proc reset*(d: var DcBlocker) =
  d.mean = 0.0
  d.primed = false
