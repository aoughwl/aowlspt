## The frame-resident cheats that are pure managed writes/hooks -- no rendering,
## so they run cleanly on Unity's thread and are the parts most likely to work
## on a live client.
##
##   * **God mode** -- a prefix hook on the damage-application method that
##     suppresses the call when God mode is on and the instance being damaged is
##     the local player. Suppression only; nothing is written into a health
##     structure whose layout is not known here. The exact method name is
##     unverified, so a short candidate list is tried and the first that binds
##     wins; the suppression value is chosen from the method's real return type.
##
##   * **Infinite stamina** -- a per-frame write of the local player's stamina
##     back to full. Best-effort: it binds the chain `MainPlayer -> Physical ->
##     Stamina` and writes the `Current` field, and reports "unavailable" if any
##     link refuses rather than guessing.
##
## Every other mode is declared but not yet bound, and says so through its
## capability flag -- the safe-by-default contract: a mode that cannot be armed
## on this build is drawn "unavailable" and does nothing.

import std/strutils
import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import aowlspt/game

import state
import world

# ---------------------------------------------------------------------------
# God mode -- the damage-suppression hook
# ---------------------------------------------------------------------------

var gGodTarget = ""
var gGodArmed = false
var gGodVoid = false
var gGodSuppressJson = "null"
var gGodWhy = "not attempted"
var gGodHits = 0

proc returnTypeName(owner, member: string): string =
  ## The declared return type of `owner::member`, from the runtime's metadata,
  ## or "" when it cannot be read. Any arity.
  result = ""
  let rt = worldRuntime()
  if not rt.loaded:
    return
  let cls = findClass(rt, owner)
  if cls == nil:
    return
  let m = findMethod(rt, cls, member, -1)
  if m == nil:
    return
  result = typeName(rt, methodReturnType(rt, m))

proc onDamage(target, args: string): HookResult =
  ## Fires before the game applies a hit. Suppresses only the local player's,
  ## and only while God mode is on -- so bots still take damage and the world
  ## still behaves.
  if not toggleOn(tgGod):
    return carryOn()
  let selfPtr = thisPointer(args)
  if selfPtr != 0'u64 and selfPtr == localPlayerPtr():
    gGodHits = gGodHits + 1
    if gGodVoid:
      return stopVoid()
    return stopWith(gGodSuppressJson)
  result = carryOn()

proc splitTarget(t: string; owner, member: var string): bool =
  ## Split "Owner::Member" at the last "::". Written as a manual scan because
  ## nimony's strutils has no `rfind`.
  var idx = -1
  var k = 0
  while k < t.len - 1:
    if t[k] == ':' and t[k + 1] == ':':
      idx = k
    inc k
  if idx < 0:
    return false
  owner = t.substr(0, idx - 1)
  member = t.substr(idx + 2, t.len - 1)
  result = true

const GodCandidates = [
  "EFT.Player::ApplyDamageInfo",
  "EFT.Player::ReceiveDamage",
  "EFT.HealthSystem.ActiveHealthController::ApplyDamage"]

proc installGodmode*() =
  ## Registration is a host call, not a managed one, so it is safe to *call* from
  ## load -- but it can only *succeed* once the game's assemblies are up. So this
  ## is idempotent and retried from `applyCheats` until it arms.
  discard

proc tryArmGodmode() =
  if gGodArmed or not worldReady():
    return
  for cand in GodCandidates:
    var owner = ""
    var member = ""
    if not splitTarget(cand, owner, member):
      continue
    let rt = returnTypeName(owner, member)
    if rt.len == 0:
      continue    # method not present on this build; try the next name
    # Choose the suppression value from the real return type.
    if rt == "System.Void":
      gGodVoid = true
      gGodSuppressJson = "null"
    elif rt == "System.Single" or rt == "System.Double":
      gGodVoid = false
      gGodSuppressJson = "0.0"
    elif rt == "System.Boolean":
      gGodVoid = false
      gGodSuppressJson = "false"
    else:
      gGodVoid = false
      gGodSuppressJson = "null"
    if hookArgs(cand, onDamage) == Ok:
      gGodTarget = cand
      gGodArmed = true
      gGodWhy = "armed on " & cand & " (returns " & rt & ")"
      info "admin: God mode " & gGodWhy
      return
  gGodWhy = "no damage method from the candidate list bound on this build"

proc removeGodmode*() =
  ## The host clears a mod's hooks on unload; nothing to undo here beyond marking
  ## it disarmed so a hot-reload re-arms cleanly.
  gGodArmed = false

# ---------------------------------------------------------------------------
# Infinite stamina -- a per-frame write, best-effort
# ---------------------------------------------------------------------------

var bPhysical: Binding
var bStamina: Binding
var fCurrent: FieldBinding
var fTotal: FieldBinding
var gStamBound = false
var gStamTried = false
var gStamWhy = "not attempted"

proc tryBindStamina() =
  if gStamTried or not worldReady():
    return
  gStamTried = true
  let rt = worldRuntime()
  bPhysical = bindMethod(rt, "EFT.Player", "get_Physical", 0)
  # `Physical` is an interface/handle; the stamina object hangs off it.
  bStamina = bindMethod(rt, "EFT.Player.Physical", "get_Stamina", 0)
  fCurrent = bindField(rt, "GStruct.StaminaValues", "Current")
  fTotal = bindField(rt, "GStruct.StaminaValues", "TotalCapacity")
  gStamBound = bPhysical.ok and bStamina.ok
  if gStamBound:
    gStamWhy = "bound (Physical -> Stamina -> Current)"
  else:
    gStamWhy = "refused: Physical=" & (if bPhysical.ok: "ok" else: bPhysical.why) &
               " Stamina=" & (if bStamina.ok: "ok" else: bStamina.why)

proc applyStamina() =
  if not gStamBound:
    return
  # The local player pointer the ESP pass already resolved this frame -- no
  # second world walk, and correct against whatever Player subclass it is.
  let lp = localPlayerPtr()
  if lp == 0'u64:
    return
  let player = cast[Il2CppPtr](lp)
  var a = noArgs()
  let phys = callPtr(bPhysical, player, a)
  if phys == nil: return
  a.reset()
  let stam = callPtr(bStamina, phys, a)
  if stam == nil: return
  if fCurrent.ok:
    var maxVal = 100.0
    if fTotal.ok:
      let t = readFloat(fTotal, stam)
      if t > 0.0: maxVal = t
    writeFloat(fCurrent, stam, maxVal)

# ---------------------------------------------------------------------------
# The per-frame apply, and the capability report
# ---------------------------------------------------------------------------

proc applyCheats*() =
  ## Called every frame on Unity's thread. Arms what it can, applies the toggles
  ## that are on and capable, and updates every mode's capability flag so the
  ## menu can say "unavailable" honestly.
  tryArmGodmode()
  tryBindStamina()

  setCapable(tgGod, gGodArmed)
  setCapable(tgStamina, gStamBound)
  # ESP capability is decided by the world pass, but reflect it here too so the
  # menu has one source: capable if the runtime is up (projection may still be
  # refused, which the diag reports).
  setCapable(tgEsp, worldReady())

  # Modes not yet bound: honest "unavailable".
  setCapable(tgNoRecoil, false)
  setCapable(tgNoWeight, false)
  setCapable(tgInstaHeal, false)
  setCapable(tgAmmo, false)
  setCapable(tgThermal, false)
  setCapable(tgNightVis, false)
  setCapable(tgFly, false)
  setCapable(tgTeleport, false)
  setCapable(tgTime, false)

  if toggleOn(tgStamina):
    applyStamina()
  # God mode needs no per-frame work: the hook does it when damage arrives.

proc godDiag*(): string =
  "god=" & gGodWhy & " (hits " & $gGodHits & ")"
proc staminaDiag*(): string =
  "stamina=" & gStamWhy
