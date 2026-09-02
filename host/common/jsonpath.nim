## `jsonpath` lives in `aowl/src/aowlspt/jsonpath.nim` (a MOD needed it: the manager
## reads other mods' config.json with the HOST's parser). This file keeps the old
## `import jsonpath` sites in host/ and backend/ working.
##
## It is an INCLUDE, not `import aowlspt/jsonpath; export jsonpath`. MEASURED
## 2026-09-01: the re-export form made nimony's hexer die tree-wide with
## `getOrQuit: missing key` at the graph stage, naming no file, for ~2 hours;
## replacing it with this include made the identical tree build. `export` of a
## whole module is not something this compiler survives -- do not reintroduce it.
include "../../aowl/src/aowlspt/jsonpath.nim"
