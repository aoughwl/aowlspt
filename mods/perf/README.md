# aowl.perf

Engine-level performance settings for post-1.0 (IL2CPP) Escape from Tarkov,
written entirely against `aowlspt`, `aowlspt/game` and `aowlspt/fast`.

```
aowl build-mod mods/perf
aowl run mods/perf                     # the simulator self-test
```

## Read this before you turn anything on

**Nothing in this mod has ever run against BSG's client.** Every type name and
every property name here is a hypothesis until the runtime answers it. Post-1.0
Tarkov is IL2CPP with managed code stripping on, so a Unity property setter that
no code in the game calls can be missing from the shipped build entirely — and
"missing" is a perfectly ordinary answer that this mod is built to receive.

So: every knob resolves by name at runtime, refuses cleanly when the name is
absent, logs what it refused and why, and is off until you turn it on. Every
change it makes is read back and reversible. The frame-rate numbers in the log
are real measurements; the claim that any particular knob makes *Tarkov* faster
is not, because it has only ever been measured against a stand-in runtime.

## What it applies

Everything below is `{"apply": false, "value": …}` in `config.json` as shipped.
Turning one on asks the mod to try; the log then says whether it could.

| config path | Unity property | what it buys | what it costs visually |
|---|---|---|---|
| `quality.shadowDistance` | `QualitySettings.shadowDistance` | the largest single GPU win here — shadow map draw calls scale with the volume covered | distant objects stop casting shadows; the cut-off edge is visible if you set it very low |
| `quality.shadowCascades` | `QualitySettings.shadowCascades` | fewer cascades, fewer shadow map renders per frame | coarser shadows further out, and a visible seam where a cascade changes |
| `quality.shadowResolution` | `QualitySettings.shadowResolution` (enum) | smaller shadow maps | softer, blockier shadow edges |
| `quality.lodBias` | `QualitySettings.lodBias` | swaps to cheaper meshes sooner | distant models are visibly coarser. **Band floor is 0.5 and the mod refuses below it** — a very low bias can push a `LODGroup` into its culled band, and a model that disappears is a correctness bug, not a setting |
| `quality.maximumLODLevel` | `QualitySettings.maximumLODLevel` | skips the highest-detail mesh entirely | everything is one LOD step coarser, close up included |
| `quality.textureMipmapLimit` | `QualitySettings.globalTextureMipmapLimit`, falling back to the older `masterTextureLimit` | drops the top mip; large VRAM saving | textures are visibly softer |
| `quality.anisotropicFiltering` | `QualitySettings.anisotropicFiltering` (enum) | cheaper texture sampling at glancing angles | ground and wall textures blur into the distance |
| `quality.pixelLightCount` | `QualitySettings.pixelLightCount` | fewer per-pixel lights in forward rendering | some lights become vertex-lit or stop contributing |
| `quality.particleRaycastBudget` | `QualitySettings.particleRaycastBudget` | fewer raycasts for colliding particles | particle collisions get approximate |
| `quality.softParticles` | `QualitySettings.softParticles` | removes a depth-buffer read per particle | hard edges where smoke meets geometry |
| `quality.realtimeReflectionProbes` | `QualitySettings.realtimeReflectionProbes` | stops re-rendering reflection probes | reflections go stale |
| `quality.billboardsFaceCameraPosition` | `QualitySettings.billboardsFaceCameraPosition` | cheaper billboard orientation | distant tree billboards rotate slightly differently |
| `quality.skinWeights` | `QualitySettings.skinWeights` (enum) | fewer bones per vertex when skinning characters | joints deform less smoothly, most visible at shoulders |
| `quality.vSyncCount` | `QualitySettings.vSyncCount` | 0 uncaps the frame rate and removes a frame of latency | tearing |
| `quality.maxQueuedFrames` | `QualitySettings.maxQueuedFrames` | fewer frames buffered ahead of the GPU: lower input latency | can lower average fps on a GPU-bound machine |
| `quality.streamingMipmapsActive` | `QualitySettings.streamingMipmapsActive` | mip streaming; a large VRAM saving on a card that is short of it | texture pop-in while mips load |
| `quality.streamingMipmapsMemoryBudget` | `QualitySettings.streamingMipmapsMemoryBudget` | the streaming budget in MB | too low and everything is permanently blurry |
| `quality.asyncUploadTimeSlice` | `QualitySettings.asyncUploadTimeSlice` | ms per frame spent uploading textures; lower means fewer loading hitches and slower loads | none, it is a scheduling knob |
| `quality.asyncUploadBufferSize` | `QualitySettings.asyncUploadBufferSize` | the ring buffer for those uploads, in MB | none |
| `quality.asyncUploadPersistentBuffer` | `QualitySettings.asyncUploadPersistentBuffer` | keeps the buffer alive between loads | none |
| `app.targetFrameRate` | `Application.targetFrameRate` | caps the frame rate. This does not raise fps — it stabilises frame *time*, and it stops the GPU heating the room in a menu | none |
| `time.fixedDeltaTime` | `Time.fixedDeltaTime` | how often `FixedUpdate` and physics run. Raising it from 0.02 to 0.0222 is a 10% cut in physics CPU | **this is a gameplay change, not a graphics one.** Band is 1/120 s .. 1/30 s and values outside it are refused |
| `time.maximumDeltaTime` | `Time.maximumDeltaTime` | caps how much physics catch-up one slow frame can trigger, which is what turns a hitch into a spiral | physics slows down rather than catching up after a long stall |

Rules the applier follows, in order of how much they matter:

1. **A knob that cannot be read is never written.** The original is what makes
   the change reversible, and a change that cannot be undone is not made.
2. **A value outside the band is refused, not clamped.** Clamping a typo into a
   plausible number hides the typo.
3. **Every write is read back, including the restore.** Unity clamps several of
   these itself — `shadowCascades` snaps to 0, 2 or 4 — so "the setter did not
   error" is a weaker claim than "the setting is what I asked for", and the log
   distinguishes them:
   `applied 4.000 -> 4.000 [asked for 3.000; the engine clamped it to 4.0]`. The
   restore is checked the same way, which it was not before: a value that did not
   go home says so instead of being counted as a success.
4. **Nothing is written from the wrong thread.** Unity API is main-thread-only.
   `onUpdate` runs on the host's own attached thread, so the whole apply pass is
   queued through `onMainThread` — and with `general.requireMainThread` true
   (the default) it does not run at all until the host confirms its per-frame
   drain really is Unity's thread. A revert goes back the same way and **waits**
   for it; see the unload caveat.
5. **A value that arrives handle-shaped is refused, whatever its declared kind.**
   `asFloat` on `{"handle":6,"type":"..."}` is 0.0 with `ok` true, and a knob
   that read its "original" that way would faithfully restore a zero it never
   read. The shape is checked before the number is trusted, and the handle the
   host took out is released rather than left pinning an object.

## What it reads and deliberately does not write

Logged once at startup, under `perf  read-only`:

`Physics.autoSyncTransforms`, `Physics.defaultSolverIterations`,
`Physics.defaultSolverVelocityIterations`, `Time.timeScale`,
`Time.fixedDeltaTime`, `SystemInfo.processorCount`,
`SystemInfo.systemMemorySize`, and `SystemInfo.graphicsDeviceName`.

The three `Physics` ones are genuine performance knobs and this mod will not
touch them. `autoSyncTransforms = false` makes a physics query see transforms as
they were at the last sync rather than as they are now; fewer solver iterations
change where a body comes to rest. Both change *what a raycast hits*, and a mod
that changes what a bullet hits is not a graphics setting however it is spelled.
The same line rules out everything culling-shaped — camera far planes, layer
culling distances, occlusion, LOD *culling* thresholds — because making
something visible that the game meant to hide is not a performance change at
all. This is single-player emulation and the line is still worth keeping clean.

`System.GC` is not touched either, and that is not squeamishness: IL2CPP uses
Boehm, the managed `System.GC` surface is a thin shim over it, and
`GCSettings.LatencyMode` is a no-op there. `GC.Collect` *is* reachable by name
and calling it would be a deliberate stutter, which is the opposite of the job.

## The readout

Once per `hud.intervalMs` (1000 ms by default):

```
perf  61.015 fps over 999 ms (61 frames)  best 61.015  worst 59.123
```

**The line says which counter produced the number, and the host is what says
so.** `call("aowlspt.host::main_thread")` reports `frames`, which is the
host's `aowl_mq_fires`: one increment per firing of whichever per-frame method
the host managed to detour. That is a frame count only when the method runs
once a frame, and the host's last-resort candidate,
`UnityEngine.Time::get_deltaTime`, does not — it is on the list because a
main-thread-only API proves its caller's thread, and it runs many times a
frame. Dividing that by wall-clock time gives calls per second, larger than
the frame rate by an unknown factor.

The same report carries **`perFrame`** beside `frames`, recorded in the host
where the choice of drain method is made. This mod read it out of a whitelist
of method names until the host answered it, which worked and was the wrong
place for it: a mod-side list of host-side names has to be edited every time
the host's list is, and the failure when it is not is a readout confidently
reporting fps for something that is not a frame count.

A host too old to answer omits the key, and **an absent key means unknown, not
true** — so an older host gets "drain firings/s" even on a method that does
run once a frame. That is the intended trade: a number nobody vouched for does
not get called a frame rate. The log distinguishes the two reasons, because
they want different actions:

```
perf  the readout counts the host's drain, which it reports as more than once
      a frame: ... its firing count is not a frame count.
perf  the readout counts the host's drain, whose multiplicity this host does
      not report ... A newer host answers it.
perf  61.190 drain firings/s over 996 ms (61 firings)
```

`hud.readUnityTime` (off by default) binds `UnityEngine.Time::get_frameCount`
and `get_deltaTime` through `bindMethod`, and where it is on the window is
closed against **`Time.frameCount`** instead: a frame count by definition rather
than by an argument about which method the host detoured, at one bound call
(about 10 ns) per window. It is still refused unless the host reports its drain
really is Unity's thread, because those are Unity API and the host's tick thread
is not guaranteed to be it. Switching source mid-run discards the window that
straddles the switch and resets best/worst rather than subtracting one counter
from the other.

The last window is published to `store/aowl.perf/perf.lastWindow`, with the
source named and an `isFrameRate` flag, for anything else that wants it.

## The distribution, which is the half a mean cannot give

```
perf  frame time p50 15.744 ms  p99 30.336 ms  p99.9 30.784 ms  worst 30.777 ms  (1402 frames, 2 over 50 ms)
perf  pacing p99/p50 1.926  (1.000 is perfectly even; the further above, the more the stutter a mean cannot see)
perf  per-frame sampler: 764 firing(s), 567 ns of each spent in this mod (of which 25 ns is the recording); the re-arm and the host's drain are NOT in that figure, 2 scheduler slot(s) at peak
```

**A mean is the wrong statistic and this mod used to report only means.** A
second holding fifty-five even frames and one 200 ms freeze reports about the
same frames-per-second as a second of sixty even ones. `best` and `worst` did
not rescue it: they were the best and worst *of the one-second means*, so a
hitch had to last most of a second before either moved. Stutter is what a
performance mod is for, and nothing that samples once a second can see it.

So `hist.nim` takes a sample every frame into 1024 buckets of 64 microseconds —
4 KB, one page, so the increment never misses cache — and reports percentiles, a
hitch count and the pacing ratio. The tail is exact where the histogram is not:
a frame past 65.5 ms is counted separately and `worst` is the true maximum
whatever bucket it would have fallen in, so a 300 ms freeze is reported as 300
ms rather than clamped into the top bucket. A percentile whose rank lands in
that tail prints `+` and says so, rather than reporting the top edge as though
the histogram had contained it.

`p99.9` appears only once a thousand samples exist. Below that its rank rounds
up to the largest sample, so it would be the maximum printed twice under two
names — and the second name implies a distribution the sample count cannot
support. Percentiles at all wait for 120 samples.

**It resets when what it is measuring changes.** Applying or restoring a setting
clears it, because a distribution spanning the change describes neither
configuration. That is also what makes an A/B possible: apply, let it fill, read
p99; `emit("aowl.perf.restore")`, let it fill, read p99 again. The store key
`perf.frameTimes` carries an `epoch` that increments on every reset, so a
consumer can tell two configurations apart rather than averaging them.

### Where the per-frame callback comes from

`everyMain(handler)` — one callback per drain of the host's main-thread queue,
on the thread the drain runs on. This mod built that chain by hand until the
library grew one, and the paragraph that used to be here said the ABI had no
`everyMain` and that `every` "repeats on the host's own thread". The first half
is out of date. **The second half was never quite right**, and it is the more
useful correction: on the IL2CPP client host `hostSchedule` and `hostInvokeMain`
feed one queue drained by one thread, so `every(16, …)` does already land on the
game's thread there.

What actually separates the two is:

* **A deadline is not a frame.** `every` fires when a wall-clock deadline has
  passed; `everyMain` fires once per drain. At 144 fps a 16 ms timer fires
  roughly every third frame; at 30 fps it fires once a frame and drifts. Either
  fed into `hist.nim` would give a p50 of 16 ms on every machine in the world,
  which is the confident-wrong-number shape this whole mod is arranged to avoid.
* **The ABI only ever promised the main thread for `invoke_main`.** That the two
  queues are one is this host's implementation, not a guarantee — the backend
  host keeps its timers on its own thread.

That the chain does not spin inside one frame is still a property of the host:
`drainDue` snapshots the due list under the lock and runs it outside, so a
re-queue from inside a firing is picked up by the next drain. `everyMain` is now
the single place that depends on that, instead of every mod that wants a frame.

It holds **one** scheduler slot for the life of the chain, because it re-arms on
the same cookie. The hand-rolled chain called `onMainThread` again inside each
firing, claiming a slot and giving it back at the end of the same firing. The
self-test bounds the table at 4 and it reads 2 — but note what that number
cannot do: `claimTick` reuses freed slots, so the peak was 2 for the old chain
too. The peak catches a real leak; what rules out the churn is that `everyMain`
re-arms on the same cookie.

### What it costs, measured — and what stopped being measurable

| | ns | how |
|---|---:|---|
| recording one interval (clock read, subtract, array store) | **25** | `benchPumpBody`, 200000 samples |
| this mod's half of a firing | **350–800** | accumulated inside `pumpTick` over every firing |
| `everyMain`'s re-arm | **not measured** | it happens in the library's trampoline after the handler returns; nothing here can hold a clock around it |
| the host's drain overhead for a non-empty queue | **89, elsewhere** | measured in `docs/PERF.md` on 2026-08-19, not from here. This row used to read *not measured*, and used to add that `drainDue` allocates two seqs per frame: `takeDue` compacts in place and reuses the caller's buffer, so the steady per-frame chain allocates nothing |

**The middle row shrank without the work getting cheaper, and that is what the
row under it is for.** With the hand-rolled chain the `onMainThread` call was
inside `pumpTick` and inside the clock window around it, and the same figure —
then called `pumpBusyNs` — read 850–1350 ns against the stand-in. Taking the
enqueue out of the measured window halved it, on the same machine in the same
minute. So the enqueue was about half a firing, not nearly all of it, and the
other half is two `perfCounter` reads plus whatever preemption lands between
them.

The self-test bound moved with the number: 5 µs, not the 100 µs it was. 100 µs
bounded a figure that included the expensive half; against a figure that no
longer does, it would have passed a firing that had grown thirty times worse. It
is not tightened to 900 ns either — the drift with machine load is real, and a
bound that tight would be measuring the box.

**A differential A/B could not resolve it, and that is reported rather than
hidden.** Four 14-second runs against the stand-in, alternating
`hud.frameTimes` on and off, gave 53.48 / 53.65 / 50.50 / 54.67 fps — the
run-to-run variance of the stand-in is several percent and the effect being
looked for is 0.006 percent. The in-firing measurement is what resolves this;
the A/B is only evidence that there is no *gross* regression.

### The cross-check that says a firing is a frame

Two independent measurements of one quantity: the window divides the host's
drain counter by wall clock, and the histogram is the median of intervals the
pump timed for itself. If the chain fired twice a frame, or every other frame,
these would disagree by a factor of two and **nothing else in this mod would
notice** — every percentile would still look like a frame time with a decimal
point on it.

```
ok    selftest  the sampler's median frame interval (15.680 ms) agrees with the
      53.949 fps the window measured (18.536 ms implied), over 444 samples --
      so one firing of the chain is one frame
```

The median sits below the interval the mean implies, which is the expected
direction: the mean is dragged up by exactly the slow frames the histogram
exists to separate out. The band is sized to catch a factor of two, not to
police the difference between a mean and a median.

### When it refuses

The pump does not start unless the host reports its drain runs **once per
frame** — the same gate, for the same reason, that stops the readout saying
"fps". Sub-frame intervals recorded into a frame-time histogram would give a p99
of about zero and a confident claim that the game never stutters. A host that
reports more than once a frame, a host that does not answer, and a drain that is
not Unity's thread are all refused with a reason, and all four refusals are in
the simulator self-test.

## Events

| event | effect |
|---|---|
| `aowl.perf.restore` | put every applied setting back, on the game's thread, **before the emit returns**. Answers `{"ok":true,"restored":n,"stillApplied":0}`, or `ok:false` and the reason in the log |
| `aowl.perf.apply` | re-read nothing, re-apply the current config |
| `aowl.perf.report` | log the per-knob table again |
| `aowl.perf.resetFrameTimes` | start the frame-time distribution over. Answers `{"ok":true,"discarded":n,"epoch":e}`. The mod already resets on its own when a setting is applied or restored; this covers the changes it cannot see — the player moving a slider in the game's own settings menu, a raid loading, another mod arming a hook |

It also *subscribes* to one: `aowlspt.host.mods.unload`. The mod manager's
unload request is queued by the host and then delivered to subscribers, and the
host performs it from its own loop on a later turn — so that is a whole host
tick of warning with the game still running and the
drain still firing — which is the earliest and safest moment to put the
settings back. A request naming another mod's guid is ignored; one naming no
guid is treated as ours, because a restore that did not need to happen is
cheaper than settings that outlive the mod that set them.

## What host answered

First line of every run, before any refusal:

```
perf  talking to aowlspt-host-il2cpp 0.1.0, host API size 224 (mod built
      against 224), store yes, live pointers yes, typed patches yes,
      perFrame reported yes
perf  first run recorded against this host
```

This is here because of a mistake this mod made about itself. Its enum refusal
was recorded honestly and stayed reproducible for weeks after the host stopped
deserving it — because the host DLL in the test stage was two hours older than
the one being built, and nothing in the log said which host the refusal was
evidence about. A refusal is evidence about **the host that produced it** and
about no other. So the mod prints what it is talking to, remembers that in its
own store, and says outright when the answer has changed:

```
perf  THIS IS A DIFFERENT HOST from the one the last run recorded its refusals
      against. Every REFUSED line below is evidence about this host and about
      no other ...
perf  was: {"host":"aowlspt-host-il2cpp","version":"0.1.0","apiSize":224,
            "store":true,"livePointers":true,"typedPatches":true,
            "perFrameReported":true}
perf  now: {"host":"aowlspt-host-il2cpp","version":"0.1.0","apiSize":192,
            "store":true,"livePointers":false,"typedPatches":false,
            "perFrameReported":false}
```

The fingerprint is made of **capabilities, not a version string**, and the two
lines above are why: both of those hosts call themselves `0.1.0`. A version
says what a host calls itself; capabilities say what it will do, which is what
a refusal is about. It costs one `store` key (`perf.lastHost`); a host with no
store says so and prints the identity line anyway.

## The self-test

Both halves run automatically.

`aowl run mods/perf` — the simulator, with no IL2CPP runtime in the process:

```
ok    the knob table has 23 entries, all named
ok    no two knobs share a config path
ok    every knob has a sane band and a real owner
ok    the config named 23 knobs without error
ok    the frame sampler refuses to sample unbound
ok    binding Unity's Time refuses with a reason
ok    the refusal names something
ok    the first window reports nothing
ok    the second window reports a rate
ok    a drain the host reports as per-frame counts frames
ok    a drain the host reports as firing more than once a frame does not
ok    a host that does not answer perFrame is unknown, not per-frame
ok    the two not-a-frame-count cases stay distinguishable
ok    a report that did not parse claims nothing
ok    a window whose counter changed is discarded, not subtracted
ok    an empty distribution reports no percentile
ok    the sample count is exact
ok    the exact minimum and maximum survive bucketing
ok    the mean is the arithmetic mean, not a bucket
ok    the median lands in the bucket holding the median sample
ok    p99 is the 990th sample, not the largest one
ok    p99.9 crosses into the slow group
ok    the percentile is the bucket's upper edge, never its lower
ok    pacing is 1.000 when 99 percent of frames are the same length
ok    a sample past the histogram's top is counted in the tail
ok    a sample past the top is not clamped into the top bucket
ok    a percentile whose rank lands in the tail says so
ok    hitches are counted against the threshold exactly
ok    a negative interval is dropped rather than recorded
ok    reset clears the distribution and starts a new epoch
ok    no bucket survived the reset
ok    the sampler refuses a host that did not answer
ok    the sampler refuses a drain that is not Unity's thread
ok    the sampler refuses a drain that fires more than once a frame
ok    the sampler treats an unanswered perFrame as unknown, not yes
ok    every sampler refusal named a reason
ok    recording a frame interval costs under 200 ns
ok    measuring the recording path leaves the distribution untouched
ok    and does not advance the epoch, because nothing changed
ok    nothing applied with no runtime present
ok    every refusal recorded a reason
ok    restoring nothing is a no-op
ok    an out-of-band value is refused, not clamped
ok    reverting with nothing applied returns at once
```

Against `tests/mockil2cpp`, staged and run for eight seconds:

```
installer\build\aowl.exe build-mod mods/perf
copy mods\perf\bin\perf.dll installer\build\perfstage\mods\perf\
installer\build\hostharness.exe installer\build\perfstage ^
    --runtime tests\mockil2cpp\GameAssembly.dll --seconds 8
```

```
info  host: aowlspt-host-il2cpp 0.1.0, host API size 224 (mod built against
      224), store yes, live pointers yes, typed patches yes, perFrame
      reported yes
ok    the host says whether its drain counter counts frames
ok    every knob answered or refused with a reason
ok    the probe reached at least one knob
info  0 of 10 knobs needed an asserted int32 binding to read
info  anisotropicFiltering: the boxed getter answered 1 - a plain number, so
      no assertion is needed; the value read is 1.000
ok    the boxed enum getter agrees with the asserted binding
ok    anisotropicFiltering needs no asserted binding on this host
ok    no enabled knob refused without saying why
ok    every applied setting was restored to its original
ok    the restored values equal the originals that were read
info  selftest: 9 setting(s) put back on the game's thread
ok    a restore queued onto the game's thread completes before the caller returns
info  the queued restore came back in 11 ms
info  the frame sample path costs 11 ns/call over 200000 calls
ok    the sample path is allocation-free (under 200 ns/call over 200000 calls)
ok    the per-frame sampler fired
ok    the sampler holds a bounded number of scheduler slots
info  the sampler peaked at 2 scheduler slot(s) over 115 firing(s)
ok    recording 20000 frame intervals allocates nothing
info  20000 samples into the histogram: 0 allocation(s) in the mod
ok    recording a frame interval stays under 200 ns
info  recording half: 25 ns/sample over 200000 samples
info  one sampler firing spends 776 ns in this mod (25 ns of it recording) over
      115 firing(s); the re-arm is in the library and the drain is in the host,
      and neither is in that number
ok    this mod's half of a sampler firing costs under 5 us
info  that is 46 parts per million of a 16.7 ms frame, and it is a floor rather
      than the price: everyMain's re-arm (a lock and a seq append in the host)
      is NOT MEASURED and is not included, and the host's own drain overhead is
      measured in the host rather than here -- 90 ns for an armed chain frame,
      2.8 ns for an empty one, no allocations either way (docs/PERF.md)
```

and, once enough frames have accumulated for a median, from the readout rather
than from the self-test:

```
ok    the sampler's median frame interval (15.680 ms) agrees with the 53.949
      fps the window measured (18.536 ms implied), over 444 samples -- so one
      firing of the chain is one frame
```

The mock is deliberately **partial**, and the gaps are what make the run worth
anything: some properties have a getter and a setter, one (`maxQueuedFrames`)
has a getter and no setter, one is reachable only through its old name
(`masterTextureLimit`), one takes an enum, `shadowCascades` clamps its input the
way Unity does, and thirteen of the twenty-three are simply absent. A run
against it therefore exercises applied, clamped, alias-resolved, readable-but-
not-writable, out-of-band and absent — all six outcomes — rather than only the
happy one. It is staged into `installer\build\perfstage` rather than
`installer\build\hoststage`, because the latter is rebuilt wholesale by
`aowl test` and shared with whatever else is being driven at the time.
`installer\build\perfstage\mods\perf\config.json` is the test config that turns
the relevant knobs on; the shipped `mods/perf/config.json` leaves them all off.
Keep the host DLL in that stage current: a stale `aowlspt-host-il2cpp.dll`
there is a run against last month's ABI, and it is exactly how this mod came to
go on believing an enum return was still a handle after it had stopped being
one.

What that run **cannot** exercise is `onUnload` -- `hostharness` ends by
stopping the process rather than by taking the mod out. The restore-on-unload
path is covered instead by the queued-restore check above, which goes through
the same `onMainThread`-and-wait code, and by the simulator's no-op case.

### About the allocation claim

This section used to open "the mod runs **no per-frame code at all**, so its
per-frame allocation count is zero for the dull reason that there is no frame
path", and go on to explain that `allocationCount()` and `allocProbeOk()` were
"the right tools for a **hook**; this mod has none". Both halves are now false,
and the correction is the point: **a zero that came from having no code is worth
nothing once there is code.**

There is a frame path now — the pump — so the claim is measured the way
`examples/highlevel` measures a typed hook, against mimalloc's *cumulative*
block count with the probe that proves the counter is live:

```
ok    selftest  recording 20000 frame intervals allocates nothing
info  selftest  20000 samples into the histogram: 0 allocation(s) in the mod
```

Cumulative is the whole point: a string built and freed once per frame leaves a
live-bytes figure exactly where it was. The counter is read *outside* the loop,
because reading it through anything that allocates is how `examples/highlevel`
came to report "20000 firings made 5 allocations".

The 10 ns/call figure for the optional Unity sampler is unchanged and is still
an indirect proof, which is fine for a two-bound-call path: a nimony heap
allocation and its matching free are tens of nanoseconds even with a warm
allocator, and `docs/PERF.md` puts two bound calls at about 19 ns.

## What the API could not express

Four of the five entries this section used to hold have been closed in the host.
They are kept, with what happened, because a list of gaps that only ever grows
is a list nobody reads.

* **An enum *return* on the boxed path — CLOSED.** `describeResult` unboxes a
  small value type by the payload width the runtime reports, so the boxed getter
  answers a number:

  ```
  selftest  anisotropicFiltering: the boxed getter answered 1 - a plain number,
            so no assertion is needed; the value read is 1.000
  ok        the boxed enum getter agrees with the asserted binding
  ok        anisotropicFiltering needs no asserted binding on this host
  ```

  It used to answer `{"handle":6,"type":"System.Int32"}`, on which
  `get("anisotropicFiltering").asFloat()` is **0.0 with `ok` true** — a
  plausible number, not a refusal, which is the failure mode with the longest
  time-to-diagnosis available — and it leaked one GC handle per read. So every
  enum knob went through `bindMethodAs(..., [], fkI32)`, asserting the width.

  The assertion is still in the code and is now a **fallback**, entered when the
  boxed getter answers something handle-shaped rather than when a version number
  says so. A knob that used it says so in its log line, and the self-test says so
  in a warning, because "the runtime reported four bytes" and "this mod asserted
  four bytes" are different amounts of confidence. `aowlspt/fast`'s
  `classifyType` **used to refuse an enum outright**, on the grounds that it
  decided from `findClass` and `classIsValueType` and neither distinguishes a
  byte enum from a long one. That refusal is gone: `classifyClass` consults the
  type name first and then the width the runtime reports -- instance size minus
  a *measured* box header -- so a 1-, 2-, 4- or 8-byte enum classifies now. What
  is still refused is a value type too wide for a register, and must be: Win64
  passes one by hidden pointer, which is a different call shape rather than a
  different register.

* **A repeating main-thread callback — CLOSED.** `everyMain` is in the library
  now and this mod uses it; the hand-rolled chain, and the fifty lines of
  commentary establishing that it was safe, are gone. It re-arms on the same
  cookie, so it holds one slot rather than churning one per firing, and
  `stopMainRepeats` is the stop.

  Two things came with it that are not improvements. The re-arm moved out of
  this mod's clock window, so the per-firing figure printed here is now its own
  half only and the queue is stated as **not measured** — see "What it costs"
  above. And the library's re-arm failure path releases the slot and tells
  nobody, so the old "the host refused to re-queue me" flag has no equivalent;
  `chainWentQuiet` replaces it by watching for a readout window in which a chain
  that had been firing did not, which catches strictly more (a silent drain, a
  removed detour) at the price of noticing a window late.

  What is still missing is only the price: several hundred nanoseconds a firing
  in this mod plus an unmeasured enqueue and drain, against the 23 ns a
  `hookTyped` on the same method would cost.

* **An allocation-free per-frame callback — CLOSED.** `hookTyped` and
  `hookReturnTyped` (ABI revision 4) hand a handler the saved registers instead
  of JSON: about 24 ns a firing against 650, measured at zero allocations in the
  mod and zero payload bytes in the host over twenty thousand firings. The old
  complaint — that `patchTrampoline` calls `toString` on both slices before any
  mod code runs, even for `hook`, which discards them — is no longer true of
  either, and this paragraph used to say it still held for the JSON hooks. The
  target name comes from the registration rather than from the slice, and an
  empty argument slice converts without allocating, so the no-arguments `hook`
  form is free. A JSON hook that does take arguments still builds one string a
  firing.

  **This mod still installs no hooks**, and the reason is now small rather than
  structural: the only method it would want to hook is the per-frame method the
  host's own drain is already detoured onto, and a second detour there, for a
  readout, is not a trade worth making when the drain's counter answers the same
  question for nothing. If a frame-time *distribution* is ever wanted rather than
  a mean, `hookTyped` is the shape it should take, and what it costs is a patch
  slot and a second trampoline on the game's hottest path.

* **A postfix hook — available, and deliberately unused.** `hookReturn` can
  adjust what a game method answers: 443 ns to watch a return value, 2320 ns to
  also read the arguments and replace the result, 80 ns for the same work on
  `hookReturnTyped`. (The first two read 418 and 2245 until `docs/PERF.md` was
  re-measured.) Nothing here wants one. A setting is written twice in a
  session, not adjusted per call, and a postfix holding a `QualitySettings`
  property against the game's own settings menu would be fighting the player
  rather than the frame time.

* **A way to prove an allocation count — CLOSED**, and not used here; see
  "About the allocation claim" above.

* **IL2CPP's garbage collector — still nothing, and still the right answer.**
  IL2CPP uses Boehm, `System.GC`'s managed surface is a thin shim over it, and
  `GCSettings.LatencyMode` is a no-op there. `GC.Collect` *is* reachable by name
  and this mod will not call it: a forced collection is a stutter, which is the
  opposite of the job.

And the one gap this list had left, closed since it was written:

* **`aowlspt.host::main_thread` did not say whether `frames` counted frames —
  CLOSED.** It answers `perFrame` now, out of the host's own drain-candidate
  table rather than out of anything a mod re-derives, and the host logs the
  caveat when it binds the last resort. This mod's whitelist of method names is
  gone; what is left is reading the key, and treating its absence on an older
  host as unknown rather than as true.

## Honest caveats

* **This has never run against BSG's client.** Not once. Everything green above
  is green against `tests/mockil2cpp`, a stand-in that exports the same C API
  over a hand-built type universe. What that establishes is the *mechanism* —
  resolution by name, boxing by declared type, the enum route and its fallback,
  read-back, restore, the queued restore completing on the game's thread, the
  sampler's cost, and that one firing of the per-frame chain is one frame of
  whatever the stand-in is doing. What it cannot establish is that
  `UnityEngine.QualitySettings::set_shadowDistance` exists in Tarkov's
  `global-metadata.dat`, or that writing it there does what Unity documents.
* **Unity's public API is stable; BSG's build of it may not be.** Stripping can
  remove an unused setter. A renamed property (`masterTextureLimit`,
  `blendWeights`) may have kept either name or neither. The first run against the
  real game is an experiment, and the `perf  read-only` and per-knob log lines
  are its result sheet — read them before turning anything on for real.
* **Thread safety is inferred, not tested.** The apply pass is gated on the host
  reporting a real Unity main thread, but "the host's drain hook fires on the
  same thread the player loop runs on" has itself only been observed against the
  mock's frame thread.
* **Unload now waits, and can still fail — loudly.** `onUnload` runs on the
  host's thread and a Unity write belongs on Unity's, so the restore is queued
  and then **waited on** for up to `general.restoreWaitMs` (2000 by default).
  Blocking there is safe and necessary: the host runs `onUnload`, then drops
  every callback this mod still has queued, then frees the library, so a restore
  that has not run by the time `onUnload` returns never runs at all — which is
  what the previous version's "queued a restore" line was quietly reporting. The
  thread being blocked is the host's tick thread and the thread being waited on
  is the game's, so it cannot wait on itself; where the host has taken the queue
  back onto its own thread (`stalled`), nothing is queued and nothing is waited
  for at all: the settings are reported STILL APPLIED in an `error` naming the
  count, because a Unity write from that thread is the crash the apply gate
  exists to avoid. This used to say the wait was "skipped", which reads as
  though the restore still happened.

  When it does fail — the drain gone, the budget spent, the settings still
  applied — that is an `error` naming the count, saying whether the drain was
  firing at all, and re-logging every knob, rather than a warning about a
  possibility. The settings then persist until the game exits, which is the
  cosmetic outcome; writing them from the wrong thread would be a crash on the
  way out, which is not.

  Two things make the wait rarely the thing that saves it: a manager-driven
  unload restores a whole host tick earlier, from the `aowlspt.host.mods.unload`
  subscription, and `aowl.perf.restore` reverts on demand and does not answer
  until it has. **`onUnload` itself has never been exercised against a runtime**
  — `hostharness` stops the process rather than unloading the mod — so what
  is proven is the queued-restore mechanism it is built on, not the unload.
* **`restoreWaitMs: 0` is not "no wait", it is the old broken behaviour.** The
  queued restore was not merely unreliable: the host drops every callback this
  mod still has queued immediately after `onUnload` returns, so with no wait the
  restore reliably did **not** happen while the log said it had been queued.
  The key exists to reproduce that, not to save time on the way out.
* **A refusal is evidence about the host that produced it.** The identity line
  and the stored fingerprint make a changed host visible in one run; they cannot
  make a refusal recorded against one host mean anything about another, and
  nothing can. Re-read the per-knob lines after the warning fires.
* **The restore is read back now, and that can surface a knob that will not go
  home.** Unity clamps; a setting whose original was itself outside what the
  engine will accept comes back as something else, and that is reported instead
  of counted as a success. It was not checked at all before.
* **`time.fixedDeltaTime` changes the game, not just the frame rate.** Physics
  step size affects ragdolls, grenade throws and anything else integrated in
  `FixedUpdate`. It is in the table because it is a real and large CPU saving; it
  is off, banded narrowly, and flagged here because it is not a free one.
* **`quality.maxQueuedFrames` can lower average fps.** It trades throughput for
  latency. That is the right trade in a shooter and it is still a trade.
* **The frame-rate figures are still means, and a mean still cannot see a
  hitch — but they are no longer all there is.** This entry used to end "a real
  distribution is possible now, and this mod does not take it". It takes one
  now: `hud.frameTimes` samples every frame through `everyMain` and reports
  p50/p99/p99.9, a hitch count and a pacing ratio. What that costs is partly
  measured (350–800 ns a frame inside the mod, about 46 ppm of a 16.7 ms frame)
  and what it does not cover is stated rather than estimated (`everyMain`'s
  re-arm, still **not measured** from here; the host's own drain overhead is
  89.9 ns for an armed chain frame in `docs/PERF.md`, measured there rather
  than here). The self-test's own line used to print both as NOT MEASURED; it
  prints the re-arm as NOT MEASURED and the drain's measured figure beside it,
  and is quoted verbatim above.

  Two limits remain. The distribution needs 120 samples before it reports
  anything and 1000 before it reports p99.9, so the first seconds of a session
  are still mean-only. And when the host's drain bound to
  `UnityEngine.Time::get_deltaTime`, the window's number is firings per second —
  the readout says so rather than calling it fps, and the per-frame sampler
  refuses to run at all rather than recording sub-frame intervals as frames.

## Rules this mod keeps

Unchanged, and worth restating because every change above was made inside them:
post-1.0 only, nimony only, every change reversible and configurable,
conservative defaults (every knob off as shipped), and nothing that alters what
the player can see or hit relative to anything else. Visual and CPU
optimisations yes; culling changes no. Nothing here has ever run against BSG's
client.
