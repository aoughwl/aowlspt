---
name: empirical-debugging
description: The debugging method for aowlspt — make the client tell you, rather than reasoning about source. Load whenever something in the running game is wrong (a feature does not appear, bots do not spawn, UI text is wrong, a route misbehaves, the game seems to have crashed) and before proposing any fix derived only from reading code. Also covers the false-crash trap where an idle game looks like a hung one.
---

# Debug empirically. Do not reason from source.

The rule was learned expensively: on one bug, **six** attempts that reasoned from
the source all failed, and the **first two** empirical attempts solved it inside
an hour. Source reasoning in this codebase is unreliable because the thing you
are reasoning about is a stripped IL2CPP binary whose behaviour is not in any
source you can read.

So: before you form a hypothesis, get the system to emit a fact.

## The four instruments, cheapest first

### 1. Read the logs we already write — with `hostlog.py`

The host **truncates its log at every start**, so `aowlspt-host.log` is always
exactly one run. Use the tool rather than ad-hoc greps:

```powershell
python tools\hostlog.py summary      # did it boot? what broke?
python tools\hostlog.py faults
python tools\hostlog.py feature <name>
python tools\hostlog.py summary --backend
```

`summary` separates features that **turned themselves off** (a self-disable after
N faults — a real failure) from mere warnings. Keep that distinction in any report.

Raw files, if the tool is not on your branch:
`aowlspt-host.log` (the host says what it refuses and why, step by step),
`aowlspt-backend.log`, `nettrace.log` — all in `D:\Aowlspt\aowlspt\`.

### 2. Make the client log for itself

The client knows far more about what it just did than you can infer. Read the
newest directory under `D:\Aowlspt\Logs\`:

```powershell
Get-ChildItem D:\Aowlspt\Logs | Sort-Object LastWriteTime | Select-Object -Last 1
```

`tools/ailog.py` raises the client's own log level — but it **exists only on some
branches**, so check before relying on it. When changing log levels by hand,
remember the consistency-check landmine: level names must keep the same character
length. See the `aowlspt-deploy` skill.

### 3. Probe the payload on the wire

If the question is "did the server send what I think it sent", do not read the
server. Read the bytes. `tools/bsgwire.py` and `tools/bsgaes.py` decode the
post-1.0 envelope in both directions; `nettrace.log` has the traffic. A route
that "should" return the right shape and a route that *did* are different claims.

### 4. Instrument with a read-only guarded detour

When nothing else can see it, add a temporary detour that only *reads* and logs.
It must obey every rule in the `il2cpp-host` skill — prologue verify, pointer
validation, one SEH guard, capped iteration, flag-gated OFF by default. A probe
that crashes the game has told you nothing and cost you a session.

Delete probes once they have answered, or gate them behind a flag that stays off.

## The false crash

**The game takes over 60 seconds to reach profile-select, and then waits
indefinitely for a human.**

Consequences, all of which have wasted real time this project:

- A process check at 20 seconds reads "gone" because the process has not spawned
  yet, not because it died.
- An idle game sitting at profile-select is **indistinguishable** from a hung one
  by process state, window title, or CPU.
- Several "crashes" chased in one session were simply an undriven game.

**Use `tools/harness.py` — it solves exactly this.** It launches, waits and
captures with no human, tracking the sentinel, log progress and a stall clock
rather than a bare timer, so it reports `IDLE` (alive, waiting for a person)
separately from `TIMEOUT` (genuinely stopped):

```powershell
python tools\harness.py run --until "host running"
python tools\harness.py run --profile <name>     # drive past the picker
```

`IDLE` is not a failure. Say the game is waiting and ask for a human, or re-run
with `--profile`.

By hand, if the harness is not on your branch:

1. Wait **90 seconds or more** before concluding anything about the process.
2. Confirm `aowlspt-host.log` has actually **stopped progressing** — compare the
   tail twice, a good interval apart. A log still gaining lines is a live game.
3. Read the client's own log in `D:\Aowlspt\Logs\` for a real exception.
4. Only then call it a crash.

Never report "the game crashed" on the strength of a process check alone. Say
what you observed: "no new host-log lines for N seconds, last line was X".

## How to report a finding

State the observation and the instrument separately from the conclusion:

> `aowlspt-host.log` line 412 says `settingsBindProbe: container null`. The probe
> read offset 0x78 on the screen object. Therefore the container is not reachable
> at that offset on this build.

Not: "the container offset is wrong". The first can be checked by someone else;
the second cannot.
