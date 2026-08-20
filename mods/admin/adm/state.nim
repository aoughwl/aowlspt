## The admin menu's own state: the toggles, the capability flags, the menu
## cursor, and the keyboard.
##
## None of this touches the IL2CPP runtime, so all of it is safe on any thread
## -- which is the point. The menu opens and navigates whether or not a game
## world exists, and `GetAsyncKeyState` is a `user32` read that has nothing to do
## with Unity's thread. The cheat logic elsewhere reads `toggleOn` and writes
## `setCapable`; this file owns the switches, not what they do.

import std/strutils
import aowlspt

type
  Toggle* = enum
    tgEsp        ## box / distance / side-colour ESP
    tgGod        ## suppress incoming damage on the local player
    tgStamina    ## infinite stamina
    tgNoRecoil   ## no recoil / no sway
    tgNoWeight   ## no encumbrance
    tgInstaHeal  ## keep body parts topped up
    tgAmmo       ## no ammo drain
    tgThermal    ## force thermal vision
    tgNightVis   ## force night vision
    tgFly        ## fly / noclip
    tgTeleport   ## teleport to marker
    tgTime       ## set time of day

const ToggleCount* = 12

proc label*(t: Toggle): string =
  case t
  of tgEsp: "ESP"
  of tgGod: "God mode"
  of tgStamina: "Infinite stamina"
  of tgNoRecoil: "No recoil / sway"
  of tgNoWeight: "No weight"
  of tgInstaHeal: "Instant heal"
  of tgAmmo: "Unlimited ammo"
  of tgThermal: "Thermal vision"
  of tgNightVis: "Night vision"
  of tgFly: "Fly / noclip"
  of tgTeleport: "Teleport to marker"
  of tgTime: "Set time of day"

# ---------------------------------------------------------------------------
# The switches
# ---------------------------------------------------------------------------
#
# Plain module globals; assigned in procs, never at declaration (a nimony
# --app:lib global set by a call is left zeroed). `seq` rather than a fixed
# array so nimony has a concrete element type to infer at every index.

var gOn: seq[bool] = @[]
var gCapable: seq[bool] = @[]

proc ensureArrays() =
  if gOn.len != ToggleCount:
    gOn = @[]
    gCapable = @[]
    for i in 0 ..< ToggleCount:
      gOn.add false
      gCapable.add false

proc setToggle*(t: Toggle; on: bool) =
  ensureArrays()
  gOn[int(t)] = on

proc toggleOn*(t: Toggle): bool =
  ensureArrays()
  result = gOn[int(t)]

proc flipToggle*(t: Toggle) =
  ensureArrays()
  gOn[int(t)] = not gOn[int(t)]

proc setCapable*(t: Toggle; can: bool) =
  ## Set by the cheat logic once it knows whether a mode's bindings resolved.
  ## The menu draws an incapable mode dim and says "unavailable".
  ensureArrays()
  gCapable[int(t)] = can

proc capable*(t: Toggle): bool =
  ensureArrays()
  result = gCapable[int(t)]

# ---------------------------------------------------------------------------
# The menu
# ---------------------------------------------------------------------------

var gMenuVisible = false
var gMenuSel = 0

proc menuVisible*(): bool = gMenuVisible
proc menuSelection*(): int = gMenuSel

# ---------------------------------------------------------------------------
# Keyboard -- Win32, edge-detected. Safe from any thread.
# ---------------------------------------------------------------------------

proc getAsyncKeyState(vk: int32): int16 {.importc: "GetAsyncKeyState",
                                          header: "windows.h".}

const
  VkF6     = 0x75'i32
  VkUp     = 0x26'i32
  VkDown   = 0x28'i32
  VkLeft   = 0x25'i32
  VkRight  = 0x27'i32
  VkReturn = 0x0D'i32
  VkSpace  = 0x20'i32

# The keys we watch, and last frame's down-state for each, so a hold is one
# action rather than one per frame.
var gWatch: seq[int32] = @[]
var gPrev: seq[bool] = @[]

proc ensureKeys() =
  if gWatch.len == 0:
    gWatch = @[VkF6, VkUp, VkDown, VkLeft, VkRight, VkReturn, VkSpace]
    gPrev = @[]
    for i in 0 ..< gWatch.len:
      gPrev.add false

proc keyDownNow(vk: int32): bool =
  (int(getAsyncKeyState(vk)) and 0x8000) != 0

proc pollInput*() =
  ## Called once per frame. Detects rising edges and drives the menu. Does
  ## nothing managed, so it runs before the main-thread gate.
  ensureArrays()
  ensureKeys()
  # Edge state, indexed the same as gWatch.
  var pressed: seq[bool] = @[]
  for i in 0 ..< gWatch.len:
    let downNow = keyDownNow(gWatch[i])
    pressed.add (downNow and not gPrev[i])
    gPrev[i] = downNow

  # gWatch order: F6, Up, Down, Left, Right, Return, Space
  if pressed[0]:
    gMenuVisible = not gMenuVisible
  if not gMenuVisible:
    return
  if pressed[1]:  # Up
    gMenuSel = (gMenuSel + ToggleCount - 1) mod ToggleCount
  if pressed[2]:  # Down
    gMenuSel = (gMenuSel + 1) mod ToggleCount
  if pressed[5] or pressed[6]:  # Return / Space -> toggle selected
    let t = Toggle(gMenuSel)
    if capable(t):
      flipToggle(t)
  # Left/Right also toggle, so the menu is usable with either hand.
  if pressed[3] or pressed[4]:
    let t = Toggle(gMenuSel)
    if capable(t):
      flipToggle(t)

# ---------------------------------------------------------------------------
# The menu, as text -- for the log today and the native drawer tomorrow
# ---------------------------------------------------------------------------

proc menuLines*(): seq[string] =
  ## The menu contents, one line per mode. The renderer draws these; until it
  ## can paint, they are logged so the menu is observable in Player.log.
  result = @[]
  result.add "== ADMIN MENU (F6) =="
  for i in 0 ..< ToggleCount:
    let t = Toggle(i)
    let cursor = (if i == gMenuSel: "> " else: "  ")
    let stateStr =
      if not capable(t): "unavailable"
      elif toggleOn(t): "ON"
      else: "off"
    result.add cursor & label(t) & " : " & stateStr
