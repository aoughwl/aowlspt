"""Where the game the HOST RUNS AGAINST lives -- ONE answer for every tool.

MEASURED 2026-09-05 16:04: the retail install ``D:\\Games\\Tarkov`` updated
itself to 1.1.0.46911 (72 files: EscapeFromTarkov.exe, GameAssembly.dll,
global-metadata.dat, ConsistencyInfo, ...). The aowlspt install
``D:\\Aowlspt`` -- the copy the client actually boots from, the one the host
DLL is deployed into and byte-verifies its prologues against -- stayed at
1.1.0.46777. Sixteen tools defaulted to the RETAIL path, so the next
``buildlock build host`` read the NEW GameAssembly with the OLD decrypted
metadata, and drainaudit reported "no method resolves to this RVA in the
metadata" for 52 of 53 detour targets: a confusing symptom of a plain
mismatch, and a refusal that stopped a build whose sources had not changed.

So every offline tool asks HERE, and here answers with the binary the host
runs against, saying which one it chose:

  1. ``AOWLSPT_GAMEASM`` (or the older ``AOWL_GAMEASM``) in the environment,
     for a deliberate look at some other binary -- the new retail build, a
     downloaded one;
  2. ``<install>\\GameAssembly.dll`` where ``<install>`` is ``AOWLSPT_INSTALL``
     or ``D:\\Aowlspt`` -- the default, because that is what is running;
  3. the retail copy, only if the install has none.

``python tools/gamepaths.py`` prints the choice, its sha, and whether the
retail copy differs (which is how "the game updated" becomes visible instead
of a resolver saying nothing resolves).
"""
import hashlib
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RETAIL = r"D:\Games\Tarkov"


def install_dir():
    return os.environ.get("AOWLSPT_INSTALL", r"D:\Aowlspt")


def gameasm():
    for key in ("AOWLSPT_GAMEASM", "AOWL_GAMEASM"):
        v = os.environ.get(key)
        if v:
            return v
    p = os.path.join(install_dir(), "GameAssembly.dll")
    if os.path.isfile(p):
        return p
    return os.path.join(RETAIL, "GameAssembly.dll")


def gamedir():
    return os.path.dirname(os.path.abspath(gameasm()))


def datadir():
    return os.path.join(gamedir(), "EscapeFromTarkov_Data")


def metadec():
    for key in ("AOWLSPT_METADEC", "AOWL_METADEC"):
        v = os.environ.get(key)
        if v:
            return v
    return os.path.join(REPO, ".cache", "global-metadata.dec.dat")


def sha16(path):
    """First 16 hex digits of the file's sha256 -- the key the resolver's
    callgraph cache already uses -- or "" when the file cannot be read."""
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()[:16]
    except OSError:
        return ""


def _mtime(path):
    try:
        import time
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(path)))
    except OSError:
        return "missing"


def describe():
    """One paragraph a human or a log can read: which binary, why, and
    whether the retail copy is a different build."""
    chosen = gameasm()
    why = ("environment override" if os.environ.get("AOWLSPT_GAMEASM") or
           os.environ.get("AOWL_GAMEASM") else
           ("the aowlspt install" if chosen.lower().startswith(install_dir().lower())
            else "the RETAIL install (the aowlspt install has no GameAssembly.dll)"))
    lines = ["gamepaths: GameAssembly = %s  (%s; sha %s; mtime %s)"
             % (chosen, why, sha16(chosen) or "unreadable", _mtime(chosen))]
    retail = os.path.join(RETAIL, "GameAssembly.dll")
    if os.path.isfile(retail) and os.path.abspath(retail).lower() != os.path.abspath(chosen).lower():
        a, b = sha16(chosen), sha16(retail)
        if a and b and a != b:
            lines.append("gamepaths: the retail copy %s DIFFERS (sha %s; mtime %s) -- "
                         "the retail game is a different build from the one the "
                         "host runs against; the tools read the chosen one on purpose"
                         % (retail, b, _mtime(retail)))
        else:
            lines.append("gamepaths: the retail copy is byte-identical")
    lines.append("gamepaths: metadata cache = %s (mtime %s)" % (metadec(), _mtime(metadec())))
    return "\n".join(lines)


def _selftest():
    fails = []
    saved = {k: os.environ.get(k) for k in ("AOWLSPT_GAMEASM", "AOWL_GAMEASM", "AOWLSPT_INSTALL")}
    try:
        # 1. the override wins, whatever is on disk
        os.environ["AOWLSPT_GAMEASM"] = r"X:\nowhere\GameAssembly.dll"
        if gameasm() != r"X:\nowhere\GameAssembly.dll":
            fails.append("override not honoured: %s" % gameasm())
        os.environ.pop("AOWLSPT_GAMEASM")
        # 2. an install without the DLL falls back to the retail path (negative)
        os.environ.pop("AOWL_GAMEASM", None)
        os.environ["AOWLSPT_INSTALL"] = r"X:\no-such-install"
        if gameasm() != os.path.join(RETAIL, "GameAssembly.dll"):
            fails.append("fallback to retail did not happen: %s" % gameasm())
        # 3. the install's copy is chosen when present
        os.environ.pop("AOWLSPT_INSTALL")
        p = os.path.join(install_dir(), "GameAssembly.dll")
        if os.path.isfile(p) and gameasm() != p:
            fails.append("install copy present but not chosen: %s" % gameasm())
        # 4. sha16 refuses a missing file with "" and answers 16 hex on a real one
        if sha16(r"X:\nowhere.dll") != "":
            fails.append("sha16 of a missing file was not empty")
        if sha16(os.path.abspath(__file__)) == "" or len(sha16(os.path.abspath(__file__))) != 16:
            fails.append("sha16 of this file did not answer 16 hex digits")
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    if fails:
        for f in fails:
            print("FAIL " + f)
        return 1
    print("PASS -- 5 checks (override, retail fallback, install preferred, "
          "sha16 missing, sha16 real)")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(_selftest())
    print(describe())
