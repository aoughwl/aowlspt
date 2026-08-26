## A worked capability CONSUMER, and the instrument the mutation proofs read.
##
## It stands in for `mods/admin`: it holds a preset, it cannot spawn anything
## itself, and it asks whoever provides `items.spawn/1` to do it. The whole
## point is what happens when nobody does.
##
##   GET /aowlspt/capdemo             invoke items.spawn/1
##   GET /aowlspt/capdemo?v=2         invoke items.spawn/2 -- the version proof
##   GET /aowlspt/capdemo?bad=1       send a malformed request, which is
##                                    refused HERE and never reaches the wire
##
## The response is always a strict JSON object with an `outcome` field naming
## one member of the taxonomy, e.g.
##
##   {"outcome":"ok","applied":true,"provider":"aowl.capprovider",
##    "message":"","result":{...}}
##   {"outcome":"provider-not-loaded","applied":false,"provider":"...",
##    "message":"no provider for items.spawn/1: ... the selection does NOT
##               load it ... The mod is installed; it is switched off."}
##
## `applied` is the field a test asserts on, and it is `true` on exactly one
## outcome. A 200 is not evidence of anything: this route answers 200 for every
## refusal too, deliberately, so that a caller has to read the body.
##
## Build:  aowl build-mod examples/capconsumer

import std/strutils
import aowlspt
import aowlspt/json
import aowlspt/capability

proc presetJson(): string =
  ## Byte-for-byte the shape `mods/admin`'s `presetRequestJson()` emits.
  "{\"preset\":\"Starter kit\",\"lines\":[" &
  "{\"q\":\"AKM\",\"n\":1,\"c\":85}," &
  "{\"q\":\"7.62x39 mm PS\",\"n\":240,\"c\":100}," &
  "{\"q\":\"Salewa\",\"n\":2,\"c\":100}]}"

proc wanted(url: string): int =
  ## `?v=N`, defaulting to 1. Hand-parsed: this is a fixture, and a query
  ## parser is not what is under test.
  result = 1
  let k = url.find("v=")
  if k < 0: return
  var i = k + 2
  var n = 0
  var any = false
  while i < url.len and url[i] >= '0' and url[i] <= '9':
    n = n * 10 + (ord(url[i]) - ord('0'))
    any = true
    inc i
  if any: result = n

proc demo(url, body, session: string): string =
  let version = wanted(url)
  let req = if url.contains("bad=1"): "{\"lines\":[}" else: presetJson()
  let r = invoke("items.spawn", version, req)

  var d = newDoc()
  d.setText("outcome", outcomeName(r.outcome))
  d.setBool("applied", r.outcome == coOk)
  d.setText("provider", r.provider)
  d.setText("message", r.message)
  d.setText("describe", describe(r))
  var vs = newList()
  for v in r.versions: vs.add $v
  d.setRaw("versions", text(vs))
  # The provider result is included ONLY when there is one. An empty object
  # here would be indistinguishable from a provider that answered with one.
  if r.outcome == coOk:
    d.setRaw("result", r.body)
  else:
    d.setRaw("result", "null")
  result = text(d)

proc onLoad(): Status =
  if side() == sideClient: return Ok
  let st = route("/aowlspt/capdemo", rkDynamic, demo)
  if st != Ok:
    error "capconsumer: could not register its route: " & lastError()
    return st
  # Deliberately invoked once from `onLoad`, BEFORE the provider is guaranteed
  # to have published. A refusal here is correct and is not a failure; the
  # route proves the same call succeeds later. This is the `loadAfter` point
  # made executable rather than asserted.
  let probe = invoke("items.spawn", 1, presetJson())
  info "capconsumer: items.spawn/1 at load time -> " & describe(probe)
  result = Ok

exportMod(
  guid = "aowl.capconsumer", name = "Capability consumer example",
  author = "aowlspt", version = "1.0.0", sptRange = "*",
  sides = {sideServer, sideSim}, onLoad = onLoad)
