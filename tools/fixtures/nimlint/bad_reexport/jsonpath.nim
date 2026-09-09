## POSITIVE CONTROL for nimlint's `module-reexport-samename`.
##
## This is `host/common/jsonpath.nim` as it stood between 531498a and cb9a816,
## reduced to the two lines that matter. It made nimony's hexer die tree-wide
## with `getOrQuit: missing key`, naming no file, for 2.5 hours.
##
## NEVER COMPILED. It exists so the linter can be shown to fire.

import aowlspt/jsonpath
export jsonpath
