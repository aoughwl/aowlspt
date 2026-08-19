## Writing a number into a document.
##
## One proc, and it is here rather than in the module that first needed it so
## that there is exactly **one** answer to "how does this server print a float".
## Scattered formatting is how two routes end up disagreeing about the same
## value, and the value they disagree about is usually one a player is reading
## off a screen.
##
## ## Why `$` is not the answer
##
## `$` on a float prints the shortest text that round-trips the *binary* value.
## That is the right default for a language and the wrong one for a document a
## player's account is stored in: Fence standing after two scav runs worth 0.01
## each went into the profile as `0.020000000000000004`. Valid JSON, correct
## arithmetic, and still wrong to store, for two reasons.
##
## It **grows**. The profile is read and written whole on every request, and a
## value that gains digits every time it is added to is a document that gets
## bigger and a request that gets slower, forever, with nothing announcing it.
##
## And it makes a checkable value unquotable. A test, a bug report and a support
## answer all have to say "about 0.02" instead of "0.02", and "about" is exactly
## the word that lets a wrong number through.
##
## ## Why this is fixed point, not a prettier print
##
## The important half is not the printing: it is that the value is **snapped to
## a 1/1,000,000 grid every time it is written**. The stored decimal is the
## accumulator, so the next addition starts from a clean number and the error
## cannot compound. That is fixed point in micro-units, kept as a decimal on the
## wire because the wire is what the reference specifies — `TraderInfo.Standing`
## and the rest are `Nullable<Double>`, and a client expecting a number and
## handed a string is a far worse bug than an ugly decimal.
##
## The cost is named rather than hidden: **a gain smaller than 5×10⁻⁷ rounds to
## nothing.** Every rate in this server is a hundredth or larger, four orders of
## magnitude clear of it, and a rate that small would be one a player could
## never observe either. If something ever needs finer, the grid is one constant.

proc numText*(v: float): string =
  ## A float as JSON text: rounded to six decimal places, with no fractional
  ## part when it does not need one — so a durability of 99 reads back as `99`
  ## and a standing of one hundredth as `0.01`.
  var neg = false
  var x = v
  if x < 0.0:
    neg = true
    x = -x
  if x >= 1.0e15:
    # Past the point where scaling by a million loses the integer part. Nothing
    # here produces such a number, and answering with the plain conversion is
    # better than answering with a wrapped one.
    return $v
  let scaled = int(x * 1000000.0 + 0.5)
  let whole1 = scaled div 1000000
  var frac = scaled mod 1000000
  result = $whole1
  if frac > 0:
    var digits = ""
    var place = 100000
    while place > 0:
      digits.add char(ord('0') + (frac div place))
      frac = frac mod place
      place = place div 10
    var last = digits.len - 1
    while last >= 0 and digits[last] == '0':
      dec last
    if last >= 0:
      result = result & "." & digits.substr(0, last)
  if neg:
    result = "-" & result
