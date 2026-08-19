## The response envelope — the one thing a `/client/*` route cannot get wrong.
##
##     aowl build-mod examples/envelope
##     aowl run examples/envelope
##
##     :: and to see the four bodies come back over the sim's route driver
##     host\Aowlspt.Sim\bin\aowlspt-sim.exe examples/envelope --side sim --ticks 1 ^
##         --route /client/aowlspt/envelope/status ^
##         --route /client/aowlspt/envelope/nothing ^
##         --route /client/aowlspt/envelope/refuse ^
##         --route /client/aowlspt/envelope/bare
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## Every other example in this directory answers a **private** path —
## `/aowlspt/status`, `/aowlspt/echo`, `/aowlspt/item/<id>` — and answers it with
## a bare object, `{"ok":true,...}`. That is correct for a private path: nothing
## but your own tooling ever calls it, and your own tooling reads whatever you
## decided to send.
##
## It stops being correct the moment the caller is the game. `aowlspt/server`
## says it in its own words, above `envelope`:
##
##     Every `/client/*` endpoint answers with the same wrapper, and the client
##     reads `err` before it looks at anything else. A route that returns bare
##     data gets a client that treats a perfectly good response as a failure,
##     which is a whole evening to find and one function to prevent.
##
## Until this file, **no example showed `envelope`, `envelopeNull` or
## `failure`**. The only code in the repository that uses them is
## `mods/tarkov`, which is twenty thousand lines of game server, and nobody
## learning the API reads that first. So the first `/client/*` route a mod
## author writes is copied from `examples/gameserver`, comes back bare, and the
## symptom arrives at the far end of the pipeline as a client that says nothing
## useful.
##
## The sharp edge is the line count. Written out, the two are:
##
##     result = done(o).text        # one line, wrong on /client/*
##     result = envelope(o)         # one line, right — once you know it exists
##
## and the whole cost of not knowing is that both compile, both return 200, and
## both look right in a terminal. That is the argument for an example rather
## than a doc comment.
##
## ---------------------------------------------------------------------------
## WHAT IS MEASURED HERE AND WHAT IS ARGUED
## ---------------------------------------------------------------------------
##
## **Nothing in this repository has ever run against BSG's client.** That
## sentence stands over the whole tree and it bears directly on this file,
## because this file claims to know what the client does with a body.
##
## Precisely, then:
##
##   * *Argued from code.* The envelope shape `{"err":0,"errmsg":null,"data":…}`
##     is what `aowlspt/server` builds, what `mods/tarkov` returns from every one
##     of its ~200 `/client/*` routes, and what the SPT server this project
##     reimplements sends. `asClientReads` below is a **model** of a client that
##     reads `err` first, written from that shape. It is not a client.
##   * *Observed here.* That the four bodies below are what the four handlers
##     return, that `envelope` and `failure` produce documents which parse, and
##     that the model accepts three of them and rejects the fourth. The
##     simulator runs those checks on every `aowl test`, and this mod logs at
##     error level — which is how a simulator run fails — if any of them stops
##     holding.
##
## So: if the model is right about the client, the bare route is broken. This
## file proves the first half and is honest that the second half is inherited
## belief.
##
## ---------------------------------------------------------------------------
## THE PATHS
## ---------------------------------------------------------------------------
##
## `/client/aowlspt/envelope/*`, not a real endpoint. Two reasons, both
## practical: the game never calls these, so nothing is hijacked; and
## `mods/tarkov` already serves the real ones, and both hosts refuse a second
## registration of a url that is taken (`the route X is already registered`),
## so an example that grabbed `/client/game/start` would break the game server
## the first time somebody loaded them together.
##
## They are still `/client/*` paths. Neither host reserves the prefix — the
## backend's `route_register` checks for a duplicate and nothing else — so what
## makes an endpoint "a client endpoint" is who calls it, which is exactly why
## the envelope is the author's responsibility and not the host's.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

var hits = 0
var faults = 0

proc fault(msg: string) =
  ## A failed self-check. `error` is what makes the simulator exit non-zero, so
  ## this is the difference between an example that demonstrates something and
  ## an example that asserts it.
  inc faults
  error msg

# ---------------------------------------------------------------------------
# A model of the reader
# ---------------------------------------------------------------------------
#
# What the client does with a body, in the terms the envelope is written for:
# read `err` first, and only then look at `data`. Everything this example
# claims about the wrong answer is claimed through here, so the belief is in
# one place with its name on it rather than spread through the comments.

type
  Verdict = object
    accepted: bool
    reason: string
    data: string

proc asClientReads(body: string): Verdict =
  let doc = whole(body)
  if not isObject(doc):
    return Verdict(accepted: false, data: "",
                   reason: "the body is not a JSON object, so there is no " &
                           "err to read")
  let err = doc.child("err")
  if not exists(err):
    # The interesting case, and the one a bare body lands in. Note what the
    # reader has to do here: there is no error in the response to report,
    # because the response was a success. It has to invent one.
    return Verdict(accepted: false, data: "",
                   reason: "no err member. A reader that checks err first " &
                           "has nothing to check, and the failure it reports " &
                           "is its own")
  let code = err.asInt(-1)
  if code != 0:
    return Verdict(accepted: false, data: "",
                   reason: "err=" & $code & " (" &
                           doc.child("errmsg").asText("no message") & ")")
  result = Verdict(accepted: true, reason: "err=0",
                   data: doc.child("data").raw)

# ---------------------------------------------------------------------------
# The four answers
# ---------------------------------------------------------------------------

proc onStatus(url, body, session: string): string =
  ## The ordinary case: data, wrapped.
  ##
  ## Four lines, and the fourth is the one that matters. Build the object the
  ## endpoint is documented to return, then hand it to `envelope` — never to
  ## `done`.
  inc hits
  var o = obj()
  put(o, "mod", "aowl.envelope")
  put(o, "hits", hits)
  put(o, "session", session)
  result = envelope(o)

proc onNothing(url, body, session: string): string =
  ## A success that carries nothing.
  ##
  ## `envelopeNull()`, not `envelope(emptyObject())`. They are different
  ## documents — `"data":null` against `"data":{}` — and `aowlspt/server` says
  ## some endpoints are checked for `data === null` specifically. A mod that
  ## sends the empty object because it looks tidier has changed the answer.
  inc hits
  result = envelopeNull()

proc onRefuse(url, body, session: string): string =
  ## A refusal, said in the response rather than by not answering.
  ##
  ## The HTTP status is still 200: the envelope *is* the error channel, which
  ## is why a mod cannot skip it and signal failure some other way.
  ## `failure(0, …)` would say "success" in the field the reader trusts, so
  ## `failure` rewrites a zero code to 1 rather than sending it.
  inc hits
  result = failure(228, "this route refuses on purpose, so that a refusal has " &
                        "a shape in this file too")

proc onBare(url, body, session: string): string =
  ## **The mistake, kept.**
  ##
  ## This is `examples/gameserver`'s `onStatus` moved to a `/client/*` path and
  ## otherwise untouched, because that is the actual provenance of the bug: the
  ## body is well-formed, the data is right, the route works, and the reader
  ## rejects it. Deleting this handler would make the example shorter and would
  ## teach half of the lesson — the half nobody gets wrong.
  inc hits
  var o = obj()
  put(o, "ok", true)
  put(o, "mod", "aowl.envelope")
  put(o, "hits", hits)
  result = done(o).text

# ---------------------------------------------------------------------------
# The demonstration
# ---------------------------------------------------------------------------

proc show(label, body: string; wantAccepted: bool) =
  ## Print one body and what the model makes of it, and fail the run if the
  ## model disagrees with what this file claims about it.
  let v = asClientReads(body)
  if v.accepted:
    info label & ": " & body
    info "    the reader accepts it (" & v.reason & "), data = " &
         (if v.data.len > 0: v.data else: "-")
  else:
    warn label & ": " & body
    warn "    the reader REJECTS it: " & v.reason
  if v.accepted != wantAccepted:
    fault label & " was " & (if v.accepted: "accepted" else: "rejected") &
          " and this example says the opposite. Either the model in " &
          "asClientReads or the handler above it has changed; they are the " &
          "two halves of the same claim."

proc onLoad(): Status =
  success "envelope loaded on " & hostName() & " (side " & $ord(side()) & ")"

  # `!= sideClient`, not `== sideServer`.
  #
  # Routes are the server's — the client host refuses `route_register` outright,
  # because there is no HTTP server in the game process — but the simulator
  # serves, and it presents as `sim` unless it is told otherwise. A mod that
  # guards on `== sideServer` registers nothing under `aowl run` and then
  # answers "no route registered for ...", which reads as a typo in the url. Two
  # files in this directory had that bug; `examples/gameserver` still returns
  # early on any side but the server, which is why its routes cannot be driven
  # from the simulator and these can.
  if side() == sideClient:
    info "the client does not serve HTTP; nothing to register here"
    return Ok

  discard serve("/client/aowlspt/envelope/status", onStatus)
  discard serve("/client/aowlspt/envelope/nothing", onNothing)
  discard serve("/client/aowlspt/envelope/refuse", onRefuse)
  discard serve("/client/aowlspt/envelope/bare", onBare)

  # The handlers are ordinary procs, so the demonstration does not need a
  # server, a socket or the game — it calls them and reads what comes back. The
  # same four bodies come out of the sim's `--route` driver; this runs on every
  # `aowl test`, where nothing passes `--route`.
  info "---- what a /client/* reader does with four responses ----"
  show("envelope(o)     ", onStatus("/client/aowlspt/envelope/status", "", "sim"), true)
  show("envelopeNull()  ", onNothing("/client/aowlspt/envelope/nothing", "", "sim"), true)
  show("failure(228, ..)", onRefuse("/client/aowlspt/envelope/refuse", "", "sim"), false)
  show("done(o).text    ", onBare("/client/aowlspt/envelope/bare", "", "sim"), false)

  # The two rejections are not the same kind of thing, and that difference is
  # the whole point of the file: `failure` is rejected *because it said so*, and
  # the bare body is rejected while saying nothing at all. From the reader's
  # side they are indistinguishable — both are "this request did not work" —
  # which is why the bare one costs an evening. There is no bad response
  # anywhere to find. The request succeeded, the data was right, and the field
  # that decides was missing.
  let refused = asClientReads(onRefuse("", "", "sim"))
  let bare = asClientReads(onBare("", "", "sim"))
  if refused.accepted or bare.accepted:
    fault "a refusal or a bare body was accepted; the demonstration below is " &
          "not showing what it says it is"
  else:
    warn "both rejections reached the caller as \"it did not work\". The " &
         "first one meant to; the second one is a working route with a " &
         "missing field, and nothing in the exchange says so."

  # And the shape itself, checked rather than eyeballed. `envelope` is one
  # string concatenation in `aowlspt/server`; if a `data` payload ever stopped
  # being spliced in whole, every route in every mod would be wrong at once and
  # the first place it would show is a document that no longer parses.
  let sample = envelope(objOf("nested", objOf("deep", 42)))
  let d = whole(sample)
  if not isObject(d) or d.child("err").asInt(-1) != 0 or
     not d.child("errmsg").isNull or
     d.field("data.nested.deep").asInt(-1) != 42:
    fault "envelope() did not produce {\"err\":0,\"errmsg\":null,\"data\":…} " &
          "with the payload intact: " & sample
  else:
    success "envelope() nests a payload and keeps err/errmsg readable"

  if faults == 0:
    success "four routes registered under /client/aowlspt/envelope/"
  Ok

proc onUnload(): Status =
  info "envelope unloading after " & $hits & " handler call(s), " &
       $faults & " self-check failure(s)"
  Ok

exportMod(
  guid = "aowl.envelope",
  name = "Response Envelope",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
