## POSITIVE CONTROL for nimlint's `checkout-relative-mod-import`.
##
## `mods/manager/mgr/cfgscan.nim` as it stood before 531498a: it reached into
## the repo checkout, so a fresh install could not build it.
##
## The path below climbs three levels from a file one directory deep inside
## its mod -- i.e. out of the mods folder entirely. NEVER COMPILED.

import "../../../host/common/jsonpath"

proc scan*(): int = 0
