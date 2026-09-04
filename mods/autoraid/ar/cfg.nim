## ar/cfg.nim -- THE SETTINGS SCHEMA AND THE VALUES READ BACK FROM IT.
##
## ONE schema, declared on BOTH sides. The client half and the server half of
## this mod are the same DLL (`sides = {sideClient, sideServer}`), loaded into
## two processes, and each reads the `config.json` sitting beside it. Declaring
## the same schema in both means the F12 panel, the native MODS tab and the
## backend's own settings route all show the same rows, and `tools/
## settingscheck.py` can enforce -- at BUILD time -- that every declared key
## exists in `config.json`. A key that is declared and absent is a control that
## silently reads its default forever.
##
## EVERY ROW SAYS WHEN IT TAKES EFFECT, and says it honestly. `appliesOn` is
## the machine-readable half and the hot-apply hook is the human half; a control
## that moves and changes nothing, without saying why, is the defect this whole
## mechanism exists to stop.

import aowlspt
import aowlspt/server
import aowlspt/settings
import uitree

const
  DefaultMaps* =
    "Customs,Woods,Shoreline,Interchange,Reserve,Lighthouse," &
    "Streets of Tarkov,Ground Zero,Factory,Laboratory,Icebreaker,Terminal"
    ## The labels OFFERED in the menu, not the labels the game has. Those are
    ## two different things and the difference is stated here rather than
    ## discovered: the location screen shows only the maps the current mode
    ## offers, and the MEASURED offer set on 2026-09-02 was
    ##   [RESERVE][LIGHTHOUSE][INTERCHANGE][CUSTOMS][GROUND ZERO][ICEBREAKER][WOODS]
    ## -- seven of these twelve. Asking for one that is not on offer is not a
    ## crash and not a silence: SELECT-MAP refuses and NAMES EVERY MAP THAT WAS
    ## ON OFFER, which is the line to read.

  MaxMapRows* = 12
    ## Rows the menu will draw. Kept at or below `ar/native`'s own compile-time
    ## row cap, which truncates rather than overflowing, so the two cannot
    ## disagree in a dangerous direction.

var cfgHotkeys = false
var cfgMenuKey = "F8"
var cfgEnterKey = "None"
var cfgDefaultMap = "Woods"
var cfgMaps = DefaultMaps
var cfgLoadoutMode = "current"
var cfgApplyAt = "auto"

proc hotkeysOn*(): bool = cfgHotkeys
proc menuKeyName*(): string = cfgMenuKey
proc enterKeyName*(): string = cfgEnterKey
proc defaultMap*(): string = cfgDefaultMap
proc mapsCsv*(): string = cfgMaps
proc loadoutMode*(): string = cfgLoadoutMode
proc applyAt*(): string = cfgApplyAt

proc mapList*(): seq[string] =
  ## The `maps` setting, split and trimmed. Empty entries are DROPPED rather
  ## than kept as blank rows: a blank row in the menu is a row that arms an
  ## empty map, which `machine.arm` then refuses -- correct, but confusing to
  ## look at.
  result = @[]
  var cur = ""
  var i = 0
  while i <= cfgMaps.len:
    if i == cfgMaps.len or cfgMaps[i] == ',':
      let t = trim(cur)
      if t.len > 0 and result.len < MaxMapRows:
        result.add t
      cur = ""
    else:
      cur.add cfgMaps[i]
    i = i + 1

proc loadConfig*() =
  ## Re-read every value from `config.json`. Called at load and from the
  ## hot-apply hook, so the two can never read different keys.
  cfgHotkeys = setting("hotkeys").asBool(cfgHotkeys)
  cfgMenuKey = setting("menuKey").asText(cfgMenuKey)
  cfgEnterKey = setting("enterKey").asText(cfgEnterKey)
  cfgDefaultMap = setting("defaultMap").asText(cfgDefaultMap)
  cfgMaps = setting("maps").asText(cfgMaps)
  cfgLoadoutMode = setting("loadoutMode").asText(cfgLoadoutMode)
  cfgApplyAt = setting("applyAt").asText(cfgApplyAt)

proc summary*(): string =
  "hotkeys=" & (if cfgHotkeys: "on" else: "off") &
  " menuKey=" & cfgMenuKey & " enterKey=" & cfgEnterKey &
  " defaultMap=" & cfgDefaultMap & " loadoutMode=" & cfgLoadoutMode &
  " applyAt=" & cfgApplyAt & " maps=" & $mapList().len

proc schema*(): seq[Setting] =
  @[
    boolSetting("hotkeys", "Enable AutoRaid hotkeys", false,
      keybind = true, category = "Keys",
      description =
        "THE GATE. With this off NOTHING is polled: not GetModuleHandle, not " &
        "UnityEngine.Input::GetKeyDown, and the two key rows below provably " &
        "do nothing. It is a keybind row itself so that a keybinds-only view " &
        "cannot show you a key while hiding the switch that makes it fire -- " &
        "a control that provably does nothing, with no way to find out why, " &
        "is the failure this facet exists to prevent. Default OFF."),

    keybindSetting("menuKey", "Open the map menu", "F8",
      category = "Keys",
      description =
        "Opens an overlay list of the maps below. Up/Down or 1-9 to choose, " &
        "Enter to enter that raid, Escape or this key again to close. Needs " &
        "`hotkeys` ON. The key is read with the game's own " &
        "UnityEngine.Input::GetKeyDown, so it is already ignored while the " &
        "window is unfocused, and every press is cross-checked against a key " &
        "the player cannot be holding -- if BOTH read down the press is " &
        "REFUSED and counted, because a read that ignores its argument would " &
        "otherwise open this menu on any keystroke."),

    keybindSetting("enterKey", "Enter the default map, no menu", "None",
      category = "Keys",
      description =
        "One key that arms a raid on `defaultMap` immediately, with no menu " &
        "shown. `None` = off, which is the shipped value. Needs `hotkeys` ON."),

    selectSetting("defaultMap", "Default map", "Woods",
      options = @["Customs", "Woods", "Shoreline", "Interchange", "Reserve",
                  "Lighthouse", "Streets of Tarkov", "Ground Zero", "Factory",
                  "Laboratory", "Icebreaker", "Terminal"],
      category = "Raid",
      description =
        "The map `enterKey` uses, and the row the menu starts on. This is the " &
        "map's DISPLAYED name on the location screen, matched " &
        "case-insensitively -- the only thing that identifies a map on this " &
        "build, because every tile GameObject is called `Location " &
        "Template(Clone)`. A map that is not on offer is REFUSED, and the " &
        "refusal names every map that WAS on offer."),

    stringSetting("maps", "Maps in the menu", DefaultMaps,
      category = "Raid",
      description =
        "Comma-separated DISPLAYED map names, in the order the menu lists " &
        "them. Up to 12 are drawn. These are the maps ON OFFER TO THE MENU, " &
        "not the maps the game is offering right now: the location screen " &
        "shows only what the current mode allows (MEASURED 2026-09-02: " &
        "RESERVE, LIGHTHOUSE, INTERCHANGE, CUSTOMS, GROUND ZERO, ICEBREAKER, " &
        "WOODS -- seven of the twelve here). Choosing one that is not offered " &
        "produces a named refusal listing what was."),

    enumSetting("loadoutMode", "Loadout for a spawned raid", "current",
      options = @["current", "spawned"],
      category = "Loadout", appliesOn = "restart",
      description =
        "SERVER SIDE. `current` (the shipped value) means the mod does " &
        "NOTHING to your gear: you go in wearing whatever the character " &
        "wears. `spawned` means the kit in `mods/autoraid/loadout.json` is " &
        "CREATED for the raid -- the gear you were wearing is moved to the " &
        "stash first (never destroyed), and the created items are stripped " &
        "from the profile at match end so they can never reach the stash. " &
        "Takes effect on the NEXT RAID, not on the current one: the loadout " &
        "is applied before the client's last profile fetch, which has already " &
        "happened by the time you can change this."),

    enumSetting("applyAt", "When to apply a spawned loadout", "auto",
      options = @["auto", "raidconfigured", "profileselected"],
      category = "Loadout", appliesOn = "restart",
      description =
        "Which backend event triggers the loadout. `auto` (the shipped value) " &
        "subscribes to BOTH `tarkov.raid.configured` and " &
        "`tarkov.profile.selected` and applies ONCE PER RAID, idempotently -- " &
        "which is correct whichever of the two precedes the client's last " &
        "`/client/game/profile/list` fetch, and that ordering is a wire " &
        "measurement, not something this mod should guess at. The other two " &
        "values pin it to one event and are for diagnosing that ordering.")]
