## aowlspt/menutext — set the main menu's bottom-right game-mode label.
##
## A stock post-1.0 main menu reads **"PVE ZONE"** in the bottom-right corner.
## That is `EFT.UI.PreloaderUI::_sessionModeText`, and the client host can set it
## by calling the game's own `PreloaderUI::SetGameModeText`. This module is how a
## mod asks it to.
##
##     import aowlspt/menutext
##     import aowlspt/settings
##
##     proc onLoad(): Status =
##       declareSettings(@[
##         stringSetting("menuModeText", "Menu corner label", "",
##                       category = "Menu",
##                       description = "What the main menu's bottom-right " &
##                                     "corner shows. Empty = the character's name.")])
##       discard serve("/aowlspt/settings/" & ModGuid, onSettings)
##       setMenuModeText(setting("menuModeText").asText(""))
##
##     proc onSettings(url, body, session: string): string =
##       if body.len > 0 and applySettingFromBody(body) == Ok:
##         setMenuModeText(setting("menuModeText").asText(""))
##       result = declaredSchemaJson().text
##
## ---------------------------------------------------------------------------
## How it actually gets there
## ---------------------------------------------------------------------------
##
## `setMenuModeText` broadcasts `aowlspt.menu.modeText`. The mod manager holds
## the value and publishes it as `menuModeText` on the client-set poll response
## the client host **already** fetches every `modSyncMs` — the same body it
## already reads `inRaid` out of. The host applies it on the next Unity frame.
##
##     mod --setMenuModeText--> aowlspt.menu.modeText --> mod manager
##       manager --> GET /aowlspt/mods/client/<hostver> {"menuModeText":"..."}
##         client host --> PreloaderUI::SetGameModeText(<string>)
##
## No new endpoint, no new poll, no new socket. That is deliberate: the client
## host has exactly one route to the backend and a second one would only be a
## second thing that can be down.
##
## ---------------------------------------------------------------------------
## What to expect
## ---------------------------------------------------------------------------
##
## * **The player must opt in.** The host side is gated on `uxMenuModeText` in
##   `aowlspt-host.json`, default `false`. A mod calling this on an install that
##   has not enabled it changes nothing, and that is not an error.
## * **Empty clears.** `setMenuModeText("")` drops this mod's override and the
##   label goes back to the default, which is the logged-in character's name.
##   It is not a way to blank the label.
## * **Short, plain ASCII.** At most `MenuTextMax` printable ASCII characters.
##   Anything else is refused here rather than sent — the label is one short line
##   in a corner, and the host refuses the same shape at the far end, so a value
##   that would not survive the trip is better rejected where someone can be told.
## * **Last writer wins.** There is one label and one override slot. Two mods
##   both setting it is two mods fighting over one corner of the screen; the
##   manager holds whichever spoke last.

import ".." / aowlspt            # Status, Ok, ErrBadArg
import "." / server              # broadcast, objOf

const MenuTextMax* = 48
  ## The longest label this will send. Matches `MenuModeTextMax` in the client
  ## host's `modcontrol.nim`, and both exist so the limit is enforced at the end
  ## where it can still be reported rather than only at the end where it can
  ## only be dropped.

proc menuTextAcceptable*(s: string): bool =
  ## Whether `s` is a label this will carry: printable ASCII, `MenuTextMax` or
  ## fewer characters. Exposed so a mod can validate a setting it just read and
  ## say something useful about it, instead of calling `setMenuModeText` and
  ## having to infer the refusal from a label that did not change.
  ##
  ## An empty string is NOT "acceptable" by this test — it is the clear
  ## instruction, which `setMenuModeText` handles separately.
  if s.len == 0 or s.len > MenuTextMax:
    return false
  for ch in s:
    if ord(ch) < 0x20 or ord(ch) > 0x7E:
      return false
  result = true

proc setMenuModeText*(text: string): Status =
  ## Ask for the main menu's bottom-right corner label to read `text`.
  ##
  ## Returns `Ok` when the request was broadcast, `ErrBadArg` when `text` is
  ## not a label this will carry (see `menuTextAcceptable`). `Ok` means "asked",
  ## not "shown": whether it appears depends on the player having set
  ## `uxMenuModeText`, on the manager being up, and on the client host having
  ## reached its menu. None of those are things this call can know, and none of
  ## them are failures worth an error — the honest answer to all three is a
  ## label that stays as it was.
  ##
  ## `setMenuModeText("")` clears this override; the label reverts to the
  ## logged-in character's name.
  if text.len > 0 and not menuTextAcceptable(text):
    return ErrBadArg
  result = broadcast("aowlspt.menu.modeText", objOf("text", text))

proc clearMenuModeText*(): Status =
  ## Drop the override and go back to the default (the character's name).
  ## Exactly `setMenuModeText("")`, named so the intent reads at the call site —
  ## and worth calling from a mod's `onUnload`, so a mod that is switched off
  ## does not leave its label behind for the rest of the session.
  setMenuModeText("")
