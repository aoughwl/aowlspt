## Whether a payload may be installed onto a given client, and why not.
##
## This module is the reason the installer is worth having. Copying files into
## a game directory is easy; knowing when *not* to is the part that saves
## someone a 40 GB re-download.
##
## There is one rule here that cannot be overridden, and it is deliberate.
##
## The usual way to get a modded Tarkov running is to take whatever client the
## official launcher gave you and roll it backwards to whichever older build
## the mod runtime was written against. It works, and it is also the thing this
## installer will not do: it means the game you play is not the game you own,
## every subsequent official update has to be fought off, and a "downgrade"
## across a major release is a rewrite of the client's assemblies and asset
## bundles rather than a patch. If the payload targets a pre-1.0 client and the
## install is post-1.0, this module refuses, `--force` included. Every other
## check can be relaxed by someone who has read what they are relaxing.

import std/strutils
import eft
import payload

type
  Severity* = enum
    sevOk       ## nothing to say
    sevNote     ## worth knowing, changes nothing
    sevWarn     ## proceeds, but the user should have read it
    sevBlock    ## refuses unless overridden
    sevRefuse   ## refuses, full stop

  Finding* = object
    severity*: Severity
    title*: string
    body*: string

  Verdict* = object
    findings*: seq[Finding]
    ## True when the install may proceed given the overrides that were passed.
    allowed*: bool
    ## True when it would proceed if the user passed `--force`.
    forcible*: bool

proc `$`*(s: Severity): string =
  case s
  of sevOk: result = "ok"
  of sevNote: result = "note"
  of sevWarn: result = "warn"
  of sevBlock: result = "block"
  of sevRefuse: result = "refuse"

proc add(v: var Verdict; sev: Severity; title, body: string) =
  v.findings.add Finding(severity: sev, title: title, body: body)

proc evaluate*(install: EftInstall; pay: Payload; force: bool;
               whole: bool = true): Verdict =
  ## `whole` says whether the plan will lay down a client of its own. Several
  ## objections here are about *where the client came from*, and those simply
  ## do not apply when no client is being copied -- adding mods to an install
  ## that is already SPT is the ordinary thing to do, not a mistake.
  result = Verdict(findings: @[], allowed: true, forcible: true)

  # ---------------------------------------------------------------- payload

  if not pay.valid:
    for p in pay.problems:
      add(result, sevRefuse, "payload is not usable", p)
    result.allowed = false
    result.forcible = false
    return

  # ---------------------------------------------------------------- install

  if not install.exists:
    add(result, sevRefuse, "not a Tarkov install",
        install.root & " has no EscapeFromTarkov.exe. Point --source at the " &
        "folder the official launcher installed the game into.")
    result.allowed = false
    result.forcible = false
    return

  if not known(install.version):
    add(result, sevRefuse, "client version unreadable",
        "EscapeFromTarkov.exe has no readable version resource, so there is " &
        "nothing to check the payload against. A client that cannot be " &
        "identified is not one to install over.")
    result.allowed = false
    result.forcible = false
    return

  if install.backend == bkUnknown:
    add(result, sevRefuse, "client layout unrecognised",
        "EscapeFromTarkov_Data holds neither a Managed/ tree (Mono) nor " &
        "GameAssembly.dll plus il2cpp_data (IL2CPP). This does not look like " &
        "a complete install.")
    result.allowed = false
    result.forcible = false
    return

  # ------------------------------------------------------- the 1.0 boundary

  # Checked before the general version comparison so the message names the
  # actual objection rather than talking about mismatched numbers.
  if isPostOneZero(install.version) and not isPostOneZero(pay.targetTarkov):
    add(result, sevRefuse, "this payload would downgrade you across 1.0",
        "The install is Tarkov " & $install.version & "; the payload was " &
        "built for " & $pay.targetTarkov & ", which is a pre-1.0 client.\n" &
        "Getting from one to the other is not a patch -- it is " &
        "replacing the client's assemblies and asset bundles with an older " &
        "game's.\n" &
        "This installer does not do that, and --force does not " &
        "enable it. Use a payload built for " & $install.version & ".")
    result.allowed = false
    result.forcible = false
    return

  # ---------------------------------------------------------------- backend

  if pay.targetBackend != install.backend:
    add(result, sevRefuse, "scripting backend mismatch",
        "The client is " & $install.backend & "; the payload's binaries need " &
        $pay.targetBackend & ".\n" &
        "This is not a version disagreement that a flag can settle. " &
        "A Mono BepInEx plugin has no way to load into an IL2CPP process, " &
        "and an IL2CPP interop assembly has nothing to bind to under Mono.")
    result.allowed = false
    result.forcible = false
    return

  # ---------------------------------------------------------------- version

  let cmp = compare(pay.targetTarkov, install.version)
  if cmp < 0:
    add(result, sevBlock, "payload is older than the client",
        "The install is " & $install.version & "; the payload targets " &
        $pay.targetTarkov & ".\n" &
        "Mods built against an older client of the same major " &
        "release usually load and sometimes misbehave. Pass --force if you " &
        "know this pair works.")
  elif cmp > 0:
    add(result, sevBlock, "payload is newer than the client",
        "The install is " & $install.version & "; the payload targets " &
        $pay.targetTarkov & ".\n" &
        "Update the game through the official launcher, then run " &
        "this again.")

  # ---------------------------------------------------------------- flavour

  case install.flavour
  of flSpt:
    if whole:
      add(result, sevBlock, "the source is already an SPT install",
        "SPT_Runtime is present in " & install.root & ".\n" &
        "--source is meant to be the untouched install the official " &
        "launcher maintains, so that this one can be rebuilt at any time " &
        "without re-downloading. Installing from an already-patched copy " &
        "carries its patches forward invisibly.")
  of flPatched:
    if whole:
      add(result, sevWarn, "the source already has a mod loader",
          "doorstop or BepInEx is present in " & install.root & ". " &
          "Whatever is there will be carried into the target.")
  of flVanilla:
    if known(install.consistencyVersion) and
       compare(install.consistencyVersion, install.version) != 0:
      add(result, sevNote, "manifest and executable disagree",
          "ConsistencyInfo says " & $install.consistencyVersion &
          ", the executable says " & $install.version &
          ". BSG's manifest carries an extra component; this is normal.")
  of flNotAnEft:
    discard

  if install.hasBattlEye and whole:
    add(result, sevNote, "BattlEye is present in the source",
        "It is not copied into the target and not started by it. The " &
        "modded client runs without it, which is also why the modded client " &
        "must never be pointed at a live server.")

  # ---------------------------------------------------------------- verdict

  for f in result.findings:
    if f.severity == sevRefuse:
      result.allowed = false
      result.forcible = false
    elif f.severity == sevBlock:
      if not force:
        result.allowed = false

proc render*(v: Verdict): seq[string] =
  ## One block per finding, severity first, so the reason a run stopped is the
  ## thing on screen rather than something to scroll back for.
  result = @[]
  for f in v.findings:
    result.add $f.severity & "  " & f.title
    for line in splitLines(f.body):
      result.add "        " & line
