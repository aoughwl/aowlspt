## NEGATIVE CONTROL. A mod file importing a sibling directory INSIDE its own
## mod. `mods/maps/sp/hud.nim` does exactly this (`import ../core/place`) and
## it builds in a fresh install, so it must not be reported. NEVER COMPILED.

import aowlspt
import ../core/place

proc draw*(): int = 0
