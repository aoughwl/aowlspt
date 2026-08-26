"""Every route-shaped literal the CLIENT carries, out of the decrypted il2cpp metadata.

The capture only shows what one session happened to do. This shows what the
client is *capable* of asking for: the string table is the client's own.

Usage: python tools/audit/clientroutes.py [--grep SUBSTR]
"""
import os
import re
import sys

BLOB = os.path.join(os.path.expanduser("~"), "Projects", "aowlspt", ".cache",
                    "global-metadata.dec.dat")
HEAD = "/(?:client|singleplayer|launcher|v2|raid)/"
PAT = re.compile((HEAD + r"[A-Za-z0-9_\-/{}\.]{2,400}").encode())
SPLIT = re.compile("(?=" + HEAD + ")")


def main():
    want = None
    if len(sys.argv) > 2 and sys.argv[1] == "--grep":
        want = sys.argv[2].lower()
    data = open(BLOB, "rb").read()
    parts = set()
    for m in PAT.findall(data):
        for piece in SPLIT.split(m.decode("ascii", "replace")):
            if piece.startswith("/"):
                parts.add(piece)
    seen = sorted(parts)
    if want:
        seen = [s for s in seen if want in s.lower()]
    for s in seen:
        print(s)
    print("-- %d literal(s)" % len(seen), file=sys.stderr)


if __name__ == "__main__":
    main()
