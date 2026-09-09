# Getting past character-select: the host does it, not the launcher

**The default since 2026-09-02: the launcher writes NOTHING to the live
inspector at boot.** The host answers the character/mode screen natively. Pass
`--auto-enter` to `aowlspt-launch.exe` if you want the launcher to drive that
screen instead.

## The two paths

**The host path (default).** `host/Aowlspt.Host.Il2Cpp/modeskip.nim`, gated by
`uxSkipModeScreen` in `aowlspt-host.json`, calls `Submit` for the bound profile
from inside the client. It runs on the Unity main thread, needs no channel, no
polling and no file, and it lands at ~26s of a normal boot. Its line in
`aowlspt-host.log` is:

```
skip mode screen: Submit called for profile <id>
```

**The launcher path (`--auto-enter`).** `tools/aowllaunch.nim` waits for the
`CharacterSelectionScreen` to be up and presses the "PvE" slot through the
live-inspector file channel, using `tools/aowlui.nim`. Keep it for debugging
the selector itself, or for a build where `uxSkipModeScreen` is off.

## Why the default flipped

Measured on a normal boot, auto-enter wrote nine batches into
`aowlspt-inspect.txt` in the first 22 seconds: eight `roots` polls and then a
58-command batch carrying `allow write` and 29
`call name:get_activeInHierarchy`. That is a call into game code that nobody
asked for, on a channel that has exactly ONE command file and no arbitration
beyond a lock, at the same moment the host was already doing the same job. It
also left that 58-command probe batch on disk, where the next boot's host reads
it first.

Doing a job twice is only cheap when the second attempt is free. This one cost
the channel: any tool driving the inspector during those 22 seconds had its
batch delayed or dropped.

## What `--auto-enter` does now, when you do pass it

Three things changed at the same time as the default, because the traffic was
worth fixing whether or not it is on by default:

* **The readiness poll is READ-ONLY.** It is `roots` + `children` with no
  `allow write` and no call into game code, and it is what runs for the whole
  cold-boot minute while the answer is "the screen is not there yet".
* **The `allow write` batch only fires once the selector node exists.**
  `activeInHierarchy` is reachable only through
  `call name:get_activeInHierarchy`, and the host gates every `call` behind
  `allow write` -- so confirming the screen is UP genuinely needs a write
  batch. It is now a separate batch from the readiness poll and from the press,
  and it is not issued when there is nothing to confirm.
* **The command file is blanked when the launcher is done**, on every exit path
  -- pressed, already past it, timed out, no channel. If another writer holds
  the channel lock at that moment the file is left alone and the launcher says
  so, because clobbering someone else's in-flight batch is the collision the
  lock exists to prevent.
* **Every batch names its writer.** Sentinels are
  `aowl-batch-launch<pid>-<ms>-<n>`, the convention
  `plugins/aowlsptcode/mcp/channel.py` uses. The sentinel is the only part of a
  batch that reaches the host log (the host echoes `> echo aowl-batch-...` and
  skips `#`-prefixed serial lines), so unattributed traffic previously had to
  be traced to its writer by the SHAPE of the sentinel. It is a grep now.

## Flags

| flag | effect |
|---|---|
| *(none)* | the host answers character-select; the launcher writes nothing to the channel |
| `--auto-enter` | the launcher drives character-select over the inspector channel |
| `--no-auto-enter` | accepted and ignored -- it asks for what already happens. Kept so existing scripts and shortcuts keep working |

The launcher says which it chose, once, on stdout and in
`aowlspt/aowlspt-autoenter.log`:

```
auto-enter verdict: OFF (default) -- the host answers character-select
natively (uxSkipModeScreen, modeskip.nim); pass --auto-enter to drive it from
the launcher instead
```

`aowlspt-launch --dry-run` prints the same decision as a `would enter` line in
its plan, from the same option the real run branches on.

## The test, and what it does not cover

`python tools/test_autoenter.py` drives the real launcher binary against a
scratch install: the default plan enters nothing, `--auto-enter` flips it (the
positive control), `--no-auto-enter` is still accepted, and a real default run
leaves no `aowlspt-inspect.txt` -- with `channel.py` writing into the same
directory as the control that proves the detector is looking in the right
place.

**Not covered:** no client is booted, so the `--auto-enter` side of "and then it
writes" is NOT exercised. The auto-enter block only runs after a successful
process start and a successful host injection into a real IL2CPP client.
Proving the write side needs a live boot with `--auto-enter` and a grep of
`aowlspt-inspect.txt` for an `aowl-batch-launch<pid>-` sentinel.
