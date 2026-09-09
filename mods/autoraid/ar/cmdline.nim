## ar/cmdline.nim -- THE TWO COMMAND-LINE ARGUMENTS THIS MOD OWNS.
##
## THIS FILE DOES NOT PARSE THE COMMAND LINE, and that is the point.
##
## The first cut of this mod was going to call `GetCommandLineW` from an
## `{.emit.}` block and scan for `-aowlraid=<label>`, because no helper existed.
## That would have been a mod-specific token, a mod-specific parser, a
## mod-specific quoting rule and a bounded-copy bug waiting to happen -- and the
## next mod that wanted an argument would have written a second one. The
## argument surface is now GENERIC and lives in the SDK
## (`aowl/src/aowlspt/args.nim`): the host parses `-aowl.<name>=<value>` tokens
## once, the launcher forwards any unknown `--name=value` as `-aowl.name=value`,
## and a mod DECLARES what it reads.
##
## WHY DECLARING MATTERS WHEN READING DOES NOT REQUIRE IT
## -----------------------------------------------------
## `cmdArg` answers from the host's parsed table whether or not anything was
## declared. Declaring buys three things that are worth the four lines:
##
##   * the boot audit and `--help` can LIST what this mod accepts, so an
##     argument is discoverable without reading source;
##   * a typo in a token can be reported as "no mod declares `-aowl.rade`"
##     instead of being silently ignored, which is the failure mode that makes
##     a command line feel broken;
##   * `registry/mods.json` carries the same two rows, and the README carries
##     the same two sentences, so the three cannot drift apart without somebody
##     noticing.
##
## THREE OUTCOMES, AS ALWAYS. `cmdlineAvailable()` false means the HOST could
## not give us the command line at all -- an older host, or a parse that
## refused. That is INCONCLUSIVE and is logged as such: it is NOT the same as
## "no `-aowl.raid` was passed", and reporting it as such would send the next
## reader to look at the launcher instead of at the host.

import aowlspt
import aowlspt/args

const
  ArgRaid* = "raid"
    ## `-aowl.raid=<MapLabel>` -- the map to enter, matched case-insensitively
    ## against the location tile's DISPLAYED TEXT, which is the only thing that
    ## identifies a map on this build (every tile GameObject is called
    ## `Location Template(Clone)`).
  ArgSide* = "raidside"
    ## `-aowl.raidside=pmc|scav` -- which side control to press on the PMC/SCAV
    ## selector. Default `pmc`.

const
  ArgExit* = "raidexit"
    ## `-aowl.raidexit=<seconds>` -- how long to stay in the command-line raid
    ## after the client reports DEPLOYED before leaving it through the in-raid
    ## menu. 0 = never leave, which is the default and what makes the mod
    ## inert on this axis when the token is absent.

proc declare*() =
  ## Declare both arguments. Called ONCE from `onLoad`, before anything reads
  ## them.
  declareArgs(@[
    argSpec(ArgRaid,
      "Enter an offline raid on this map as soon as the main menu is up. " &
      "The value is the map's DISPLAYED name on the location screen, matched " &
      "case-insensitively -- e.g. Woods, Customs, \"Ground Zero\". Absent = " &
      "the mod does nothing at launch.",
      default = "", kind = akString,
      example = "-aowl.raid=\"Ground Zero\"  (launcher: --raid=\"Ground Zero\")"),
    argSpec(ArgSide,
      "Which side to choose on the PMC/SCAV selector before the map list. " &
      "`pmc` or `scav`. Only consulted when -aowl.raid is present.",
      default = "pmc", kind = akString,
      example = "-aowl.raidside=scav"),
    argSpec(ArgExit,
      "After the command-line raid reaches DEPLOYED, stay this many SECONDS " &
      "and then LEAVE through the in-raid menu (SHOW-IN-RAID -> DISCONNECT " &
      "-> LEAVE -> results -> main menu), so one launch can enter AND exit a " &
      "raid with nobody at the keyboard. 0 (the default) = never leave. " &
      "Only consulted when -aowl.raid is present.",
      default = "0", kind = akInt,
      example = "-aowl.raidexit=90  (launcher: --raidexit 90)")])

proc requestedMap*(): string =
  ## The map asked for on the command line, or "" for "nothing was asked".
  cmdArg(ArgRaid, "")

proc requestedSide*(): string =
  cmdArg(ArgSide, "pmc")

proc exitAfterSeconds*(): int =
  ## Seconds to dwell in the raid before leaving; 0 = never. Read from the
  ## parsed table, so an unparseable value reads as the default and the
  ## host's own cmdline audit line is where a typo shows up.
  cmdArgInt(ArgExit, 0)

proc wasAsked*(): bool =
  ## Was `-aowl.raid` present AND non-empty? A BARE `-aowl.raid` with no value
  ## is deliberately NOT treated as a request: there is no default map worth
  ## guessing at, and entering the wrong raid is worse than entering none.
  hasCmdArg(ArgRaid) and requestedMap().len > 0

proc reportArgs*() =
  ## Say, at load, exactly what was found. One line, always -- silence here is
  ## what makes a launcher flag feel unreliable.
  if not cmdlineAvailable():
    warn "AutoRaid cmdline: INCONCLUSIVE -- the host did not give this mod " &
         "the parsed command line at all (an older host, or its parse " &
         "refused). That is NOT the same as `-aowl.raid was not passed`, and " &
         "it is not reported as such. Command-line raid entry is OFF for this " &
         "session; the " & "menu key and the settings still work."
    return
  if not hasCmdArg(ArgRaid):
    info "AutoRaid cmdline: no -aowl.raid token on the command line, so " &
         "nothing is armed at launch. Pass --raid=\"Woods\" to " &
         "aowlspt-launch, or press the menu key in game."
    return
  if requestedMap().len == 0:
    warn "AutoRaid cmdline: -aowl.raid was present with an EMPTY value. " &
         "Nothing is armed: there is no default map worth guessing at, and " &
         "entering the wrong raid is worse than entering none."
    return
  info "AutoRaid cmdline: -aowl.raid=\"" & requestedMap() & "\" side=\"" &
       requestedSide() & "\"" &
       (if exitAfterSeconds() > 0:
          " raidexit=" & $exitAfterSeconds() & "s (leave that long after DEPLOYED)"
        else: " raidexit=0 (stay in the raid)") &
       ". Arming is deferred until the host's main-thread " &
       "drain has fired -- calling into Unity before that is the documented " &
       "way to crash a frame or two later."
