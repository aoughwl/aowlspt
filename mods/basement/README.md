# aowl.basement — Escape From My Basement

There is no main menu, no stash and no loadout screen: you are always in a
**world**. It is generated from a seed and a world prompt, and it is full of
people who keep living while you are gone — they talk, they remember you, they
deal, they rob you, they hire you, and they can take you prisoner and march you
across the map. The whole brain is in the backend, in nimony, where a mistake is
a bad HTTP response instead of a crashed raid.

* the design, and what is measured versus decided: **`DESIGN.md`**
* what the game client must send and obey: **`CLIENT-CONTRACT.md`**
* what each `bm/` module exports: **`bm/CONTRACT.md`**

## Turning it on

It ships **disabled**, for three reasons that are each worth agreeing to first:
it spawns whisper/piper subprocesses, it writes a persistent world and keeps
advancing it on a timer, and with `llmEngine` set to anything but `builtin` it
makes outbound calls to a paid API. So:

1. `mods/basement/config.json` → `"enabled": true`
2. rebuild — PowerShell, naming the target, through the lock:

   ```powershell
   $env:AOWLSPT_GAMEASM="D:\Aowlspt\GameAssembly.dll"
   python tools\buildlock.py --wait 1200 build-mod mods\basement
   ```

3. `python tools\basement_check.py` — the selfcheck plus a scripted story
   through the routes, PASS/FAIL/INCONCLUSIVE per step, exit 0/1/3.

Everything below works with **no game running**. That was the point of putting
it in the backend.

## The proof sequence, with curl

```bash
B=https://127.0.0.1/aowlspt/basement          # add -k for the self-signed cert

# 1. what is on and what resolved to which absolute path
curl -sk $B/status

# 2. a world. seed 7 is reproducible; omit "seed" and it picks one and tells you.
curl -sk -X POST $B/world/new -d '{"preset":"warlords","seed":7}'

# 3. who is in it (this is what the client spawns)
curl -sk "$B/world/people?map=Woods"

# 4. talk to one of them. text in -> a decision -> spoken segments.
curl -sk -X POST $B/say -d '{"person":"<id from step 3>","text":"hello there"}'

# 5. point a gun at them, and read what the world decided to do about it
curl -sk -X POST $B/observe -d '{"kind":"player_aimed_at","personId":"<id>"}'
curl -sk "$B/events?since=0&wait=0"     # npc.stance hostile, and a say

# 6. lower the weapon in front of a SLAVER and you are the property now
curl -sk -X POST $B/observe -d '{"kind":"player_lowered_weapon","personId":"<slaver id>"}'
curl -sk "$B/events?since=0&wait=0"     # player.captive {escortTo, leashM, ...}
curl -sk $B/world/person/<slaver id>    # a captivity contract, active

# 7. run for it. Past the leash is an escape attempt either way — the attempt
#    is the fact; whether you got away is a field on it.
curl -sk -X POST $B/observe -d '{"kind":"player_moved","map":"Woods","x":9999,"y":0,"z":0}'

# 8. or shoot your way out
curl -sk -X POST $B/observe -d '{"kind":"player_fired","personId":"<slaver id>"}'

# and the nine falsifiable checks of DESIGN.md §9, each PASS/FAIL/INCONCLUSIVE
curl -sk $B/selfcheck
```

The same sequence runs offline against the built DLL with no backend at all:

```powershell
host\Aowlspt.Sim\bin\aowlspt-sim.exe mods\basement --side server --store %TEMP%\bm `
  --route /aowlspt/basement/selfcheck
```

## What is NOT done

Keep this list honest; a demo that hides its edges is worse than no demo.

* **There is no client bridge.** Neither the aowlspt IL2CPP host side nor an
  SPT 4.1.5 plugin exists. Every directive on `/events` is a thing nobody
  executes yet — `CLIENT-CONTRACT.md` is the spec both will implement.
* **`GET /events?wait=` is a bounded poll on the request thread, not a parked
  socket.** The mod SDK exposes no sleep or condition variable. Every reply says
  which mechanism it used and how long it actually waited, so nobody has to
  guess; a real long-poll needs a host-side primitive that does not exist.
* **No LLM key on this machine.** `anthropic` is wired, probed and reported, and
  has never run end-to-end here. The default tier is `builtin`, which is a
  template responder and *not a language model* — every note it produces says so.
* **Bot actuation is a contract, not a behaviour.** `group.spawn`, `npc.follow`,
  `npc.attack` are directives the client must honour; the SAIN driver does not
  yet move live bots.
* **`mods/autoraid` does not consume `basement.raid.request`**, so
  `autoRaidRequests` is off: turning it on today emits an event nothing hears.
* Microphone capture is the client's job.
