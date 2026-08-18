## `Toggle` — a boolean that remembers when it last changed.
##
## This is SAIN's `ToggleEvent`, and it is the single most load-bearing
## primitive in the whole design. Nearly every threshold in the C# is not
## "is X true" but "has X been true for long enough", and nearly every
## oscillation bug in bot AI is a check that forgot the second half.
##
## SAIN's version is a class with a C# event; a mod that allocates one of those
## per boolean per bot is allocating a few thousand objects at raid start and
## invoking delegates from the tick loop. Here it is 24 bytes of value type with
## no indirection, which is the same behaviour and none of the cost.

type
  Toggle* = object
    value*: bool
    changedAt*: float
    ## The value before the last change. Lets a consumer distinguish "just
    ## became true" from "has been true", which several of SAIN's checks need
    ## and get by comparing against a separately stored previous flag.
    previous*: bool

func newToggle*(initial: bool = false): Toggle =
  Toggle(value: initial, changedAt: 0.0, previous: initial)

proc set*(t: var Toggle; value: bool; now: float): bool =
  ## Returns whether this call changed it — the edge, which is what a caller
  ## that wants to react once rather than every tick is asking for.
  if t.value == value:
    return false
  t.previous = t.value
  t.value = value
  t.changedAt = now
  result = true

func timeSinceChange*(t: Toggle; now: float): float = now - t.changedAt

func heldFor*(t: Toggle; now: float; seconds: float): bool =
  ## True when the flag is set *and* has been for at least `seconds`. The
  ## normal way to read one of these.
  t.value and (now - t.changedAt) >= seconds

func clearedFor*(t: Toggle; now: float; seconds: float): bool =
  (not t.value) and (now - t.changedAt) >= seconds

type
  Cooldown* = object
    ## The other half of the hysteresis vocabulary: "not again before".
    ## SAIN spells this out as a `_nextSomethingTime` float per check; naming
    ## the pattern makes the checks read as what they are.
    readyAt*: float

func newCooldown*(): Cooldown = Cooldown(readyAt: 0.0)

func ready*(c: Cooldown; now: float): bool = now >= c.readyAt

proc arm*(c: var Cooldown; now: float; seconds: float) =
  c.readyAt = now + seconds
