## Reading a store key without confusing "nothing here" with "unreadable".
##
## One line of this module exists because of one bug, and the bug is worth
## stating in full because its *shape* recurs and the shape is what a reader
## should learn to spot.
##
## `load` used to answer `ok: false` for two completely different situations:
##
## - **there is nothing under this key**, which is ordinary. A profile that has
##   never listed anything on the flea has no market key; a new profile has no
##   mailbox. Every reader here treats that as "start from empty", correctly.
## - **there is something under this key and it could not be read** -- a sharing
##   violation, a disk error, a file another process has open. Rare, transient,
##   and invisible.
##
## The recovery for the first is *to start from empty and write*. Applied to the
## second, that recovery **overwrites a real value with an empty one**. A
## mailbox holding a quest reward and four insurance returns becomes a mailbox
## holding one message. A profile's saved builds become none. The flea offers
## the player has money tied up in cease to exist. Nothing errors anywhere: the
## read failure is silent, the write succeeds, and the client is told everything
## is fine.
##
## The general form: **two different situations answering the same value, where
## the recovery for one of them is destructive to the other.** Anywhere a "not
## found" leads to *creating* or *replacing* something, the question to ask is
## whether the read underneath can also fail for a reason that is not absence.
##
## `Stored.missing` is the store's answer: `ok: false, missing: true` is
## genuinely nothing there, and `ok: false, missing: false` is a value that
## exists and could not be read. This module is the one place that distinction
## is turned into a flag the callers here act on, so there is one place to look
## when it is wrong.
##
## ## What the callers do with it
##
## A **read-only** path takes the empty answer, as it always did: showing an
## empty mailbox for one request is not damage, and the failure is now logged
## rather than silent. A path that is about to **write** refuses instead. That
## asymmetry is the whole design: reading wrong is a screen, writing wrong is a
## player's account.

import aowlspt
import aowlspt/server

proc readKey*(key: string; usable: var bool): string =
  ## The value under `key`, or "" when there is genuinely none.
  ##
  ## `usable` is false only for the third case -- present and unreadable -- and
  ## a caller that is about to write must refuse on it. It is *true* for a key
  ## that is simply not there, because writing over nothing is what creating
  ## something is.
  usable = true
  let stored = load(key)
  if stored.ok:
    return stored.raw
  if stored.missing:
    return ""
  usable = false
  error "the store holds " & key & " and could not read it: " & stored.error &
        "; refusing to treat that as an empty value"
  result = ""

proc readKey*(key: string): string =
  ## For the read-only paths. The failure is logged by the overload above; what
  ## the caller gets is the same empty value it got before this module existed,
  ## which is a screen showing nothing rather than a write destroying something.
  var usable = true
  result = readKey(key, usable)
