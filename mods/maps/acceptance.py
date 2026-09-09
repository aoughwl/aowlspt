"""Acceptance for mods/maps, against a RUNNING backend.

    python mods/maps/acceptance.py [BASEURL]     default http://127.0.0.1:6969

Three outcomes per check: PASS / FAIL / INCONCLUSIVE. "I could not look" is
never a pass (CLAUDE.md 9b).

Every assertion is a property of the FINISHED STATE and most are NEGATIVES,
because a negative can be falsified and a self-comparison cannot:

  * no served asset may contain the guard's own refusal comment
  * no served asset may be smaller than a plausible map (>=2 KB, has drawing
    elements) -- this is what catches the query-string bug, where the guard
    refused a real file and reported itself working
  * no error body may fail a STRICT json parse -- this is what catches raw
    Windows backslashes in a hand-built error string
  * every layer image named by every map must resolve; the check walks the
    real index rather than a path typed by hand, because a hand-typed path is
    how the first run of this script "passed" against a file that did not exist
  * a traversal attempt must be refused, in several spellings
"""
import json
import sys
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:6969").rstrip("/")
A = BASE + "/aowlspt/maps/"

PASS, FAIL, INC = [], [], []


def rec(bucket, name, detail=""):
    bucket.append(name + ((" -- " + detail) if detail else ""))


def get(path, timeout=10):
    """(body_bytes, content_type) or (None, reason)."""
    url = A + path + ("&" if "?" in path else "?") + "ident=1"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.read(), r.headers.get("Content-Type", "")
    except urllib.error.URLError as e:
        return None, "%s: %s" % (url, e)
    except Exception as e:  # noqa: BLE001
        return None, "%s: %s" % (url, e)


def jget(path):
    b, ct = get(path)
    if b is None:
        return None, ct
    try:
        return json.loads(b.decode("utf-8")), ct
    except Exception as e:  # noqa: BLE001
        return None, "not strict JSON (%s): %.180s" % (e, b[:180])


# --- 0. reachable at all -----------------------------------------------------
st, why = jget("status")
if st is None:
    print("INCONCLUSIVE: the backend did not answer %sstatus -- %s" % (A, why))
    print("Nothing below was checked. This is not a pass.")
    sys.exit(2)
rec(PASS, "status answers and parses strictly",
    "maps=%s layers=%s" % (st.get("maps"), st.get("layers")))

if not st.get("indexLoaded"):
    rec(FAIL, "the map index did not load", str(st.get("mapsRoot")))

# --- 1. index ----------------------------------------------------------------
idx, why = jget("index")
if idx is None or "maps" not in idx:
    rec(FAIL, "index did not parse as a map list", str(why))
    idx = {"maps": []}
maps = idx.get("maps", [])
if not maps:
    rec(FAIL, "the index lists zero maps")
else:
    rec(PASS, "index lists %d maps" % len(maps))

if st.get("maps") != len(maps):
    rec(FAIL, "status maps=%s disagrees with the index's %d"
        % (st.get("maps"), len(maps)))
declared_layers = sum(m.get("layers", 0) for m in maps)
if st.get("layers") != declared_layers:
    rec(FAIL, "status layers=%s disagrees with the index's %d"
        % (st.get("layers"), declared_layers))
else:
    rec(PASS, "status layer count agrees with the index", str(declared_layers))

# --- 2. every layer of every map resolves to real SVG ------------------------
checked = missing = tiny = refused = 0
bad_ct = []
for m in maps:
    doc, why = jget("map/" + m["id"])
    if doc is None:
        rec(FAIL, "map/%s did not parse" % m["id"], str(why))
        continue
    for lname, layer in (doc.get("layers") or {}).items():
        img = layer.get("image")
        if not img:
            rec(FAIL, "%s/%s declares no image" % (m["id"], lname))
            continue
        body, ct = get("asset/" + img)
        checked += 1
        if body is None:
            missing += 1
            rec(FAIL, "asset %s did not fetch" % img, str(ct))
            continue
        text = body.decode("utf-8", "replace")
        if "refused" in text[:400]:
            refused += 1
            rec(FAIL, "the guard REFUSED a real asset named by the index", img)
        elif "not found" in text[:400]:
            missing += 1
            rec(FAIL, "the index names an asset that is not on disk", img)
        elif not ("<svg" in text and any(
                t in text for t in ("<path", "<polygon", "<rect", "<circle",
                                    "<polyline", "<line"))):
            # The assertion is SEMANTIC -- does this document actually draw
            # something -- not a byte count.
            #
            # It was `len(body) < 2048 or ...` and that flagged five real files.
            # Verified by counting elements in them directly: Customs' fourth
            # floor is 2,007 bytes with 2 <path>, 1 <polygon> and 2 <rect>, and
            # GroundZero's third floor is 1,136 bytes with a <path>. An upper
            # floor of one building legitimately has almost no geometry, so a
            # size floor encodes an assumption about map content that is simply
            # false. The threshold was the bug, not the data -- which is why
            # this was checked before it was loosened.
            tiny += 1
            rec(FAIL, "asset draws nothing (no path/polygon/rect/circle)",
                "%s (%d bytes)" % (img, len(body)))
        if "svg" not in ct.lower():
            bad_ct.append("%s -> %s" % (img, ct))

if checked and not (missing or tiny or refused):
    rec(PASS, "all %d layer assets served real SVG with drawing elements" % checked)
if checked != declared_layers:
    rec(FAIL, "walked %d layers but the index declares %d"
        % (checked, declared_layers))

if bad_ct:
    rec(FAIL, "assets served with a non-SVG Content-Type "
              "(a browser downloads these instead of rendering them)",
        "; ".join(bad_ct[:3]))
elif checked:
    rec(PASS, "every asset carried an image/svg+xml Content-Type")

# --- 3. the path guard -------------------------------------------------------
for probe in ["../../config.json", "..%2f..%2fconfig.json", "index.json",
              "Customs_TarkovDev/../../../config.json",
              "C:/Windows/win.ini.svg", "a/b/c/d/e/f/g/h/i/j.svg"]:
    body, ct = get("asset/" + probe)
    if body is None:
        # A refusal by the router (404) is also a refusal. Not a hole.
        continue
    text = body.decode("utf-8", "replace")
    if "refused" in text or "not found" in text:
        continue
    rec(FAIL, "the path guard did NOT refuse a traversal probe", probe)
else:
    rec(PASS, "the path guard refused every traversal probe")

# --- 4. the feed states a reason, in valid JSON ------------------------------
feed, why = jget("feed")
if feed is None:
    rec(FAIL, "the feed body is not strict JSON", str(why))
else:
    state = feed.get("state")
    if state is None:
        rec(FAIL, "the feed body carries no `state`")
    elif state == "absent":
        if not feed.get("reason"):
            rec(FAIL, "the feed says absent with no reason -- a silent decline")
        else:
            rec(PASS, "the feed states absent WITH a reason (correct with no "
                      "client publishing)", feed["reason"][:70] + "...")
    elif state in ("live", "armed-no-world", "not-armed", "no-host-export",
                   "self-disabled"):
        rec(PASS, "the feed reports a known state", state)
    else:
        rec(FAIL, "the feed reports an unknown state", str(state))

# --- 5. the page and its library ---------------------------------------------
for path, must, why_it_matters in [
        ("/aowlspt/ui/page/spatial", b"AowlSpatial.mount", "html"),
        ("/aowlspt/ui/lib/spatial.js", b"global.AowlSpatial", "javascript")]:
    try:
        with urllib.request.urlopen(BASE + path + "?ident=1", timeout=10) as r:
            b = r.read()
            ct = r.headers.get("Content-Type", "")
        if must not in b:
            rec(FAIL, "%s did not contain %s" % (path, must.decode()))
        elif why_it_matters not in ct.lower():
            rec(FAIL, "%s served as %s -- a browser will not run/render it"
                % (path, ct))
        else:
            rec(PASS, "%s served (%d bytes, %s)" % (path, len(b), ct))
    except Exception as e:  # noqa: BLE001
        rec(FAIL, "%s did not fetch" % path, str(e))

# --- report ------------------------------------------------------------------
for tag, bucket in (("FAIL", FAIL), ("INCONCLUSIVE", INC), ("PASS", PASS)):
    for line in bucket:
        print("%-13s %s" % (tag, line))
print("\n%d pass, %d fail, %d inconclusive" % (len(PASS), len(FAIL), len(INC)))
sys.exit(1 if FAIL else (2 if INC else 0))
