"""The three cheap route defects, asserted over the wire on the finished state.

Each check is a NEGATIVE about what the served payload may not be, and each is
falsifiable by the build that had the defect:

  1 `/client/items/prices` with NO trailing slash must not 404, and must carry a
    non-empty `prices` map. `servePrefix` requires a trailing slash, so the bare
    spelling -- which IS a literal in the client's own string table, measured:
    it occurs twice in the decrypted `global-metadata`, once bare and once with
    the slash -- matched nothing.
  2 `/client/airdrop/loot` must not 404. Measured: that literal occurs ONCE in
    the client's metadata and `/client/location/getAirdropLoot`, which is what
    this server served, occurs ZERO times.
  3 `/client/mail/dialog/info` for a dialog that EXISTS must not answer `{}`.
    It was served by `onEmptyObject`, and an empty header for a real dialog is
    a wrong answer rather than an empty one: the client draws the row with no
    preview and no unread badge.

Strict `json.loads` throughout, `Accept-Encoding: identity` throughout.

    python tools/routeproof.py --dll PATH
"""

import argparse
import json
import sys

import xferproof as X


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll", required=True)
    args = ap.parse_args()

    fails = []
    X.stage(args.dll)
    with X.Backend():
        _, made = X.call("/aowlspt/tarkov/launcher/profile/create",
                         {"nickname": "RouteProof", "side": "Usec"})
        token = made.get("token") or ""
        pid = (made.get("profile") or {}).get("id") or token
        if not token:
            print("[INCONCLUSIVE] no profile could be made: %r" % made)
            return 1

        # 1 -------------------------------------------------------------
        st, bare = X.call("/client/items/prices", {}, token)
        prices = (bare.get("data") or {}).get("prices")
        if st == 404:
            fails.append("/client/items/prices (no trailing slash) is NOT "
                         "SERVED: 404")
        elif bare.get("err"):
            fails.append("/client/items/prices (no trailing slash) answered "
                         "err=%r errmsg=%r" % (bare.get("err"),
                                               bare.get("errmsg")))
        elif not isinstance(prices, dict) or not prices:
            fails.append("/client/items/prices (no trailing slash) carried no "
                         "prices map: %s" % json.dumps(bare)[:200])
        else:
            print("[PASS] /client/items/prices  -> %d prices" % len(prices))

        # 2 -------------------------------------------------------------
        st, air = X.call("/client/airdrop/loot", {}, token)
        if st == 404:
            fails.append("/client/airdrop/loot is NOT SERVED: 404 -- and it is "
                         "the only airdrop route this client ever asks for")
        elif air.get("err"):
            fails.append("/client/airdrop/loot answered err=%r errmsg=%r"
                         % (air.get("err"), air.get("errmsg")))
        else:
            print("[PASS] /client/airdrop/loot -> served")

        # 3 -------------------------------------------------------------
        # Make a dialog exist first, by ending a raid that hands items over --
        # the same mechanism P0 restores. Then ask for that dialog's header.
        _, prof = X.call("/client/game/profile/list", {}, token)
        pmc = None
        for doc in (prof.get("data") or []):
            if doc.get("_id") == pid:
                pmc = doc
        if pmc is None:
            print("[INCONCLUSIVE] no PMC in profile/list; dialog/info not tested")
            return 1
        X.call("/client/match/local/end", {
            "serverId": "ROUTEPROOF_1", "lostInsuredItems": [],
            "results": {"profile": pmc, "result": "Survived", "exitName": "RUAF",
                        "inSession": True, "playTime": 60},
            "transferItems": {pid: X.CARRIED}, "locationTransit": None}, token)
        _, listed = X.call("/client/mail/dialog/list", {}, token)
        rows = listed.get("data") or []
        if not rows:
            # Note WHY this is inconclusive rather than a pass: on a build that
            # drops `transferItems`, the raid above posts nothing, so there is
            # no dialog to ask about. "I could not look" is not a pass.
            fails.append("INCONCLUSIVE: the mailbox has no dialog to ask "
                         "about, so mail/dialog/info was not exercised")
        want = rows[0] if rows else None
        head = None
        if want is not None:
            _, info = X.call("/client/mail/dialog/info",
                             {"dialogId": want.get("_id")}, token)
            head = info.get("data")
        if want is None:
            pass
        elif not isinstance(head, dict) or not head:
            fails.append("mail/dialog/info answered %s for dialog %r, which "
                         "IS in dialog/list" % (json.dumps(head),
                                                want.get("_id")))
        elif head.get("_id") != want.get("_id") or not head.get("message"):
            fails.append("mail/dialog/info answered a header that is not that "
                         "dialog's: %s" % json.dumps(head)[:200])
        else:
            print("[PASS] /client/mail/dialog/info -> header for %r with "
                  "attachmentsNew=%s" % (head.get("_id"),
                                         head.get("attachmentsNew")))

        # 4 -------------------------------------------------------------
        # An action this server has never heard of must still be REPORTED.
        # The batch must not abort -- that property is asserted too, by
        # sending a real `Examine` alongside and requiring it to be applied --
        # but the unknown one must reach the player's warnings list, not just
        # a log line. `err:0` with an empty `warnings` is the defect.
        _, ev = X.call("/client/game/profile/items/moving", {"data": [
            {"Action": "AowlNoSuchActionEverInvented", "item": "x"},
            {"Action": "Examine", "item": "5449016a4bdc2d6f028b456f"},
        ]}, token)
        warns = ((ev.get("data") or {}).get("warnings") or [])
        said = [w.get("errmsg", "") for w in warns]
        named = [m for m in said if "AowlNoSuchActionEverInvented" in m]
        if ev.get("err") not in (0, None):
            fails.append("the batch was aborted by one unknown action: err=%r"
                         % ev.get("err"))
        elif not named:
            fails.append("an unknown action produced no warning the client can "
                         "see; warnings were %r" % said)
        elif "nothing was done" not in named[0]:
            fails.append("the warning names the action but does not say it did "
                         "nothing: %r" % named[0])
        else:
            changes = (ev.get("data") or {}).get("profileChanges") or {}
            if not changes:
                fails.append("the unknown action was reported but the rest of "
                             "the batch was dropped: no profileChanges")
            else:
                print("[PASS] unknown action -> %r" % named[0])

    for f in fails:
        print("[FAIL]", f)
    print("RESULT:", "ok" if not fails else "not ok")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
