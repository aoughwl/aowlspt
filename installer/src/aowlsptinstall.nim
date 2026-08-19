## aowlspt-install -- turn a vanilla Escape From Tarkov install into an
## aowlspt one, without touching the vanilla install.
##
##     aowlspt-install detect
##     aowlspt-install plan    --source D:\Games\Tarkov --target D:\Aowlspt --payload payload
##     aowlspt-install install --source D:\Games\Tarkov --target D:\Aowlspt --payload payload
##     aowlspt-install verify  --target D:\Aowlspt
##     aowlspt-install uninstall --target D:\Aowlspt
##
## Two properties are load-bearing.
##
## **The source is only ever read.** The install the official launcher
## maintains is the source of truth and stays that way; everything is built in
## a separate target directory. That is what makes the whole operation
## reversible -- and it is why `install` takes a `--target` at all rather than
## patching in place, which is the usual design and the one that costs people a
## re-download when it goes wrong.
##
## **It refuses more readily than it proceeds.** See `compat.nim`; the rule
## that cannot be overridden is the one that would roll a post-1.0 client
## backwards to a pre-1.0 build.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log, eft, payload, compat, plan, journal]
import aowlsptinstall/registry

const Usage = """
aowlspt-install -- install aowlspt over a Tarkov client

  detect [PATH]              report what is installed, here or on this machine
  plan                       show what an install would do, and do nothing
  install                    do it
  verify   --target T        check an install still looks the way it was left
  uninstall --target T       remove what was installed, leaving the client

Options
  --source PATH    the vanilla install to build from (read only, never written)
  --target PATH    where the aowlspt install goes (created if missing)
  --payload PATH   the payload directory to install from
  --registry PATH  the mod registry (mods.json, or a directory holding one).
                   Defaults to the one in the payload, if it carries one.
  --list ID        the mod list a fresh install starts with
                   (default aowl.list.vanillaplus; `none` leaves the
                   payload's own default alone)
  --overlay        add the payload to the install already at --target, rather
                   than mirroring a client into it. What you want when you are
                   updating the mods in an install you already made.
  --copy           copy every file, rather than hard linking the asset bundles
  --force          proceed past a recoverable objection; see below
  --yes            do not ask for confirmation
  --dry-run        print every step, execute none
  -v, --verbose    name every file
  -q, --quiet      errors only
  -h, --help       this

By default the client's asset bundles -- tens of gigabytes of data that nothing
ever writes to -- are hard linked from the source rather than copied, so a full
install takes seconds and no additional disk. Everything a mod loader or patcher
could rewrite is copied regardless, because a hard link is a second name for the
same bytes and writing through one would reach back into the source install.
--copy turns linking off entirely, at the cost of a full second copy of the game.

--force relaxes objections that a person can reasonably overrule: a payload
built for a slightly different build of the same release, a source that already
has a mod loader in it. It does not relax a scripting-backend mismatch, and it
does not relax a payload that would take a post-1.0 client backwards across the
1.0 line. Those two are refusals, not warnings.
"""

type
  Options = object
    command: string
    source: string
    target: string
    payloadPath: string
    registryPath: string
    listId: string
    positional: seq[string]
    copyInstead: bool
    overlay: bool
    force: bool
    assumeYes: bool
    help: bool

proc parseArgs(): Options =
  result = Options(command: "", source: "", target: "", payloadPath: "",
                   registryPath: "", listId: registry.DefaultList,
                   positional: @[], copyInstead: false, overlay: false,
                   force: false,
                   assumeYes: false, help: false)
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--source" or a == "-s":
      inc i
      if i <= n: result.source = paramStr(i)
    elif a == "--target" or a == "-t":
      inc i
      if i <= n: result.target = paramStr(i)
    elif a == "--payload" or a == "-p":
      inc i
      if i <= n: result.payloadPath = paramStr(i)
    elif a == "--registry":
      inc i
      if i <= n: result.registryPath = paramStr(i)
    elif a == "--list":
      inc i
      if i <= n: result.listId = paramStr(i)
    elif a == "--overlay":
      result.overlay = true
    elif a == "--copy":
      result.copyInstead = true
    elif a == "--force":
      result.force = true
    elif a == "--yes" or a == "-y":
      result.assumeYes = true
    elif a == "--dry-run" or a == "-n":
      setDryRun true
    elif a == "--verbose" or a == "-v":
      setVerbosity vVerbose
    elif a == "--quiet" or a == "-q":
      setVerbosity vQuiet
    elif a == "--help" or a == "-h":
      result.help = true
    elif a.startsWith("-"):
      fatal "unknown option: " & a
    elif result.command.len == 0:
      result.command = a
    else:
      result.positional.add a
    inc i

proc confirm(question: string; assumeYes: bool): bool =
  ## A dry run never asks, because it never does anything.
  if assumeYes or dryRun():
    return true
  write stdout, question & " [y/N] "
  flushFile stdout
  var answer = ""
  if not readLine(stdin, answer):
    return false
  let a = toLowerAscii(strip(answer))
  result = a == "y" or a == "yes"

proc printLines(lines: seq[string]; indent: string = "") =
  for l in lines:
    line indent & l

# --------------------------------------------------------------- detect

proc cmdDetect(o: Options): int =
  var roots: seq[string] = @[]
  if o.positional.len > 0:
    for p in o.positional:
      roots.add p
  elif o.source.len > 0:
    roots.add o.source
  else:
    heading "Tarkov installs found on this machine"
    roots = discover()
    if roots.len == 0:
      line "  none. Pass a path explicitly if it lives somewhere unusual."
      return 1

  for r in roots:
    let install = identify(r)
    heading r
    let lines = describe(install)
    printLines(lines, "  ")

    if install.exists:
      # The two facts a person is actually about to act on, spelled out rather
      # than left to be inferred from the version number.
      if isPostOneZero(install.version):
        line "  suitable  yes -- this is a post-1.0 client"
      else:
        line "  suitable  no -- this is a pre-1.0 client; aowlspt targets " &
             "post-1.0 only"
  result = 0

# ----------------------------------------------------------- shared setup

proc wholeInstall(o: Options; pay: Payload): bool =
  ## Whether this run lays down a client of its own. The payload declares it;
  ## `--overlay` can only ever turn it off, never on -- a payload with no client
  ## in it cannot be talked into producing one, and a flag that pretended
  ## otherwise would produce a target with a journal claiming it owns a game
  ## that is not there.
  result = pay.kind == plFull and not o.overlay

proc requireOpt(value: string; name: string): string =
  if value.len == 0:
    fatal "missing " & name
  result = value

proc buildPlan(install: EftInstall; pay: Payload; targetIn: string;
               registryPath, listId: string; whole: bool): Plan =
  ## The order matters and is the order a person would do it by hand: lay down
  ## the client, put the runtime beside it, then the mod loader, then aowlspt,
  ## then the configuration that points the client at the backend. Each step
  ## only overwrites what the step before it put there.
  let target = absolutePathOf(targetIn)

  # `whole` -- the payload's declared kind, unless `--overlay` overrode it --
  # decides whether a client is mirrored into the target, and with it whether
  # the target belongs to this installer. Uninstall needs to know, so it is
  # decided once by the caller and passed in rather than re-derived here where
  # it could disagree with what was printed.
  result = newPlan(target, whole)

  # BattlEye is not carried across. It is anti-cheat for the live service, the
  # modded client never talks to the live service, and leaving it in place
  # invites the launcher to start it against a client it will not recognise.
  # ConsistencyInfo is BSG's file manifest and would fail against a modified
  # install by definition, so carrying it forward is worse than not.
  let skip = @["BattlEye", "ConsistencyInfo", "EscapeFromTarkov_BE.exe",
               "Uninstall.exe"]

  # Everything a mod loader, a patcher or the game itself might rewrite. These
  # are copied even when the rest of the install is hard linked, because a hard
  # link is a second name for the same bytes and writing through one would
  # reach back into the install the launcher maintains. It is a few hundred
  # megabytes out of tens of gigabytes, so it costs almost nothing to be safe.
  let hot = @["EscapeFromTarkov.exe",
              "UnityPlayer.dll",
              "GameAssembly.dll",
              "baselib.dll",
              "UnityCrashHandler64.exe",
              "EscapeFromTarkov_Data\\Managed",
              "EscapeFromTarkov_Data\\boot.config",
              "EscapeFromTarkov_Data\\globalgamemanagers",
              "EscapeFromTarkov_Data\\il2cpp_data",
              "EscapeFromTarkov_Data\\Resources",
              "EscapeFromTarkov_Data\\Plugins"]

  if whole:
    mirrorTree(result, install.root, target,
               "the client, from the install the launcher maintains", skip, hot)

  if pay.hasRuntime:
    copyTree(result, runtimeDir(pay), target,
             "the backend server and its data")
  if pay.hasClient:
    copyTree(result, clientDir(pay), target,
             "the mod loader the client boots through")
  if pay.hasAowlspt:
    # Into a directory of its own rather than over the root: everything this
    # installer owns and can therefore remove lives in one place.
    copyTree(result, aowlsptDir(pay), joinPath(target, "aowlspt"),
             "aowlspt: the hosts, and the mods built against them")

  # The registry, and the list a fresh install starts with. Both come after the
  # `aowlspt/` copy, because both write into what that copy laid down -- and the
  # plan is executed in the order it is printed, so "after" here is the same
  # word it is on screen.
  if registryPath.len > 0:
    copyFile(result, registryPath, joinPath(target, RegistryRelPath),
             "the mod registry: what exists, and the lists that name it")

    # And the default selection. The manager seeds itself, once, from
    # `activeLists` in its own config; there is no other way in. So the payload's
    # copy of that config is read here, patched, and written back as a step of
    # its own -- rather than a config invented here, which would be missing
    # every key the mod grows after today.
    if listId.len > 0 and listId != NoList:
      let cfgPath = joinPath(aowlsptDir(pay), "mods\\manager\\config.json")
      var cfgText = ""
      if not fileExists(cfgPath):
        note "the payload has no mod manager; no default selection to set"
      elif not readTextFile(cfgPath, cfgText):
        warn "could not read " & cfgPath & "; leaving the default selection alone"
      else:
        let patched = patchActiveLists(cfgText, listId)
        if patched.len == 0:
          warn "no \"activeLists\" array in the manager's config; leaving its " &
               "default selection (" & activeListsOf(cfgText) & ") alone"
        else:
          writeFile(result, joinPath(target, ManagerConfigRelPath), patched,
                    "the mod list a fresh install starts with: " & listId)

  if pay.backendUrl.len > 0:
    # Deliberately a file of its own rather than an edit to someone else's
    # config: a setting this installer owns is one it can also remove.
    var cfg = "{\n"
    cfg.add "  \"backendUrl\": \"" & pay.backendUrl & "\",\n"
    cfg.add "  \"tarkovVersion\": \"" & $install.version & "\",\n"
    cfg.add "  \"backend\": \"" & $install.backend & "\"\n"
    cfg.add "}\n"
    writeFile(result, joinPath(target, "aowlspt\\backend.json"), cfg,
              "where the client looks for the backend server")

proc showVerdict(v: Verdict) =
  let lines = render(v)
  if lines.len > 0:
    heading "Findings"
    printLines(lines, "  ")

# --------------------------------------------------------------- plan

proc prepare(o: Options; install: var EftInstall; pay: var Payload;
             verdict: var Verdict): bool =
  let target = requireOpt(o.target, "--target (where the aowlspt install goes)")
  let payPath = requireOpt(o.payloadPath, "--payload (what to install)")

  pay = payload.load(payPath)

  # The payload decides what `--source` means, so it is loaded first.
  #
  # A payload carrying a client turns some other directory into an install, and
  # `--source` is that other directory: required, and necessarily not the
  # target. A payload carrying only mods is added to an install that already
  # exists, and the install it is added to is the target -- so `--source`
  # defaults to it, and pointing them at the same directory is the normal case
  # rather than a mistake.
  let whole = wholeInstall(o, pay)
  if o.overlay and pay.kind == plFull:
    note "--overlay: the client at --target is left as it is; only the " &
         "payload is (re)written"
  var source = o.source
  if source.len == 0:
    if whole:
      fatal "missing --source (the vanilla install to build from)"
    source = target

  install = identify(source)

  heading (if whole: "Source" else: "Install")
  let sl = eft.describe(install)
  printLines(sl, "  ")

  heading "Payload"
  let pl = payload.describe(pay)
  printLines(pl, "  ")

  # The registry is reported here, beside the payload, because it is part of
  # what is about to be installed and because its absence is otherwise
  # invisible until the game is running and the mod manager says it found
  # nothing. It is a note rather than a refusal: an install with no registry is
  # a working install with an unmanaged mod set, which is a thing somebody may
  # legitimately want.
  # A registry objection does not short-circuit: the compatibility verdict
  # below is the thing a person came here to read, and hiding a refusal about
  # the 1.0 line behind "your list id is wrong" would be a poor trade.
  var registryOk = true
  heading "Registry"
  let regPath = resolveRegistry(pay.root, o.registryPath)
  if regPath.len == 0:
    if o.registryPath.len > 0:
      err "no mods.json at " & o.registryPath
      registryOk = false
    note "this payload carries no registry"
    note "the mod manager will load, find nothing to manage, and say so"
  else:
    line "  file      " & regPath
    var regText = ""
    if readTextFile(regPath, regText):
      printLines(describeRegistry(regText), "  ")
      if o.listId.len > 0 and o.listId != NoList:
        line "  default   " & o.listId
        if not hasList(regText, o.listId):
          # A default naming a list the registry does not define resolves to
          # nothing, and the player gets an install with everything off and no
          # reason given. Blocked rather than refused: a registry that gains the
          # list later is a real thing, and --force is the way to say so.
          err "this registry defines no list called " & o.listId
          note "pass --list with one it does define, or --list none"
          if not o.force:
            registryOk = false
      else:
        line "  default   (the payload's own)"

  verdict = evaluate(install, pay, o.force, whole)
  showVerdict(verdict)

  # Only meaningful for a full install: a target inside the source would be
  # walked by the very copy that creates it, and a source inside the target
  # would be overwritten while being read. An overlay does not copy the client
  # at all, so the two being the same directory is exactly right. Checked here
  # rather than in `compat`, because it is a fact about the arguments rather
  # than about the game.
  if whole:
    if isUnder(target, install.root):
      err "the target is inside the source; choose a target beside it, not " &
          "under it"
      return false
    if isUnder(install.root, target):
      err "the source is inside the target; that would install over the " &
          "install being read"
      return false

  result = verdict.allowed and registryOk

proc cmdPlan(o: Options): int =
  var install = identify("")
  var pay = payload.load("")
  var verdict = Verdict(findings: @[], allowed: false, forcible: false)
  let okToGo = prepare(o, install, pay, verdict)

  let p = buildPlan(install, pay, o.target,
                    resolveRegistry(pay.root, o.registryPath), o.listId,
                    wholeInstall(o, pay))
  heading "Plan"
  let lines = plan.render(p)
  printLines(lines, "  ")

  heading "Verdict"
  if okToGo:
    line "  this would proceed. Re-run with `install` to do it."
    result = 0
  else:
    line "  this would NOT proceed."
    if verdict.forcible:
      line "  --force would override the objections above."
    result = 1

# --------------------------------------------------------------- install

proc cmdInstall(o: Options): int =
  var install = identify("")
  var pay = payload.load("")
  var verdict = Verdict(findings: @[], allowed: false, forcible: false)
  if not prepare(o, install, pay, verdict):
    err "refusing to install"
    if verdict.forcible and not o.force:
      note "--force would override the objections above"
    return 1

  let target = absolutePathOf(o.target)
  let p = buildPlan(install, pay, target,
                    resolveRegistry(pay.root, o.registryPath), o.listId,
                    wholeInstall(o, pay))

  heading "Plan"
  let lines = plan.render(p)
  printLines(lines, "  ")

  if hasJournal(target):
    note ""
    note "an aowlspt install is already here; it will be written over"

  if not confirm("\nProceed?", o.assumeYes):
    line "nothing was done."
    return 1

  heading "Installing"
  let stats = apply(p, not o.copyInstead)

  if dryRun():
    heading "Dry run"
    line "  nothing was written."
    return 0

  heading "Result"
  let sum = summarise(stats)
  printLines(sum, "  ")

  if stats.failures > 0:
    err "the install did not complete cleanly; see the errors above"
    return 1

  let mode = if p.wholeTarget: "full" else: "overlay"
  # `pay.version` rather than a constant here: the release number lives in
  # `VERSION` at the top of the repo, `aowl release` copies it into the
  # `payload.json` that goes in the archive, and this is where it stops being a
  # property of the download and becomes a property of the install.
  var j = newJournal(target, install.root, pay.root, $install.version,
                     pay.version, "", mode)
  for c in stats.created:
    j.paths.add c
  let saved = journal.save(j)
  if not saved.ok:
    warn "could not write the uninstall manifest (error " & $saved.err & ")"
  else:
    ok "wrote " & j.path

  ok "installed into " & target
  if p.wholeTarget:
    note "the source install was not modified"
  result = 0

# --------------------------------------------------------------- verify

proc cmdVerify(o: Options): int =
  let target = absolutePathOf(requireOpt(o.target, "--target"))
  let j = journal.load(target)

  heading "Installed"
  if j.paths.len == 0:
    err "no aowlspt install manifest in " & target
    note "either nothing was installed here, or " & JournalName & " was removed"
    return 1

  line "  source    " & j.source
  line "  payload   " & j.payload
  line "  tarkov    " & j.tarkovVersion
  if j.payloadVersion.len > 0:
    line "  aowlspt   " & j.payloadVersion
  if j.mode.len > 0:
    line "  mode      " & j.mode

  heading "Paths"
  var missing = 0
  for p in j.paths:
    if winfs.exists(p):
      line "  ok      " & p
    else:
      line "  MISSING " & p
      inc missing

  heading "Client"
  let install = identify(target)
  let lines = eft.describe(install)
  printLines(lines, "  ")

  if known(install.version) and j.tarkovVersion.len > 0 and
     $install.version != j.tarkovVersion:
    warn "the client here is " & $install.version & ", but this was " &
         "installed against " & j.tarkovVersion

  if missing > 0:
    err $missing & " of " & $j.paths.len & " installed paths are gone"
    return 1
  ok "all " & $j.paths.len & " installed paths are present"
  result = 0

# --------------------------------------------------------------- uninstall

proc cmdUninstall(o: Options): int =
  let target = absolutePathOf(requireOpt(o.target, "--target"))
  let j = journal.load(target)

  if j.paths.len == 0:
    err "no aowlspt install manifest in " & target
    note "nothing is removed without one -- guessing at what to delete in a " &
         "game directory is not a thing this program does"
    return 1

  heading "Would remove"
  for p in j.paths:
    line "  " & p
  line "  " & j.path

  if j.mode == "full":
    line ""
    line "  This is a full install: the target holds its own copy of the"
    line "  client, and removing it removes that copy too."
    if j.source.len > 0:
      line "  The install it was built from -- " & j.source & " --"
      line "  was never written to and is not affected."

  if not confirm("\nRemove these?", o.assumeYes):
    line "nothing was done."
    return 1

  heading "Removing"
  var failures = 0
  for p in j.paths:
    say "remove " & p
    if dryRun():
      continue
    let r = winfs.removeTree(p)
    if not r.ok:
      err "remove " & p & ": error " & $r.err
      inc failures

  if not dryRun():
    let r = removeFileAt(j.path)
    if not r.ok:
      warn "could not remove " & j.path

  if failures > 0:
    err $failures & " paths could not be removed"
    return 1
  ok "removed"
  result = 0

# --------------------------------------------------------------- main

proc main(): int =
  let o = parseArgs()
  if o.help or o.command.len == 0:
    echo Usage
    return (if o.help: 0 else: 1)

  case o.command
  of "detect": result = cmdDetect(o)
  of "plan": result = cmdPlan(o)
  of "install": result = cmdInstall(o)
  of "verify": result = cmdVerify(o)
  of "uninstall": result = cmdUninstall(o)
  else:
    err "unknown command: " & o.command
    echo Usage
    result = 1

quit(main())
