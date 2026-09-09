# betanotice.nim -- THE HOST'S OWNERSHIP OF THE MAIN-MENU BETA NOTICE.
#
# `abi/aowlspt_betanotice.h` is the whole feature. This file does four small
# things and nothing else:
#
#   1. It is the ONE translation unit that includes that header, so the
#      participant exists exactly once in the process. It is included AFTER
#      `invoke2.nim` (for the byte-verified `UnityEngine.Screen::get_width`
#      target table) and AFTER `region.nim` (for `aowl_region_register`, which
#      is file-static and only exists once `AOWL_REGION_HOST` has been defined).
#
#   2. It reads the flag AS READ and says so. `uxBetaOverlay`, default OFF,
#      out of `aowlspt-host.json` -- named here in full because
#      `tools/hostcfg.py` SKIPS any host source that does not contain that
#      literal, so without this line the key it validates against would not
#      include this file's and a correct key would read as a typo. That is a
#      defect in the tool, not a property of the key; see the report.
#      A NEW key: it deliberately does not reuse `uxBetaNotice`, which still
#      belongs to the RETIRED path that repurposed the game's seasons banner,
#      nor `uxHideSeasons`, which hides that banner and is what makes room for
#      this one. All three can be set independently and the log states the
#      combination that was actually read, because a default in source is not a
#      value -- a flag defaulted false here was still `true` in a deployed
#      `config.json` today and the dangerous branch ran.
#
#   3. It registers the participant with the shared region. It installs NO
#      detour: the region already rides the existing `EFT.UI.PreloaderUI::
#      Update` chain, and the whole point of the region is that a per-frame draw
#      is a REGISTRATION and not another entry in the rider list.
#
#   4. It forwards the host's raid state, so the notice is main-menu only.
#
# NO GUARD IS OPENED HERE, and none is opened in the header. The region
# dispatcher opens exactly one `aowl_p_p_seh` around the callback; that guard is
# not re-entrant and a second one inside it would DISARM it rather than add to
# it. This is the same reasoning `region.nim` records for `regionFired`.
#
# THE ONE THING THIS FILE CANNOT DO. The overlay never publishes the back-buffer
# size to the region, so the header asks Unity for it instead. If the overlay
# ever starts calling a `aowl_region_set_screen_x`, the header should prefer it
# and the Screen call becomes the fallback -- see the note in the header.

{.emit: """
#include "aowlspt_betanotice.h"

/* The log sink, adapting the header's plain `const char*` to the nimony proc
 * below. Same shape and same cast as `aowl_region_sink` in `region.nim`:
 * nimony renders a `cstring` parameter as `unsigned char*`. */
extern void aowlspt_nim_beta_log(unsigned char* line);
static void aowl_beta_sink_impl(const char* line) {
    aowlspt_nim_beta_log((unsigned char*)(void*)line);
}
static void aowl_beta_boot(void) { aowl_beta_set_sink(aowl_beta_sink_impl); }
""".}

proc cBetaBoot() {.importc: "aowl_beta_boot", nodecl.}
proc cBetaRegister(): int32 {.importc: "aowl_beta_register", nodecl.}
proc cBetaUnregister(): int32 {.importc: "aowl_beta_unregister", nodecl.}
proc cBetaSetMenu(on: int32) {.importc: "aowl_beta_set_menu", nodecl.}
proc cBetaSetPosStr(s: cstring): int32 {.importc: "aowl_beta_set_pos_str", nodecl.}
proc cBetaHandle(): int32 {.importc: "aowl_beta_handle", nodecl.}
proc cBetaDraws(): int64 {.importc: "aowl_beta_draws", nodecl.}
proc cBetaScrW(): int32 {.importc: "aowl_beta_scr_w", nodecl.}
proc cBetaScrH(): int32 {.importc: "aowl_beta_scr_h", nodecl.}

var gBetaOverlayOn = false
var gBetaOverlayBooted = false
var gBetaOverlayAnnounced = false

proc betaLog(line: cstring) {.exportc: "aowlspt_nim_beta_log", cdecl.} =
  ## Everything the notice says goes through here. A refusal is a WARNING so
  ## `tools/hostlog.py summary` separates it from chatter -- a feature that
  ## declines silently is the worst outcome this project produces.
  let s = $line
  if s.len == 0: return
  if s.contains("REFUSED") or s.contains("FAULT") or s.contains("DISABLED"):
    warn s
  else:
    info s

proc betaNoticeSetMenu(inRaid: bool) =
  ## Driven from the host's existing raid-state signal, the same one the
  ## graphics post-process gates on. In a raid the callback returns before it
  ## submits anything, so the notice cannot appear over a firefight.
  if not gBetaOverlayOn: return
  cBetaSetMenu(if inRaid: 0'i32 else: 1'i32)

proc betaNoticeReadFlags() =
  ## Read AS READ, and logged as read. Called from the same place every other
  ## `readBoolKey` is.
  gBetaOverlayOn = readBoolKey("uxBetaOverlay")
  if not gBetaOverlayOn:
    return
  info "uxBetaOverlay read as ON: a main-menu beta notice will be DRAWN on " &
       "the overlay (it constructs no Unity UI and rewrites no game label -- " &
       "it is not the retired uxBetaNotice path, which repurposed the " &
       "seasons banner and is a separate flag). It draws only outside a raid " &
       "and submits FILL and TEXT only, so it cannot take a click."
  # `var`, not `let`: nimony's `toCString` takes its string by `var`, because it
  # hands out a pointer into the SSO buffer and will not do that for a value it
  # cannot prove is addressable.
  var pos = readStrKey("uxBetaOverlayPos")
  if pos.len > 0:
    if cBetaSetPosStr(toCString(pos)) != 0'i32:
      info "beta notice: position set from uxBetaOverlayPos = \"" & pos &
           "\" (centre X, top Y, as a fraction of the back buffer)"
    else:
      warn "beta notice: uxBetaOverlayPos = \"" & pos & "\" was REFUSED -- it " &
           "must be \"<centreX>,<topY>\" with centreX in 0.02..0.98 and topY " &
           "in 0.0..0.95. The default (0.50, 0.11) is being used instead."

proc bindBetaNotice(verbose: bool): bool =
  ## Registers the participant. It does NOT need the region to be armed first:
  ## registration is always legal, and a participant registered before the
  ## Unity-thread rider comes up is the documented waiting state, not a
  ## failure. It DOES need `sharedRegion`, because nothing will ever dispatch
  ## it otherwise -- and that is said out loud rather than left to look like
  ## "the notice does not work".
  if not gBetaOverlayOn:
    return false
  if cBetaHandle() >= 0'i32:
    return true
  if not gRegionOn:
    if verbose:
      warn "beta notice: uxBetaOverlay is ON but sharedRegion is OFF. The " &
           "notice is registered with nothing that dispatches it and will " &
           "NEVER draw. Turn on sharedRegion (python tools/hostcfg.py set " &
           "sharedRegion on) or turn uxBetaOverlay back off."
    return false
  if not gBetaOverlayBooted:
    gBetaOverlayBooted = true
    cBetaBoot()
  let h = cBetaRegister()
  if h < 0'i32:
    if verbose:
      warn "beta notice: the shared region REFUSED the registration (" & $h &
           "). The refusal codes are in abi/aowlspt_region.h; nothing is " &
           "drawn and nothing was patched."
    return false
  okLog "beta notice: registered with the shared region as participant '" &
        "beta-notice' (handle " & $h & ", draw-only, 120 us budget). It " &
        "installs NO detour of its own and rides the region's existing " &
        "PreloaderUI::Update chain; the overlay's region append rasterises it."
  result = true

proc betaNoticeReport() =
  ## The FINISHED STATE, once. Not "we called the setter" -- the number of
  ## frames the participant actually submitted on, and the resolution it
  ## positioned against. Zero draws here is the falsifiable failure.
  if not gBetaOverlayOn or gBetaOverlayAnnounced: return
  if cBetaDraws() <= 0'i64: return
  gBetaOverlayAnnounced = true
  okLog "beta notice: " & $cBetaDraws() & " frame(s) submitted against a " &
        $cBetaScrW() & "x" & $cBetaScrH() & " back buffer"
