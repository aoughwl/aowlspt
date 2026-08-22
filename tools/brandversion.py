#!/usr/bin/env python3
"""brandversion.py -- brand the bottom-left version label, on the live client.

WHY A SCRIPT AND NOT THE HOST FEATURE
-------------------------------------
The host already has a `uxVersionBrand` feature and it has never visibly
worked. The reason is now measured rather than suspected: its `$verlabel`
anchor -- `PreloaderUI + cUxVersionLabelOffset()` -- points at an object whose
`m_text` reads EMPTY. It is not the label on screen. The label on screen is

    Preloader UI/BottomPanel/Content/UpperPart/AlphaLabel

and the TextMeshProUGUI on that node reads e.g. "1.1.0.1.46777 | PvE".

So the host feature was branding the wrong object, and every attempt to debug
it cost a build -> deploy -> relaunch cycle. This does it against the RUNNING
client through the live inspector, which makes the whole loop seconds instead
of minutes, and it is also the honest place for it until the host feature is
retargeted: a script that works today beats a host flag that does not.

IT WRITES THROUGH THE REAL SETTERS. A raw store into `m_text` appears to work
and is then clobbered, because `LocalizedText` re-applies its own string. The
inspector's `settext` verb goes through `LocalizedText::SetLabelText` and
`TMP_Text::set_text` + the repaint latch, and reads the value back afterwards.
Measured: the write sticks (re-read after 8s still ours), and TMP reallocates
the String, so the pointer changes while the text does not.

  python tools/brandversion.py                    # "aowlspt <dash> <stock>"
  python tools/brandversion.py --text "MY BUILD"  # replace it outright
  python tools/brandversion.py --show             # read it, write nothing

Exit codes: 0 branded (or already branded), 2 the label was not found,
3 the write did not take.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inspector import run_batch, Timeout  # noqa: E402

ROOT = re.compile(r"\[\$r(\d+)\] transform=(0x[0-9a-fA-F]+).*name=\"([^\"]*)\"")
TEXT = re.compile(r'text = "(.*)"')
AFTER = re.compile(r'after  = "(.*)"')
BRAND = "aowlspt — "


def preloader_root():
    out = run_batch(["roots"], timeout=40)
    for m in ROOT.finditer(out):
        if m.group(3) == "Preloader UI":
            return m.group(2)
    return None


def read_label(root):
    """The version label's TMP component and its current text.

    `component ... TextMeshProUGUI` is required: `label` on the Transform that
    `find` binds reports a plausible empty string off unrelated memory, which
    reads as "the label is empty" and is not an answer.
    """
    out = run_batch(["find AlphaLabel %s 60000" % root,
                     "component $f1 TextMeshProUGUI",
                     "label $comp"], timeout=90)
    if "FOUND" not in out:
        return None, None
    m = re.search(r"FOUND TextMeshProUGUI component = (0x[0-9a-fA-F]+)", out)
    t = TEXT.search(out)
    return (m.group(1) if m else None), (t.group(1) if t else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default=None,
                    help="replace the whole label instead of prefixing it")
    ap.add_argument("--show", action="store_true",
                    help="print the current label and exit")
    a = ap.parse_args()

    try:
        root = preloader_root()
    except Timeout as e:
        print("!! %s" % e, file=sys.stderr)
        return 2
    if not root:
        print("!! no `Preloader UI` scene root -- the client is not far enough "
              "along, or the host is not running.", file=sys.stderr)
        return 2

    comp, current = read_label(root)
    if not comp:
        print("!! AlphaLabel has no TextMeshProUGUI under Preloader UI. The "
              "label moved, or this is a different game build.", file=sys.stderr)
        return 2
    print("label %s currently reads %r" % (comp, current))
    if a.show:
        return 0

    if a.text is not None:
        want = a.text
    else:
        if current and current.startswith("aowlspt"):
            print("already branded; nothing to do.")
            return 0
        want = BRAND + (current or "")

    out = run_batch(["settext %s %s" % (comp, want)], timeout=60, write=True)
    m = AFTER.search(out)
    if m and m.group(1) == want:
        print("VERIFIED: the label now reads %r" % want)
        return 0
    if "VERIFIED" in out:
        print("branded.")
        return 0
    print("!! the write did not take:\n%s" % out, file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
