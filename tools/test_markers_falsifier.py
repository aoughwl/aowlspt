#!/usr/bin/env python3
"""test_markers_falsifier.py -- proves markers.py cannot answer PRESENT to
everything, and does not answer MISSING when it could not look.

markers.py replaced a PowerShell one-liner that reported markers ABSENT from a
build that contained them (five agents, facts #151/#152). A replacement that
answers PRESENT to everything would have looked like a fix for exactly as long.
So: the positive control and the negative control, through the real CLI.

    python tools/test_markers_falsifier.py    exit 0 = all three outcomes reachable
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MARKERS = os.path.join(HERE, "markers.py")
bad = []


def run(*a):
    r = subprocess.run([sys.executable, MARKERS] + list(a),
                       capture_output=True, text=True, timeout=120)
    return r.returncode, (r.stdout + r.stderr)


d = tempfile.mkdtemp(prefix="markers-fals-")
art = os.path.join(d, "fake.dll")
with open(art, "wb") as f:
    f.write(b"\x00" * 64 + "aowlsptPresentMarker".encode("utf-8")
            + b"\x00" * 32 + "aowlsptUtf16Marker".encode("utf-16-le")
            + b"\x00" * 64)

rc, out = run("--string", "aowlsptPresentMarker", art)
if rc != 0:
    bad.append("positive control: a literal that IS there exited %d\n%s" % (rc, out))

rc, out = run("--string", "aowlsptDefinitelyNotInThisFile",
              "--control", "aowlsptPresentMarker", art)
if rc != 1:
    bad.append("NEGATIVE CONTROL: an absent literal WITH a positive control "
               "exited %d, want 1 (MISSING). markers.py can answer PRESENT to "
               "anything.\n%s" % (rc, out))

# And the vacuity guard itself: with NO positive control, a miss must be
# INCONCLUSIVE, because a scan never shown capable of finding anything cannot
# carry a negative. `--absent` needs a control or it passes vacuously.
rc, out = run("--string", "aowlsptDefinitelyNotInThisFile", art)
if rc != 3:
    bad.append("a miss with no positive control exited %d, want 3 "
               "(INCONCLUSIVE) -- an unproven scan produced a verdict.\n%s"
               % (rc, out))

rc, out = run("--string", "aowlsptUtf16Marker", art)
if rc != 0:
    bad.append("a UTF-16LE-only literal exited %d -- the exact false MISSING "
               "the PowerShell one-liner produced.\n%s" % (rc, out))

rc, out = run("--string", "anything", os.path.join(d, "no-such-file.dll"))
if rc == 0 or rc == 1:
    bad.append("an unreadable file exited %d -- 'I could not look' was "
               "flattened into a verdict.\n%s" % (rc, out))

for b in bad:
    print("FAIL " + b)
print("test_markers_falsifier: %d failure(s)" % len(bad))
sys.exit(1 if bad else 0)
