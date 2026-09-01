#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ichannel.py -- a RE-EXPORT of `plugins/aowlsptcode/mcp/channel.py`.

It used to be a verbatim COPY of that file, with its own docstring saying so
and saying that "if that plugin branch merges, this file should be replaced by
an import of the real module instead of kept as a second copy". The plugin is
merged (`plugins/aowlsptcode/mcp/channel.py` is in the tree), so this is now
that import.

Why this matters and is not tidying: the copy had already drifted --
`parse_call`'s regex fix and `_has_err_line`'s single-'!' fix are each
described in the copy as "the same fix as channel.py", i.e. both files had to
be patched twice for one bug. A second parser of the same prose that can drift
is exactly the failure mode CLAUDE.md 9b is about: two views of one answer, one
of them silently wrong.

Everything channel.py exports is available here under its original name, so
`import ichannel` keeps working unchanged for `tools/acceptance.py` and
anything else that took the vendored copy.
"""
import os
import sys

_MCP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "plugins", "aowlsptcode", "mcp")
if _MCP not in sys.path:
    sys.path.insert(0, _MCP)

try:
    from channel import *  # noqa: F401,F403 -- deliberate re-export
    import channel as _channel
except ImportError as _e:  # pragma: no cover -- named, never silent
    raise ImportError(
        "ichannel is a re-export of plugins/aowlsptcode/mcp/channel.py and "
        "that module could not be imported from %s (%s). This file no longer "
        "carries its own copy of the transport on purpose -- restore the "
        "plugin rather than re-vendoring the parser." % (_MCP, _e))

# `from x import *` skips underscore-prefixed names; acceptance.py and the REPL
# use these, so they are re-bound explicitly rather than left missing.
_read = _channel._read
_has_err_line = _channel._has_err_line
_completeness = _channel._completeness
_Lock = _channel._Lock
_nolock = _channel._nolock
