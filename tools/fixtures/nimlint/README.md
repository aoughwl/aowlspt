# nimlint controls

`tools/nimlint.py --selftest` scans these. They are never compiled and never
shipped; a whole-checkout scan deliberately walks around this directory,
because the positive controls are supposed to fire.

* `bad_reexport/jsonpath.nim` -- the measured 2026-09-01 incident, reduced: a
  shim named `jsonpath` that re-exports the module `aowlspt/jsonpath`. Must
  produce exactly one `module-reexport-samename` ERROR.
* `bad_modimport/mods/badmod/sub/cfgscan.nim` -- a mod importing out of the
  mods folder. Must produce exactly one `checkout-relative-mod-import` ERROR.
* `good/` -- four files that must produce NOTHING at any severity: a symbol
  re-export, an `export` that is only inside a comment, an `export` that is
  only inside a string literal, and a mod-internal `../` import.

If a control stops behaving, the linter has stopped being evidence. Do not
"fix" the selftest by editing a control to match new behaviour without saying
what changed and why.
