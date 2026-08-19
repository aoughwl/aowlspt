# Debugging a native mod

The reason this system has a simulator at all is that the alternative edit loop
— build, start the SPT server, launch Tarkov, load into a raid, discover the mod
is wrong, kill everything, repeat — is measured in minutes, and a native crash
in that loop tells you almost nothing.

There are three levels here. Use the cheapest one that can see your bug.

## 0. `aowl doctor`

Before any of the below, when it is the *build* behaving strangely rather than
the mod:

```
aowl doctor
```

Every check in it caught something real once, and each of those failed by
pointing somewhere else. The sharpest is PATH order — a Git-for-Windows
`mingw64` ahead of `C:\msys64\ucrt64\bin` gives gcc a `cc1` that loads the wrong
libgcc and **dies with no diagnostic at all**, which reads as a broken compiler
rather than a broken PATH. It also tells you when the C headers have changed
under a build cache, which otherwise links yesterday's ABI into today's mod.

## 1. The simulator, no debugger

```
aowl run examples/hello
```

`aowlspt-sim` loads a mod through the same `host/common/modhost.nim` the two
real hosts use, and answers routes, the database, events, timers, config and
the **store** with the same code the backend does. Most logic bugs die here.
What it cannot do it refuses rather than fakes: `patch` and `patch_typed` have
no compiled game code to detour, `handle_pointer` and `handle_pin` have no
managed heap to address, and `call` answers only what you scripted with
`--stubs`.

Script the parts that would otherwise need a server:

```
aowlspt-sim examples/backend --side server \
  --db examples/backend/testdb.json \
  --stubs examples/backend/stubs.json \
  --route /aowlspt/backend/status \
  --emit aowlspt.ping,{"n":1}
```

- `--db FILE` — a JSON file served as the SPT database, so `dbGet`/`dbPatch`
  work with data you control and can diff afterwards.
- `--stubs FILE` — a map of `"Type::Member"` to canned results, so `call`
  returns what a real server would without one being present.
- `--route`, `--emit` — drive a route or publish an event and print what came
  back.
- `--store DIR` — where the mod's store lives. The default is
  `%TEMP%\aowlspt-sim\<mod>` and it **persists between runs**, so "save, exit,
  come back and it is still there" is testable; delete the directory to reset.
- `--watch --ticks 0` — the loop to leave open while editing.

`aowl run` builds the mod and runs `aowlspt-sim` on it with defaults. To pass any
of the options above, build with `aowl build-mod` and invoke `aowlspt-sim`
yourself.

## 2. The simulator, under a debugger

The mod is a normal native DLL in a normal process, so nothing exotic is needed.
Build with symbols:

```
aowl build-mod examples/hello --debug
```

That builds with debug info and no optimisation. The generated C sits
in the mod's `nimcache/<hash>/` directory and the debug info points at it, so
you are stepping through nimony's output rather than your `.nim` source
directly — the function names survive, which is usually enough to tell you where
you are.

### gdb

```
gdb --args host/Aowlspt.Sim/bin/aowlspt-sim.exe examples/hello --side server
(gdb) set breakpoint pending on
(gdb) break aowlspt_init
(gdb) run
```

The breakpoint is pending because the DLL is not loaded until the host asks for
it. `break` on any exported symbol works the same way; for an internal proc,
look up the mangled name in the generated C first.

### Visual Studio

Debug → Attach to Process → the `aowlspt-sim.exe` process, with **Native code**
ticked in "Attach to". Everything in that process is native now — the simulator
is nimony, like the mod — so you can step from `loadMod` in
`host/common/modhost.nim` straight into the mod's `aowlspt_init`, across the ABI
boundary, which is the single most useful thing to be able to do when a load is
failing.

## 3. In the real host

When the bug only reproduces in a raid.

Symbols must travel with the library or breakpoints will not bind.

**Only `--watch` loads a copy.** `aowlspt-sim --watch` loads the library out of
`<store>/shadow/`, because Windows locks a mapped DLL and the file you are
editing has to stay writable for the next build to land — so under `--watch`,
when a debugger asks which module you mean, it is that copy.

Every other run loads the file where it sits, and so do both real hosts —
`aowlspt-backend` and the IL2CPP client host. The module you attach to is then
the one you built, and rebuilding over it while the host
runs fails with a sharing violation. Stop the host first.

### Calling a route from outside

`curl` cannot read an answer from this server. This page used to say the reason
was the *request* side — "the listener reads every request body through a zlib
stream, so a plain body fails to inflate before any router is consulted". That
is not what happens, and this page contradicts it two paragraphs down:
`inflateBody` (`backend/aowlbackend.nim:217-229`, re-read 2026-08-19) checks the
two-byte zlib header and passes an unframed body straight through. The reason is
the **response**, which is deflated unless the caller sent `Accept-Encoding:
identity` — so what comes back is a 200 `curl` cannot read, which looks like your
mod returned nothing. Use `aowlprobe`, which speaks the protocol:

```
installer\build\aowlprobe.exe http://127.0.0.1:6969/aowlspt/status --expect '"ok":true'
```

The session id must be 24 hex characters. `aowlbackend.nim` reads it as a
MongoId and refuses anything else **before any route sees it**, so a malformed
id is never reported as your mod's bug.

`aowlspt-backend` accepts an *unframed* request as well, deliberately: the tools
people debug with do not compress, and refusing them would make the server
untestable by hand. The check is the two-byte zlib header, not a guess.

`aowlprobe --body TEXT` sends a body and `--expect TEXT` makes the process exit
non-zero unless the response contains it, which is what makes it usable in a
gate. Beware of Windows PowerShell here: it strips double quotes from arguments
to native executables, so inline JSON arrives as `{hi:1}` and is reported as
malformed. Escape them, or drive the probe from a script file.

To exercise the whole server-side integration in one command, without touching
your install, see `aowlspt-verify` (`tools/verifyinstall.nim`, built by `aowl
build` into `installer\build\aowlspt-verify.exe`).

### Backend

`aowlspt-backend` is an ordinary native process, so attach to it or start it
under gdb; there is no managed runtime in the way at all. It loads mods out of
`<root>/mods`, so point `--root` at a scratch directory holding your build
rather than at an install.

There is no environment variable that redirects the mod directory. `--root` is
the whole of it.

### Client

Attach to `EscapeFromTarkov.exe`. Post-1.0 there is no Mono runtime and no
managed debugging to be awkward about — the host and every mod in it are native
code, so a breakpoint in your mod behaves like a breakpoint in any DLL. What you
will not get is a managed stack: `il2cpp_runtime_invoke` and the compiled game
bodies under it are C as far as the debugger is concerned.

`aowlspt-launch --root D:\Aowlspt` starts the game suspended, injects the host
and resumes. It terminates the client rather than resuming one whose host failed
to load — being in a raid before noticing the mods are missing is worse than not
starting. For anything that happens during load, read
`aowlspt/aowlspt-host.log` before reaching for a debugger; the host reports each
step it refuses and why.

None of this has been done against BSG's client. The host has been run against a
stand-in runtime that exports the same C API, which is a different claim.

## Reading a failure

**The mod does not load.** The host logs why before it gives up, and the order of
the load sequence is chosen so the message is specific. Every host shares
`host/common/modhost.nim`, so the wording below is the same in the backend, the
client host and the simulator:

| message | meaning |
|---|---|
| `could not load <path> (error 126)` | a *dependency* is missing, not the file itself |
| `does not export the aowlspt entry points` | `exportMod` is missing, or not last in the file |
| `was built against ABI version N; this host implements M` | rebuild the mod against this host's header |
| `<name>: describe failed` | `aowlspt_describe` returned non-OK |
| `<name> does not support the server side; skipping` | add the side to `sides = {...}` |

Error 126 is worth calling out: Windows reports "module not found" both for a
missing DLL and for a DLL whose own imports cannot be resolved. If the file is
clearly there, run `objdump -p yourmod.dll | grep 'DLL Name'` and check each one.

**A mod faults at run time.** This page used to say the host marks it `Faulted`,
logs the message and stops dispatching to it, and told you to look for
`faulted, mod disabled` in the log. **No such mechanism and no such log line
exist.** Re-derived 2026-08-19: nothing under `host/` carries a faulted mod
state, the string appears nowhere in the tree, and `modhost.tickMods`
(`host/common/modhost.nim:938-941`) is three lines that `discard` whatever
`on_update` returned. A mod that answers non-`Ok` every tick does so silently
and keeps being ticked.

What survives of the claim is the part about the ABI: nothing crosses this
boundary as an exception, so a mod that returns a failure returns a *status*,
and the host carries on. The consequence is the opposite of what was written —
the failure you will see is silence rather than a log line, or the whole process
going if the mod faults hard. Check the status in your own `on_update` and log
it yourself. Marking a mod dead after repeated non-`Ok` is a host change, not a
documentation one; it is not in this repository today.

**A host call returns non-OK.** `lastError()` carries the host's own text for the
most recent failure on this thread, and every helper sets it. Log it; the status
code alone rarely tells you enough:

```nim
if st != Ok:
  warn "patch failed: " & lastError()
```

**A capability answers `ErrUnsupported`.** That is an answer, not a broken build.
Every host fills the entries it cannot honour with a refusing implementation
rather than leaving them null — the backend does it for `handle_pointer`,
`handle_pin` and `patch_typed` before raising its watermark to revision 5, the
simulator does the same three before stopping at revision 4, and every host does
it for the rev-1 entries it has no runtime behind. So `AowlHostApi.size`
reaching a revision's boundary means "there is a function here that will
answer", never "the answer is yes". Test the boundary to find out whether you
may call it, and read the status to find out what it said.

## Things that will bite

**Slices are borrowed.** A slice handed to a callback is valid only for that
call. The library copies into a string before you ever see one, so you have to
work at getting this wrong — but if you drop to the raw ABI, that is the rule.

**Strings are SSO.** A nimony string keeps short contents inline in the string
object, so a pointer into it dies when the object moves. This is why `slice()`
takes `{.byref.}` and why `toString` uses `beginStore`/`endStore` instead of
`addr s[0]`. It cost an afternoon to find the first time: the round trip
returned four bytes of garbage rather than crashing.

**The allocator belongs to the host.** A mod DLL and its host are separate
modules with their own CRT state, and a buffer allocated on one side and freed
on the other is a crash somewhere else entirely, later, under load. Anything
crossing the boundary is allocated with `host.alloc` and freed with `host.free`.
`allocBuffer`/`takeBuffer` are the only two places this has to be got right.

**Unity's main thread.** Touching a GameObject from a worker thread throws, or
worse, silently corrupts. Use `onMainThread` from any thread that is not the
frame loop — and on the IL2CPP host, check what it actually gave you. It drains
from inside a per-frame method the host detoured, which is Unity's thread when
one of its candidates binds and the host's own when none does.
`call("aowlspt.host::main_thread")` answers, and `bound` is true only once the
hook has fired. The boot log says the same thing. See [IL2CPP.md](IL2CPP.md).

**A zeroed global.** In a nimony `--app:lib` build a global initialised by a
*call* is silently left zeroed. This has cost hours more than once. `gameType`
is a template to dodge it; `aowlspt/fast`'s bindings cannot be, so assign them
from inside a proc. The symptom is an API that reports "no such type: " with
nothing after the colon, or a `Binding` whose `ok` is never true.

**A raw pointer held across a frame.** The collector moves objects. `GameObj`
holds a GC handle for exactly this reason; the fast path hands you a raw pointer
and makes it your problem. Resolve it fresh each frame.
