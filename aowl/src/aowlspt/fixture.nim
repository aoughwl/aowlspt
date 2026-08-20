## Where an offline binding self-test is allowed to get a runtime from.
##
## Several mods carry a `--side sim` self-test that reports, offline, which of
## their IL2CPP bindings resolve and which refuse. With no runtime in the
## process every one of them refuses for that reason, which is a true answer but
## a thin one, so the self-tests can be pointed at a `GameAssembly.dll` to load:
## `tests/mockil2cpp` builds a stand-in implementing the same C API, and the
## gate points them at it.
##
## **Pointing them at one is a `LoadLibrary` of a second `GameAssembly.dll`, and
## that is why this module exists rather than each mod reading the key itself.**
## Until now the path came from `selfTestRuntime` in the mod's `config.json`, it
## was a repository-relative path -- `tests/mockil2cpp/GameAssembly.dll` -- and
## `aowl payload` copies each mod's `config.json` into the installer payload
## verbatim. So a development fixture path shipped into a player's install. It
## fired on nothing, for two reasons that are both accidents rather than rules:
## the self-test only runs on `sideSim` and no simulator ships in a payload, and
## the relative path resolves to nothing outside a checkout. A thing that is
## safe only because it never happened is not safe.
##
## Two rules, and between them the fixture cannot steer a real client however a
## `config.json` reaches it:
##
## 1. **A path must be absolute.** A relative one resolves against whatever
##    directory the host happened to be started in, which in an install is the
##    game's own directory -- that is a `LoadLibrary` of a file chosen by the
##    working directory, and it is refused with the reason said out loud. It is
##    also the only form the loader defines here: `openIl2Cpp` loads with
##    `LOAD_WITH_ALTERED_SEARCH_PATH` so that `GameAssembly.dll` finds
##    `UnityPlayer.dll` beside itself, and that flag's behaviour is only
##    specified for an absolute path.
##
## 2. **The value can come from the environment**, `AOWLSPT_SELFTEST_RUNTIME`
##    and `AOWLSPT_SELFTEST_DATADIR`, which is where the gate now puts it. That
##    is what lets the committed `config.json` keys be empty: the fixture path
##    is set by the harness that owns the fixture, for the child processes it
##    starts, and there is nothing left in a mod's config for `aowl payload` to
##    carry into an install. The key stays declared, and empty, because it is a
##    real thing a developer can set to a real client's `GameAssembly.dll` --
##    with an absolute path, which is the only kind that would have worked.
##
## The refusal is a warning and a fallback, never a failure: the self-test then
## reports against the process, which is the same answer it gave before anyone
## thought to point it at a runtime.

import std/envvars

const
  EnvRuntime* = "AOWLSPT_SELFTEST_RUNTIME"
    ## Set by `aowl` for the simulator runs in the gate and by `aowl run`.
  EnvDataDir* = "AOWLSPT_SELFTEST_DATADIR"
    ## The `*_Data` directory `il2cpp_init` is given, when there is one.

type
  SelfTestPath* = object
    ## What the self-test should do about a runtime or a data directory.
    path*: string
      ## Empty means "nothing was asked for, use the process". Never relative.
    source*: string
      ## Where the value came from, for the report line.
    refusal*: string
      ## Non-empty when something *was* asked for and was refused. Say it, then
      ## carry on against the process.

proc trimmed(s: string): string =
  var a = 0
  var b = s.len - 1
  while a <= b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or s[a] == '\n'):
    inc a
  while b >= a and (s[b] == ' ' or s[b] == '\t' or s[b] == '\r' or s[b] == '\n'):
    dec b
  if b < a:
    return ""
  result = s.substr(a, b)

proc unquoted(s: string): string =
  ## Some mods read their settings as raw JSON text and get the quotes with it.
  ## Stripping them here means the rule below is applied to the path a person
  ## wrote rather than to a quote character.
  result = trimmed(s)
  if result.len >= 2 and result[0] == '"' and result[result.len - 1] == '"':
    result = trimmed(result.substr(1, result.len - 2))

proc isAbsolutePath*(p: string): bool =
  ## Windows, and deliberately strict. `C:\x` and `\\host\share\x` are absolute;
  ## `\x` and `/x` are *drive-relative* -- they mean "the current drive", which
  ## is as much a function of where the host was started as `tests\x` is -- and
  ## are not accepted.
  if p.len >= 3 and p[1] == ':' and (p[2] == '\\' or p[2] == '/'):
    return true
  if p.len >= 2 and p[0] == '\\' and p[1] == '\\':
    return true
  result = false

proc resolve(configured, envName, what: string): SelfTestPath =
  result = SelfTestPath(path: "", source: "", refusal: "")
  var value = unquoted(configured)
  var source = "\"" & what & "\" in config.json"
  if value.len == 0:
    value = unquoted(getEnv(envName, ""))
    source = envName
  if value.len == 0:
    return
  if not isAbsolutePath(value):
    result.refusal =
      source & " is " & value & ", which is a relative path. A relative " &
      what & " resolves against whatever directory this host was started " &
      "in -- in an install that is the game's own directory -- so it names " &
      "a file the working directory chose rather than one anybody did. It " &
      "is refused; falling back to the process. Give an absolute path."
    return
  result.path = value
  result.source = source

proc selfTestRuntime*(configured: string): SelfTestPath =
  ## The `GameAssembly.dll` an offline binding report should be run against.
  result = resolve(configured, EnvRuntime, "selfTestRuntime")

proc selfTestDataDir*(configured: string): SelfTestPath =
  ## The `*_Data` directory handed to `il2cpp_init` when a runtime was loaded
  ## out of process. Same rule, for the same reason: it is a path a development
  ## fixture supplies, and an install has no business acting on a relative one.
  result = resolve(configured, EnvDataDir, "selfTestDataDir")
