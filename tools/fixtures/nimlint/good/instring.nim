## NEGATIVE CONTROL. The bad line appears only inside string literals -- which
## is exactly what a refusal message about the bad line looks like. A linter
## that fires here would fire on its own error text. NEVER COMPILED.

import aowlspt/instring

const advice* = """
import aowlspt/instring
export instring
"""

const oneline* = "export instring"

proc why*(): string =
  if advice.len > 0: "export instring" else: oneline
