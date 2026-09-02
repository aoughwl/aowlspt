## NEGATIVE CONTROL. Re-exporting NAMED SYMBOLS is the correct form and must
## never be reported. NEVER COMPILED.

import aowlspt/jsonpath

export pathGet, pathGetInt, jsonFault

proc reads*(doc: string): string =
  pathGet(doc, "a.b")
