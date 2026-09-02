## NEGATIVE CONTROL. Every `export` below is inside a comment, and a linter
## that reads comments as code would fire on this file. It is the shape this
## repo's own docs have: the rule is explained in prose right next to the
## import it is about. NEVER COMPILED.
##
##     import aowlspt/incomment
##     export incomment
##
## The line above is documentation of the BAD form and must stay quiet.

import aowlspt/incomment  # not re-exported

#[
  export incomment
  A block comment, nested: #[ export incomment ]#
]#

proc use*(): int =
  # export incomment
  0
