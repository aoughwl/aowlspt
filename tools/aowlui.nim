## aowlui -- a NAVIGATION layer over the live inspector, as a first-class
## `aowl` subcommand.
##
##     aowl ui roots
##     aowl ui screen  --root "Menu UI"
##     aowl ui findtext DEPLOY --root "Menu UI"
##     aowl ui click NEXT --root "Menu UI" --expect-screen "Matchmaker Insurance"
##     aowl raid --map factory --no-insurance
##
## WHY THIS EXISTS
## ---------------
## The inspector's verbs all key off the OBJECT NAME, and object names lie:
## `CharacterSlotView_pvp` displays "PvE" (fact #7). The only honest way to
## point at a control is the text a PERSON sees, and the inspector has no verb
## for that. This supplies it, plus the cached screen map, plus the two rules
## that were learned expensively:
##
##  * A press goes through `EFT.UI.DefaultUIButton.OnClick`. It is NOT a
##    `UnityEngine.UI.Button` (fact #1), and `ButtonFeedback::OnPointerClick`
##    plays the click SOUND and presses nothing (fact #5) -- the best false
##    positive in this codebase. `AnimatedToggle` IS a Unity Toggle whose
##    `m_IsOn` sits at +0x120, the SAME offset DefaultUIButton keeps its
##    UnityEvent at, so `press` on a toggle would invoke a BOOL as an event;
##    it is actuated through `Toggle::set_isOn` instead.
##  * Nothing here is force-activated. A GameObject you SetActive yourself is
##    a screen the game does not think is open.
##
## EVERY FAILURE PATH ANNOUNCES ITSELF, and a walk that TRUNCATED is a
## distinct outcome from one that found nothing -- absence is only ever
## reported from a COMPLETE walk.
##
## This is a port of `tools/ui.py`, whose behaviour it preserves deliberately.
## The differences are the four bugs that port was asked to fix, each marked
## `PORT FIX` below.

import std/[strutils, syncio, sha1, envvars, widestrs]
import std/windows/winlean
import aowlsptinstall/winfs

# ---------------------------------------------------------------------------
# small utilities nimony's stdlib does not carry
# ---------------------------------------------------------------------------

proc warnLine*(s: string) =
  ## Diagnostics go to stderr so a caller that pipes the answer still SEES the
  ## warning. A retry, a truncation or a burnt fault must never be invisible.
  write(stderr, s & "\n")

proc joinStr*(xs: seq[string]; sep: string): string =
  result = ""
  for i in 0 ..< xs.len:
    if i > 0: result.add sep
    result.add xs[i]

proc tailPath*(path: seq[string]; n: int): string =
  var start = path.len - n
  if start < 0: start = 0
  var parts: seq[string] = @[]
  for i in start ..< path.len: parts.add path[i]
  result = joinStr(parts, "/")

proc parseNat*(s: string): int =
  ## A non-negative integer, or -1 if `s` is not one.
  ##
  ## `strutils.parseInt` is `.raises` and nimony refuses it outside a
  ## try/except; more to the point, every number this tool parses comes out of
  ## the host's output, where "not a number" is an ordinary answer and not an
  ## exceptional one.
  if s.len == 0: return -1
  var v = 0
  for i in 0 ..< s.len:
    if s[i] < '0' or s[i] > '9': return -1
    v = v * 10 + (int(s[i]) - int('0'))
  result = v

type
  Tri* = enum
    ## Three states, on purpose. Collapsing "could not tell" into `false` is
    ## how this project has repeatedly reported a confident wrong answer.
    triUnknown, triNo, triYes

proc triText*(t: Tri): string =
  case t
  of triYes: result = "yes"
  of triNo: result = "no"
  of triUnknown: result = "unknown"

# ---------------------------------------------------------------------------
# a tiny pointer -> index map
#
# The walk is a few thousand nodes and every child has to be looked up by its
# transform pointer. A linear scan is quadratic over 4,600 nodes; this is 25
# lines and removes the question.
# ---------------------------------------------------------------------------

type
  PtrMap* = object
    keys: seq[string]
    vals: seq[int]
    mask: int

proc hashHex(s: string): int =
  var h = 5381
  for i in 0 ..< s.len:
    h = ((h shl 5) + h + int(s[i])) and 0x3FFFFFFF
  result = h

proc initPtrMap*(capacity: int): PtrMap =
  var n = 16
  while n < capacity * 4: n = n * 2
  var ks = newSeq[string](n)
  var vs = newSeq[int](n)
  for i in 0 ..< n:
    ks[i] = ""
    vs[i] = -1
  result = PtrMap(keys: ks, vals: vs, mask: n - 1)

proc mget*(m: PtrMap; k: string): int =
  var i = hashHex(k) and m.mask
  while m.keys[i].len > 0:
    if m.keys[i] == k: return m.vals[i]
    i = (i + 1) and m.mask
  result = -1

proc mput*(m: var PtrMap; k: string; v: int) =
  var i = hashHex(k) and m.mask
  while m.keys[i].len > 0:
    if m.keys[i] == k:
      m.vals[i] = v
      return
    i = (i + 1) and m.mask
  m.keys[i] = k
  m.vals[i] = v

# ---------------------------------------------------------------------------
# parsing -- BY FIELD NAME, never by position
#
# `parent` prints transform=, klass=, name= and go= on ONE line. Grabbing "the
# second hex number" off that line hands back the KLASS, and GetComponent on a
# klass pointer FAULTS -- burning one of the eight faults the inspector allows
# itself before it switches off for the whole session (fact #56). So every
# field is read by its own name.
# ---------------------------------------------------------------------------

const HexChars = {'0'..'9', 'a'..'f', 'A'..'F', 'x', 'X'}

proc hexAfter*(line, key: string): string =
  let i = line.find(key)
  if i < 0: return ""
  var j = i + key.len
  var r = ""
  while j < line.len and line[j] in HexChars:
    r.add line[j]
    inc j
  if r.len > 2 and r.startsWith("0x"): result = r
  else: result = ""

proc firstHex*(s: string): string =
  ## The first `0x...` token in `s`, INCLUDING the prefix.
  ##
  ## Distinct from `hexAfter(s, "0x")`, which starts scanning after the
  ## prefix and then rejects its own result for not beginning with `0x`. That
  ## returned "" for every `tree` line and made the whole walk parse as empty
  ## -- caught by `aowl ui selftest`, which is the entire reason it exists.
  let i = s.find("0x")
  if i < 0: return ""
  var r = ""
  var j = i
  while j < s.len and s[j] in HexChars:
    r.add s[j]
    inc j
  if r.len > 2: result = r
  else: result = ""

proc quotedAfter*(line, key: string; into: var string): bool =
  ## Empty is a legitimate value (`name=""`), so presence is a separate answer
  ## from content.
  into = ""
  let i = line.find(key)
  if i < 0: return false
  var j = i + key.len
  if j >= line.len or line[j] != '"': return false
  inc j
  while j < line.len and line[j] != '"':
    into.add line[j]
    inc j
  result = j < line.len

proc wordAfter*(line, key: string): string =
  let i = line.find(key)
  if i < 0: return ""
  var j = i + key.len
  var r = ""
  while j < line.len and line[j] != ' ' and line[j] != '\t' and
        line[j] != '\r':
    r.add line[j]
    inc j
  result = r

# ---------------------------------------------------------------------------
# the channel
# ---------------------------------------------------------------------------

type
  Ui* = object
    live*: string          ## the live install directory
    timeoutMs*: int        ## per-batch ceiling
    verbose*: bool
    serial*: int
    lastErr*: string       ## why the last false was false
    faults*: int           ## component faults we have SEEN this run
    timeoutPinned*: bool   ## the caller named a timeout, so it WINS
    tag*: string
      ## WRITER ATTRIBUTION, carried into every sentinel this Ui writes -- the
      ## same convention `plugins/aowlsptcode/mcp/channel.py` uses
      ## (`aowl-batch-<tag><pid>-<ms>-<n>`). The sentinel is the ONE part of a
      ## batch that reaches the host log, because the host echoes `> echo
      ## aowl-batch-...` and SKIPS `#`-prefixed serial lines without logging
      ## them. Measured 2026-09-02: nine batches ran unattributed in the first
      ## 23s of a boot and had to be traced to their writer by the SHAPE of
      ## their sentinel (`aowl-batch-<6 digits>` was this file) instead of by
      ## anything the log said. Empty means `aowlui`.

const
  # Pressable component types, MOST SPECIFIC FIRST. Never ButtonFeedback.
  ButtonComponents* = ["DefaultUIButton", "SimpleStateButton",
                       "AnimatedToggle", "Button"]
  # Unity's GetComponent(string) matches BASE type names, so TMP_Text catches
  # TextMeshProUGUI and TextMeshPro in one pass. `Text` is a genuinely
  # different component and gets its own pass over whatever is still bare.
  TextComponents* = ["TMP_Text", "Text"]
  ToggleSetIsOnRva* = "0x55ba430"   ## UnityEngine.UI.Toggle::set_isOn(bool)
  # TWO MEASURED CEILINGS, both silent: 127 commands answer, 128 hang; 40
  # `children` answer, 60 are dropped. Output volume is not knowable in
  # advance, so this starts optimistic and HALVES on a timeout.
  MaxCmds* = 120

proc initUi*(live: string; timeoutMs = 45000; pinned = false;
             tag = "aowlui"): Ui =
  var l = live
  if l.len == 0: l = "D:\\Aowlspt\\aowlspt"
  var t = ""
  # Sanitised to [a-z0-9], exactly as `channel.py`'s `writer_tag` does, so a
  # tag can never break the sentinel's tokenisation.
  for c in tag:
    if (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'): t.add c
    elif c >= 'A' and c <= 'Z': t.add chr(int(c) + 32)
  if t.len == 0: t = "aowlui"
  result = Ui(live: l, timeoutMs: timeoutMs, verbose: false, serial: 0,
              lastErr: "", faults: 0, timeoutPinned: pinned, tag: t)

proc cmdPath(u: Ui): string = joinPath(u.live, "aowlspt-inspect.txt")
proc outPath(u: Ui): string = joinPath(u.live, "aowlspt-inspect-out.txt")
proc logPath*(u: Ui): string = joinPath(u.live, "aowlspt-host.log")

proc diagnose(u: Ui): string =
  ## Say WHY there was no answer, in the host's own words. A timeout with no
  ## explanation is the failure mode this project keeps paying for.
  var blob = ""
  if not readShared(logPath(u), blob) or blob.len == 0:
    return "the host log is absent or empty -- the host is not running."
  var hits: seq[string] = @[]
  for line in blob.splitLines():
    if line.contains("live inspector"): hits.add line.strip()
  if hits.len == 0:
    return "the host log never mentions the live inspector at all -- the " &
           "`liveInspector` flag is off in aowlspt-host.json."
  var tail: seq[string] = @[]
  var i = hits.len - 3
  if i < 0: i = 0
  while i < hits.len:
    tail.add "   " & hits[i]
    inc i
  result = "last of what the host said about the channel:\n" &
           joinStr(tail, "\n")

# ---------------------------------------------------------------------------
# THE CHANNEL LOCK -- the same one `plugins/aowlsptcode/mcp/channel.py` takes,
# and interoperable with it BY CONSTRUCTION.
#
# The command file is ONE file with no two-writer protocol: B's write replaces
# A's before the host has read it, and A then waits out its whole timeout for an
# answer to a batch the host never saw. That reads as a host fault or a hang; it
# is neither. `channel.py` has guarded its side since it was written -- and
# `docs/HARNESS-AUDIT.md` names THIS file as the non-cooperating fourth writer,
# which matters more than the others because it is the side `aowlspt-launch.exe`
# uses in-process, next to a human who may be playing.
#
# INTEROPERABILITY IS THE WHOLE POINT, so every detail below mirrors
# `channel.py` deliberately and is asserted by `aowl ui selftest`:
#   * same directory: the system temp dir, NOT the live install (a human may be
#     mid-raid and this has no business creating files next to the game);
#   * same name: "aowlspt-inspect-" & the first 12 hex digits, LOWERCASE, of the
#     SHA-1 of the lowercased absolute live path, & ".lock";
#   * same acquire: create-EXCLUSIVE, so a lock file left on disk by the Python
#     side (which closes its handle and leaves the file) blocks us, which a
#     CREATE_ALWAYS open would not;
#   * same self-heal: a lock older than LOCK_STALE_S is broken, because a
#     crashed holder must not wedge the channel forever;
#   * same failure semantics: if the lock cannot be taken AT ALL (no temp dir,
#     permissions) we proceed UNLOCKED and say so -- that is what this file did
#     before, so it is not a regression -- but a lock held by someone else is a
#     REFUSAL with its own message, never a timeout.
# ---------------------------------------------------------------------------
const LockStaleMs* = 180_000'i64   ## == channel.py's LOCK_STALE_S = 180.0
const LockWaitMs*  = 60_000'i64    ## == channel.py's default timeout = 60.0

proc lockTempDir*(): string =
  ## Python's `tempfile.gettempdir()` consults TMPDIR, TEMP, TMP in THAT order
  ## on every platform. Matching the order matters more than matching the
  ## Windows API: if the two disagree about the directory they compute
  ## different paths and neither ever sees the other's lock -- a lock that
  ## silently does not interoperate is worse than no lock, because it reads as
  ## protection.
  var d = getEnv("TMPDIR")
  if d.len == 0: d = getEnv("TEMP")
  if d.len == 0: d = getEnv("TMP")
  if d.len == 0: d = "C:\\Temp"
  result = d

proc normLive*(live: string; sep: char): string =
  ## `os.path.abspath(live).lower()` for an already-absolute path, with `sep`
  ## as the separator every component is joined by.
  ##
  ## THE SEPARATOR IS A PARAMETER BECAUSE PYTHON'S ANSWER IS NOT FIXED, and
  ## that is a measured hazard, not a hypothetical one. `channel.py` hashes
  ## `os.path.abspath(live).lower()`; run under the Python on this machine
  ## that returns `d:/aowlspt/aowlspt` (sha1[:12] `ad4ef68aa8f3`), while a
  ## native-Windows Python returns `d:\aowlspt\aowlspt`, a DIFFERENT hash and
  ## therefore a DIFFERENT lock file. A lock whose name depends on which
  ## interpreter computed it does not interoperate, and a lock that does not
  ## interoperate is worse than none because it reads as protection.
  ##
  ## So this side does not guess which one the peer used: it takes BOTH (see
  ## `lockAcquire`). The real fix belongs on the Python side -- normalise the
  ## separators before hashing -- and is reported, not silently worked around.
  var t = ""
  for i in 0 ..< live.len:
    if live[i] == '/' or live[i] == '\\': t.add sep
    else: t.add live[i]
  while t.len > 3 and t[t.len - 1] == sep:
    t = t.substr(0, t.len - 2)
  result = toLowerAscii(t)

proc sha1Hex12*(s: string): string =
  ## The first 12 characters of a LOWERCASE hex SHA-1 -- `hexdigest()[:12]`.
  ## `$SecureHash` in the stdlib emits UPPERCASE, which would produce a
  ## different filename and therefore a lock nobody else can see.
  var st = newSha1State()
  update(st, s)
  let d = finalize(st)
  const HexLower = "0123456789abcdef"
  result = ""
  var i = 0
  while i < 6:
    result.add HexLower[int(d[i] shr 4)]
    result.add HexLower[int(d[i] and 0x0F'u8)]
    i = i + 1

proc lockPathFor*(live: string; sep: char = '\\'): string =
  ## The path `channel.py`'s `lock_path()` computes for the same live dir, for
  ## one choice of separator. The temp directory itself is used EXACTLY as the
  ## environment gives it -- Python does the same, and Windows treats `/` and
  ## `\` identically when opening, so a differing spelling still names the
  ## same file.
  result = joinPath(lockTempDir(),
                    "aowlspt-inspect-" & sha1Hex12(normLive(live, sep)) &
                    ".lock")

proc lockFileAgeMs(p: string): int64 =
  ## Age of the lock file in ms, or 0 when it cannot be read (which is treated
  ## as "young", i.e. NOT breakable -- guessing old would break a live lock).
  var blob = ""
  if not readShared(p, blob): return 0
  # The holder writes "<pid> <unix-seconds>\n"; parse the timestamp rather than
  # asking the filesystem, so the two sides agree even across a clock/FS quirk.
  var i = 0
  while i < blob.len and blob[i] != ' ': inc i
  inc i
  var secs = ""
  while i < blob.len and blob[i] != '\n' and blob[i] != '\r':
    secs.add blob[i]
    inc i
  var whole = ""
  for c in secs:
    if c == '.': break
    whole.add c
  if whole.len == 0: return 0
  var v = 0'i64
  for c in whole:
    if c < '0' or c > '9': return 0
    v = v * 10'i64 + int64(int(c) - int('0'))
  # nowMs() is FILETIME-based ms; convert to unix seconds the same way.
  let nowUnix = (nowMs() div 1000'i64) - 11644473600'i64
  if nowUnix <= v: return 0
  result = (nowUnix - v) * 1000'i64

proc lockTryCreate(p: string): bool =
  ## CREATE_NEW: succeeds only if the file does not exist. This is the whole
  ## interop: `channel.py` uses O_CREAT|O_EXCL and CLOSES its handle, leaving
  ## the FILE as the lock, so anything that opens with CREATE_ALWAYS would sail
  ## straight through it.
  var wp = p
  let w = newWideCString(wp)
  let h = createFileW(w.toWideCString, GENERIC_WRITE, DWORD(0), nil,
                      CREATE_NEW, FILE_ATTRIBUTE_NORMAL, Handle(0))
  if not heldValid(h):
    return false
  var body = $processId() & " " & $((nowMs() div 1000'i64) - 11644473600'i64) &
             ".0\n"
  discard heldWrite(h, body)
  heldClose(h)
  result = true

type
  LockState* = enum
    lsHeld,        ## we own it and must release it
    lsUnlockable,  ## no lock could be created at all; we proceed unlocked
    lsBusy         ## someone else holds it; the caller must NOT write

proc lockOne(path: string; unlockable: var bool): int =
  ## 1 = taken, 0 = someone holds it, -1 = cannot lock here at all.
  unlockable = false
  if lockTryCreate(path):
    return 1
  if not exists(path):
    # Creation failed and yet nothing is there: we cannot lock in this
    # environment (no temp dir, permissions). Proceed unlocked and SAY SO --
    # refusing to talk to the host would be worse, and an unlocked write is
    # exactly what this file did before the lock existed.
    unlockable = true
    return -1
  if lockFileAgeMs(path) > LockStaleMs:
    discard removeFileAt(path)
    if lockTryCreate(path): return 1
  result = 0

proc lockAcquire*(u: var Ui; pathA, pathB: var string): LockState =
  ## Take BOTH spellings of the lock, ALWAYS IN THE SAME ORDER (A then B), so
  ## two cooperating writers can never take them in opposite orders and wedge.
  ## Holding a superset of the peer's lock is still correct exclusion; holding
  ## a name the peer never looks at is not, which is why both are taken.
  pathA = lockPathFor(u.live, '\\')
  pathB = lockPathFor(u.live, '/')
  if pathB == pathA: pathB = ""
  let deadline = nowMs() + LockWaitMs
  var unl = false
  while true:
    let a = lockOne(pathA, unl)
    if a < 0:
      return lsUnlockable
    if a == 1:
      if pathB.len == 0:
        return lsHeld
      let b = lockOne(pathB, unl)
      if b == 1:
        return lsHeld
      if b < 0:
        # The first was takeable and the second is not lockable at all; keep
        # the one we have rather than dropping to unlocked.
        pathB = ""
        return lsHeld
      # B is held by someone else: drop A so we cannot deadlock against a
      # writer coming the other way, and retry the pair.
      discard removeFileAt(pathA)
    if nowMs() >= deadline:
      return lsBusy
    sleep(DWORD(100))

proc lockRelease*(state: LockState; pathA, pathB: string) =
  if state == lsHeld:
    discard removeFileAt(pathA)
    if pathB.len > 0:
      discard removeFileAt(pathB)

proc runBatchOnce(u: var Ui; cmds: seq[string]; timeoutMs: int; wr: bool;
                  answer: var string): bool =
  ## One batch, keyed to ITS OWN sentinel. The wait is on the sentinel, never
  ## on a duration: a read taken before the host answered shows the PREVIOUS
  ## batch, which looks like a plausible answer to the question just asked.
  answer = ""
  var lines: seq[string] = @[]
  if wr: lines.add "allow write"
  for c in cmds: lines.add c
  inc u.serial
  let ser = int(nowMs() mod 1000000'i64) + u.serial
  # ATTRIBUTED, and unique per call: `aowl-batch-<tag><pid>-<ms>-<n>`, the
  # shape `channel.py` writes. The old form was `aowl-batch-<ser>` with `ser`
  # derived from `nowMs() mod 1000000` -- unattributed AND wrapping every ~17
  # minutes, so two long-lived writers could in principle collide on it.
  var tg = u.tag
  if tg.len == 0: tg = "aowlui"
  let sentinel = "aowl-batch-" & tg & $processId() & "-" & $nowMs() & "-" &
                 $u.serial
  # A byte write with LF endings and NO BOM. PowerShell's utf8 encoder emits
  # one; `writeTextFile` cannot regress that way. The serial is what re-arms
  # the poll, because the host triggers on a CONTENT change.
  var body = "#" & $ser & "\n"
  for l in lines: body.add l & "\n"
  body.add "echo " & sentinel & "\n"
  # THE LOCK SPANS WRITE **AND** POLL, exactly as `channel.py` does. Releasing
  # after the write would not help: the hazard is a second writer replacing our
  # batch while we are waiting for its answer.
  var lockFile = ""
  var lockFileB = ""
  let lock = lockAcquire(u, lockFile, lockFileB)
  if lock == lsBusy:
    u.lastErr = "another process holds the inspector channel lock (" &
                lockFile & ") -- it was NOT taken, so nothing was written. " &
                "This is a CONTENTION refusal, not a host fault and not a " &
                "timeout: two writers to one command file drop each other's " &
                "batches. A lock older than " & $int(LockStaleMs div 1000'i64) &
                "s is broken automatically."
    answer = u.lastErr
    return false
  if lock == lsUnlockable:
    warnLine("  (the channel lock could not be created at all; proceeding " &
             "UNLOCKED, which is what this tool did before the lock existed. " &
             "A concurrent writer can still clobber this batch.)")
  let w = writeTextFile(cmdPath(u), body)
  if not w.ok:
    lockRelease(lock, lockFile, lockFileB)
    answer = "could not write " & cmdPath(u) & " (error " & $w.err & ")"
    return false
  let deadline = nowMs() + int64(timeoutMs)
  while nowMs() < deadline:
    var blob = ""
    if readShared(outPath(u), blob) and blob.contains(sentinel):
      var keep: seq[string] = @[]
      for line in blob.splitLines():
        if not line.contains(sentinel): keep.add line
      answer = joinStr(keep, "\n")
      lockRelease(lock, lockFile, lockFileB)
      return true
    sleep(DWORD(150))
  lockRelease(lock, lockFile, lockFileB)
  answer = "no answer for batch " & sentinel & " within " &
           $(timeoutMs div 1000) & "s. " & diagnose(u)
  result = false

proc releaseChannel*(u: var Ui): bool =
  ## Blank this process's batch out of the command file when it is DONE.
  ##
  ## `runBatchOnce` leaves the last batch it wrote sitting in
  ## `aowlspt-inspect.txt` forever. The host triggers on a CONTENT change, so
  ## nothing re-runs it in THIS session -- but the file is what the next boot's
  ## host reads first, and the launcher's 58-command `allow write` probe batch
  ## is not something a fresh client should be answering before anyone has
  ## asked it anything. It also makes the file useless as a record of who is
  ## driving the channel right now.
  ##
  ## So: replace it with a comment-only body. `#`-prefixed lines are skipped by
  ## the host's parser by design, so this queues NOTHING; it only changes the
  ## content and names the writer that finished.
  ##
  ## Under the SAME lock as a batch, and a busy lock is a REFUSAL, not a
  ## retry-until-clear: another writer holding the channel has its own batch in
  ## that file and clobbering it is exactly the collision the lock exists to
  ## prevent. Returns false, with `lastErr` set, in that case -- the caller
  ## should say so rather than treat it as done.
  var lockFile = ""
  var lockFileB = ""
  let lock = lockAcquire(u, lockFile, lockFileB)
  if lock == lsBusy:
    u.lastErr = "the command file was NOT blanked: another process holds the " &
                "inspector channel lock (" & lockFile & "), and its batch is " &
                "what is in the file. Nothing was overwritten."
    return false
  var tg = u.tag
  if tg.len == 0: tg = "aowlui"
  let body = "# " & tg & $processId() & " released the channel at " &
             $nowMs() & " -- no commands queued\n"
  let w = writeTextFile(cmdPath(u), body)
  lockRelease(lock, lockFile, lockFileB)
  if not w.ok:
    u.lastErr = "could not blank " & cmdPath(u) & " (error " & $w.err & ")"
    return false
  result = true

proc runBatch*(u: var Ui; cmds: seq[string]; wr: bool; timeoutMs: int;
               answer: var string): bool =
  ## `runBatchOnce` with a RETRY, because the host DROPS batches it has read.
  ##
  ## Not a hypothesis: the host log shows `lastRead=1485B lastKnown=1485B
  ## pending=0` -- it consumed a 1.4KB batch -- while warning "no batch queued
  ## for 55s". A retry writes a NEW serial, which is what actually re-arms the
  ## poll. This is a WORKAROUND for a host bug and it is deliberately noisy on
  ## stderr so the bug does not become invisible.
  # `timeoutMs` is the CALL's own suggestion -- `roots` and `tree` are slower
  # than a `children`, so they ask for longer. A timeout the caller named on
  # the command line beats all of them, because a flag that some verbs quietly
  # ignore is worse than no flag: a `--timeout 3` that still blocks for three
  # minutes reads as a hang.
  var t = timeoutMs
  if t <= 0 or u.timeoutPinned: t = u.timeoutMs
  for attempt in 0 ..< 3:
    if runBatchOnce(u, cmds, t, wr, answer): return true
    if attempt < 2:
      warnLine("  (inspector dropped a " & $cmds.len & "-command batch; " &
               "retry " & $(attempt + 1) & "/2)")
  u.lastErr = answer
  result = false

proc batched*(u: var Ui; cmds: seq[string]; wr: bool; per: int; start: int;
              outs: var seq[string]): bool =
  ## Chunks that survive the host's silent batch caps AND its silent MID-BATCH
  ## truncation.
  ##
  ## THE TRUNCATION IS THE DANGEROUS PART (fact #19). A fault caught by the
  ## host's guard unwinds the ENTIRE guarded body, so every command after the
  ## faulting one never runs -- and the output simply stops. To a parser that
  ## reads what came back, a batch cut short at command 12 of 80 is
  ## indistinguishable from 80 commands that all found nothing. That would
  ## make a screen map QUIETLY INCOMPLETE, which is the precise failure this
  ## module exists to prevent.
  ##
  ## So every chunk is RECONCILED against the `> ...` lines the host echoes
  ## for the commands it actually ran, and a short batch is resumed from
  ## exactly where it stopped -- never accepted as a complete answer.
  outs = @[]
  var step = start
  if step <= 0: step = MaxCmds
  var i = 0
  while i < cmds.len:
    var n = cmds.len - i
    if step < n: n = step
    n = n - (n mod per)
    if n < per: n = per
    var chunk: seq[string] = @[]
    var k = i
    while k < cmds.len and k < i + n:
      chunk.add cmds[k]
      inc k
    var answer = ""
    if not runBatch(u, chunk, wr, 0, answer):
      if n <= per:
        u.lastErr = "the host dropped even a minimal " & $n &
          "-command batch. Not a size problem -- check the client is alive " &
          "and the liveInspector flag is on. First command: " & cmds[i] &
          "\n" & answer
        return false
      step = n div 2
      if step < per: step = per
      continue
    var ran = 0
    for line in answer.splitLines():
      if line.strip().startsWith("> "): inc ran
    if wr and ran > 0: dec ran     # `allow write` is echoed too
    outs.add answer
    if ran >= n:
      i = i + n
      continue
    if ran <= 0:
      warnLine("  !! the host echoed NONE of a " & $n & "-command batch -- " &
               "its output cannot be reconciled, so those nodes are being " &
               "reported as UNANSWERED, not as empty.")
      i = i + n
      continue
    warnLine("  !! batch TRUNCATED: sent " & $n & " commands, the host ran " &
             $ran & ". A caught fault unwinds the whole guarded body (fact " &
             "#19), so the rest never ran. Resuming at command " & $(i + ran) &
             " in smaller pieces -- NOT treating the missing answers as empty.")
    var adv = (ran div per) * per
    if adv < per: adv = per
    i = i + adv
    step = 8 * per
    if step > n: step = n
  result = true

# ---------------------------------------------------------------------------
# structure primitives
# ---------------------------------------------------------------------------

type
  Node* = object
    t*, go*, name*: string
    path*: seq[string]
    depth*: int
    active*: Tri
  Walk* = object
    nodes*: seq[Node]
    ## False when the walk hit its budget. A False here is NOT proof that a
    ## name or a label is absent, and no caller may report absence from one.
    complete*: bool
  Hit* = object
    t*, text*, name*: string
    path*: seq[string]

proc parseRoots*(answer: string; into: var seq[Node]): bool =
  into = @[]
  for line in answer.splitLines():
    if not line.contains("[$r"): continue
    let t = hexAfter(line, "transform=")
    let g = hexAfter(line, "go=")
    if t.len == 0 or g.len == 0: continue
    var nm = ""
    discard quotedAfter(line, "name=", nm)
    into.add Node(t: t, go: g, name: nm, path: @[nm], depth: 0,
                  active: triUnknown)
  result = into.len > 0

proc roots*(u: var Ui; into: var seq[Node]): bool =
  ## Every scene root. `roots` is the only way in: the live UI is in
  ## DontDestroyOnLoad, which SceneManager does not enumerate, so every listed
  ## scene truthfully reports rootCount=0 and a `find` without a root reaches
  ## nothing.
  var answer = ""
  if not runBatch(u, @["roots"], false, 60000, answer):
    u.lastErr = answer
    return false
  if not parseRoots(answer, into):
    u.lastErr = "`roots` returned no scene roots. The host answered:\n" & answer
    return false
  result = true

proc rootIndex*(rs: seq[Node]; name: string): int =
  result = -1
  for i in 0 ..< rs.len:
    if rs[i].name == name: return i

proc rootNames*(rs: seq[Node]): string =
  var ns: seq[string] = @[]
  for r in rs: ns.add r.name
  result = joinStr(ns, ", ")

proc parseChildren*(answer: string; parentPath: seq[string];
                    into: var seq[Node]) =
  for line in answer.splitLines():
    if not line.contains("($c"): continue
    let t = hexAfter(line, "transform=")
    let g = hexAfter(line, "go=")
    if t.len == 0 or g.len == 0: continue
    var nm = ""
    discard quotedAfter(line, "name=", nm)
    var p: seq[string] = @[]
    for s in parentPath: p.add s
    p.add nm
    into.add Node(t: t, go: g, name: nm, path: p, depth: p.len - 1,
                  active: triUnknown)

proc children*(u: var Ui; ptrExpr: string; into: var seq[Node]): bool =
  ## The GameObject is READ OUT, never computed. It is usually transform-0x20
  ## and sometimes is not (three of the 28 menu screens differ), so computing
  ## it would be right 90% of the time -- the worst possible failure rate for
  ## a pointer.
  var answer = ""
  if not runBatch(u, @["children " & ptrExpr], false, 40000, answer):
    u.lastErr = answer
    return false
  into = @[]
  parseChildren(answer, @[], into)
  result = true

proc parseTree*(answer: string; into: var seq[Node]): bool =
  ## `tree` prints "(N child)" only for nodes that HAVE children, so a parser
  ## that requires it silently drops every leaf -- which is to say, every
  ## label. That bug made a 128-node subtree parse as 68 nodes and read as a
  ## complete answer.
  into = @[]
  var stackIndent: seq[int] = @[]
  var stackName: seq[string] = @[]
  for raw in answer.splitLines():
    let line = raw.strip(leading = false)
    if line.len == 0: continue
    var j = 0
    while j < line.len and line[j] == ' ': inc j
    let indent = j
    if j < line.len and line[j] == '+':
      inc j
      while j < line.len and line[j] == ' ': inc j
    if j >= line.len or line[j] != '"': continue
    inc j
    var nm = ""
    while j < line.len and line[j] != '"':
      nm.add line[j]
      inc j
    if j >= line.len: continue
    let rest = line.substr(j + 1, line.len - 1)
    let ptrTok = firstHex(rest)
    if ptrTok.len == 0: continue
    while stackIndent.len > 0 and stackIndent[stackIndent.len - 1] >= indent:
      discard stackIndent.pop()
      discard stackName.pop()
    var path: seq[string] = @[]
    for s in stackName: path.add s
    path.add nm
    stackIndent.add indent
    stackName.add nm
    into.add Node(t: ptrTok, go: "", name: nm, path: path,
                  depth: path.len - 1, active: triUnknown)
  result = into.len > 0

proc tree*(u: var Ui; ptrExpr: string; depth: int; w: var Walk): bool =
  var answer = ""
  if not runBatch(u, @["tree " & ptrExpr & " " & $depth], false, 90000, answer):
    u.lastErr = answer
    return false
  w = Walk(nodes: @[], complete: false)
  var ns: seq[Node] = @[]
  if not parseTree(answer, ns):
    u.lastErr = "`tree " & ptrExpr & "` produced no nodes. Host said:\n" & answer
    return false
  w.nodes = ns
  # "complete." vs "STOPPED EARLY on a cap" -- the host says which, and the
  # difference is the whole point. `tree` stops at 128 LINES despite
  # advertising "max 3000 nodes", so this goes False often.
  w.complete = answer.contains("complete.") and
               not answer.contains("STOPPED EARLY")
  result = true

proc actives*(u: var Ui; gos: seq[string]; into: var seq[Tri]): bool =
  ## activeInHierarchy for MANY GameObjects. Each answer is tied to an
  ## `echo UIQ<n>` MARKER rather than to output order, so a call that faults
  ## mid-batch cannot shift every subsequent result onto the wrong object.
  ## triUnknown means "no answer for this one" and is never rounded to triNo.
  into = @[]
  for i in 0 ..< gos.len: into.add triUnknown
  if gos.len == 0: return true
  var cmds: seq[string] = @[]
  for i in 0 ..< gos.len:
    cmds.add "echo UIQ" & $i
    cmds.add "call name:get_activeInHierarchy i_p " & gos[i]
  var outs: seq[string] = @[]
  if not batched(u, cmds, true, 2, 60, outs): return false
  for chunk in outs:
    var cur = -1
    for line in chunk.splitLines():
      let s = line.strip()
      if s.startsWith("UIQ") and s.len > 3:
        var num = ""
        var k = 3
        while k < s.len and s[k] >= '0' and s[k] <= '9':
          num.add s[k]
          inc k
        if k == s.len and num.len > 0:
          cur = parseNat(num)
          continue
      if cur < 0: continue
      if line.find("-> i32 ") >= 0:
        let v = wordAfter(line, "-> i32 ")
        if v.len > 0 and cur < into.len:
          if v == "0": into[cur] = triNo
          else: into[cur] = triYes
        cur = -1
  result = true

proc walk*(u: var Ui; ptrExpr, rootName: string; budget: int;
           visibleOnly: bool; w: var Walk): bool =
  ## FULL subtree enumeration by BFS over `children`.
  ##
  ## This exists because `tree` cannot do it: `tree` advertises "max 3000
  ## nodes" and then stops after 128 PRINTED LINES, so on any real screen it
  ## truncates, and a caller that trusted it would conclude a label is absent
  ## when the walk merely stopped. Measured: Common UI at depth 4 prints
  ## "128 node(s) printed -- STOPPED EARLY on a cap".
  ##
  ## Each block is attributed to the parent the HOST echoed on its own
  ## `> children 0x...` line, so a fault mid-batch cannot reparent the nodes
  ## that follow it.
  w = Walk(nodes: @[], complete: true)
  var idx = initPtrMap(budget)
  w.nodes.add Node(t: ptrExpr, go: "", name: rootName, path: @[rootName],
                   depth: 0, active: triUnknown)
  mput(idx, ptrExpr, 0)
  var frontier: seq[string] = @[ptrExpr]
  while frontier.len > 0:
    if w.nodes.len >= budget:
      w.complete = false
      break
    var cmds: seq[string] = @[]
    for p in frontier: cmds.add "children " & p
    var outs: seq[string] = @[]
    if not batched(u, cmds, false, 1, 40, outs): return false
    var nxt: seq[string] = @[]
    for chunk in outs:
      var cur = -1
      for line in chunk.splitLines():
        let s = line.strip()
        if s.startsWith("> children "):
          let p = hexAfter(s, "> children ")
          if p.len > 0: cur = mget(idx, p)
          else: cur = -1
          continue
        if cur < 0: continue
        if not line.contains("($c"): continue
        let t = hexAfter(line, "transform=")
        let g = hexAfter(line, "go=")
        if t.len == 0 or g.len == 0: continue
        if mget(idx, t) >= 0: continue
        var nm = ""
        discard quotedAfter(line, "name=", nm)
        var path: seq[string] = @[]
        for s2 in w.nodes[cur].path: path.add s2
        path.add nm
        mput(idx, t, w.nodes.len)
        w.nodes.add Node(t: t, go: g, name: nm, path: path,
                         depth: path.len - 1, active: triUnknown)
        nxt.add t
    if visibleOnly and nxt.len > 0:
      # An INACTIVE node hides its whole subtree, so not descending into one
      # is both a big pruning win and the correct meaning of "what is on
      # screen". activeInHierarchy is asked of the GAMEOBJECT: asking a
      # Transform does not fail -- `call` does not type-check pointer
      # arguments -- it returns a number read off the wrong object.
      var gos: seq[string] = @[]
      for p in nxt: gos.add w.nodes[mget(idx, p)].go
      var st: seq[Tri] = @[]
      if not actives(u, gos, st): return false
      var keep: seq[string] = @[]
      for i in 0 ..< nxt.len:
        let ni = mget(idx, nxt[i])
        w.nodes[ni].active = st[i]
        if st[i] == triYes: keep.add nxt[i]
        elif st[i] == triUnknown:
          # Could not tell. Do not descend, but say so on the node rather
          # than silently pruning it -- and the walk is no longer complete.
          warnLine("  (could not read activeInHierarchy for " &
                   w.nodes[ni].name & " -- that branch was NOT walked, which " &
                   "is not the same as it being empty)")
          w.complete = false
      nxt = keep
    frontier = nxt
  result = true

# ---------------------------------------------------------------------------
# THE VERB THE INSPECTOR DOES NOT HAVE: read what a node DISPLAYS
# ---------------------------------------------------------------------------

proc labelsOf*(u: var Ui; ptrs: seq[string]; texts: var seq[string]): bool =
  ## The DISPLAYED text of many transforms, parallel to `ptrs` ("" = none).
  ##
  ## `label` on a TRANSFORM reports `text = ""`. That is not an answer, it is
  ## the wrong object -- so this ALWAYS goes through the component, and a
  ## lookup that returned NULL is never read. Results are keyed off the
  ## pointer the HOST echoed on its own `> component 0x...` line, not off a
  ## loop index, so a value cannot drift onto the wrong node even if a lookup
  ## faults mid-batch -- which is how an earlier session got a complete and
  ## entirely fictional field map.
  texts = @[]
  for i in 0 ..< ptrs.len: texts.add ""
  if ptrs.len == 0: return true
  var idx = initPtrMap(ptrs.len)
  for i in 0 ..< ptrs.len: mput(idx, ptrs[i], i)
  for ci in 0 ..< TextComponents.len:
    let comp = TextComponents[ci]
    var todo: seq[string] = @[]
    for i in 0 ..< ptrs.len:
      if texts[i].len == 0: todo.add ptrs[i]
    if todo.len == 0: break
    var cmds: seq[string] = @[]
    for p in todo:
      cmds.add "component " & p & " " & comp
      cmds.add "label $comp"
    var outs: seq[string] = @[]
    if not batched(u, cmds, true, 2, 80, outs): return false
    for chunk in outs:
      var cur = -1
      for line in chunk.splitLines():
        let s = line.strip()
        if s.startsWith("> component "):
          let p = hexAfter(s, "> component ")
          if p.len > 0: cur = mget(idx, p)
          else: cur = -1
          continue
        if cur < 0: continue
        if line.contains("returned NULL") or line.contains("not readable"):
          cur = -1
          continue
        if line.contains("FAULTED"):
          inc u.faults
          warnLine("  (a `component`/`label` FAULTED -- that burns one of " &
                   "the inspector's 8 faults for the session; " & $u.faults &
                   " seen so far by this run)")
          cur = -1
          continue
        var txt = ""
        if quotedAfter(line, "text = ", txt):
          if txt.strip().len > 0 and cur < texts.len: texts[cur] = txt
          cur = -1
  result = true

proc findText*(u: var Ui; text, rootName: string; exact: bool; budget: int;
               visibleOnly: bool; subtree: string; hits: var seq[Hit];
               complete: var bool): bool =
  ## Find every control whose DISPLAYED text matches.
  ##
  ## `complete` is false when the walk hit its budget -- in which case an
  ## EMPTY hit list is NOT evidence that the text is absent, and any caller
  ## that reports "not found" must say so.
  hits = @[]
  complete = false
  var start = subtree
  if start.len == 0:
    var rs: seq[Node] = @[]
    if not roots(u, rs): return false
    let ri = rootIndex(rs, rootName)
    if ri < 0:
      u.lastErr = "no scene root named '" & rootName & "'. Present: " &
                  rootNames(rs)
      return false
    start = rs[ri].t
  var w = default(Walk)
  if not walk(u, start, rootName, budget, visibleOnly, w): return false
  complete = w.complete
  var ptrs: seq[string] = @[]
  for n in w.nodes: ptrs.add n.t
  var texts: seq[string] = @[]
  if not labelsOf(u, ptrs, texts): return false
  let want = text.strip().toLowerAscii()
  for i in 0 ..< w.nodes.len:
    if texts[i].len == 0: continue
    let got = texts[i].strip().toLowerAscii()
    var isHit = false
    if exact: isHit = got == want
    else: isHit = got.contains(want)
    if isHit:
      hits.add Hit(t: w.nodes[i].t, text: texts[i], name: w.nodes[i].name,
                   path: w.nodes[i].path)
  result = true

proc completenessNote*(complete: bool): string =
  if complete: result = "COMPLETE"
  else: result = "TRUNCATED (absence proves nothing)"

# ---------------------------------------------------------------------------
# screens
# ---------------------------------------------------------------------------

type
  Screen* = object
    name*, t*, go*: string
    active*: Tri
  ScreenSet* = object
    screens*: seq[Screen]
    ## PORT FIX (bug 1): `ui.py`'s `screen()` assumed a `Menu UI` scene root
    ## exists and failed outright in a raid. The absence of the root is not an
    ## error -- it is the single most reliable IN-RAID signal we have, better
    ## than the RegisterPlayer count -- so it is reported as data.
    rootPresent*: bool

proc screens*(u: var Ui; rootName: string; s: var ScreenSet;
              probeActive = true): bool =
  ## `probeActive = false` is the READ-ONLY form: roots + children only, with
  ## every `active` left `triUnknown`.
  ##
  ## Why it exists: `activeInHierarchy` is only obtainable through
  ## `call name:get_activeInHierarchy`, and the host gates EVERY `call` behind
  ## `allow write` (inspect.nim: "the whole point is that reads are read-only,
  ## and `call` is therefore gated by the same `allow write`"). So the ordinary
  ## form of this proc writes a batch that arms writes and then calls into game
  ## code once per child -- 29 calls on this build's `Menu UI`. That is a fine
  ## price to confirm a screen is up; it is NOT a fine price to pay every three
  ## seconds for a minute while waiting for the screen to EXIST.
  ##
  ## `triUnknown` is returned rather than `triNo` deliberately: a caller that
  ## reads "not active" off a probe that never asked is the confidently-wrong
  ## answer this whole module is written against.
  s = ScreenSet(screens: @[], rootPresent: false)
  var rs: seq[Node] = @[]
  if not roots(u, rs): return false
  let ri = rootIndex(rs, rootName)
  if ri < 0:
    # Not a failure. Present roots are recorded so the caller can say what it
    # actually saw.
    u.lastErr = "no scene root named '" & rootName & "'. Present: " &
                rootNames(rs)
    return true
  s.rootPresent = true
  var kids: seq[Node] = @[]
  if not children(u, rs[ri].t, kids): return false
  if kids.len == 1 and kids[0].name == "UI":
    var deeper: seq[Node] = @[]
    if not children(u, kids[0].t, deeper): return false
    kids = deeper
  var gos: seq[string] = @[]
  for k in kids: gos.add k.go
  var st: seq[Tri] = @[]
  if probeActive:
    if not actives(u, gos, st): return false
  else:
    for i in 0 ..< kids.len: st.add triUnknown
  for i in 0 ..< kids.len:
    s.screens.add Screen(name: kids[i].name, t: kids[i].t, go: kids[i].go,
                         active: st[i])
  result = true

proc activeScreens*(s: ScreenSet): seq[string] =
  ## Plural on purpose: this build routinely has an overlay active over a base
  ## screen, and returning "the" screen would be a confidently wrong answer.
  result = @[]
  for sc in s.screens:
    if sc.active == triYes: result.add sc.name

proc dumpScreen*(u: var Ui; name, rootName: string; visibleOnly: bool;
                 rows: var seq[Hit]; complete: var bool): bool =
  rows = @[]
  complete = false
  var ss = default(ScreenSet)
  if not screens(u, rootName, ss): return false
  if not ss.rootPresent:
    u.lastErr = "there is no scene root named '" & rootName & "' right now. " &
      "If that root is 'Menu UI', the menu is not loaded -- which on this " &
      "build means a raid is in progress. Nothing was dumped."
    return false
  var ti = -1
  if name.len == 0:
    for i in 0 ..< ss.screens.len:
      if ss.screens[i].active == triYes: ti = i
    if ti < 0:
      u.lastErr = "no active screen under '" & rootName & "' -- nothing to " &
                  "dump. Screens present: " & $ss.screens.len
      return false
  else:
    for i in 0 ..< ss.screens.len:
      if ss.screens[i].name == name: ti = i
    if ti < 0:
      var ns: seq[string] = @[]
      for sc in ss.screens: ns.add sc.name
      u.lastErr = "no screen named '" & name & "'. Present: " &
                  joinStr(ns, ", ")
      return false
  var w = default(Walk)
  if not walk(u, ss.screens[ti].t, ss.screens[ti].name, 4000, visibleOnly, w):
    return false
  complete = w.complete
  var ptrs: seq[string] = @[]
  for n in w.nodes: ptrs.add n.t
  var texts: seq[string] = @[]
  if not labelsOf(u, ptrs, texts): return false
  for i in 0 ..< w.nodes.len:
    if texts[i].len > 0:
      rows.add Hit(t: w.nodes[i].t, text: texts[i], name: w.nodes[i].name,
                   path: w.nodes[i].path)
  result = true

# ---------------------------------------------------------------------------
# acting
# ---------------------------------------------------------------------------

type
  Anc* = object
    t*, go*, name*: string
    activeSelf*: bool
  Button* = object
    at*, kind*, name*: string
    chain*: seq[string]
    found*: bool

proc ancestors*(u: var Ui; ptrExpr: string; up: int;
                into: var seq[Anc]): bool =
  into = @[]
  var answer = ""
  if not runBatch(u, @["parent " & ptrExpr & " " & $up], false, 40000, answer):
    u.lastErr = answer
    return false
  for line in answer.splitLines():
    if not line.contains("activeSelf="): continue
    let t = hexAfter(line, "transform=")
    let g = hexAfter(line, "go=")
    if t.len == 0: continue
    var nm = ""
    discard quotedAfter(line, "name=", nm)
    into.add Anc(t: t, go: g, name: nm,
                 activeSelf: wordAfter(line, "activeSelf=") == "true")
  result = true

proc buttonFor*(u: var Ui; ptrExpr: string; up: int; b: var Button): bool =
  ## The pressable component at or above <ptr>.
  ##
  ## A label is a CHILD of its button far more often than it is the button --
  ## the main-menu PLAY control is `PlayButton` and the text lives two levels
  ## down on `PlayButton/SizeLabel/Label` -- so this walks the parent chain.
  ## DefaultUIButton is tried first because that is what EFT actually uses:
  ## GetComponent("Button") returns NULL on one.
  b = Button(at: "", kind: "", name: "", chain: @[], found: false)
  var chain: seq[Anc] = @[]
  if not ancestors(u, ptrExpr, up, chain): return false
  var names: seq[string] = @[]
  for a in chain: names.add a.name
  for node in chain:
    for ci in 0 ..< ButtonComponents.len:
      let ctype = ButtonComponents[ci]
      var answer = ""
      if not runBatch(u, @["component " & node.t & " " & ctype], true, 40000,
                      answer):
        return false
      # NULL is an ANSWER ("no such component here"); FAULTED is not, and it
      # costs one of the eight faults the inspector allows itself before it
      # switches off for the session. Both are skipped; only NULL is
      # unremarkable.
      if answer.contains("GetComponent returned NULL"): continue
      if answer.contains("FAULTED"):
        inc u.faults
        warnLine("  (component " & ctype & " on " & node.name &
                 " FAULTED -- that burns one of the inspector's 8 faults; " &
                 $u.faults & " seen so far by this run)")
        continue
      b = Button(at: node.t, kind: ctype, name: node.name, chain: names,
                 found: true)
      return true
  result = true    # searched successfully; found nothing

proc actuate*(u: var Ui; ptrExpr, ctype: string; answer: var string): bool =
  ## Actuate a control the way its OWN type is actuated.
  ##
  ## "returned without faulting" is NOT success -- it only means the handler
  ## did not crash. Every caller must still verify an EFFECT.
  var cmds: seq[string] = @[]
  if ctype == "AnimatedToggle":
    # A Unity Toggle whose m_IsOn is at the same offset DefaultUIButton keeps
    # its UnityEvent at, so `press` here would invoke a BOOL as an event.
    cmds = @["component " & ptrExpr & " " & ctype,
             "call rva:" & ToggleSetIsOnRva & " v_pb $comp 1",
             "wait 300"]
  elif ctype == "Button":
    cmds = @["component " & ptrExpr & " " & ctype, "click $comp", "wait 300"]
  else:
    cmds = @["component " & ptrExpr & " " & ctype, "press $comp", "wait 300"]
  if not runBatch(u, cmds, true, 60000, answer): return false
  result = answer.contains("returned without faulting") and
           not answer.contains("FAULTED")

type
  ExpectKind* = enum
    xkNone,        ## no predicate -- the result is UNVERIFIED and says so
    xkScreen,      ## a named screen under `root` becomes active
    xkNoScreen,    ## a named screen under `root` stops being active
    xkNoRoot       ## a named scene root disappears (Menu UI -> in raid)
  Expect* = object
    kind*: ExpectKind
    name*: string
    root*: string

proc noExpect*(): Expect =
  result = Expect(kind: xkNone, name: "", root: "")

proc expectMet*(u: var Ui; e: Expect): bool =
  case e.kind
  of xkNone: result = true
  of xkNoRoot:
    var rs: seq[Node] = @[]
    if not roots(u, rs): return false
    result = rootIndex(rs, e.name) < 0
  of xkScreen, xkNoScreen:
    var ss = default(ScreenSet)
    if not screens(u, e.root, ss): return false
    if not ss.rootPresent:
      # The root is gone. For xkNoScreen that IS the screen being gone; for
      # xkScreen it can never become true, and saying so beats spinning.
      return e.kind == xkNoScreen
    var isActive = false
    for sc in ss.screens:
      if sc.name == e.name and sc.active == triYes: isActive = true
    if e.kind == xkScreen: result = isActive
    else: result = not isActive

proc waitUntil*(u: var Ui; e: Expect; timeoutMs: int; pollMs = 1000): bool =
  ## Poll OBSERVED state. Never sleeps a fixed duration and hopes, which is
  ## the habit this repo keeps paying for.
  if e.kind == xkNone: return true
  let deadline = nowMs() + int64(timeoutMs)
  while true:
    if expectMet(u, e): return true
    if nowMs() >= deadline: return false
    sleep(DWORD(pollMs))

type
  ClickResult* = object
    ok*: bool
    msg*: string

proc clickText*(u: var Ui; text, rootName: string; exact: bool;
                subtree: string; e: Expect; settleMs: int;
                visibleOnly: bool): ClickResult =
  ## Find a control by its DISPLAYED text, actuate it, and verify an effect.
  var hits: seq[Hit] = @[]
  var complete = false
  if not findText(u, text, rootName, exact, 4000, visibleOnly, subtree, hits,
                  complete):
    return ClickResult(ok: false, msg: u.lastErr)
  if hits.len == 0:
    var why = ""
    if complete:
      why = "The tree walk was COMPLETE, so this IS evidence of absence."
    else:
      why = "The tree walk was TRUNCATED, so this is NOT evidence of " &
            "absence -- raise the budget or search a narrower subtree."
    return ClickResult(ok: false, msg:
      "no control DISPLAYS '" & text & "' under '" & rootName & "'. " & why)
  # PREFER AN EXACT MATCH when a substring search turned up several.
  if hits.len > 1 and not exact:
    var ex: seq[Hit] = @[]
    let want = text.strip().toLowerAscii()
    for h in hits:
      if h.text.strip().toLowerAscii() == want: ex.add h
    if ex.len > 0: hits = ex
  # SEVERAL NODES CAN DISPLAY THE SAME TEXT and only some are controls. On the
  # location screen "Factory" is on the map toggle AND on the info panel's
  # Location Name; on every screen a button's label is duplicated by its
  # parent SizeLabel. Taking the first hit picked the info panel and reported
  # "nothing pressable", which reads as "you cannot press Factory" and is
  # simply wrong. So: take the first candidate that actually resolves.
  var btn = Button(at: "", kind: "", name: "", chain: @[], found: false)
  var chosen = -1
  var rejected = 0
  for i in 0 ..< hits.len:
    var b = default(Button)
    if not buttonFor(u, hits[i].t, 5, b):
      return ClickResult(ok: false, msg: u.lastErr)
    if b.found:
      btn = b
      chosen = i
      break
    inc rejected
  if chosen < 0:
    var considered: seq[string] = @[]
    var i = 0
    while i < hits.len and i < 6:
      considered.add tailPath(hits[i].path, 3)
      inc i
    var kinds: seq[string] = @[]
    for k in 0 ..< ButtonComponents.len: kinds.add ButtonComponents[k]
    return ClickResult(ok: false, msg:
      $hits.len & " node(s) display '" & text & "' but NONE has a pressable " &
      "component on it or its 5 nearest ancestors (tried " &
      joinStr(kinds, ", ") & "). Nothing was pressed. Considered: " &
      joinStr(considered, "; "))
  var extra = ""
  if hits.len > 1:
    extra = "  (" & $hits.len & " node(s) displayed that text; actuated " &
            tailPath(hits[chosen].path, 2) & " via " & btn.name
    if rejected > 0:
      extra.add ", skipped " & $rejected & " unpressable label(s)"
    extra.add ")"
  var answer = ""
  if not actuate(u, btn.at, btn.kind, answer):
    var tail = answer
    if tail.len > 600: tail = tail.substr(tail.len - 600, tail.len - 1)
    return ClickResult(ok: false, msg:
      "actuated " & btn.kind & " on " & btn.at &
      " and the call did not return cleanly:\n" & tail)
  if e.kind == xkNone:
    return ClickResult(ok: true, msg:
      "pressed '" & hits[chosen].text & "' via " & btn.kind & " on " & btn.at &
      extra & " -- UNVERIFIED: no 'expect' predicate was given, so this " &
      "proves only that the handler did not fault.")
  if waitUntil(u, e, settleMs):
    return ClickResult(ok: true, msg:
      "pressed '" & hits[chosen].text & "' via " & btn.kind &
      " and VERIFIED the expected effect." & extra)
  result = ClickResult(ok: false, msg:
    "pressed '" & hits[chosen].text & "' via " & btn.kind & " on " & btn.at &
    " -- the handler ran without faulting but the expected effect did NOT " &
    "appear within " & $(settleMs div 1000) & "s. This is the false-positive " &
    "shape: treat it as a failure." & extra)

# ---------------------------------------------------------------------------
# raid state
# ---------------------------------------------------------------------------

type
  RegCount* = object
    ## PORT FIX (bug 2): `ui.py` returned None where 0 was meant. "No events"
    ## and "cannot tell" are different answers and are now different fields.
    known*: bool
    count*: int
    why*: string

proc registerPlayerCount*(u: var Ui): RegCount =
  ## How many times EFT.GameWorld::RegisterPlayer has fired this session.
  ##
  ## PORT FIX (bug 3): this is NOT a valid in-raid predicate and nothing here
  ## uses it as one. Measured: it fires when the SERVER starts, well before
  ## the player is in-raid (5 events at server start, 22 by the time the
  ## player was actually in). It is a TRANSITION hint at best, and it is
  ## cumulative for the whole host session so it never decreases.
  var blob = ""
  if not readShared(logPath(u), blob):
    return RegCount(known: false, count: 0,
                    why: "the host log could not be read")
  var last = -1
  for line in blob.splitLines():
    if line.find("botdiag: RegisterPlayer #") < 0: continue
    let n = wordAfter(line, "botdiag: RegisterPlayer #")
    var digits = ""
    for c in n:
      if c >= '0' and c <= '9': digits.add c
      else: break
    if digits.len > 0: last = parseNat(digits)
  if last >= 0:
    return RegCount(known: true, count: last, why: "")
  if blob.contains("botdiag:"):
    # botDiag is on and the line has genuinely never appeared: a real zero.
    return RegCount(known: true, count: 0, why: "")
  result = RegCount(known: false, count: 0, why:
    "the `botDiag` host flag is off, so the RegisterPlayer line is never " &
    "emitted -- a 0 here would be a lie")

proc inRaid*(u: var Ui; menuRoot: string): Tri =
  ## triYes / triNo / triUnknown -- and triUnknown is a REAL, reportable
  ## answer.
  ##
  ## Built only from POSITIVELY-OBSERVED signals:
  ##  * `Game Scene` being an ACTIVE scene root is positive evidence of a raid.
  ##  * the menu root being ABSENT ENTIRELY is positive evidence of a raid --
  ##    this build unloads it (PORT FIX, bug 1: `ui.py` treated that as an
  ##    error and could not answer at all).
  ##  * the menu root present and active, with `Game Scene` absent or
  ##    inactive, is positive evidence of the menu.
  ##
  ## What this deliberately does NOT use: the inspector's `in-raid anchor
  ## slot` (reads -1 while a human is demonstrably inside a raid, fact #51 --
  ## it binds by name and by-name resolution is dead, fact #35), and the
  ## cumulative RegisterPlayer counter (fires at SERVER start, and never
  ## decreases when a raid ends).
  var rs: seq[Node] = @[]
  if not roots(u, rs): return triUnknown
  let gi = rootIndex(rs, "Game Scene")
  let mi = rootIndex(rs, menuRoot)
  var gos: seq[string] = @[]
  if gi >= 0: gos.add rs[gi].go
  if mi >= 0: gos.add rs[mi].go
  var st: seq[Tri] = @[]
  if gos.len > 0:
    if not actives(u, gos, st): return triUnknown
  var gameScene = triUnknown
  var menu = triUnknown
  var k = 0
  if gi >= 0:
    gameScene = st[k]
    inc k
  if mi >= 0:
    menu = st[k]
  if gameScene == triYes: return triYes
  if mi < 0: return triYes          # the menu root is not even loaded
  if menu == triYes and gameScene != triYes: return triNo
  result = triUnknown

# ---------------------------------------------------------------------------
# the path cache
#
# A plain two-column text file rather than JSON: it is read by people as often
# as by programs, and it must never be the reason a run fails to parse.
# ---------------------------------------------------------------------------

type
  CacheEntry* = object
    key*: string
    path*: seq[string]
  Cache* = object
    scope*: string
    entries*: seq[CacheEntry]
    wasStale*: bool

proc scopeKey*(u: Ui): string =
  ## A key that CHANGES when the game build changes. A cached UI path that
  ## silently points at the wrong node is worse than no cache at all, so a
  ## mismatch discards the WHOLE file rather than trusting one entry of it.
  ##
  ## (`ui.py` used size+mtime; winfs exposes size, so this is size only. A
  ## Tarkov update that left both files byte-identical in length would slip
  ## through -- stated rather than glossed.)
  let base = parentOf(u.live)
  var parts: seq[string] = @[]
  let a = joinPath(base, "GameAssembly.dll")
  let b = joinPath(base, "EscapeFromTarkov_Data\\il2cpp_data\\Metadata\\" &
                   "global-metadata.dat")
  for p in @[a, b]:
    if exists(p): parts.add baseName(p) & ":" & $fileSizeOf(p)
    else: parts.add baseName(p) & ":absent"
  result = joinStr(parts, "|")

proc cachePath*(repo: string): string =
  result = joinPath(repo, "tools\\uimap.txt")

proc loadCache*(u: Ui; repo: string): Cache =
  result = Cache(scope: scopeKey(u), entries: @[], wasStale: false)
  var blob = ""
  if not readTextFile(cachePath(repo), blob): return
  var fileScope = ""
  var ents: seq[CacheEntry] = @[]
  for line in blob.splitLines():
    if line.startsWith("scope\t"):
      fileScope = line.substr(6, line.len - 1)
    elif line.startsWith("path\t"):
      let rest = line.substr(5, line.len - 1)
      let tab = rest.find('\t')
      if tab > 0:
        ents.add CacheEntry(key: rest.substr(0, tab - 1),
                            path: rest.substr(tab + 1, rest.len - 1).split('/'))
  if fileScope != result.scope:
    # The build moved. Do not salvage individual entries -- a path that
    # resolves but points somewhere else is exactly the failure this file
    # exists to prevent.
    result.wasStale = fileScope.len > 0
    return
  result.entries = ents

proc saveCache*(u: Ui; repo: string; c: Cache): bool =
  var body = "scope\t" & scopeKey(u) & "\n"
  for e in c.entries:
    body.add "path\t" & e.key & "\t" & joinStr(e.path, "/") & "\n"
  result = writeTextFile(cachePath(repo), body).ok

proc cachePut*(u: Ui; repo, key: string; path: seq[string]): bool =
  var c = loadCache(u, repo)
  var replaced = false
  for i in 0 ..< c.entries.len:
    if c.entries[i].key == key:
      c.entries[i].path = path
      replaced = true
  if not replaced: c.entries.add CacheEntry(key: key, path: path)
  result = saveCache(u, repo, c)

proc resolvePath*(u: var Ui; path: seq[string]; hit: var Node): bool =
  ## Walk a path of NAMES from a scene root to a live pointer, VERIFYING every
  ## hop. Pointers do not survive a restart, so the cache stores names; a name
  ## that no longer exists at that level means the entry is stale, which fails
  ## so the caller re-derives. It never falls back to something similar.
  if path.len == 0: return false
  var rs: seq[Node] = @[]
  if not roots(u, rs): return false
  let ri = rootIndex(rs, path[0])
  if ri < 0: return false
  hit = rs[ri]
  for i in 1 ..< path.len:
    var kids: seq[Node] = @[]
    if not children(u, hit.t, kids): return false
    var matches: seq[Node] = @[]
    for k in kids:
      if k.name == path[i]: matches.add k
    if matches.len != 1: return false   # absent, or ambiguous -- both stale
    hit = matches[0]
  result = true

proc cachedPath*(u: var Ui; repo, key: string; hit: var Node;
                 how: var string): bool =
  let c = loadCache(u, repo)
  if c.wasStale:
    warnLine("  (the UI path cache was written against a different game " &
             "build and was DISCARDED WHOLE, not entry by entry.)")
  for e in c.entries:
    if e.key == key:
      if resolvePath(u, e.path, hit):
        how = "cache"
        return true
      # Say it out loud. A silently-dropped cache entry is how a tool starts
      # lying about how fast it is.
      warnLine("cache MISS (stale): " & key & " -> " & joinStr(e.path, "/") &
               " no longer resolves.")
      how = "stale"
      return false
  how = "absent"
  result = false
