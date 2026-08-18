# Debugging a native mod

The reason this system has a simulator at all is that the alternative edit loop
— build, start the SPT server, launch Tarkov, load into a raid, discover the mod
is wrong, kill everything, repeat — is measured in minutes, and a native crash
in that loop tells you almost nothing.

There are three levels here. Use the cheapest one that can see your bug.

## 1. The simulator, no debugger

```
powershell tools/aowlspt-build.ps1 -Mod examples/hello -Run -Side server
```

`aowlspt-sim` implements the same `IHostServices` the real hosts do, so a mod
cannot tell the difference except by asking `side()`. Most logic bugs die here.

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

## 2. The simulator, under a debugger

The mod is a normal native DLL in a normal process, so nothing exotic is needed.
Build with symbols:

```
powershell tools/aowlspt-build.ps1 -Mod examples/hello -DebugBuild
```

That passes `-g -O0` to the C compile and `-g` to the link. The generated C sits
in the mod's `nimcache/<hash>/` directory and the debug info points at it, so
you are stepping through nimony's output rather than your `.nim` source
directly — the function names survive, which is usually enough to tell you where
you are.

### gdb

```
gdb --args dotnet host/Aowlspt.Sim/bin/Release/net10.0/aowlspt-sim.dll examples/hello --side server
(gdb) set breakpoint pending on
(gdb) break aowlspt_init
(gdb) run
```

The breakpoint is pending because the DLL is not loaded until the host asks for
it. `break` on any exported symbol works the same way; for an internal proc,
look up the mangled name in the generated C first.

### Visual Studio

Debug → Attach to Process → the `dotnet` process, with **Native code** ticked in
"Attach to". Mixed mode also works and lets you step from `ModHost.TryLoad`
straight into the mod's `aowlspt_init`, across the ABI boundary, which is the
single most useful thing to be able to do when a load is failing.

## 3. In the real host

When the bug only reproduces in a raid.

Symbols must travel with the library or breakpoints will not bind. Both the
build script and `ModHost.ShadowCopy` copy `.pdb`/`.debug` alongside the DLL for
exactly this reason.

**The shadow copy matters here.** The host does not load your DLL — it loads a
copy of it, in `%TEMP%\aowlspt-shadow\`. That is what leaves the original
writable so a rebuild can overwrite it while the host is running. When you attach
a debugger and it asks which module you mean, it is the shadow copy that is
mapped.

### Calling a route from outside

`curl` cannot test an SPT route. SPT's listener reads every request body through
a zlib stream, so a plain body fails to inflate before any router runs and the
server answers 200 with an empty body — which looks like your mod returned
nothing. Use `sptprobe`, which speaks the protocol:

```
dotnet tools/SptProbe/bin/Release/net10.0/sptprobe.dll   https://127.0.0.1:6969/aowlspt/hello   --body-file body.json --session 000000000000000000000001
```

The session id must be 24 hex characters — SPT parses it as a MongoId and
rejects anything else with a message about `ObjectId`. Pass the body as a file:
Windows PowerShell strips double quotes from arguments to native executables,
so inline JSON arrives as `{probe:true}` and SPT reports it as malformed.

To exercise the whole server-side integration in one command, without touching
your install, see `tools/aowlspt-verify-live.ps1`.

### Server

The server host is a normal .NET process. Attach to `SPT.Server.exe` with native
debugging enabled. `AOWLSPT_MODS` overrides the mod directory, so you can point
a running install at your build output without copying anything:

```
set AOWLSPT_MODS=C:\Users\savant\Projects\aowlspt\examples
```

### Client

Attach to `EscapeFromTarkov.exe`. Unity's Mono runtime makes managed debugging
awkward, but the native side is unaffected — a breakpoint in your mod's code
behaves normally.

## Reading a failure

**The mod does not load.** The host logs why before it gives up, and the order of
the load sequence is chosen so the message is specific:

| message | meaning |
|---|---|
| `ABI v2, host speaks v1` | rebuild the mod against this host's header |
| `does not export 'aowlspt_init'` | `exportMod` is missing, or not last in the file |
| `LoadLibrary failed (error 126)` | a *dependency* is missing, not the file itself |
| `not built for the server side` | add the side to `sides = {...}` |
| `describe failed` | `aowlspt_describe` returned non-OK |

Error 126 is worth calling out: Windows reports "module not found" both for a
missing DLL and for a DLL whose own imports cannot be resolved. If the file is
clearly there, run `objdump -p yourmod.dll | grep 'DLL Name'` and check each one.

**A mod faults at run time.** The host marks it `Faulted`, logs the message, and
stops dispatching to it. The rest of the server keeps running — a broken mod
should cost you that mod, not the raid. Look for `faulted, mod disabled` in the
log.

**A host call returns non-OK.** `lastError()` carries the host's own text for the
most recent failure on this thread, and every helper sets it. Log it; the status
code alone rarely tells you enough:

```nim
if st != Ok:
  warn "patch failed: " & lastError()
```

## Things that will bite

**Slices are borrowed.** A slice handed to a callback is valid only for that
call. The library copies into a string before you ever see one, so you have to
work at getting this wrong — but if you drop to the raw ABI, that is the rule.

**Strings are SSO.** A nimony string keeps short contents inline in the string
object, so a pointer into it dies when the object moves. This is why `slice()`
takes `{.byref.}` and why `toString` uses `beginStore`/`endStore` instead of
`addr s[0]`. It cost an afternoon to find the first time: the round trip
returned four bytes of garbage rather than crashing.

**The allocator belongs to the host.** A mingw-built DLL and a .NET host do not
share a CRT heap. Anything crossing the boundary is allocated with `host.alloc`
and freed with `host.free`. `allocBuffer`/`takeBuffer` are the only two places
this has to be got right.

**Unity's main thread.** Touching a GameObject from a worker thread throws, or
worse, silently corrupts. Use `onMainThread` from any thread that is not the
frame loop.
