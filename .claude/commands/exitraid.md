---
description: Leave an in-progress raid and get back to the main menu
---

Get the client out of a raid and back to the main menu.

**Recall first:** `recipe_get("exit-raid-to-menu")`. Load
`.claude/skills/aowl-inspector/SKILL.md` before touching the UI.

**Precondition, not yet automated:** the in-raid ESC menu must already be **open**.
It is built on demand — while closed it is genuinely not in the tree
(`find EscapeMenu` under `Common UI` returns EXHAUSTIVE / NOT PRESENT, so that is
real absence, not a truncated walk). A human pressing ESC is currently the only
way in. **Do not synthesise a key press.**

To automate it properly, find and call the game's own open-in-raid-menu method
rather than hunting for a node that only sometimes exists — by-name resolution
works now through `aowlspt-names.idx`.

Then:

1. `DISCONNECT` under `Common UI` → `MenuScreen/RaidButtonsGroup/DisconnectButton`.
2. `CONFIRM LEAVE` under `Common UI` → `ReconnectionScreen/LeaveButton`.
3. `NEXT` under **`Session End UI`** — a scene root that exists only after leaving
   a raid. `Menu UI` is gone and `Common UI` has no `NEXT`; 0 hits there with a
   COMPLETE walk means wrong tree. Press it repeatedly; the `NextButton`
   GameObject is **rebuilt on each results page**.

**Check `activeInHierarchy` before every press.** `MenuScreen/RaidButtonsGroup`
persists into the raid while inactive, and pressing an inactive control reports
success and does nothing — measured, twice, with the client still in the raid.

Two independent signals that a press did something, and you want both: the target
was `active=True` *before* pressing, and its GameObject pointer **changed**
afterwards. `ok=True` alone means only "the handler did not fault."
