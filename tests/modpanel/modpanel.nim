## modpanel -- the switch position a panel row shows, for a mod that runs on a
## side this manager is not.
##
## `mods/manager/manager.nim` drew `enabled` on `/panel` and `/list` straight
## from `d.verdict == vLoaded`, where `d` came from the resolution computed on
## the side the manager runs on -- the server. Every mod that declares a client
## side and no server side resolves `wrong-side` there, so the row read
## `enabled:false` no matter what the player had asked for.
##
## Measured against the live install on 2026-08-28, before the fix:
## `/aowlspt/mods/panel` returned, for `aowl.fovfix`, `"enabled": false` beside
## `"clientLive": true, "clientWant": true, "live": true`, while
## `store/aowl.manager/selection` held `{"id":"aowl.fovfix","enabled":true}`.
## The mod was loaded and running in the game and the switch was drawn OFF.
## Pressing it would have flipped the stored override to false and unloaded it,
## so the gesture that looks like enabling FOV is the one that disables it.
##
## What is checked here is the RULE, over the repo's own `registry/mods.json`,
## not the edit: `effectiveWant` substitutes the client resolution's answer for
## a `wrong-side` verdict on a mod that declares a client side, and for nothing
## else. The negative cases are the point -- a rule that only ever turned
## switches on would pass a check written the other way round.
##
## No backend, no host, no socket: `resolve` depends on nothing but its
## arguments, which is what makes the panel's arithmetic testable at all.
##
## To run it alone:
##
##   nimony c --passC:-I<repo>\abi -p:<repo>\mods\manager\mgr
##            -p:<repo>\installer\src -p:<repo>\aowl\src
##            -o:modpanel.exe modpanel.nim

import std/syncio
import registry, resolve

var fails = 0
proc check(what: string; cond: bool) =
  if cond:
    echo "ok   ", what
  else:
    echo "FAIL ", what
    fails = fails + 1

# The repo's registry, read from disk. If this cannot be read every check below
# is INCONCLUSIVE rather than passing, and the file says so and stops -- a gate
# that reports "ok" over a registry it never loaded is the failure mode this
# whole test is about.
let reg = loadRegistry("registry/mods.json")
if not reg.ok:
  echo "FAIL could not read registry/mods.json: ", reg.error
  echo "INCONCLUSIVE -- nothing below was checked"
  quit 1

# The selection the live install actually holds: the beta list, with fovfix,
# graphics and debug overridden on. Written out rather than read so this test
# does not depend on a store that a human can change under it.
let lists = @["aowl.list.beta"]
let ovIds = @["aowl.fovfix", "aowl.graphics", "aowl.debug", "aowl.textures"]
let ovOn = @[true, true, true, false]

let srv = resolve(reg, lists, ovIds, ovOn, "server", "0.1.0")
let cli = resolve(reg, lists, ovIds, ovOn, "client", "0.1.0")

proc verdictOf(r: Resolution; id: string): Verdict =
  var i = -1
  if not decisionFor(r, id, i):
    return vUnknown
  result = r.decisions[i].verdict

proc declaresClient(id: string): bool =
  var i = -1
  if not findMod(reg, id, i):
    return false
  result = hasSide(reg.mods[i], "client")

## `effectiveWant`, reproduced exactly as manager.nim computes it. Kept as its
## own proc so the rule is stated once and every case below exercises the same
## arithmetic the routes do.
proc effectiveWant(id: string): bool =
  let v = verdictOf(srv, id)
  if v != vWrongSide:
    return v == vLoaded
  if not declaresClient(id):
    return false
  result = verdictOf(cli, id) == vLoaded

## Switching a client-only mod OFF does NOT reach the substitution: the
## override makes it `not-selected` on the server, which is a real decision and
## returns early. Measured, by asserting `wrong-side` there and watching it
## fail. So the negative that reaches the branch has to be a mod you DID ask
## for which the CLIENT resolution excludes on its own -- here by version: the
## overrides stay on, and the client host is pretended to be 0.0.1, below the
## `pipeline: ">=0.1.0"` every one of these three declares.
let srvOff = resolve(reg, lists, ovIds, ovOn, "server", "0.1.0")
let cliOff = resolve(reg, lists, ovIds, ovOn, "client", "0.0.1")

proc wantOff(id: string): bool =
  let v = verdictOf(srvOff, id)
  if v != vWrongSide:
    return v == vLoaded
  if not declaresClient(id):
    return false
  result = verdictOf(cliOff, id) == vLoaded

echo "-- the bug, stated as the server sees it --"
# If these ever stop holding, the premise has changed and the rest of this file
# is testing nothing. That is why they are checked rather than assumed.
check "aowl.fovfix is wrong-side on the server",
      verdictOf(srv, "aowl.fovfix") == vWrongSide
check "aowl.graphics is wrong-side on the server",
      verdictOf(srv, "aowl.graphics") == vWrongSide
check "aowl.debug is wrong-side on the server",
      verdictOf(srv, "aowl.debug") == vWrongSide
check "the raw server answer would have drawn fovfix OFF",
      (verdictOf(srv, "aowl.fovfix") == vLoaded) == false

echo "-- a client-only mod you asked for reads ON --"
check "aowl.fovfix", effectiveWant("aowl.fovfix")
check "aowl.graphics", effectiveWant("aowl.graphics")
check "aowl.debug", effectiveWant("aowl.debug")

echo "-- and one you did not still reads OFF --"
# `aowl.textures` declares a client side exactly as fovfix does and is
# overridden OFF. It is a weaker negative than it looks: on the server it
# resolves `not-selected`, not `wrong-side`, so `effectiveWant` returns before
# the substitution and this case never reaches the new branch at all. Kept,
# labelled, and NOT relied on -- the real negative is the group below.
check "aowl.textures is client-side too",
      declaresClient("aowl.textures")
check "aowl.textures reads OFF (early return, not the new branch)",
      effectiveWant("aowl.textures") == false

echo "-- the substitution branch can still answer OFF --"
# THE negative this file turns on, and it was missing for a first draft: a mod
# that IS `wrong-side` on the server, DOES declare a client side, and is
# switched off. That reaches the substitution and must come back false. Without
# it, replacing the branch body with a bare `return true` passed the whole
# file -- measured, by doing exactly that.
check "aowl.fovfix still reaches the branch (wrong-side on server)",
      verdictOf(srvOff, "aowl.fovfix") == vWrongSide
check "aowl.fovfix excluded by the client reads OFF", wantOff("aowl.fovfix") == false
check "aowl.graphics excluded by the client reads OFF", wantOff("aowl.graphics") == false
check "aowl.debug excluded by the client reads OFF", wantOff("aowl.debug") == false

echo "-- the server's own rows are untouched --"
# `effectiveWant` may only speak where the server returned `wrong-side`. A
# server-side mod's switch must still be the server's answer, on or off.
check "aowl.manager still ON", effectiveWant("aowl.manager")
check "aowl.tarkov still ON", effectiveWant("aowl.tarkov")
check "aowl.sain still ON", effectiveWant("aowl.sain")
check "a mod in no list reads OFF",
      effectiveWant("aowl.callproof") == false

echo "-- a mod nothing describes is never switched on --"
check "unknown guid reads OFF", effectiveWant("aowl.no.such.mod") == false

echo "-- the client resolution did not become the server's --"
# The fix must not have swapped which resolution `/panel`'s verdict comes from:
# a server-only mod is `wrong-side` on the CLIENT, and if that leaked into the
# panel every backend mod would have gone dark.
check "aowl.tarkov is wrong-side on the client",
      verdictOf(cli, "aowl.tarkov") == vWrongSide
check "...and still reads ON on the panel", effectiveWant("aowl.tarkov")

if fails == 0:
  echo "modpanel: all checks passed"
  quit 0
echo "modpanel: ", fails, " FAILED"
quit 1
