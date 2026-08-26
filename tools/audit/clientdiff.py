"""Diff what the CLIENT can ask for (il2cpp string table) against what we serve.

Independent of the capture: the capture only shows one session's traffic, this
shows every route literal compiled into the client.
"""
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from edgecensus import routes, served  # noqa: E402


def main():
    out = subprocess.run([sys.executable, os.path.join(HERE, "clientroutes.py")],
                         capture_output=True, text=True).stdout
    lits = [l.strip() for l in out.splitlines() if l.strip().startswith("/")]
    exact, prefix = routes()
    miss = [l for l in lits if not served(l.rstrip("/") if l.endswith("/") else l,
                                         exact, prefix) and not served(l, exact, prefix)]
    print("client route literals: %d   unserved: %d\n" % (len(lits), len(miss)))
    for l in miss:
        print("  " + l)


if __name__ == "__main__":
    main()
