## `jsonpath` moved to `aowl/src/aowlspt/jsonpath.nim`. This re-exports it.
##
## ## Why it moved
##
## A MOD needed it. `mods/manager/mgr/cfgscan.nim` reads other mods'
## `config.json` files and reports which are unreadable, and it must use the
## HOST's parser to do that -- a second parser that disagrees about what is
## valid is how the manager comes to say a config is fine that the host then
## refuses. So it imported this file, the only way it could:
##
##     import "../../../host/common/jsonpath"
##
## That path is relative to the REPO CHECKOUT. It resolves while the mods
## folder sits inside the repo and nowhere else. Measured 2026-09-01, building
## a mods folder in a fresh install with only the bundled toolchain:
##
##     mgr/cfgscan.nim(47, 1) Error: file not found:
##         <install>\toolchain\host\common\jsonpath.nim
##     mgr/cfgscan.nim(107, 15) Error: undeclared identifier: 'jsonFault'
##
## -- one of three mods out of sixteen that could not be built by an install.
## Since aowlspt's whole shape is "the user's mods folder holds SOURCE and is
## compiled at startup", a mod that only compiles inside our checkout is not a
## mod anyone else can have.
##
## `aowl/src/aowlspt/` is the library every mod already compiles against
## (`-p:aowl\src` is on every mod, host, backend and tool command line), so
## that is where something a mod needs belongs. The mod now says
## `import aowlspt/jsonpath`, which is layout-independent.
##
## ## Why this shim exists rather than a bare move
##
## Three other places import this path -- `tools/aowllaunch.nim`,
## `tools/aowlsession.nim` and `tests/json/test_config_merge.nim` -- and this
## is a shared checkout with several agents building in it. Re-exporting keeps
## every one of them compiling unchanged, so the move costs nobody a build.
##
## It is a RE-EXPORT, not a copy. There is still exactly one implementation;
## two copies of a JSON parser is the precise failure the original file was
## written to end, and reintroducing it here to avoid a one-line edit would be
## absurd.
##
## New code should import `aowlspt/jsonpath` directly.

import aowlspt/jsonpath
export jsonpath
