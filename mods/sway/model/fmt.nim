## Numbers as text, for a log line.
##
## `$` on a float here prints the full repr, which for a readout of a dozen
## numbers a line is unreadable, and the characterisation prints several hundred
## of them. In `model/` rather than beside the mod entry point because the
## characterisation is in `model/` and must stay runnable with no game and no
## host in the process.

import vec

proc fmt*(v: float; places: int): string =
  ## Fixed point, rounded, with a sign. No exponent form: a swept parameter that
  ## has gone to 1e300 should read as an obviously wrong number rather than as a
  ## compact one.
  if v != v:
    return "nan"
  if v > 1.0e300:
    return "+inf"
  if v < -1.0e300:
    return "-inf"
  var neg = false
  var x = v
  if x < 0.0:
    neg = true
    x = -x
  var scale = 1.0
  var i = 0
  while i < places:
    scale = scale * 10.0
    inc i
  if x * scale > 9.0e17:
    return (if neg: "-" else: "") & "big"
  let scaled = int(x * scale + 0.5)
  let whole = scaled div int(scale)
  let frac = scaled mod int(scale)
  result = (if neg: "-" else: "") & $whole
  if places > 0:
    var f = $frac
    while f.len < places:
      f = "0" & f
    result = result & "." & f

proc fmt3*(v: float): string = fmt(v, 3)
proc fmt2*(v: float): string = fmt(v, 2)

proc fmtNum*(v: float): string =
  ## Enough places to tell two config values apart, and no more. A tunable of
  ## 0.117 and one of 0.12 are different settings; a tunable of 5000 and one of
  ## 5000.001 are not.
  let a = (if v < 0.0: -v else: v)
  if a >= 100.0:
    result = fmt(v, 1)
  elif a >= 1.0:
    result = fmt(v, 3)
  else:
    result = fmt(v, 4)

proc fmtVec*(a: Vec3): string =
  "p " & fmt3(a.x) & "  y " & fmt3(a.y) & "  r " & fmt3(a.z)

proc pad*(s: string; n: int): string =
  ## Left-justified in a column, so a table of results reads as a table.
  result = s
  while result.len < n:
    result = result & " "
