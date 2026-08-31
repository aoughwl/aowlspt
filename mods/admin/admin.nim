## Admin / cheat menu -- a fully native, client-side admin panel for post-1.0
## Escape From Tarkov (IL2CPP build 1.1.0.1.46777).
##
## ---------------------------------------------------------------------------
## THE ARCHITECTURE, AND WHY IT IS THIS ONE
## ---------------------------------------------------------------------------
##
## Press **F6** for an in-game admin menu of togglable cheat modes. **Every mode
## defaults OFF** -- this build goes to testers, so nothing cheats until the
## player opts in (config.json, the F12 schema and `AOWL_ADM_DEFAULTS` are three
## copies of that one decision and must agree).
##
## Calling a managed game method through the per-frame `MethodInfo.methodPointer`
## is not available on this build -- the anti-cheat strips it. Three things do
## work, and this mod is built entirely on them:
##
##   * **Reading/writing object memory by a MEASURED STATIC field offset.** No
##     reflection: `il2cpp_object_get_class` and friends FAULT on this build, and
##     every offset in `adm/data.nim` is a constant taken offline from
##     `Il2CppMetadataRegistration.fieldOffsets`. Works from any thread. That is
##     the ESP data pass and the God mode / stamina writes.
##
##   * **A direct call at a byte-verified static RVA.** Direct RVA calls DO work
##     -- only reflection is dead. That is how world->screen projection is
##     obtained: `Camera::get_main` plus the two sret `Matrix4x4` getters, from
##     Unity's own thread via `everyMain`, published as one view-projection
##     matrix that the off-thread ESP pass then does pure arithmetic against.
##
##   * **Drawing inside the game's own `IDXGISwapChain::Present`.** The overlay
##     already hooks Present once; the ESP boxes and the F6 menu are drawn there
##     as a HUD on the frame (`abi/aowlspt_overlay.h` + `abi/aowlspt_admin.h`),
##     the same place Steam/Discord/RivaTuron and the graphics post-process draw.
##     This is a HUD, not the vetoed mod-manager panel.
##
## The two halves rendezvous through a named shared-memory region
## (`abi/aowlspt_admin.h`): this mod publishes the projected entities + toggles'
## capability into it (on the host's `on_update`, since a memory read needs no
## particular thread), and the overlay's Present hook reads it and draws. The F6
## keypress and menu navigation are handled in the overlay's WndProc, writing the
## toggles this mod then reads.
##
## ---------------------------------------------------------------------------
## WHAT IS REAL, WHAT NEEDS THE OFFSET DUMP
## ---------------------------------------------------------------------------
##
##   * **The whole native pipeline is real and complete:** shared region, the
##     Present-hook HUD (ESP boxes + F6 menu), the WndProc input, the publish
##     path, and the field-offset read/write framework.
##   * **The offsets and RVAs are MEASURED CONSTANTS for build 1.1.0.1.46777**,
##     not runtime name lookups -- runtime lookup needed the faulting reflection
##     API. A Tarkov update therefore invalidates them, which is exactly why
##     every hop is validated and `adminDiag()` names the FIRST one that did not.
##
##   * **The one remaining external dependency is the GameWorld.** `EFT.GameWorld`
##     is only reachable through `Comfort.Common.Singleton<GameWorld>._instance`,
##     a static on a GENERIC INSTANTIATION whose storage is allocated at runtime
##     and has no static address, so this mod borrows the host's existing
##     read-only `RegisterPlayer` detour cache instead of binding a second detour
##     on the same function (which would overwrite the first's trampoline). That
##     cache is only populated when the host flag `debugEsp` or `botDiag` is on.
##     Not being able to see a world for that reason is INCONCLUSIVE and is
##     reported in those words -- never as "not in a raid".
##
## Nothing here can crash the game: every read is address-checked, every mode is
## capability-gated, and an absent region or runtime is a no-op.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/capability # the F6 spawner calls aowl.items, provided by mods/tarkov
import aowlspt/json

import "adm" / shared
import "adm" / data
import "adm" / admprof
import "adm" / invui   # the native inventory screen's backend half
# Prototypes only -- `adm/admprof.nim` owns the state (AOWL_ADMPROF_IMPL).
{.emit: """#include "aowlspt_admprof.h" """.}

const
  ModGuid = "aowl.admin"
  ModName = "Admin Menu"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

# ---------------------------------------------------------------------------
# Config -- the initial toggle states + ESP range
# ---------------------------------------------------------------------------

var cfgEspMaxDistance = 400.0

proc cfgBool(key: string; default: bool): bool =
  setting(key).asBool(default)

var gRegion: AdminRegion

# ---------------------------------------------------------------------------
# Action hotkeys
# ---------------------------------------------------------------------------
#
# A key that toggles an admin action. Three rules, and all three are enforced
# in ONE place -- the C in `abi/aowlspt_admin.h` -- so the settings page and
# the F6 menu cannot drift apart:
#
#   * an unknown key name is REFUSED WITH THE NAME PRINTED. It is never read
#     as `KeyCode.None`, which is a real member with ordinal 0. The unbound
#     sentinel is -1, which is not a KeyCode at all.
#   * a key is never accepted for an action whose WRITE IS NOT BOUND on this
#     build. Seven of this mod's settings are still `implemented = false`; a
#     hotkey on one of those would be a key that does nothing, which is worse
#     than no key, so the set is REFUSED and says so, in the log and in the F6
#     menu.
#   * one key, one action.
#
# Only the FIVE actions this mod can actually perform get a row here. That list
# is not a guess: it is exactly the set `publishCapability()` publishes a
# capability bit for (`dataResolved`, `godCapable`, `staminaCapable`,
# `noRecoilCapable`, `noWeightCapable`). Adding a sixth capability makes a sixth
# row bindable; forgetting to add one makes the key refuse, out loud, rather
# than letting the two lists disagree. The shared region has always carried
# `hotkeyKc[AOWL_ADM_COUNT]` -- twelve slots -- so widening this table needs no
# region version bump and no change on the C side.
#
# The key NAMES come from the 328-member table generated by
#     python tools/fldoff.py enum UnityEngine.KeyCode
# into `abi/aowlspt_keycode.h`. Not one key ordinal is typed anywhere.
#
# DELIVERY. The keys are read with the game's own
# `UnityEngine.Input::GetKeyDown(KeyCode)`, not with `GetAsyncKeyState` and not
# from the overlay wndproc. The reasoning is in the block comment above
# `aowl_admin_hotkey_poll` in `abi/aowlspt_admin.h`; the short version is that
# GetAsyncKeyState fires while the game is in the background (wrong for a key
# that turns God mode on) and the wndproc speaks Win32 virtual-keys, which
# would need a 328-entry VK<->KeyCode mapping of hand-typed constants.

const
  HkCount  = 5
  HkBit    = [admEsp, admGodmode, admStamina, admNoRecoil, admNoWeight]
  HkCfgKey = ["hotkeyEsp", "hotkeyGodmode", "hotkeyStamina",
              "hotkeyNoRecoil", "hotkeyNoWeight"]

var cfgHotkeys = true
  ## The master gate. config.json, and it now defaults **ON** -- reversing the
  ## decision the previous pass shipped. The objection recorded there was that
  ## turning it on "adds a per-frame Input::GetKeyDown call into the game for
  ## every user by default", and MEASURED against the poll's own source
  ## (`aowl_admin_hotkey_poll`, abi/aowlspt_admin.h) that is not what happens:
  ##
  ##   * `if (!s || !enabled) return 0;`             -- gate off: nothing.
  ##   * with the gate ON and no capture in flight, the function scans the 12
  ##     `hotkeyKc` slots -- shared-memory `LONG`s in our OWN mapping, not game
  ##     memory -- and returns before `aowl_admin_hotkey_state()`, i.e. before
  ##     the bind, if every slot is `AOWL_KC_UNBOUND`. **Zero il2cpp calls,
  ##     zero allocation, one bounded 12-iteration loop.** Every slot IS unbound
  ##     in the shipped config, so that is the cost every user actually pays.
  ##   * the first `GetKeyDown` happens only once a player has bound a key,
  ##     which is a per-key opt-in they performed deliberately. It is then at
  ##     most one call per bound-AND-capable action per tick, capped at 5, at a
  ##     byte-verified static RVA, self-disabling after 240 consecutive bind
  ##     refusals.
  ##
  ## So the default that was shipped OFF did not avoid a per-frame game call --
  ## it only guaranteed that a player who bound a key got nothing, which is the
  ## user-visible complaint this change exists to fix. Rule 5 ("flag-gated,
  ## default OFF") still governs the thing that touches the game: no key is
  ## bound by default, so no game call is made by default. The gate above it is
  ## the UI's master switch, and a master switch that silently disables the
  ## feature it fronts is the "renders and does nothing" failure in another
  ## costume.
var gWantKey: array[HkCount, string]
var gHkApplied = false            ## the wanted keys have been pushed once
var gHkEpochSeen = -1             ## last hotkeyEpoch reflected into config.json
var gHkRefusals = 0
var gHkTries = 0

const HkMaxTries = 600
  ## Ticks the push is retried before it gives up. It MUST give up: a key that
  ## is refused for a reason that will never change -- a duplicate, or a name
  ## that is not a KeyCode -- would otherwise leave `gHkApplied` false forever,
  ## which allocates a few strings every tick AND, worse, permanently blocks
  ## `persistHotkeys`, so a rebind made in the F6 menu would flip live and then
  ## silently revert on the next launch. Retrying is only there to outlast the
  ## first ticks, before capability is published.

proc loadHotkeyConfig() =
  ## Read the desired keys out of config.json. NOTHING is written to the region
  ## here: capability is not published until the first `onUpdate`, and pushing
  ## a key before then would be refused with "not bound on this build" for a
  ## reason that is about ORDER, not about the build.
  cfgHotkeys = cfgBool("hotkeys", true)
  var i = 0
  while i < HkCount:
    gWantKey[i] = setting(HkCfgKey[i]).asText("")
    inc i
  gHkApplied = false
  gHkTries = 0

proc pushHotkeys() =
  ## Push the wanted keys into the region. Retried every tick until it takes,
  ## because the first ticks have no capability published yet. Idempotent: a
  ## slot whose live name already equals the wanted name is not rewritten, so
  ## this never fights a rebind made from the F6 menu.
  if gRegion == nil or gHkApplied: return
  gHkTries = gHkTries + 1
  var pending = false
  var i = 0
  while i < HkCount:
    let want = gWantKey[i]
    if hotkeyName(gRegion, HkBit[i]) != want:
      if not hotkeySetName(gRegion, HkBit[i], want):
        # REFUSED. The reason is in the region note and is drawn under the F6
        # menu; log it a bounded number of times rather than every frame.
        gHkRefusals = gHkRefusals + 1
        if gHkRefusals <= HkCount:
          warn "admin: hotkey " & HkCfgKey[i] & " = " & "\"" & want & "\"" &
               " REFUSED -- " & hotkeyNote(gRegion)
        pending = true
    inc i
  if not pending:
    gHkApplied = true
    gHkEpochSeen = hotkeyEpoch(gRegion)
  elif gHkTries >= HkMaxTries:
    # Stop retrying, but do NOT pretend it worked: the key stays unbound, the
    # reason stays in the region note and in adminDiag(), and this says so.
    gHkApplied = true
    gHkEpochSeen = hotkeyEpoch(gRegion)
    warn "admin: a configured hotkey was still REFUSED after " & $HkMaxTries &
         " ticks, so the push has stopped retrying -- " & hotkeyNote(gRegion) &
         ". The key is UNBOUND, not silently applied; rebinding in the F6 " &
         "menu (select the row, press K) still works and still persists."

proc persistHotkeys() =
  ## A rebind made in the F6 menu bumps `hotkeyEpoch`; that is the ONE signal
  ## that the region changed under us, and it is what makes an in-game rebind
  ## survive a restart. Without it the key would flip live and then quietly
  ## revert on the next launch -- the same shape as a settings row that
  ## changes nothing.
  if gRegion == nil or not gHkApplied: return
  let ep = hotkeyEpoch(gRegion)
  if ep == gHkEpochSeen: return
  gHkEpochSeen = ep
  var i = 0
  while i < HkCount:
    let live = hotkeyName(gRegion, HkBit[i])
    if live != gWantKey[i]:
      gWantKey[i] = live
      if applySetting(HkCfgKey[i], "\"" & live & "\"") == Ok:
        info "admin: hotkey " & HkCfgKey[i] & " -> " &
             (if live.len > 0: live else: "(unbound)") & ", saved"
      else:
        warn "admin: hotkey " & HkCfgKey[i] & " changed to " &
             (if live.len > 0: live else: "(unbound)") &
             " but config.json could NOT be written -- it will revert on the " &
             "next launch"
    inc i

proc applyConfigToggles() =
  ## config.json is the initial state at load. seedDefaults sets ESP+God on the
  ## first time any process maps the region; then this overlays the config so a
  ## fresh launch honours the file. After load the F6 menu owns the toggles.
  if gRegion == nil: return
  adminSeedDefaults(gRegion)
  # EVERY cheat defaults OFF -- this build goes to testers. These fallbacks, the
  # schema below and AOWL_ADM_DEFAULTS in aowlspt_admin.h are three independent
  # copies of the same decision; they must agree, or the effective default is
  # whichever one happened to run last.
  setToggle(gRegion, admEsp,       cfgBool("esp", false))
  setToggle(gRegion, admGodmode,   cfgBool("godmode", false))
  setToggle(gRegion, admStamina,   cfgBool("infiniteStamina", false))
  setToggle(gRegion, admNoRecoil,  cfgBool("noRecoil", false))
  setToggle(gRegion, admNoWeight,  cfgBool("noWeight", false))
  setToggle(gRegion, admInstaHeal, cfgBool("instantHeal", false))
  setToggle(gRegion, admAmmo,      cfgBool("unlimitedAmmo", false))
  setToggle(gRegion, admThermal,   cfgBool("thermalVision", false))
  setToggle(gRegion, admNightVis,  cfgBool("nightVision", false))
  setToggle(gRegion, admFly,       cfgBool("fly", false))
  setToggle(gRegion, admTeleport,  cfgBool("teleport", false))
  setToggle(gRegion, admTimeOfDay, cfgBool("timeOfDay", false))
  cfgEspMaxDistance = setting("espMaxDistance").asFloat(400.0)
  loadHotkeyConfig()

# ---------------------------------------------------------------------------
# The F12 settings schema (client-only route; the F6 menu is the live control)
# ---------------------------------------------------------------------------

proc adminSchema(): seq[Setting] =
  result = @[
    # THE POINTER ROW. The admin surface is the F6 overlay, not this page: the
    # overlay owns the toggles the moment the game is up, it has the item
    # spawner, and it works in a raid where this page cannot be reached. What
    # remains here is the boot state (config.json) plus this signpost, so a
    # player who finds the settings page first is not left believing the seven
    # still-unbound rows below are the whole admin menu.
    #
    # NOT VESTIGIAL, asked and answered 2026-08-28: this row is the only thing
    # on the settings page that tells a player where the admin surface actually
    # is. It is `implemented = false` because it sets nothing, which is the
    # honest declaration for a signpost, not a bug -- removing it would leave
    # the F6 overlay, the item spawner and every hotkey undiscoverable from the
    # one screen a player is guaranteed to find.
    stringSetting("adminSurface", "The admin menu is F6", "press F6 in game",
                  category = "Admin", implemented = false,
                  description = "aowlspt original (F6 admin panel). The live admin surface is the in-game F6 overlay -- toggles, and an item spawner (type a name, set the count and condition, Enter). The rows on this page set the state the F6 menu STARTS in; after that F6 owns them. This row is a signpost and sets nothing."),
    boolSetting("esp", "ESP", false, category = "Visuals",
                description = "aowlspt original (F6 admin panel). Boxes and side-colour on every player (F6 menu). Needs the host's GameWorld cache: turn on the debugEsp or botDiag host flag, or adminDiag() reports ESP unavailable."),
    boolSetting("godmode", "God mode", false, category = "Combat",
                description = "aowlspt original (F6 admin panel). Neuters EFT.Player::ApplyDamageInfo while in a raid. GLOBAL: bots stop taking damage too."),
    boolSetting("infiniteStamina", "Infinite stamina", false, category = "Movement",
      description = "aowlspt original (F6 admin panel)."),
    boolSetting("noRecoil", "No recoil / sway", false, category = "Combat",
                description = "aowlspt original (F6 admin panel). BOUND 2026-08-28. Turns off the recoil pipeline's own switch (NewRecoilShotEffect.RecoilEffectOn) and zeroes the four aim-sway inputs on ProceduralWeaponAnimation, every tick -- the game re-enables recoil on a weapon change, so it is re-applied rather than set once. Offsets measured with tools/fldoff.py; adminDiag()'s 'no recoil' line reports PASS only when a LATER tick still reads the suppression in place. Weapons on the OLD recoil pipeline are not touched, and the diag says so."),
    boolSetting("noWeight", "No weight", false, category = "Movement",
                description = "aowlspt original (F6 admin panel). BOUND 2026-08-28. Zeroes PhysicalBase's Overweight / WalkOverweight / SprintOverweight and clears the two encumbrance flags every tick, and lifts WalkSpeedLimit to 1.0. It does NOT fake the inventory weight itself (PreviousWeight is a cache nothing reads back). Offsets measured with tools/fldoff.py; adminDiag()'s 'no weight' line reports FAIL, not silence, if the game re-raises overweight faster than the tick suppresses it."),
    boolSetting("instantHeal", "Instant heal", false, category = "Combat",
                implemented = false, description = "aowlspt original (F6 admin panel). NOT BOUND. The offset that would drive this has not been measured on build 1.1.0.1.46777, so the row reads and never writes -- and the F6 menu draws it \\\"n/a\\\" for the same reason. Neither surface can turn it on."),
    boolSetting("unlimitedAmmo", "Unlimited ammo", false, category = "Combat",
                implemented = false, description = "aowlspt original (F6 admin panel). NOT BOUND. The offset that would drive this has not been measured on build 1.1.0.1.46777, so the row reads and never writes -- and the F6 menu draws it \\\"n/a\\\" for the same reason. Neither surface can turn it on."),
    boolSetting("thermalVision", "Thermal vision", false, category = "Visuals",
                implemented = false, description = "aowlspt original (F6 admin panel). NOT BOUND. The offset that would drive this has not been measured on build 1.1.0.1.46777, so the row reads and never writes -- and the F6 menu draws it \\\"n/a\\\" for the same reason. Neither surface can turn it on."),
    boolSetting("nightVision", "Night vision", false, category = "Visuals",
                implemented = false, description = "aowlspt original (F6 admin panel). NOT BOUND. The offset that would drive this has not been measured on build 1.1.0.1.46777, so the row reads and never writes -- and the F6 menu draws it \\\"n/a\\\" for the same reason. Neither surface can turn it on."),
    boolSetting("fly", "Fly / noclip", false, category = "Movement",
                implemented = false, description = "aowlspt original (F6 admin panel). NOT BOUND. The offset that would drive this has not been measured on build 1.1.0.1.46777, so the row reads and never writes -- and the F6 menu draws it \\\"n/a\\\" for the same reason. Neither surface can turn it on."),
    boolSetting("teleport", "Teleport to marker", false, category = "Movement",
                implemented = false, description = "aowlspt original (F6 admin panel). NOT BOUND. The offset that would drive this has not been measured on build 1.1.0.1.46777, so the row reads and never writes -- and the F6 menu draws it \\\"n/a\\\" for the same reason. Neither surface can turn it on."),
    boolSetting("timeOfDay", "Set time of day", false, category = "World",
                implemented = false, description = "aowlspt original (F6 admin panel). NOT BOUND. The offset that would drive this has not been measured on build 1.1.0.1.46777, so the row reads and never writes -- and the F6 menu draws it \\\"n/a\\\" for the same reason. Neither surface can turn it on."),
    boolSetting("hotkeys", "Action hotkeys", true, category = "Hotkeys", keybind = true,
                description = "aowlspt original (F6 admin panel). Master gate for the keys below, and ON by default as of 2026-08-28. MEASURED cost with it on and no key bound -- the shipped state -- from aowl_admin_hotkey_poll: one bounded 12-iteration scan of our own shared-memory block, ZERO calls into the game, zero allocation. The first Input::GetKeyDown happens only after you bind a key, i.e. only when you asked for it, and then at most 5 per tick at a byte-verified static RVA. Turn this off to stop the poll entirely. Keys work in a raid, where this page cannot be reached, and are dead while the window is not focused."),
    keybindSetting("hotkeyEsp", "ESP hotkey", "", category = "Hotkeys",
                   description = "aowlspt original (F6 admin panel). A UnityEngine.KeyCode NAME (F7, Insert, KeypadPlus, ...). Empty means unbound. An unrecognised name is REFUSED with the name printed, in the host log and under the F6 menu; it is never read as KeyCode.None, which is a real key with ordinal 0. Rebindable in the F6 menu too: select the row and press K."),
    keybindSetting("hotkeyGodmode", "God mode hotkey", "", category = "Hotkeys",
                   description = "aowlspt original (F6 admin panel). As above. REFUSED while God mode reports no capability, because a key on an unbound action would do nothing, which is worse than no key."),
    keybindSetting("hotkeyStamina", "Infinite stamina hotkey", "",
                   category = "Hotkeys",
                   description = "aowlspt original (F6 admin panel). As above. REFUSED while infinite stamina reports no capability."),
    keybindSetting("hotkeyNoRecoil", "No recoil / sway hotkey", "",
                   category = "Hotkeys",
                   description = "aowlspt original (F6 admin panel). As above. New 2026-08-28, alongside the row it toggles. REFUSED until no-recoil publishes a capability bit, which it does once a write has actually landed on a live ProceduralWeaponAnimation -- so binding this outside a raid is refused, out loud, rather than accepted and dead."),
    keybindSetting("hotkeyNoWeight", "No weight hotkey", "",
                   category = "Hotkeys",
                   description = "aowlspt original (F6 admin panel). As above. New 2026-08-28. REFUSED until no-weight publishes a capability bit. The remaining seven actions still have no hotkey row: their writes are not bound on this build, and a key on an unbound action is worse than no key."),
    floatSetting("espMaxDistance", "ESP max distance (m)", 400.0,
                 lo = 10.0, hi = 2000.0, step = 10.0, category = "Visuals",
      description = "aowlspt original (F6 admin panel).")]

proc onAdminSettings(url, body, session: string): string =
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok: applyConfigToggles()
  result = declaredSchemaReply(st).text

proc onAdminSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  if st == Ok: applyConfigToggles()
  result = declaredSchemaReply(st).text

proc onSettingsHotApply(key: string) =
  ## admin is client-side, so its `/aowlspt/settings/<guid>` route is
  ## registered into nothing and the two handlers above never run in the
  ## client. Without this the F12 edit persists to config.json and the shared
  ## HUD region keeps the OLD toggle until the next launch -- a cheat switch
  ## that flips and changes nothing. Same call the route handler makes, so
  ## there is ONE apply path and not two.
  discard key
  applyConfigToggles()
  settingApplied("config toggles re-applied to the shared HUD region")

# ---------------------------------------------------------------------------
# The Unity-thread sampler: the ONLY thing in this mod that calls game code
# ---------------------------------------------------------------------------
#
# `camSample()` calls `Camera::get_main` and the two sret `Matrix4x4` getters.
# Those are Unity calls and are legal only on Unity's own thread; `onUpdate`
# runs on the HOST's thread, which is why the sampler cannot live there.
#
# FACT #136, and the whole reason for the gate below: a client mod that arms
# IL2CPP work before the host's main-thread drain is live kills the client
# about 1.2s in, with `Unity thread live` never confirmed and no client log
# directory to explain it. `mods/fov` hit exactly this and fixed it by asking
# the host, so admin asks the host too. NOT ARMING IS THE DEFAULT: the driver
# stays unarmed, and says why, until the host reports the drain has FIRED.

type MainThread = object
  ok: bool          ## the host answered at all
  bound: bool       ## the drain is on Unity's thread and has already fired
  methodName: string
  frames: int64

proc askMainThread(): MainThread =
  ## `call("aowlspt.host::main_thread")`, decoded. The host answers this before
  ## it checks whether the runtime is up, so it is meaningful with no game --
  ## which is what makes it usable as a gate rather than a race.
  result = MainThread(ok: false, bound: false, methodName: "", frames: 0'i64)
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok: return
  if raw.len == 0: return
  result.ok = true
  result.bound = asBool(field(raw, "bound"), false)
  result.methodName = asText(field(raw, "method"), "")
  result.frames = int64(asInt(field(raw, "frames"), 0))

var gSamplerState = "not attempted"
var gSamplerArmed = false
var gSamplerFirings = 0
var gSamplerGood = 0

proc onCamTick(payload: string): string =
  ## One firing per host drain, i.e. once per frame, on Unity's thread. It does
  ## exactly one thing -- refresh the view-projection snapshot -- and writes no
  ## game memory. `camSample` byte-verifies all three prologues before its first
  ## call and self-disables after repeated refusals, so this cannot become a
  ## per-frame fault for the rest of the session.
  ## FLAG-GATED, DEFAULT OFF (host rule 5): with the ESP toggle off this calls
  ## nothing at all. The driver stays installed rather than being unbound and
  ## rebound, because binding is the risky operation and toggling is not.
  result = ""
  if gRegion == nil: return
  # UNITY THREAD. `Input::GetKeyDown` is Unity's and is legal only here, which
  # is why the hotkey poll rides this tick rather than `onUpdate` (host
  # thread). It runs BEFORE the ESP gate on purpose: a hotkey that only worked
  # while ESP was already on would be useless for turning ESP on.
  #
  # With `cfgHotkeys` false -- the shipped default -- or with every slot
  # unbound, `hotkeyPoll` makes ZERO calls into the game and returns at once.
  # It byte-verifies the prologue before its first call, caps its iteration at
  # two compile-time table sizes, allocates nothing, and self-disables after
  # 240 consecutive bind refusals.
  # L0/L1 BRACKETS. Two QPC reads per pair around call sites that already
  # exist; no-ops when the profiler is off (flag-gated, DEFAULT OFF). The
  # WHOLE bracket is closed on EVERY return path -- including the ESP-off one
  # below -- so a tick that returns early is counted as a cheap tick rather
  # than silently vanishing from the denominator.
  # The control runs OUTSIDE the WHOLE bracket on purpose: inside, its cost
  # would land in the UNEXPLAINED residual of L1 and be attributed to work
  # admin does not do.
  apControl()
  let tWhole = apNow()
  let tHk = apNow()
  discard hotkeyPoll(gRegion, cfgHotkeys)
  apAdd(ApHotkey, tHk)
  if not toggleOn(gRegion, admEsp):
    apAdd(ApWhole, tWhole)
    apTick()
    return
  gSamplerFirings = gSamplerFirings + 1
  let tCam = apNow()
  let camOk = camSample()
  apAdd(ApCam, tCam)
  if camOk: gSamplerGood = gSamplerGood + 1
  # UNITY THREAD, and it has to be. `EFT.Player::get_Position` @0x6F32C0 ends in
  # `Transform::get_position_Injected`, a Unity native ICall -- it is not legal
  # from `onUpdate` (host thread), which is where the ESP data pass runs. So the
  # positions are SAMPLED here into a snapshot and READ back there. This
  # replaces `MovementContext.PreviousPosition` @0x370, which is a real field
  # that is permanently zero on this build and made `positions` report FAIL in
  # a live raid. `posSample` arms itself once behind a 16-byte prologue verify,
  # validates every hop, caps its sweep, allocates nothing, and declines with a
  # named reason rather than silently.
  let tPos = apNow()
  posSample()
  apAdd(ApPos, tPos)
  apAdd(ApWhole, tWhole)
  apTick()

proc armCamSampler() =
  ## Idempotent, retried from onUpdate until it arms or refuses for a reason
  ## that cannot change. Never arms optimistically.
  if gSamplerArmed: return
  if camState() == 2:
    gSamplerState = "refused: " & camStateText()
    return
  let mt = askMainThread()
  if not mt.ok:
    gSamplerState = "waiting: this host does not answer " &
                    "aowlspt.host::main_thread, so there is no thread the " &
                    "sampler could be shown to reach"
    return
  if not mt.bound:
    gSamplerState = "waiting: the host's main-thread drain is not confirmed " &
                    "on Unity's thread yet (" &
                    (if mt.methodName.len > 0:
                       "drain " & mt.methodName & ", " & $mt.frames & " firings"
                     else: "no drain method bound") &
                    ") -- arming il2cpp work before it is live crashes the " &
                    "client (fact #136)"
    return
  if everyMain(onCamTick) == Ok:
    gSamplerArmed = true
    gSamplerState = "armed on everyMain, drained from " & mt.methodName &
                    " on Unity's thread"
  else:
    gSamplerState = "refused: everyMain was refused by the host (" &
                    lastError() & "), so world->screen cannot be sampled"

proc samplerDiag(): string =
  "  esp sampler  : " &
  (if gSamplerArmed and gSamplerGood > 0:
     "PASS  " & gSamplerState & "; " & $gSamplerGood & " good samples of " &
     $gSamplerFirings & " firings"
   elif gSamplerArmed and gRegion != nil and not toggleOn(gRegion, admEsp):
     "INCONCLUSIVE  " & gSamplerState & ", but the ESP toggle is OFF so it " &
     "samples nothing -- turn ESP on in the F6 menu"
   elif gSamplerArmed:
     "INCONCLUSIVE  " & gSamplerState & ", " & $gSamplerFirings &
     " firings but NO good sample yet -- " & camStateText()
   else:
     "FAIL  " & gSamplerState) & "\n"

# ---------------------------------------------------------------------------
# Capability -- what the mod could actually arm, so the menu is honest
# ---------------------------------------------------------------------------

proc hotkeyDiag(): string =
  ## PASS / FAIL / INCONCLUSIVE, and the three are not interchangeable. "No key
  ## is bound" is INCONCLUSIVE, not a pass: it means nothing was tested. This
  ## check can fail -- a bound key that has never fired reports INCONCLUSIVE,
  ## not PASS, so it is not a restatement of our own write.
  if gRegion == nil:
    return "  hotkeys      : FAIL  no shared region, so no key can be read\n"
  if not cfgHotkeys:
    return "  hotkeys      : INCONCLUSIVE  the `hotkeys` setting is OFF (the " &
           "shipped default), so nothing is polled and no key was tested\n"
  if hotkeyDisabled():
    return "  hotkeys      : FAIL  SELF-DISABLED after 240 consecutive bind " &
           "refusals -- " & hotkeyStateText() & "\n"
  var bound = ""
  var i = 0
  while i < HkCount:
    let n = hotkeyName(gRegion, HkBit[i])
    if n.len > 0:
      if bound.len > 0: bound.add ", "
      bound.add modeName(HkBit[i]) & "=" & n
    inc i
  let note = hotkeyNote(gRegion)
  if bound.len == 0:
    return "  hotkeys      : INCONCLUSIVE  on, " & hotkeyStateText() &
           ", but NO key is bound to any capable action" &
           (if note.len > 0: " -- last refusal: " & note else: "") & "\n"
  if hotkeyFires(gRegion) > 0:
    return "  hotkeys      : PASS  " & bound & "; " & $hotkeyFires(gRegion) &
           " activation(s) so far\n"
  result = "  hotkeys      : INCONCLUSIVE  " & bound & "; " &
           hotkeyStateText() & ", but no key has been pressed yet -- press " &
           "one in game and re-run this diagnostic" &
           (if note.len > 0: " (last note: " & note & ")" else: "") & "\n"

proc adminDiag*(): string {.exportc: "aowl_admin_diag", cdecl.} =
  ## What actually bound, and what did not. The load banner has advertised this
  ## since day one but NO SUCH PROC EXISTED -- a diagnostic that is only
  ## promised is worse than none (CLAUDE.md 6).
  ##
  ## Every line is PASS / FAIL / INCONCLUSIVE. "I could not look" -- no raid, no
  ## world, a host flag off -- is INCONCLUSIVE, never a pass and never a FAIL
  ## blamed on the offsets.
  result = "admin diag (" & ModName & " " & ModVersion & ")\n"
  if gRegion == nil:
    result.add "  region       : FAIL  shared HUD region not mapped; " &
               "the F6 menu and ESP are unavailable this session\n"
  else:
    result.add "  region       : PASS  mapped (" & $hudWidth(gRegion) & "x" &
               $hudHeight(gRegion) & " back buffer)\n"
  result.add hotkeyDiag()
  result.add samplerDiag()
  result.add dataDiag()
  result.add "\n  toggles      : "
  if gRegion == nil:
    result.add "unavailable"
  else:
    var any = false
    for b in 0 ..< int(admCount):
      if toggleOn(gRegion, int32(b)):
        if any: result.add ", "
        result.add modeName(int32(b))
        any = true
    if not any: result.add "all off (the shipped default)"

proc publishCapability() =
  var cap = 0'u32
  if dataResolved():  cap = cap or (1'u32 shl admEsp)
  if godCapable():    cap = cap or (1'u32 shl admGodmode)
  if staminaCapable(): cap = cap or (1'u32 shl admStamina)
  # NO WEIGHT and NO RECOIL are bound as of 2026-08-28. Their capability is
  # earned the same way stamina's is -- a write actually attempted against a
  # PhysicalBase / ProceduralWeaponAnimation that read back sanely -- so the bit
  # is 0 outside a raid and the F6 menu draws the row dim, rather than offering
  # a toggle that has nothing to write to.
  if noWeightCapable(): cap = cap or (1'u32 shl admNoWeight)
  if noRecoilCapable(): cap = cap or (1'u32 shl admNoRecoil)
  # Every other mode is not bound on this build; left 0 => drawn "unavailable".
  setCapability(gRegion, cap)

# ---------------------------------------------------------------------------
# The per-frame pass, on the host thread (memory reads need no Unity thread)
# ---------------------------------------------------------------------------

var gTick = 0'i64
var gReported = false
var gRaidReported = false
var gRaidSettle = 0
var gLastDiagTick = 0'i64

const RaidSettleTicks = 300
const DiagReEmitTicks = 3600'i64
  ## Re-dump adminDiag this many in-raid ticks after the last, so an intermittent
  ## in-raid defect (the ESP flicker) is measurable from the log rather than
  ## invisible behind a once-per-raid latch.
  ## onUpdate ticks to wait after a GameWorld appears before accepting that a
  ## still-empty position walk is real. Stated as a falsifiable bound, not a
  ## safe number: at the mod tick rate this is several seconds -- far longer
  ## than the gap between RegisterPlayer firing and MainPlayer being assigned,
  ## and short enough that a genuinely broken offset is still reported within
  ## the first raid rather than never.


# ---------------------------------------------------------------------------
# The F6 item spawner -- the mod's half
# ---------------------------------------------------------------------------
#
# WHY THIS RUNS ON THE SERVER SIDE AND NOT WITH THE REST OF THE MOD.
#
# `capability.invoke` REFUSES on `sideClient`, by design and out loud: the
# client host has no mod set to resolve a provider against. The provider of
# `aowl.items` is mods/tarkov, which is a server mod. So the F6 menu -- which
# is drawn in the game process by the overlay -- cannot itself make the call.
#
# What CAN: this same mod, loaded on the server side, mapping the SAME named
# region. `Local\aowlspt_admin_shared_v4` is a session-local file mapping, and
# the backend runs in the same session on the same box, so both processes open
# one region by name. The overlay writes the request; this drains it.
#
# That is also why `onUpdate` splits by side rather than doing both: the ESP
# and cheat writes need the game's address space and are meaningless here, and
# the invoke is impossible over there.

var gSpawnServed = 0
var gSpawnFaults = 0
var gSpawnOff = false

proc spawnRequestJson(query: string; count, condition: int): string =
  ## Hand-built rather than composed, because this mod does not import the JSON
  ## builder. The query is the only free text and it is escaped here; a query
  ## carrying a quote or a backslash must not be able to change the shape of
  ## the request.
  var q = ""
  for i in 0 ..< query.len:
    let c = query[i]
    if c == '"' or c == '\\':
      q.add '\\'
      q.add c
    elif c >= ' ' and c <= '~':
      q.add c
    # anything else is dropped: the overlay only accepts printable ASCII, so a
    # control byte here means the region was written by something else.
  result = "{\"query\":\"" & q & "\",\"count\":" & $count &
           ",\"condition\":" & $condition & "}"

var gSearchLast = ""
var gSearchFaults = 0

proc searchRequestJson(query: string): string =
  ## The same escaping `spawnRequestJson` does, with `op:"search"` on the
  ## front. Composed here rather than by adding a parameter to that proc so
  ## the two request shapes stay readable side by side.
  var q = ""
  for i in 0 ..< query.len:
    let c = query[i]
    if c == '"' or c == '\\':
      q.add '\\'
      q.add c
    elif c >= ' ' and c <= '~':
      q.add c
  result = "{\"op\":\"search\",\"query\":\"" & q & "\"}"

proc serviceSearch() =
  ## TYPEAHEAD. What the player has typed so far, answered as they type.
  ##
  ## THE REPORTED DEFECT THIS EXISTS FOR: "the item spawner menu, that still
  ## never worked -- when i typed anything it wouldnt show up anywhere". Even
  ## with the keystrokes arriving, the F6 spawner had nothing to show for them:
  ## the only way to find out whether a query matched was to submit it, and a
  ## query matching nothing was indistinguishable from a query that had never
  ## been typed. The line under the query row now always says what the current
  ## text matches -- including, explicitly, that it matches nothing.
  ##
  ## Bounded by CHANGE, not by time: the search runs only when the query is
  ## different from the last one answered, so holding the menu open with a
  ## settled query costs one string compare per tick and no cross-mod call.
  if gRegion == nil or gSpawnOff: return
  # Never speak over a real spawn. `spawnBusy` is set from submit until the
  # drain acks, and that answer belongs to the player, not to the typeahead.
  if spawnInflight(gRegion): return
  let query = spawnQuery(gRegion)
  if query == gSearchLast: return
  gSearchLast = query
  if query.len == 0:
    spawnNote(gRegion, "type part of an item name, or a 24-hex template id")
    return
  # A one- or two-character query is not worth searching for, and saying so is
  # not a refusal to work -- it is the honest state of a query that has not
  # been typed yet.
  #
  # MEASURED, and the reason this threshold exists rather than being a taste
  # call: `searchItemsCounted` counts how many items REALLY matched, so it
  # visits the whole 2.7 MB locale and calls `itemExists` on every name that
  # matches. For a one-letter query that is most of the ~40,000 entries, on
  # every keystroke. Three characters is where the match set stops being
  # "nearly everything".
  if query.len < 3:
    spawnNote(gRegion, "keep typing -- " & $query.len &
              " character(s); 3 are needed before searching")
    return

  let r = invoke("aowl.items", 1, searchRequestJson(query))
  if not r.isOk:
    # A refused search is REPORTED, not swallowed. If the provider is not
    # loaded this is the line that says so, and it is the difference between
    # "this database has no such item" and "nothing is answering".
    gSearchFaults = gSearchFaults + 1
    spawnNote(gRegion, "search unavailable: " & r.message)
    if gSearchFaults >= 20:
      gSpawnOff = true
      warn "admin: twenty consecutive F6 search refusals -- the spawner has " &
           "DISABLED itself for this session rather than call a provider that " &
           "is not answering on every keystroke. Nothing else is affected."
    return
  gSearchFaults = 0
  var msg = field(r.body, "message").asText("")
  if msg.len == 0:
    # The provider is contracted to render the sentence. An empty one is a
    # provider bug, and saying "no matches" on its behalf would invent an
    # answer -- so this says which of the two it actually is.
    msg = "the search answered but described nothing; treat as UNVERIFIED"
  spawnNote(gRegion, msg)

proc serviceSpawn() =
  ## Drain at most ONE request per tick. Bounded by construction: `spawnPending`
  ## returns a single sequence number, and every exit path calls `spawnDone`,
  ## so a request can never be left in flight with the HUD showing "working...".
  if gRegion == nil or gSpawnOff: return
  let req = spawnPending(gRegion)
  if req == 0'i32: return

  let query = spawnQuery(gRegion)
  if query.len == 0:
    # Cannot happen through the overlay (submit refuses an empty query) but the
    # region is shared, so it is answered rather than assumed away.
    spawnDone(gRegion, req, "the request carried no item name")
    return
  let count = spawnCount(gRegion)
  let condition = spawnCondition(gRegion)

  let r = invoke("aowl.items", 1, spawnRequestJson(query, count, condition))
  if r.isOk:
    gSpawnServed = gSpawnServed + 1
    # The provider's own sentence, verbatim. This mod deliberately does not
    # compose a success message of its own: it does not know how many items
    # were placed, and inventing "spawned N" here is precisely the silent-
    # success failure the provider was written to make impossible.
    var msg = field(r.body, "message").asText("")
    if msg.len == 0:
      msg = "aowl.items answered OK but said nothing about what it did; " &
            "treat this as UNVERIFIED and check the stash"
    info "admin: F6 spawn -- " & msg
    spawnDone(gRegion, req, msg)
    return

  gSpawnFaults = gSpawnFaults + 1
  warn "admin: F6 spawn refused -- " & r.message
  spawnDone(gRegion, req, r.message)
  if gSpawnFaults >= 20:
    gSpawnOff = true
    warn "admin: twenty consecutive F6 spawn refusals -- the spawner drain " &
         "has DISABLED itself for this session rather than refuse every tick " &
         "forever. Nothing else in this mod is affected."

# ---------------------------------------------------------------------------
# The NATIVE INVENTORY SCREEN -- the backend half
# ---------------------------------------------------------------------------
#
# Three drains, all on the same tick as `serviceSpawn` above and for the same
# reason it is here rather than in mods/tarkov: `capability.invoke` refuses on
# `sideClient`, and the screen runs in the game process.
#
# WHAT MAKES THIS DIFFERENT FROM `serviceSpawn`. That one moves a SENTENCE. This
# one moves ROWS, and for a mint it moves a MEASUREMENT: the count of the minted
# template in the profile before the spawn and again after it. Those two numbers
# are what `aowl_invui_mint_done` turns into PASS / FAIL / INCONCLUSIVE, and
# nothing on this side can spell a PASS -- it can only supply the numbers.
#
# Every drain is bounded: one request per tick per kind, a row loop capped by
# the region's own `AOWL_IU_MAX_ROWS`, and a self-disable after twenty
# consecutive refusals so a provider that is not answering costs twenty calls,
# not one per tick forever.

var gIuRegion: InvUiRegion   # default-initialised, exactly as `gRegion` above:
                             # nimony refuses an explicit `= nil` on this
                             # pointer alias, and the zero value is the same
                             # "not mapped yet" state every reader tests for.
var gIuFaults = 0
var gIuOff = false
var gIuServed = 0
var gIuMints = 0
var gIuDiagTick = 0
var gIuLastDiag = ""

proc iuJsonEscape(s: string): string =
  ## The same escaping `spawnRequestJson` does, and here for the same reason:
  ## this mod does not import the JSON builder, and a query carrying a quote or
  ## a backslash must not be able to change the shape of the request. Anything
  ## outside printable ASCII is DROPPED rather than encoded -- the screen only
  ## accepts printable ASCII, so a control byte here means the region was
  ## written by something that is not our screen.
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c == '"' or c == '\\':
      result.add '\\'
      result.add c
    elif c >= ' ' and c <= '~':
      result.add c

proc iuNoteFault(what, why: string) =
  ## One place that counts a refusal, says it, and self-disables. A refusal that
  ## is not shown is the same as a silent no-op, so the region's note carries it
  ## too -- the screen has a line for exactly this.
  gIuFaults = gIuFaults + 1
  iuNote(gIuRegion, what & " unavailable: " & why)
  warn ModName & ": invui " & what & " refused -- " & why
  if gIuFaults >= 20:
    gIuOff = true
    warn ModName & ": twenty consecutive invui refusals -- the native " &
         "inventory screen's drain has DISABLED itself for this session " &
         "rather than call a provider that is not answering on every tick. " &
         "Nothing else in this mod is affected; the F6 spawner is separate."

proc iuServiceStash() =
  ## Fill the right-hand column: `aowl.items` `op:"list"`, as ROWS.
  if gIuOff: return
  let req = iuStashPending(gIuRegion)
  if req == 0'i32: return
  let query = iuQuery(gIuRegion)

  iuStashBegin(gIuRegion)      # clear FIRST: a query that matches nothing must
                               # not leave the previous query's rows on screen
  if query.len < 3:
    # Not a refusal -- the honest state of a query that has not been typed yet.
    # `searchItemsCounted` visits the whole 2.7 MB locale and calls `itemExists`
    # on every name that matches, and for a one-letter query that is most of
    # ~40,000 entries on every keystroke. Three is where the match set stops
    # being "nearly everything".
    iuNote(gIuRegion, (if query.len == 0:
                         "type part of an item name, or paste a 24-hex id"
                       else:
                         "keep typing -- " & $query.len &
                         " character(s); 3 are needed before searching"))
    iuStashDone(gIuRegion, req)
    return

  let r = invoke("aowl.items", 1,
                 "{\"op\":\"list\",\"limit\":" & $iuMaxRows() &
                 ",\"query\":\"" & iuJsonEscape(query) & "\"}")
  if not r.isOk:
    iuNoteFault("search", r.message)
    iuStashDone(gIuRegion, req)
    return
  gIuFaults = 0

  let matched = field(r.body, "matched").asInt(0)
  let rows = parseArray(field(r.body, "rows"))
  var landed = 0
  var dropped = 0
  var i = 0
  while i < rows.len and i < iuMaxRows():        # capped twice, deliberately
    let row = at(rows, i)
    let tpl = field(row, "tpl").asText("")
    let nm  = field(row, "name").asText("")
    if tpl.len > 0:
      if iuStashAdd(gIuRegion, tpl, (if nm.len > 0: nm else: tpl)):
        landed = landed + 1
      else:
        dropped = dropped + 1
    i = i + 1
  iuStashMatched(gIuRegion, matched)
  # The note states BOTH numbers, always. `landed` is what the screen can show;
  # `matched` is what really exists. Reporting only the first is how "no such
  # item" gets said about the fifty-first match.
  iuNote(gIuRegion, (if matched == 0:
                       "no item matches \"" & query & "\""
                     else:
                       $landed & " of " & $matched & " match \"" & query &
                       "\"" & (if dropped > 0:
                                 " (" & $dropped & " would not fit the table)"
                               else: "")))
  gIuServed = gIuServed + 1
  iuStashDone(gIuRegion, req)

proc iuServiceInv() =
  ## Fill the left-hand column: what is actually in the stash, read back.
  if gIuOff: return
  let req = iuInvPending(gIuRegion)
  if req == 0'i32: return

  iuInvBegin(gIuRegion)
  let r = invoke("aowl.items", 1,
                 "{\"op\":\"inventory\",\"limit\":" & $iuMaxRows() & "}")
  if not r.isOk:
    iuNoteFault("inventory", r.message)
    iuInvDone(gIuRegion, req)
    return
  gIuFaults = 0

  let total = field(r.body, "total").asInt(0)
  let rows = parseArray(field(r.body, "rows"))
  var landed = 0
  var i = 0
  while i < rows.len and i < iuMaxRows():
    let row = at(rows, i)
    let tpl = field(row, "tpl").asText("")
    let nm  = field(row, "name").asText("")
    let qty = field(row, "count").asInt(1)
    if tpl.len > 0:
      if iuInvAdd(gIuRegion, tpl, (if nm.len > 0: nm else: tpl), qty):
        landed = landed + 1
    i = i + 1
  iuInvTotal(gIuRegion, total)
  gIuServed = gIuServed + 1
  iuInvDone(gIuRegion, req)

proc iuTemplateCount(tpl: string; readable: var bool): int =
  ## `aowl.items` `op:"count"`. Reports READABILITY separately from the number,
  ## which is the whole point: "the profile holds zero" and "I could not open
  ## the profile" must not both come back as 0, or a before/after comparison
  ## reads an unreadable profile as a failed spawn.
  readable = false
  result = 0
  let r = invoke("aowl.items", 1,
                 "{\"op\":\"count\",\"tpl\":\"" & iuJsonEscape(tpl) & "\"}")
  if not r.isOk: return
  if not field(r.body, "readable").asBool(false): return
  readable = true
  result = field(r.body, "count").asInt(0)

proc iuServiceMint() =
  ## Mint one template into the stash, and MEASURE whether it arrived.
  ##
  ## The order is: count, spawn, count. The two counts bracket the spawn, so
  ## what is published is a property of the FINISHED PROFILE and not of the call
  ## we made. If either count could not be taken the outcome is INCONCLUSIVE --
  ## `iuMintDone` is given `readable = false` and the header refuses to call
  ## that a PASS or a FAIL.
  if gIuOff: return
  let req = iuMintPending(gIuRegion)
  if req == 0'i32: return

  let tpl = iuMintTpl(gIuRegion)
  if tpl.len == 0:
    iuMintDone(gIuRegion, req, 0, 0, false,
               "the request carried no template id")
    return
  let count = iuMintCount(gIuRegion)
  let condition = iuMintCondition(gIuRegion)

  var beforeOk = false
  let before = iuTemplateCount(tpl, beforeOk)

  # The spawn goes through the SAME `aowl.items` path the F6 spawner uses --
  # `spawnInto`, by template id, which `isTemplateId` makes exact and
  # unambiguous. There is no second minting code path in this project and this
  # screen deliberately does not add one.
  let r = invoke("aowl.items", 1,
                 "{\"query\":\"" & iuJsonEscape(tpl) & "\",\"count\":" &
                 $count & ",\"condition\":" & $condition & "}")

  var afterOk = false
  let after = iuTemplateCount(tpl, afterOk)
  let readable = beforeOk and afterOk

  var msg = ""
  if not r.isOk:
    gIuFaults = gIuFaults + 1
    msg = "REFUSED: " & r.message
    warn ModName & ": invui mint refused -- " & r.message
    if gIuFaults >= 20:
      gIuOff = true
      warn ModName & ": twenty consecutive invui refusals -- the native " &
           "inventory screen's drain has DISABLED itself for this session."
  else:
    gIuFaults = 0
    gIuMints = gIuMints + 1
    let providerSaid = field(r.body, "message").asText("")
    # The provider's sentence is carried verbatim and then the MEASUREMENT is
    # appended, in that order, so a provider that said "spawned 5" while the
    # profile gained nothing is visibly contradicted on the same line rather
    # than believed.
    msg = (if providerSaid.len > 0: providerSaid
           else: "the provider answered OK but described nothing")
    if readable:
      msg = msg & " -- profile readback: " & $before & " -> " & $after
    else:
      msg = msg & " -- READBACK COULD NOT BE TAKEN (the profile would not " &
            "open), so this is INCONCLUSIVE, not a success"
    info ModName & ": invui mint -- " & msg

  iuMintDone(gIuRegion, req, before, after, readable and r.isOk, msg)

proc iuDrainTick() =
  ## All three drains, once per tick, in the order the screen needs them: a
  ## mint first (it is what the player just clicked), then the two fills. A
  ## mint also invalidates the left-hand column, and the screen re-asks for it
  ## itself rather than this side pushing -- the region's request/ack pair only
  ## has one owner per direction and inventing a second writer here would break
  ## that.
  ##
  ## Idle cost: three shared-memory integer compares.
  if gIuRegion == nil or gIuOff: return
  iuServiceMint()
  iuServiceStash()
  iuServiceInv()
  # THE VERDICT, PRINTED. Caught by marker verification: `iuDiag` had no call
  # site at all, so the linker stripped it and the literal `invui = PASS` was
  # MISSING from the built DLL. A three-outcome verdict that nothing ever
  # emits is not a check -- it is a function that could say anything.
  #
  # Emitted only when the verdict CHANGES, so the log carries the transitions
  # rather than the same line on every tick of an idle backend.
  gIuDiagTick = gIuDiagTick + 1
  if (gIuDiagTick mod 600) == 0:
    let v = iuDiag()
    if v != gIuLastDiag:
      gIuLastDiag = v
      info ModName & ": " & v

proc iuDiag*(): string =
  ## Three outcomes, never two. INCONCLUSIVE is what "the screen has never asked
  ## for anything" reports, because a drain that was never exercised has proved
  ## nothing about itself.
  if gIuRegion == nil:
    return "invui = INCONCLUSIVE -- the region could not be mapped, so the " &
           "native inventory screen has no backend this session"
  if not iuCompatible(gIuRegion):
    return "invui = FAIL -- the region exists but its magic/version/row-stride " &
           "do not match this build. Refusing to parse another build's row " &
           "table as ours"
  if gIuOff:
    return "invui = FAIL -- SELF-DISABLED after " & $gIuFaults &
           " consecutive refusals (served=" & $gIuServed & " mints=" &
           $gIuMints & ")"
  if gIuServed == 0 and gIuMints == 0:
    return "invui = INCONCLUSIVE -- the region is mapped and compatible but " &
           "the screen has not asked for anything yet, so nothing has been " &
           "exercised. That is not a pass"
  "invui = PASS -- " & $gIuServed & " fill request(s) and " & $gIuMints &
  " mint(s) serviced with no outstanding refusal (faults=" & $gIuFaults & ")"

proc emitProfile() =
  ## The phase decomposition and the cache's own behaviour, on the SAME timer as
  ## the diag they exist to explain. Unconditional when the flag is set: the
  ## numbers are CUMULATIVE, so an unchanged-looking line is still new
  ## information (the means moved). `admProfLine` reports INCONCLUSIVE below its
  ## tick threshold rather than a number, so "I could not look yet" cannot read
  ## as a pass; `rdCacheText` reports NEVER RAN separately from a 0% hit rate,
  ## and FAILs outright if the replicated predicate ever disagreed.
  if apEnabled() == 0'i32: return
  info ModName & ": " & admProfLine()
  info ModName & ": " & rdCacheText()

proc onUpdate(elapsedMs: int64): Status =
  # THE SIDE CHECK COMES FIRST, ahead of the HUD region's null check. It used to
  # come second, which coupled two unrelated regions: if `aowl_admin_map`
  # failed, the SERVER side returned before servicing anything -- including the
  # native inventory screen, whose region is a different mapping that had
  # nothing to do with the failure. The server half has no HUD to be missing.
  if side() != sideClient:
    # The server-side copy of this mod exists for ONE reason: to service the
    # F6 spawner, which needs `invoke` and therefore needs a side that has a
    # mod set. It reads no game memory and patches nothing -- there is no game
    # in this process.
    serviceSpawn()
    # The typeahead runs AFTER the spawn drain, so a submit made on this tick
    # is serviced before any search can occupy the one result line they share.
    serviceSearch()
    # The NATIVE inventory screen's three drains. A separate region, a separate
    # self-disable counter and a separate provider call, so neither surface can
    # turn the other off: the F6 spawner refusing does not stop the native
    # screen and vice versa.
    iuDrainTick()
    return Ok
  if gRegion == nil:
    # Client side with no HUD region: no ESP, no cheats, no menu. Announced at
    # load; nothing further to do per tick.
    return Ok
  gTick = gTick + 1
  discard dataOpen()
  armCamSampler()   # idempotent; waits for the host's Unity-thread drain

  # Screen size the overlay is drawing at, so projection matches the boxes.
  var w = hudWidth(gRegion)
  var h = hudHeight(gRegion)
  if w <= 0: w = 1920
  if h <= 0: h = 1080

  collectAndPublish(gRegion, cfgEspMaxDistance, w, h)

  # God mode patches live combat code, so it is DEFERRED: applied only in an
  # actual raid (a live GameWorld), never at boot or the menu -- patching a
  # damage function while the client is still settling is both pointless and the
  # prime suspect for the boot crash. Outside a raid the patch is held reverted.
  # (The byte-patch itself also byte-verifies the exact prologue before writing,
  # so even a wrong RVA on a future build refuses rather than corrupts.)
  if dataInRaid():
    setGodmode(toggleOn(gRegion, admGodmode))
    if toggleOn(gRegion, admStamina): applyStamina()
    # Both are per-tick field writes on the LOCAL player's own objects: no
    # detour, no patch, no managed call, nothing to byte-verify. They must be
    # re-applied because the game recomputes both -- overweight on an inventory
    # change, RecoilEffectOn on a weapon change -- which is exactly what the
    # look-back in each `apply*` measures and the diag reports.
    if toggleOn(gRegion, admNoWeight): applyNoWeight()
    if toggleOn(gRegion, admNoRecoil): applyNoRecoil()
  else:
    setGodmode(false)

  publishCapability()
  # ORDER MATTERS: capability first, because a hotkey is refused for an action
  # with no capability bit; then push the wanted keys; then notice an in-game
  # rebind and write it back to config.json.
  pushHotkeys()
  persistHotkeys()
  setStatus(gRegion, dataStatus() & "  " & godStatus())

  # Report once the mod has had time to settle, and AGAIN the first time a raid
  # is actually entered -- the boot report is necessarily INCONCLUSIVE about
  # everything that needs a world, so stopping there would leave the log
  # asserting "no raid" forever.
  if not gReported and gTick > 200:
    gReported = true
    info "admin: " & dataStatus()
  # MEASURED DEFECT: THIS REPORT COULD ONLY EVER SAY "positions: FAIL".
  #
  # From a live Woods raid at [0:08:09.172], with the player already spawned:
  #     gameworld    : PASS  GameWorld live
  #     positions    : FAIL  no player position passed the finite/bounded check
  #
  # All six offsets that walk were re-verified OFFLINE against the installed
  # GameAssembly.dll after that log, with `python tools/fldoff.py`, and every
  # one is correct on this build:
  #     EFT.GameWorld.AllAlivePlayersList      0x1c8   List<Player>
  #     EFT.GameWorld.RegisteredPlayers        0x1d0   List<IPlayer>
  #     EFT.GameWorld.MainPlayer               0x230   Player
  #     EFT.Player.<MovementContext>k__Backing 0x60    MovementContext
  #     EFT.MovementContext.PreviousPosition   0x370   Vector3
  #     EFT.Player.<AIData>k__BackingField     0xa00   IAIData
  # so the walk was not what failed. The REPORT was.
  #
  # `dataInRaid()` is true the instant `hostGameWorld()` is non-null, and that
  # cache is populated by the host's `RegisterPlayer` detour -- i.e. on the very
  # first frame a player registers, which is BEFORE `GameWorld.MainPlayer` has
  # been assigned and before any MovementContext has a PreviousPosition worth
  # reading. Latching `gRaidReported` on that frame meant the one diagnostic
  # anyone ever saw was taken at the single moment it was guaranteed to be
  # empty. It is the CLAUDE.md 9b shape inverted: a check that could only fail.
  #
  # So: report the first time positions actually validate -- which is the answer
  # everyone wanted -- and otherwise only after the raid has had a fair chance,
  # at which point a FAIL is real evidence rather than an artifact of timing.
  # Both branches latch together, so this stays exactly one report per raid.
  if not gRaidReported and dataInRaid():
    gRaidSettle = gRaidSettle + 1
    if espSeen() > 0 or gRaidSettle >= RaidSettleTicks:
      gRaidReported = true
      gLastDiagTick = gTick
      info adminDiag()
      emitProfile()
  elif dataInRaid() and (gTick - gLastDiagTick) >= DiagReEmitTicks:
    # RE-EMIT while in raid. The old once-per-raid latch meant an intermittent
    # in-raid defect (the ESP flicker) could never be measured from the log: the
    # single dump was taken at raid start, before any steady state. A periodic
    # re-emit surfaces the draw-stability tally so the flicker is falsifiable
    # (CLAUDE.md 9b) without a human re-entering the raid.
    gLastDiagTick = gTick
    info adminDiag()
    emitProfile()
  elif not dataInRaid():
    # Re-arm for the NEXT raid. Leaving these latched meant a session that
    # entered a second raid reported nothing at all about it.
    gRaidSettle = 0
    gRaidReported = false
  result = Ok

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  # THE NATIVE INVENTORY SCREEN'S REGION, mapped on the SERVER side only. The
  # client side of this mod has no use for it: the screen itself lives in the
  # host DLL (it is Unity UI, on the Unity thread) and the host maps the region
  # directly. Mapping it here as well would create the section from the wrong
  # process on a cold start and prove nothing.
  #
  # Mapped BEFORE the HUD region and reported separately, because a failure of
  # one says nothing about the other -- they are two different names.
  if side() != sideClient:
    gIuRegion = iuMap()
    if gIuRegion == nil:
      warn ModName & ": could not map the native inventory screen's region " &
           "(" & "Local\\aowlspt_invui_v1" & "); that screen will report " &
           "nothing is answering. The F6 spawner is unaffected."
    elif not iuCompatible(gIuRegion):
      warn ModName & ": the native inventory region exists but its magic, " &
           "version or row stride disagrees with this build. REFUSING to " &
           "service it rather than parse another build's row table as ours."
      gIuOff = true
    else:
      info ModName & ": native inventory screen backend armed -- three " &
           "drains (stash fill, inventory fill, mint) over " &
           "Local\\aowlspt_invui_v1, all answered by aowl.items. A mint is " &
           "bracketed by a profile READBACK of the minted template, and the " &
           "PASS/FAIL/INCONCLUSIVE verdict is derived from those two counts, " &
           "not from the call returning OK."

  gRegion = adminMap()
  if gRegion == nil:
    warn ModName & ": could not map the shared HUD region; the menu and ESP " &
         "are unavailable this session (the game is otherwise untouched)"
    declareSettings(adminSchema())
    onSettingsApplied(onSettingsHotApply)
    return Ok

  applyConfigToggles()

  # THE PHASE PROFILER. Flag-gated, DEFAULT OFF (CLAUDE.md 5). It installs no
  # detour, resolves no name and touches no game memory -- it is two QPC reads
  # per bracket -- but it is still off by default and still announces itself
  # when it is on, because an instrument nobody knows is running is an
  # instrument whose cost gets attributed to the thing it is measuring.
  let profOn = cfgBool("profile", false)
  apSetEnabled(if profOn: 1'i32 else: 0'i32)
  if profOn:
    info ModName & ": phase profiler ON. onCamTick is bracketed with " &
         "QueryPerformanceCounter at FOUR DISJOINT levels (tick phases, " &
         "posSample phases, per-list-slot phases, per-hop inside pos_live), " &
         "each summed against its OWN parent bracket so the unbracketed " &
         "remainder is named as UNEXPLAINED rather than attributed. Every " &
         "duration is MICROSECONDS (us) or NANOSECONDS (ns), always spelled. " &
         "It carries a positive control of 512 integer adds through the same " &
         "bracket -- expected order 0.1-1.0us; 0.0us or milliseconds means " &
         "the meter is lying and EVERY row is VOID. One line beside each " &
         "in-raid adminDiag dump."

  declareSettings(adminSchema())
  onSettingsApplied(onSettingsHotApply)
  discard serve("/aowlspt/settings/" & ModGuid, onAdminSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onAdminSettingsReset)

  if side() == sideClient:
    info ModName & " " & ModVersion &
         " loaded; F6 opens the admin menu. ALL cheats default OFF. " &
         "Cheats read measured static field offsets (build 1.1.0.1.46777)."
    info adminDiag()
  else:
    info ModName & " loaded on the server side: no HUD and no cheats here, " &
         "only the F6 item spawner's drain, which calls aowl.items (provided " &
         "by the Singleplayer mod). If that mod is not loaded, a spawn " &
         "reports exactly that in the F6 menu instead of doing nothing."
  result = Ok

proc onUnload(): Status =
  ## Revert the God mode patch so unloading the mod restores the game's own
  ## damage code. The shared region is a file mapping shared with the overlay; it
  ## is left mapped (the overlay may still be drawing).
  setGodmode(false)
  result = Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideServer, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
