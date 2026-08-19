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
var waitedMs = 0'i64
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

    # A string argument and a string return: the one case where the value
    # crosses a managed allocation in each direction rather than sitting in a
    # register. It comes back as JSON, so the quotes are part of it.
    var greeting = ""
    if call("EFT.Player::Greet", "[\"operator\"]", greeting) == Ok:
      if find(greeting, "hello operator") >= 0:
        success "Greet: " & greeting
      else:
        warn "Greet returned " & greeting & ", expected \"hello operator\""
    else:
      warn "Greet failed: " & lastError()

    # A `System.Single`, and the value is the assertion rather than the status.
    # A float bound as an integer travels in RCX instead of XMM0 and its result
    # is read out of RAX, which answers a number -- so "Scale returned Ok" is
    # exactly the thing that stays true while the answer is wrong. The mock
    # doubles, so 2.5 is 5.0 and nothing else.
    var scaled = ""
    if call("EFT.Player::Scale", "[2.5]", scaled) == Ok:
      if scaled == "5.0":
        success "Scale(2.5) = " & scaled
      else:
        warn "Scale(2.5) returned " & scaled & ", expected 5.0"
    else:
      warn "Scale failed: " & lastError()

    # A `System.Boolean`, for the same reason: a bool is one byte in AL and the
    # rest of the register is undefined, so a host reading the whole register
    # answers "true" for very nearly any bool-returning method. The mock negates
    # what it is given, so `true` must come back `false` -- which is also the
    # answer a host that dropped the argument would fail to produce.
    var flag = ""
    if call("EFT.Player::SetFlag", "[true]", flag) == Ok:
      if flag == "false":
        success "SetFlag(true) = " & flag
      else:
        warn "SetFlag(true) returned " & flag & ", expected false"
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
      # One detour per method, across every mod in the process. The pool holds
      # 256 slots and is not what runs out here: `aowl_hook_attach` refuses a
      # method something else already detoured, with its own message.
      #
      # In the gate's stage `examples/highlevel` gets to this same method
      # first -- it hooks `Tick` on the first tick the world resolves, while
      # this probe deliberately waits three seconds -- so the refusal here is
      # the engine's rule working rather than anything wrong. Which of the two
      # is *loaded* first is not the point and is the other way round anyway;
      # this comment said "loaded first" until 2026-08-19. It is said in those
      # words because "could not patch" on its own has sent people looking at
      # the detour engine for a collision in the mods directory.
      let why = lastError()
      if find(why, "already patched") >= 0:
        info "EFT.Player::Tick is already detoured by another mod in this " &
             "stage, so this probe has nothing to patch: " & why
      else:
        warn "could not patch: " & why

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
  ## Waits by the clock, not by a tick count.
  ##
  ## Counting ticks assumes a tick rate. The host's is nominally 16ms, so "300
  ## ticks" was meant to be five seconds -- and on a loaded machine it is
  ## whatever it turns out to be, which made this probe intermittently miss the
  ## harness window and fail a gate that had nothing wrong with it.
  inc ticks
  waitedMs = waitedMs + elapsedMs
  if side() != sideClient:
    return Ok
  if not probed and waitedMs >= 3000:
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
