## ar/showbus.nim -- THE SCREEN-ARRIVAL ORACLE.
##
## EVERY SCREEN THIS MOD ACTS ON COMES FROM THE GAME, NOT FROM A SEARCH.
##
## That is the single most expensive lesson in the host's `autoraid.nim`, and it
## was learned three times in one session. Each time the symptom was a 45-second
## step timeout whose own census already showed the screen on screen; each time
## the cause was the same: hunting a `NextButton` across the scene roots for a
## screen nobody had handed us. `NEXT->location`, then the step after SIDE, then
## `NEXT->insurance`. The rule that came out of it is absolute:
##
##   **A screen is advanced only from its own `::Show` receiver.**
##
## The host gets those receivers from its `uihooks` detours. A mod cannot and
## must not detour those functions -- a second detour on one function overwrites
## the first's trampoline and silently kills the first feature -- so it rides the
## host's GENERIC EVENT BUS instead:
##
##   on("ui.show", handler)
##       payload {"site":N,"name":"..","rva":"0x..","epoch":N,"receiver":"0x.."}
##   call("aowlspt.host::ui_show_status", "")
##       per-site {bound, epoch, receiver}, for polling and for the arm-time
##       epoch snapshot
##
## WHY BOTH. The EVENT is the readback: it fires when the screen really appears,
## which is a positive observation a visibility timeout can never be. The STATUS
## POLL is what makes the mod correct across a load order it does not control:
## a screen can have appeared BEFORE this mod subscribed, and the last receiver
## for a site is still the right one (`MenuScreen` is DontDestroyOnLoad, so its
## pointer survives a raid). Neither alone is enough.
##
## THREADING, AND WHY THIS FILE HOLDS NO STRINGS
## ---------------------------------------------
## An event handler runs on whichever thread emitted the event. This mod does
## not get to assume that is Unity's thread, and a module-level Nim STRING
## assigned from a foreign thread is the measured `corrupted thread-free list`
## crash -- an ARC value freed on a thread that does not own it. So this file
## records integers and a raw pointer-sized integer and NOTHING ELSE. Every
## string, every dereference and every managed call happens later, on the
## `everyMain` tick, from a pointer that is RE-VALIDATED there.
##
## A RECEIVER IS NOT A LIVE OBJECT. The pointer is valid on the main thread at
## the moment the event fired, and by the time the tick reads it the screen may
## be gone -- a destroyed Unity object stays READABLE with `m_CachedPtr` zeroed
## (fact #182). `receiverOf` therefore re-checks readability AND liveness before
## returning anything, and returns nil rather than a corpse.

import aowlspt
import aowlspt/il2cpp
import aowlspt/json
import native
import calls

const
  SiteOfflineRaid* = 0   ## MatchmakerOfflineRaidScreen::Show   @0x1788590
  SiteMenuShow*    = 2   ## MenuScreen::Show(5-arg)             @0x15387A0
  SiteSideSelect*  = 3   ## MatchMakerSideSelectionScreen::Show @0x1790180
  SiteLocation*    = 4   ## MatchMakerSelectionLocationScreen::Show @0x178ACB0
  SiteInsurance*   = 5   ## MatchmakerInsuranceScreen::Show     @0x1769910
  SiteAccept*      = 6   ## MatchMakerAcceptScreen::Show        @0x1773EF0
  SiteShowInRaid*  = 7   ## MenuScreen::ShowInRaid              @0x1539650
  SiteSessionEnd*  = 8   ## SessionEndUI::Awake                 @0x1726850
  SiteCount* = 9
    ## SITE 1 IS `MenuScreen::Awake` AND IS NEVER USED HERE, and that is a
    ## regression fix rather than a preference. MEASURED 2026-09-02: wanting
    ## that site bound `MenuScreen::Awake` for the first time on any build this
    ## project has run, and the very next boot died at MENU ARRIVAL in
    ## `SeasonWidgetData::From @0x141FFD0+0x133` under `MenuScreen::Show(5-arg)`
    ## -- three boots, three deaths. This mod does not want it, does not read it
    ## and does not mention it to the host, because a reader is an argument for
    ## a want and that argument cost three boots.

proc siteName*(site: int): string =
  case site
  of SiteOfflineRaid: "MatchmakerOfflineRaidScreen::Show"
  of SiteMenuShow:    "MenuScreen::Show(5-arg)"
  of SiteSideSelect:  "MatchMakerSideSelectionScreen::Show"
  of SiteLocation:    "MatchMakerSelectionLocationScreen::Show"
  of SiteInsurance:   "MatchmakerInsuranceScreen::Show"
  of SiteAccept:      "MatchMakerAcceptScreen::Show"
  of SiteShowInRaid:  "MenuScreen::ShowInRaid"
  of SiteSessionEnd:  "SessionEndUI::Awake"
  else:               "uihooks site " & $site

# ---------------------------------------------------------------------------
# The mailbox. INTEGERS ONLY -- see the threading note in the banner.
# ---------------------------------------------------------------------------

var gEpoch: array[SiteCount, int]
var gRecv: array[SiteCount, uint64]
var gFires: array[SiteCount, int]
var gSubscribed = false
var gEvents = 0
  ## Every `ui.show` payload seen, including sites this mod ignores. A zero here
  ## with a live menu means the BUS is not delivering, which is a different bug
  ## from a site not binding, and the two must not be reported as one.
var gMalformed = 0
  ## Payloads that did not carry a usable site or epoch. Counted rather than
  ## ignored: a silently dropped event is a screen this mod will wait forever
  ## for.

proc parseHex(s: string): uint64 =
  ## `"0x1234abcd"` -> the number. 0 for anything malformed, which every caller
  ## treats as "no receiver" -- 0 is never a valid object pointer, so there is
  ## no ambiguity to resolve.
  result = 0'u64
  var i = 0
  if s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'):
    i = 2
  if i >= s.len: return 0'u64
  var acc = 0'u64
  var n = 0
  while i < s.len and n < 16:
    let c = s[i]
    var d = -1
    if c >= '0' and c <= '9': d = int(c) - int('0')
    elif c >= 'a' and c <= 'f': d = int(c) - int('a') + 10
    elif c >= 'A' and c <= 'F': d = int(c) - int('A') + 10
    else: return 0'u64
    acc = acc * 16'u64 + uint64(d)
    inc i
    inc n
  if i != s.len: return 0'u64
  result = acc

proc onShow(payload: string): string =
  ## The `ui.show` subscriber. RUNS ON WHOEVER EMITTED, so it does exactly two
  ## things: parse integers out of the payload, and store them. It dereferences
  ## nothing, calls nothing into the game, and assigns no module-level string.
  result = ""
  gEvents = gEvents + 1
  let site = asInt(field(payload, "site"), -1)
  if site < 0 or site >= SiteCount:
    gMalformed = gMalformed + 1
    return
  let ep = asInt(field(payload, "epoch"), -1)
  if ep < 0:
    gMalformed = gMalformed + 1
    return
  gEpoch[site] = ep
  gRecv[site] = parseHex(asText(field(payload, "receiver"), ""))
  gFires[site] = gFires[site] + 1

proc subscribe*(): bool =
  ## Subscribe once. Returns whether the host accepted the subscription --
  ## reported by the caller, because a mod that silently has no event source
  ## degrades into the timeout-driven behaviour this whole design replaced.
  if gSubscribed: return true
  if on("ui.show", onShow) != Ok:
    return false
  gSubscribed = true
  result = true

proc subscribed*(): bool = gSubscribed
proc eventsSeen*(): int = gEvents
proc malformedSeen*(): int = gMalformed
proc firesFor*(site: int): int =
  if site >= 0 and site < SiteCount: gFires[site] else: 0

# ---------------------------------------------------------------------------
# The status poll -- the half that works across a load order we do not control.
# ---------------------------------------------------------------------------

type
  SiteStatus* = object
    asked*: bool     ## the host answered the verb at all
    bound*: bool     ## the detour is installed for this site
    epoch*: int      ## how many times it has fired, host-side
    recv*: uint64    ## the last receiver, as the host last saw it

var gStatusMissing = false
  ## The host has no `ui_show_status` verb. Recorded once so the verdict can say
  ## INCONCLUSIVE-because-the-host-is-older rather than FAIL.

proc statusOf*(site: int): SiteStatus =
  ## `aowlspt.host::ui_show_status` for one site.
  ##
  ## Three outcomes, never two: `asked = false` means the verb is not there
  ## (an older host), which is NOT the same as `bound = false` (the verb is
  ## there and says the detour did not install). Collapsing those would report
  ## a missing feature as a broken one.
  result = SiteStatus(asked: false, bound: false, epoch: 0, recv: 0'u64)
  var raw = ""
  let empty = ""
  if call("aowlspt.host::ui_show_status", empty, raw) != Ok or raw.len == 0:
    gStatusMissing = true
    return
  result.asked = true
  let sites = field(raw, "sites")
  if not isArray(sites): return
  let n = count(sites)
  var i = 0
  while i < n:
    let e = at(sites, i)
    if asInt(field(e, "site"), -1) == site:
      result.bound = asBool(field(e, "bound"), false)
      result.epoch = asInt(field(e, "epoch"), 0)
      result.recv = parseHex(asText(field(e, "receiver"), ""))
      return
    i = i + 1

proc statusVerbMissing*(): bool = gStatusMissing

proc syncFromStatus*(site: int) =
  ## Take the host's own view of a site, for the case where the screen appeared
  ## BEFORE this mod subscribed. Never LOWERS what the event bus already saw: an
  ## event is a stronger fact than a poll, and a poll that overwrote it would
  ## discard the newer receiver.
  if site < 0 or site >= SiteCount: return
  let s = statusOf(site)
  if not s.asked: return
  if s.epoch > gEpoch[site]:
    gEpoch[site] = s.epoch
    gRecv[site] = s.recv

proc epochOf*(site: int): int =
  if site >= 0 and site < SiteCount: gEpoch[site] else: 0

proc snapshotEpoch*(site: int): int =
  ## The epoch to remember AT ARMING TIME. An event from BEFORE this run is not
  ## evidence about this run, and consuming a stale one would resynchronise the
  ## machine to a screen that is no longer up.
  syncFromStatus(site)
  epochOf(site)

proc receiverOf*(site: int): Il2CppPtr =
  ## The live receiver for a site, RE-VALIDATED. MAIN THREAD ONLY: it calls
  ## `alive`, which reads game memory.
  ##
  ## Returns nil for "never fired", for "not readable here" and for "the object
  ## is destroyed" alike, because every caller does the same thing with all
  ## three: refuse, and say the screen is not available.
  result = nil
  if site < 0 or site >= SiteCount: return
  let p = cast[Il2CppPtr](gRecv[site])
  if p == nil: return
  if not readable(p, 0x20) or not alive(p): return
  result = p

proc screenTransform*(site: int): Il2CppPtr =
  ## The receiver as a TRANSFORM, which is what the walkers descend.
  ##
  ## The receiver arrives as the screen's own MonoBehaviour -- `this` in RCX at
  ## its `::Show` -- and a MonoBehaviour is a Component, so
  ## `Component::get_transform` is the legal hop. Reading a Transform field off
  ## a MonoBehaviour by offset instead would be a guessed offset, and calling a
  ## Transform method with a MonoBehaviour receiver would be the type confusion
  ## this project keeps paying for.
  result = nil
  let self = receiverOf(site)
  if self == nil: return
  let tr = transformOf(self)
  if tr == nil or not readable(tr, 0x20): return
  result = tr

proc screenActive*(site: int): bool =
  ## Is that screen still on screen?
  ##
  ## THE FINISHED STATE OF EVERY "ADVANCE THE SCREEN" STEP IS THE NEGATIVE OF
  ## THIS, and that is the only form of the check that can fail. "The NextButton
  ## press returned" is not evidence of anything; "the screen this receiver
  ## belongs to is no longer active" is.
  let tr = screenTransform(site)
  if tr == nil: return false
  result = isActive(tr)
