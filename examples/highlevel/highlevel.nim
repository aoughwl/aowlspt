## The same mod as `examples/clientprobe`, written against the high-level API.
##
##     aowl build-mod examples/highlevel
##
## Worth reading side by side with `clientprobe`. That one is the raw
## interface: `resolve` into a `Handle`, build a JSON argument string, `call`,
## parse the result out of a string. This one is what a mod should look like.

import aowlspt
import aowlspt/game

# Types are named at the top and resolved on first use. Naming them here and
# resolving them here would not work -- the game's assemblies arrive later --
# and that gap is the thing `GameType` exists to close.
var Player = gameType("EFT.Player")
var Application = gameType("UnityEngine.Application")

var GameWorld = gameType("EFT.GameWorld")
var world = whenReady("EFT.GameWorld")
var ticks = 0
var hookFires = 0
var hooked = false

proc onLoad(): Status =
  success "highlevel loaded on " & hostName()
  if side() != sideClient:
    info "this mod only does anything on the client"
  Ok

proc onWorldReady() =
  ## Runs once, the first tick the game world exists.
  success "the world is up"

  let version = Application.get("unityVersion")
  if version.ok:
    info "Unity " & version.asText()
  else:
    warn "no Unity version: " & version.error

  # Arguments are ordinary values. No JSON, no quoting, no argument array.
  let sum = Player.invoke("Add", 17, 25)
  if sum.ok:
    success "Add(17, 25) = " & $sum.asInt()
  else:
    warn "Add failed: " & sum.error

  let scaled = Player.invoke("Scale", 2.5)
  if scaled.ok:
    success "Scale(2.5) = " & $scaled.asFloat()

  let greeting = Player.invoke("Greet", "operator")
  if greeting.ok:
    success "Greet -> " & greeting.asText()

  let flag = Player.invoke("SetFlag", true)
  if flag.ok:
    success "SetFlag(true) = " & $flag.asBool()

  # A wrong type is still refused, and the reason still arrives -- the high
  # level API hides the plumbing, not the errors.
  let bad = Player.invoke("Add", "seventeen")
  if bad.failed:
    success "a mistyped argument was refused: " & bad.error

  # Live objects. Everything above this line is static -- the half of the game
  # that needs no `this`. What a mod actually wants is on the other half: this
  # world, this player, this player's health.
  let instanceCall = GameWorld.get("Instance")
  let gameWorld = instanceCall.asObject()
  if gameWorld.ok:
    success "the world instance is a " & gameWorld.typeName
    let player = gameWorld.child("MainPlayer")
    if player.ok:
      success "and its main player is a " & player.typeName
      let before = player.get("Health").asFloat()
      let after = player.invoke("Damage", 25.0).asFloat()
      if after == before - 25.0:
        success "Damage(25) took this player from " & $before & " to " & $after
      else:
        warn "health went from " & $before & " to " & $after &
             ", which is not what damaging this player should do"
      # A second read proves it stuck on the object rather than on a copy.
      let again = player.get("Health").asFloat()
      if again == after:
        success "and the change is on the object, not a copy"
      else:
        warn "the object did not keep the change: " & $again
      # A field, which no property getter reaches. `Level` is a plain field on
      # the mock exactly as half the game's interesting state is on the real
      # thing.
      # The strong version of the check: the field and the property getter must
      # agree. They read the same storage by two different mechanisms, so a
      # wrong field offset shows up here rather than as a number that merely
      # looks plausible.
      let byField = player.field("Health")
      if byField.ok and byField.asFloat() == again:
        success "the Health field agrees with get_Health: " & $byField.asFloat()
      else:
        warn "the Health field says " & byField.raw & " but get_Health said " &
             $again

      let lvl = player.field("Level")
      if lvl.ok:
        success "the Level field reads " & $lvl.asInt()
        if player.setField("Level", v(7)).ok and
           player.field("Level").asInt() == 7:
          success "and writing it stuck"
        else:
          warn "writing the Level field did not stick"
      else:
        warn "could not read the Level field: " & lvl.error

      player.release()
    else:
      warn "no main player: " & gameWorld.get("MainPlayer").error
    gameWorld.release()
  else:
    warn "no world instance: " & (if instanceCall.ok: "returned " &
                                  instanceCall.raw else: instanceCall.error)

  if not hooked:
    hooked = true
    if hook("EFT.Player::Tick",
            proc (target: string) =
              inc hookFires) == Ok:
      success "hooked EFT.Player::Tick"
      for i in 0 ..< 3:
        discard Player.invoke("Tick")
      if hookFires == 3:
        success "the hook fired on all 3 calls"
      else:
        warn "the hook fired " & $hookFires & " times, expected 3"
    else:
      warn "could not hook: " & lastError()

proc onUpdate(elapsedMs: int64): Status =
  inc ticks
  if side() != sideClient:
    return Ok
  if world.ready():
    onWorldReady()
  Ok

exportMod(
  guid = "aowl.highlevel",
  name = "High Level",
  author = "aowlspt",
  version = "0.1.0",
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
