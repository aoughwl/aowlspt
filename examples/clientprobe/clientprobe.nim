## A client-side mod for post-1.0 Tarkov.
##
## Where `examples/hello` shows the plumbing that works everywhere, this one is
## about the side that only exists post-1.0: reaching into an IL2CPP client by
## name, with no managed assemblies and no BepInEx anywhere in the process.
##
##     aowl build-mod examples/clientprobe
##
## Then put it under the host's `mods/` directory and launch the game with
## `aowlspt-launch`. It writes what it found to the host log.
##
## The types it looks for are chosen to prove three different things:
##
##   `System.String`   the corlib is up. If this fails, nothing else is real.
##   `UnityEngine.Application`  the engine's own assemblies are loaded.
##   `EFT.Player`      the game's assembly is loaded, which does not happen
##                     until well after the process starts -- so a mod that
##                     resolves game types at load time is asking too early,
##                     and this one demonstrates waiting instead.

import std/strutils
import aowlspt

var ticks = 0
var probed = false
var tickHookFired = 0
var found = 0
var missing = 0

proc probe(typeName: string): bool =
  ## `resolve` on the client host means "find this type in the running game".
  ## The handle it returns is what the `#<handle>::Member` form of `call`
  ## addresses.
  var handle: Handle = 0
  let st = resolve(typeName, handle)
  if st == Ok:
    info "resolved " & typeName
    release(handle)
    inc found
    result = true
  else:
    warn "could not resolve " & typeName & ": " & lastError()
    inc missing
    result = false

proc probeAll() =
  info "probing the IL2CPP type universe"

  # Corlib first. It exists before anything else does, so a failure here is a
  # failure of the host rather than of timing.
  discard probe("System.String")
  discard probe("UnityEngine.Application")

  # Then the engine, through the escape hatch rather than through a binding.
  # `Application.get_unityVersion` is a property getter, which in IL2CPP is an
  # ordinary zero-argument static method -- exactly what `call` can invoke.
  var version = ""
  let st = call("UnityEngine.Application::get_unityVersion", "[]", version)
  if st == Ok:
    success "the game says Unity " & version
  else:
    warn "could not read the Unity version: " & lastError()

  # Finally the game's own types. These appear late; see the module comment.
  let havePlayer = probe("EFT.Player")
  discard probe("EFT.GameWorld")

  # Calls with arguments. Each of these would come back wrong rather than
  # failing if the host bound the arguments to the wrong types or in the wrong
  # order, so the values are checked rather than just the status.
  if havePlayer:
    var sum = ""
    if call("EFT.Player::Add", "[17, 25]", sum) == Ok:
      if sum == "42":
        success "Add(17, 25) = " & sum
      else:
        warn "Add(17, 25) returned " & sum & ", expected 42"
    else:
      warn "Add failed: " & lastError()

    var greeting = ""
    if call("EFT.Player::Greet", "[\"operator\"]", greeting) == Ok:
      success "Greet: " & greeting
    else:
      warn "Greet failed: " & lastError()

    var scaled = ""
    if call("EFT.Player::Scale", "[2.5]", scaled) == Ok:
      success "Scale(2.5) = " & scaled
    else:
      warn "Scale failed: " & lastError()

    var flag = ""
    if call("EFT.Player::SetFlag", "[true]", flag) == Ok:
      success "SetFlag(true) = " & flag
    else:
      warn "SetFlag failed: " & lastError()

    # And the refusal that matters: wrong argument type must be rejected, not
    # coerced into a plausible-looking wrong answer.
    var bad = ""
    if call("EFT.Player::Add", "[\"seventeen\", 25]", bad) != Ok:
      success "a mistyped argument was refused: " & lastError()
    else:
      warn "a mistyped argument was accepted, which it should not be"

  # A patch: the client-side equivalent of a Harmony hook. The method is
  # detoured in compiled code, so it fires however the game reaches it -- not
  # only through reflection.
  if havePlayer:
    let st = patch("EFT.Player::Tick", pkPrefix,
      proc (target, args: string): PatchResult =
        inc tickHookFired
        patchContinue())
    if st == Ok:
      success "patched EFT.Player::Tick"
      # Call it through the runtime a few times; the detour should fire on
      # each, and the original should still run underneath.
      for i in 0 ..< 3:
        var ignored = ""
        discard call("EFT.Player::Tick", "[]", ignored)
      if tickHookFired == 3:
        success "the patch fired on all 3 calls"
      else:
        warn "the patch fired " & $tickHookFired & " times, expected 3"
    else:
      warn "could not patch: " & lastError()

  info "probe complete: " & $found & " resolved, " & $missing & " missing"

proc onLoad(): Status =
  success "clientprobe loaded on " & hostName()

  if side() != sideClient:
    info "this mod only has anything to say on the client; idling"
    return Ok

  # Deliberately not probing here. At load the process has a runtime but not
  # yet a game: EFT's assemblies are still being brought up, and resolving
  # `EFT.Player` now would report a false negative. The probe waits for the
  # tick loop instead, which is the honest way to observe a thing that arrives
  # when it arrives.
  info "waiting for the game's assemblies before probing"
  Ok

proc onUpdate(elapsedMs: int64): Status =
  inc ticks
  if side() != sideClient:
    return Ok
  # ~5 seconds at the host's 16ms tick.
  if not probed and ticks > 300:
    probed = true
    probeAll()
  Ok

proc onUnload(): Status =
  info "clientprobe unloading after " & $ticks & " ticks"
  Ok

exportMod(
  guid = "aowl.clientprobe",
  name = "Client Probe",
  author = "aowlspt",
  version = "0.1.0",
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
