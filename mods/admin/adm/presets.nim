## Inventory presets -- named kits, and the shipped defaults.
##
## ---------------------------------------------------------------------------
## WHAT THIS FILE IS, AND WHAT IT DELIBERATELY IS NOT
## ---------------------------------------------------------------------------
##
## A preset is a NAME plus a list of (query, count, condition) lines. `query` is
## the same free-text the emulator's own item search already takes -- part of an
## item's name, or a template id -- so nothing here invents or hard-codes a
## template id, and none of the four shipped kits can go stale against a Tarkov
## database update in the silent way a literal id would.
##
## The spawner is `spawnInto()` in `mods/tarkov/emu/spawn.nim`, reachable over
## the emulator's own `/aowlspt/settings/aowl.tarkov` surface. This mod does NOT
## contain a second spawner and must not grow one.
##
## **THE DISPATCH IS NOT WIRED, AND THAT IS STATED RATHER THAN STUBBED.**
## Measured while writing this: the mod SDK's only outbound call is
## `call("aowlspt.host::<member>", ...)` -- a HOST rpc namespace. There is no
## mod-to-mod call and no HTTP client in `aowl/src/aowlspt/*`, so this mod
## cannot reach another mod's route. Rather than ship an "Apply preset" control
## that returns success and spawns nothing -- the exact false-positive shape
## CLAUDE.md 9b is about -- `presetApplyStatus()` REFUSES with that reason, and
## `adminDiag()` prints it.
##
## The unblocking change is one route in a file this agent does not own: a
## handler on `mods/tarkov` that takes `{"preset":[{"q":..,"n":..,"c":..}]}` and
## loops `spawnInto`. `presetRequestJson()` below already emits exactly that
## payload, so the wiring is a route registration, not a rewrite.
##
## Persistence: the mod SDK has no file I/O either, so presets persist the same
## way every other mod setting does -- through the settings surface, which is
## written back to `config.json`. `presetSlot` (which kit is selected) and
## `presetName` (its label) are ordinary settings and therefore survive a
## restart. A user-authored kit BODY has nowhere to live until the route above
## exists; only the four built-ins are complete today, and `presetIsBuiltin`
## says which is which instead of letting the difference be invisible.

import std/strutils
import shared

type
  PresetLine* = object
    query*: string     ## free text the emulator's item search resolves
    count*: int
    condition*: int    ## percent, 100 = pristine

  Preset* = object
    name*: string
    note*: string
    builtin*: bool
    lines*: seq[PresetLine]

proc ln(q: string; n: int; c: int = 100): PresetLine =
  PresetLine(query: q, count: n, condition: c)

## The four shipped kits. Every line is a NAME QUERY, never a template id, so a
## database update changes what a query resolves to rather than silently
## resolving to nothing. Counts are deliberately modest: a preset that fills the
## stash is a preset nobody uses twice.
proc builtinPresets*(): seq[Preset] =
  result = @[
    Preset(name: "Starter kit", builtin: true,
           note: "A complete, unremarkable first raid: armour, a rifle, ammo, " &
                 "meds and a bag. Nothing here is high tier on purpose.",
           lines: @[ln("6B23-1", 1, 90), ln("6B47", 1, 90),
                    ln("AKM", 1, 85), ln("7.62x39 mm PS", 240),
                    ln("Salewa", 2), ln("Bandage", 4),
                    ln("Splint", 2), ln("Berkut", 1, 90),
                    ln("Scav Vest", 1, 90), ln("Water bottle", 1),
                    ln("Crackers", 2)]),
    Preset(name: "High tier kit", builtin: true,
           note: "Endgame armour and ammo. The one preset that is unambiguously " &
                 "a cheat rather than a convenience.",
           lines: @[ln("Altyn", 1, 100), ln("Slick", 1, 100),
                    ln("HK 416A5", 1, 100), ln("5.56x45 mm M995", 300),
                    ln("IFAK", 3), ln("Morphine", 2),
                    ln("Surv12", 1), ln("Tri-Zip", 1, 100),
                    ln("Blackrock", 1, 100)]),
    Preset(name: "Scav run kit", builtin: true,
           note: "What a scav actually walks in with -- light, cheap, and " &
                 "roughly what the raid would have given you anyway.",
           lines: @[ln("PACA", 1, 70), ln("Ssh-68", 1, 70),
                    ln("TOZ-106", 1, 70), ln("12/70 buckshot", 40),
                    ln("Bandage", 2), ln("Analgin", 1),
                    ln("Scav Backpack", 1, 70)]),
    Preset(name: "Medical / quest kit", builtin: true,
           note: "No weapon at all: healing, hydration and the tools a quest " &
                 "run keeps running out of.",
           lines: @[ln("Grizzly", 2), ln("IFAK", 3), ln("Salewa", 3),
                    ln("Splint", 4), ln("Esmarch", 2), ln("CALOK-B", 3),
                    ln("Propital", 2), ln("Water bottle", 3),
                    ln("MRE", 3), ln("Docs case", 1),
                    ln("Secure Flash drive", 2)])]

proc presetCount*(): int = builtinPresets().len

proc presetAt*(i: int): Preset =
  ## Bounds-checked. An out-of-range slot returns an EMPTY preset whose name
  ## says so, rather than clamping to slot 0 -- clamping would silently apply a
  ## kit the user did not choose.
  let all = builtinPresets()
  if i < 0 or i >= all.len:
    return Preset(name: "(no such preset)", builtin: false, note: "", lines: @[])
  result = all[i]

proc presetIsBuiltin*(i: int): bool = presetAt(i).builtin

proc presetLabels*(): seq[string] =
  result = @[]
  let all = builtinPresets()
  for i in 0 ..< all.len:
    result.add all[i].name

proc presetSummary*(i: int): string =
  let p = presetAt(i)
  if p.lines.len == 0: return p.name & ": nothing declared"
  var items = 0
  for i in 0 ..< p.lines.len: items = items + p.lines[i].count
  result = p.name & ": " & $p.lines.len & " line(s), " & $items &
           " item(s). " & p.note

proc presetRequestJson*(i: int): string =
  ## The payload the emulator's spawner would take. Emitted here so the missing
  ## piece is a ROUTE REGISTRATION in mods/tarkov and not a second
  ## implementation of anything. Hand-built rather than via the json module
  ## because every field is a literal this file controls; the only free text is
  ## a query, and a query containing a quote is REFUSED below rather than
  ## escaped, because a preset line with a quote in it is a typo, not a feature.
  let p = presetAt(i)
  if p.lines.len == 0: return ""
  var r = "{\"preset\":\"" & p.name & "\",\"lines\":["
  var first = true
  for i in 0 ..< p.lines.len:
    let q = p.lines[i].query
    if q.contains("\"") or q.contains("\\"): continue
    if not first: r.add ","
    first = false
    r.add "{\"q\":\"" & q & "\",\"n\":" & $p.lines[i].count &
          ",\"c\":" & $p.lines[i].condition & "}"
  r.add "]}"
  result = r

proc presetApplyStatus*(): string =
  ## Why applying a preset declines. One place, so the settings description, the
  ## diagnostic and any future caller cannot drift into three different stories.
  "REFUSED  the emulator's spawner (mods/tarkov/emu/spawn.nim spawnInto, " &
  "reached over /aowlspt/settings/aowl.tarkov) is the only sanctioned way to " &
  "put items in a stash, and this SDK has no mod-to-mod call and no HTTP " &
  "client -- call() reaches the aowlspt.host:: namespace only. So this mod " &
  "cannot dispatch a preset, and it does NOT pretend to: no control here " &
  "returns success without spawning. presetRequestJson() already emits the " &
  "exact payload a route on mods/tarkov would consume."

proc presetsDiag*(selected: int): string =
  ## Three outcomes, never two. "The kits are declared" is not "the kits work".
  result = "  presets      : INCONCLUSIVE  " & $presetCount() &
           " built-in kit(s) declared and selectable (" &
           presetAt(selected).name & " selected), but NOT APPLIED: " &
           presetApplyStatus() & "\n"
