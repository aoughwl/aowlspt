// The shared engine. Everything that is the same on the server, in the client
// and in the simulator lives here; the differences arrive as IHostServices.
//
// The load sequence, and why it is in this order:
//
//   1. shadow-copy the library      so a rebuild can overwrite the original
//                                   while this copy stays mapped
//   2. aowlspt_abi_version()        cheapest possible reject, runs no mod code
//   3. aowlspt_describe()           metadata, before the mod can touch services
//   4. side / SPT-version checks    refuse here rather than half-load
//   5. build the host API           allocator, callbacks, info block
//   6. aowlspt_init()               the mod may now call back into us
//   7. on_load()                    the host is ready to serve
//
// Faults are contained: a mod that returns a bad status or throws past its own
// boundary is marked Faulted and dropped from dispatch, and the host keeps
// running. A broken mod should cost you that mod, not the raid.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace Aowlspt.Abi;

public sealed class ModHost : IDisposable
{
    private readonly IHostServices _services;
    private readonly List<LoadedMod> _mods = new();
    private readonly Dictionary<string, List<EventSubscription>> _events =
        new(StringComparer.Ordinal);
    // Handles are minted by the side-specific services (the DI container
    // server-side, the component registry client-side); this map only records
    // which ones a mod still holds so release is idempotent.
    private readonly Dictionary<ulong, object> _handles = new();
    private readonly string _shadowRoot;
    private readonly System.Diagnostics.Stopwatch _clock = System.Diagnostics.Stopwatch.StartNew();
    private bool _disposed;

    public IReadOnlyList<LoadedMod> Mods => _mods;
    public IHostServices Services => _services;

    private sealed class EventSubscription
    {
        public LoadedMod Mod = null!;
        public AowlCallbackFn Handler = null!;
        public IntPtr User;
    }

    public ModHost(IHostServices services, string? shadowRoot = null)
    {
        _services = services ?? throw new ArgumentNullException(nameof(services));
        _shadowRoot = shadowRoot ?? Path.Combine(Path.GetTempPath(), "aowlspt-shadow");
        SweepStaleShadows();
    }

    // ------------------------------------------------------------ discovery

    /// <summary>
    /// Load every mod under <paramref name="root"/>. A mod is a directory
    /// holding a library named after it — `mods/hello/hello.dll` — or a
    /// `aowlspt.mod.json` naming one explicitly.
    /// </summary>
    public int LoadAll(string root)
    {
        if (!System.IO.Directory.Exists(root))
        {
            _services.Log(AowlLogLevel.Debug, "aowlspt", $"no mod directory at {root}");
            return 0;
        }

        var loaded = 0;
        foreach (var dir in System.IO.Directory.GetDirectories(root).OrderBy(d => d, StringComparer.Ordinal))
        {
            var lib = FindLibrary(dir);
            if (lib is null) continue;
            if (TryLoad(dir, lib) is not null) loaded++;
        }
        return loaded;
    }

    private static string? FindLibrary(string dir)
    {
        var manifest = Path.Combine(dir, "aowlspt.mod.json");
        if (File.Exists(manifest) &&
            JsonValue.TryParse(File.ReadAllText(manifest), out var m) &&
            m.TryGet("library", out var libName) &&
            libName.Kind == JsonKind.String)
        {
            var explicitPath = Path.Combine(dir, libName.AsString);
            return File.Exists(explicitPath) ? explicitPath : null;
        }

        var stem = new DirectoryInfo(dir).Name;
        var byName = Path.Combine(dir, NativeLibraryLoader.LibraryFileName(stem));
        if (File.Exists(byName)) return byName;

        // Fall back to a single library in the directory; more than one is
        // ambiguous and is reported rather than guessed at.
        var pattern = NativeLibraryLoader.IsWindows ? "*.dll" : "*.so";
        var found = System.IO.Directory.GetFiles(dir, pattern);
        return found.Length == 1 ? found[0] : null;
    }

    // ------------------------------------------------------------- loading

    public LoadedMod? TryLoad(string directory, string libraryPath)
    {
        LoadedMod? mod = null;
        try
        {
            var shadow = ShadowCopy(libraryPath);
            mod = new LoadedMod(directory, libraryPath, shadow);
            mod.Library = NativeLibraryLoader.Load(shadow);

            // 2 — version probe, before any mod code runs
            var versionFn = NativeLibraryLoader.GetDelegate<AowlAbiVersionFn>(mod.Library, AowlAbi.SymAbiVersion);
            var modAbi = versionFn();
            if (modAbi != AowlAbi.Version)
            {
                _services.Log(AowlLogLevel.Error, "aowlspt",
                    $"{Path.GetFileName(libraryPath)}: ABI v{modAbi}, host speaks v{AowlAbi.Version} — refusing to load");
                mod.Dispose();
                return null;
            }

            // 3 — metadata
            var describeFn = NativeLibraryLoader.GetDelegate<AowlDescribeFn>(mod.Library, AowlAbi.SymDescribe);
            var infoPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AowlModInfoNative>());
            try
            {
                var blank = new AowlModInfoNative { Size = Marshal.SizeOf<AowlModInfoNative>() };
                Marshal.StructureToPtr(blank, infoPtr, false);
                var st = describeFn(infoPtr);
                if (st != AowlStatus.Ok)
                {
                    _services.Log(AowlLogLevel.Error, "aowlspt",
                        $"{Path.GetFileName(libraryPath)}: describe failed ({AowlStatus.Describe(st)})");
                    mod.Dispose();
                    return null;
                }
                var native = Marshal.PtrToStructure<AowlModInfoNative>(infoPtr);
                mod.Descriptor = new ModDescriptor
                {
                    Guid = native.Guid.ToUtf8String(),
                    Name = native.Name.ToUtf8String(),
                    Author = native.Author.ToUtf8String(),
                    Version = native.Version.ToUtf8String(),
                    SptRange = native.SptRange.ToUtf8String(),
                    Sides = native.Sides,
                    Flags = (AowlModFlags)native.Flags,
                };
            }
            finally { Marshal.FreeHGlobal(infoPtr); }

            // 4 — is this mod even for us?
            if (!mod.Descriptor.SupportsSide(_services.Side))
            {
                _services.Log(AowlLogLevel.Debug, "aowlspt",
                    $"{mod.Descriptor.Name}: not built for the {_services.Side} side, skipping");
                mod.Dispose();
                return null;
            }

            if (_mods.Any(m => string.Equals(m.Descriptor.Guid, mod.Descriptor.Guid, StringComparison.Ordinal)))
            {
                _services.Log(AowlLogLevel.Warn, "aowlspt",
                    $"{mod.Descriptor.Guid} is already loaded — ignoring the copy at {directory}");
                mod.Dispose();
                return null;
            }

            LoadConfig(mod);

            // 5 — the host API
            BuildHostApi(mod);

            // 6 — hand over
            var initFn = NativeLibraryLoader.GetDelegate<AowlInitFn>(mod.Library, AowlAbi.SymInit);
            var apiPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AowlModApiNative>());
            try
            {
                var blank = new AowlModApiNative { Size = Marshal.SizeOf<AowlModApiNative>() };
                Marshal.StructureToPtr(blank, apiPtr, false);
                var st = initFn(mod.HostApiPtr, apiPtr);
                if (st != AowlStatus.Ok)
                {
                    _services.Log(AowlLogLevel.Error, "aowlspt",
                        $"{mod.Descriptor.Name}: init failed ({AowlStatus.Describe(st)})");
                    mod.Dispose();
                    return null;
                }
                mod.ModApi = Marshal.PtrToStructure<AowlModApiNative>(apiPtr);
            }
            finally { Marshal.FreeHGlobal(apiPtr); }

            _mods.Add(mod);
            _services.Log(AowlLogLevel.Info, "aowlspt",
                $"loaded {mod.Descriptor} from {Path.GetFileName(libraryPath)}");
            return mod;
        }
        catch (Exception ex)
        {
            _services.Log(AowlLogLevel.Error, "aowlspt",
                $"failed to load {Path.GetFileName(libraryPath)}: {ex.Message}");
            mod?.Dispose();
            return null;
        }
    }

    /// <summary>Run every loaded mod's on_load. Call once the host can serve.</summary>
    public void StartAll()
    {
        foreach (var mod in _mods.ToList())
            Invoke(mod, "on_load", () =>
            {
                if (mod.ModApi.OnLoad == IntPtr.Zero) return AowlStatus.Ok;
                var fn = Marshal.GetDelegateForFunctionPointer<AowlLifecycleFn>(mod.ModApi.OnLoad);
                return fn(mod.ModApi.Self);
            });
    }

    /// <summary>Tick every mod. <paramref name="elapsedMs"/> is since the last call.</summary>
    public void UpdateAll(long elapsedMs)
    {
        foreach (var mod in _mods)
        {
            if (mod.Faulted || mod.ModApi.OnUpdate == IntPtr.Zero) continue;
            Invoke(mod, "on_update", () =>
            {
                var fn = Marshal.GetDelegateForFunctionPointer<AowlOnUpdateFn>(mod.ModApi.OnUpdate);
                return fn(mod.ModApi.Self, elapsedMs);
            });
        }
    }

    public void UnloadAll()
    {
        foreach (var mod in _mods.AsEnumerable().Reverse())
        {
            if (!mod.Faulted && mod.ModApi.OnUnload != IntPtr.Zero)
                Invoke(mod, "on_unload", () =>
                {
                    var fn = Marshal.GetDelegateForFunctionPointer<AowlLifecycleFn>(mod.ModApi.OnUnload);
                    return fn(mod.ModApi.Self);
                });
            mod.Dispose();
        }
        _mods.Clear();
        _events.Clear();
    }

    // ---------------------------------------------------------- hot reload

    /// <summary>
    /// Swap a running mod for a freshly built copy of the same library, handing
    /// its state across. Only attempted for mods that declared
    /// <see cref="AowlModFlags.HotReloadable"/>; anything else needs a restart,
    /// and saying so is better than silently losing state.
    /// </summary>
    public bool Reload(string guid)
    {
        var old = _mods.FirstOrDefault(m => string.Equals(m.Descriptor.Guid, guid, StringComparison.Ordinal));
        if (old is null)
        {
            _services.Log(AowlLogLevel.Warn, "aowlspt", $"reload: no mod with guid {guid}");
            return false;
        }
        if (!old.Descriptor.HotReloadable)
        {
            _services.Log(AowlLogLevel.Warn, "aowlspt",
                $"reload: {old.Descriptor.Name} is not marked hot-reloadable — restart the host to pick up changes");
            return false;
        }

        var state = SaveState(old);
        var dir = old.Directory;
        var lib = old.SourceLibraryPath;

        if (!old.Faulted && old.ModApi.OnUnload != IntPtr.Zero)
            Invoke(old, "on_unload", () =>
            {
                var fn = Marshal.GetDelegateForFunctionPointer<AowlLifecycleFn>(old.ModApi.OnUnload);
                return fn(old.ModApi.Self);
            });

        DropSubscriptions(old);
        _mods.Remove(old);
        old.Dispose();

        var fresh = TryLoad(dir, lib);
        if (fresh is null)
        {
            _services.Log(AowlLogLevel.Error, "aowlspt", $"reload: {guid} failed to come back up");
            return false;
        }

        if (state is not null) RestoreState(fresh, state);

        Invoke(fresh, "on_load", () =>
        {
            if (fresh.ModApi.OnLoad == IntPtr.Zero) return AowlStatus.Ok;
            var fn = Marshal.GetDelegateForFunctionPointer<AowlLifecycleFn>(fresh.ModApi.OnLoad);
            return fn(fresh.ModApi.Self);
        });

        _services.Log(AowlLogLevel.Success, "aowlspt", $"reloaded {fresh.Descriptor}");
        return true;
    }

    private byte[]? SaveState(LoadedMod mod)
    {
        if (mod.Faulted || mod.ModApi.StateSave == IntPtr.Zero) return null;
        var bufPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AowlBuffer>());
        try
        {
            Marshal.StructureToPtr(AowlBuffer.Empty, bufPtr, false);
            var fn = Marshal.GetDelegateForFunctionPointer<AowlStateSaveFn>(mod.ModApi.StateSave);
            if (fn(mod.ModApi.Self, bufPtr) != AowlStatus.Ok) return null;
            var buf = Marshal.PtrToStructure<AowlBuffer>(bufPtr);
            if (buf.IsEmpty) return null;
            var bytes = buf.ToArray();
            FreeModBuffer(buf);
            return bytes;
        }
        catch (Exception ex)
        {
            _services.Log(AowlLogLevel.Warn, "aowlspt", $"state_save raised: {ex.Message}");
            return null;
        }
        finally { Marshal.FreeHGlobal(bufPtr); }
    }

    private void RestoreState(LoadedMod mod, byte[] state)
    {
        if (mod.ModApi.StateLoad == IntPtr.Zero) return;
        var pin = GCHandle.Alloc(state, GCHandleType.Pinned);
        try
        {
            var slice = new AowlSlice { Ptr = pin.AddrOfPinnedObject(), Len = state.Length };
            var fn = Marshal.GetDelegateForFunctionPointer<AowlStateLoadFn>(mod.ModApi.StateLoad);
            fn(mod.ModApi.Self, slice);
        }
        catch (Exception ex)
        {
            _services.Log(AowlLogLevel.Warn, "aowlspt", $"state_load raised: {ex.Message}");
        }
        finally { pin.Free(); }
    }

    // --------------------------------------------------------------- events

    /// <summary>
    /// Publish an event to every subscriber except <paramref name="from"/>.
    ///
    /// The emitter is skipped, matching the nimony hosts. A mod that owns an
    /// event usually subscribes to it as well, and delivering it back means a
    /// handler that emits from inside itself recurses -- which is a loop nobody
    /// wrote. The simulator used to deliver to everyone, so the same mod
    /// behaved differently here and on the server.
    /// </summary>
    public void Emit(string name, string payload = "", LoadedMod? from = null)
    {
        if (!_events.TryGetValue(name, out var subs) || subs.Count == 0) return;
        var bytes = Encoding.UTF8.GetBytes(payload ?? "");
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            var slice = bytes.Length == 0
                ? AowlSlice.Empty
                : new AowlSlice { Ptr = pin.AddrOfPinnedObject(), Len = bytes.Length };

            // Snapshot: a handler may subscribe or unsubscribe while we iterate.
            foreach (var sub in subs.ToList())
            {
                if (sub.Mod.Faulted) continue;
                if (from is not null && ReferenceEquals(sub.Mod, from)) continue;
                Invoke(sub.Mod, $"event {name}", () => sub.Handler(sub.User, slice, IntPtr.Zero));
            }
        }
        finally { pin.Free(); }
    }

    private void DropSubscriptions(LoadedMod mod)
    {
        foreach (var list in _events.Values)
            list.RemoveAll(s => ReferenceEquals(s.Mod, mod));
    }

    // ------------------------------------------------------- host API build

    private void BuildHostApi(LoadedMod mod)
    {
        mod.CtxHandle = GCHandle.Alloc(mod);
        var ctx = GCHandle.ToIntPtr(mod.CtxHandle);

        var info = new AowlHostInfoNative
        {
            Size = Marshal.SizeOf<AowlHostInfoNative>(),
            AbiVersion = AowlAbi.Version,
            AbiRevision = AowlAbi.Revision,
            Side = (int)_services.Side,
            HostName = mod.NativeString(_services.HostName),
            HostVersion = mod.NativeString(_services.HostVersion),
            SptVersion = mod.NativeString(_services.SptVersion),
            GameVersion = mod.NativeString(_services.GameVersion),
            Encodings = 1u << (int)AowlEncoding.Json,
            ModDir = mod.NativeString(mod.Directory),
            DataDir = mod.NativeString(EnsureDataDir(mod)),
        };
        mod.HostInfoPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AowlHostInfoNative>());
        Marshal.StructureToPtr(info, mod.HostInfoPtr, false);

        var api = new AowlHostApiNative
        {
            Size = Marshal.SizeOf<AowlHostApiNative>(),
            Ctx = ctx,
            Info = mod.HostInfoPtr,

            Alloc = Fn(mod, new AowlAllocFn(HostAlloc)),
            Free = Fn(mod, new AowlFreeFn(HostFree)),
            Log = Fn(mod, new AowlLogFn(HostLog)),
            LastError = Fn(mod, new AowlLastErrorFn(HostLastError)),
            ConfigGet = Fn(mod, new AowlConfigGetFn(HostConfigGet)),
            ConfigSet = Fn(mod, new AowlConfigSetFn(HostConfigSet)),
            DbGet = Fn(mod, new AowlDbGetFn(HostDbGet)),
            DbPatch = Fn(mod, new AowlDbPatchFn(HostDbPatch)),
            RouteRegister = Fn(mod, new AowlRouteRegisterFn(HostRouteRegister)),
            EventSubscribe = Fn(mod, new AowlEventSubscribeFn(HostEventSubscribe)),
            EventEmit = Fn(mod, new AowlEventEmitFn(HostEventEmit)),
            Call = Fn(mod, new AowlCallFn(HostCall)),
            Resolve = Fn(mod, new AowlResolveFn(HostResolve)),
            HandleRelease = Fn(mod, new AowlHandleReleaseFn(HostHandleRelease)),
            Patch = Fn(mod, new AowlPatchRegisterFn(HostPatchRegister)),
            Schedule = Fn(mod, new AowlScheduleFn(HostSchedule)),
            InvokeMain = Fn(mod, new AowlInvokeMainFn(HostInvokeMain)),
            NowMs = Fn(mod, new AowlNowMsFn(HostNowMs)),
        };
        mod.HostApiPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AowlHostApiNative>());
        Marshal.StructureToPtr(api, mod.HostApiPtr, false);
    }

    private static IntPtr Fn<T>(LoadedMod mod, T d) where T : Delegate =>
        Marshal.GetFunctionPointerForDelegate(mod.Keep(d));

    private static LoadedMod? FromCtx(IntPtr ctx)
    {
        if (ctx == IntPtr.Zero) return null;
        try { return GCHandle.FromIntPtr(ctx).Target as LoadedMod; }
        catch (InvalidOperationException) { return null; }
    }

    // ------------------------------------------------------- host callbacks

    // The allocator is the host's, on both sides of the boundary — see the
    // header's rule 2. AllocHGlobal/FreeHGlobal is the process heap, which the
    // native mod can also reach, so a buffer allocated here and freed there (or
    // the reverse) is safe.
    private static IntPtr HostAlloc(IntPtr ctx, int bytes) =>
        bytes <= 0 ? IntPtr.Zero : Marshal.AllocHGlobal(bytes);

    private static void HostFree(IntPtr ctx, IntPtr ptr)
    {
        if (ptr != IntPtr.Zero) Marshal.FreeHGlobal(ptr);
    }

    private static void FreeModBuffer(AowlBuffer buf)
    {
        if (buf.Ptr != IntPtr.Zero) Marshal.FreeHGlobal(buf.Ptr);
    }

    private void HostLog(IntPtr ctx, int level, AowlSlice message)
    {
        var mod = FromCtx(ctx);
        _services.Log((AowlLogLevel)level, mod?.Descriptor.Guid ?? "aowlspt", message.ToUtf8String());
    }

    private void HostLastError(IntPtr ctx, IntPtr outSlice)
    {
        if (outSlice == IntPtr.Zero) return;
        var mod = FromCtx(ctx);
        var text = LoadedMod.LastErrorText ?? "";
        if (mod is null || text.Length == 0)
        {
            Marshal.StructureToPtr(AowlSlice.Empty, outSlice, false);
            return;
        }
        // Pinned until the next error on this thread, which is exactly the
        // lifetime the header promises.
        var bytes = Encoding.UTF8.GetBytes(text);
        if (mod.LastErrorPin.IsAllocated) mod.LastErrorPin.Free();
        mod.LastErrorPin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        Marshal.StructureToPtr(
            new AowlSlice { Ptr = mod.LastErrorPin.AddrOfPinnedObject(), Len = bytes.Length },
            outSlice, false);
    }

    private static void SetError(string text) => LoadedMod.LastErrorText = text;

    private static int WriteOut(IntPtr outBuffer, string? text)
    {
        if (outBuffer == IntPtr.Zero) return AowlStatus.Ok;
        if (string.IsNullOrEmpty(text))
        {
            Marshal.StructureToPtr(AowlBuffer.Empty, outBuffer, false);
            return AowlStatus.Ok;
        }
        var bytes = Encoding.UTF8.GetBytes(text!);
        var p = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, p, bytes.Length);
        Marshal.StructureToPtr(new AowlBuffer { Ptr = p, Len = bytes.Length }, outBuffer, false);
        return AowlStatus.Ok;
    }

    private int HostConfigGet(IntPtr ctx, AowlSlice key, IntPtr outBuffer)
    {
        var mod = FromCtx(ctx);
        if (mod is null) return AowlStatus.ErrBadArg;
        var path = key.ToUtf8String();
        var node = mod.Config.GetPath(path);
        if (node is null)
        {
            SetError($"config key '{path}' not found");
            return AowlStatus.ErrNotFound;
        }
        return WriteOut(outBuffer, node.ToString());
    }

    private int HostConfigSet(IntPtr ctx, AowlSlice key, AowlSlice valueJson)
    {
        var mod = FromCtx(ctx);
        if (mod is null) return AowlStatus.ErrBadArg;
        var path = key.ToUtf8String();
        if (path.Length == 0) { SetError("config_set needs a key"); return AowlStatus.ErrBadArg; }
        if (!JsonValue.TryParse(valueJson.ToUtf8String(), out var value))
        {
            SetError("config_set value is not valid JSON");
            return AowlStatus.ErrDecode;
        }
        try
        {
            mod.Config.SetPath(path, value);
            if (mod.ConfigPath.Length > 0)
                File.WriteAllText(mod.ConfigPath, mod.Config.ToString(true), new UTF8Encoding(false));
            return AowlStatus.Ok;
        }
        catch (IOException ex) { SetError($"config write failed: {ex.Message}"); return AowlStatus.ErrGeneric; }
    }

    private int HostDbGet(IntPtr ctx, AowlSlice path, IntPtr outBuffer)
    {
        try { return WriteOut(outBuffer, _services.DbGet(path.ToUtf8String())); }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
        catch (KeyNotFoundException ex) { SetError(ex.Message); return AowlStatus.ErrNotFound; }
        catch (Exception ex) { SetError(ex.Message); return AowlStatus.ErrGeneric; }
    }

    private int HostDbPatch(IntPtr ctx, AowlSlice path, AowlSlice patchJson)
    {
        try { _services.DbPatch(path.ToUtf8String(), patchJson.ToUtf8String()); return AowlStatus.Ok; }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
        catch (KeyNotFoundException ex) { SetError(ex.Message); return AowlStatus.ErrNotFound; }
        catch (Exception ex) { SetError(ex.Message); return AowlStatus.ErrGeneric; }
    }

    private int HostRouteRegister(IntPtr ctx, AowlSlice url, int kind, IntPtr handler, IntPtr user)
    {
        var mod = FromCtx(ctx);
        if (mod is null || handler == IntPtr.Zero) return AowlStatus.ErrBadArg;
        var routeUrl = url.ToUtf8String();
        var fn = Marshal.GetDelegateForFunctionPointer<AowlRouteFn>(handler);
        mod.Keep(fn);
        try
        {
            _services.RegisterRoute(routeUrl, (AowlRouteKind)kind, (u, body, session) =>
                CallRoute(mod, fn, user, u, body, session));
            _services.Log(AowlLogLevel.Debug, mod.Descriptor.Guid, $"route {routeUrl} registered");
            return AowlStatus.Ok;
        }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
        catch (Exception ex) { SetError(ex.Message); return AowlStatus.ErrGeneric; }
    }

    private string CallRoute(LoadedMod mod, AowlRouteFn fn, IntPtr user,
                             string url, string body, string session)
    {
        using var pinUrl = new PinnedUtf8(url);
        using var pinBody = new PinnedUtf8(body);
        using var pinSession = new PinnedUtf8(session);
        var outPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AowlBuffer>());
        try
        {
            Marshal.StructureToPtr(AowlBuffer.Empty, outPtr, false);
            var st = fn(user, pinUrl.Slice, pinBody.Slice, pinSession.Slice, outPtr);
            if (st != AowlStatus.Ok)
            {
                _services.Log(AowlLogLevel.Error, mod.Descriptor.Guid,
                    $"route {url} returned {AowlStatus.Describe(st)}");
                return "";
            }
            var buf = Marshal.PtrToStructure<AowlBuffer>(outPtr);
            var text = buf.ToUtf8String();
            FreeModBuffer(buf);
            return text;
        }
        finally { Marshal.FreeHGlobal(outPtr); }
    }

    private int HostEventSubscribe(IntPtr ctx, AowlSlice name, IntPtr handler, IntPtr user)
    {
        var mod = FromCtx(ctx);
        if (mod is null || handler == IntPtr.Zero) return AowlStatus.ErrBadArg;
        var evt = name.ToUtf8String();
        if (evt.Length == 0) { SetError("event name is empty"); return AowlStatus.ErrBadArg; }
        var fn = Marshal.GetDelegateForFunctionPointer<AowlCallbackFn>(handler);
        mod.Keep(fn);
        if (!_events.TryGetValue(evt, out var list))
        {
            list = new List<EventSubscription>();
            _events[evt] = list;
        }
        list.Add(new EventSubscription { Mod = mod, Handler = fn, User = user });
        return AowlStatus.Ok;
    }

    private int HostEventEmit(IntPtr ctx, AowlSlice name, AowlSlice payload)
    {
        Emit(name.ToUtf8String(), payload.ToUtf8String(), FromCtx(ctx));
        return AowlStatus.Ok;
    }

    private int HostCall(IntPtr ctx, AowlSlice target, AowlSlice args, IntPtr outBuffer)
    {
        try { return WriteOut(outBuffer, _services.Call(target.ToUtf8String(), args.ToUtf8String())); }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
        catch (MissingMemberException ex) { SetError(ex.Message); return AowlStatus.ErrNotFound; }
        catch (Exception ex) { SetError(ex.Message); return AowlStatus.ErrGeneric; }
    }

    private int HostResolve(IntPtr ctx, AowlSlice typeName, IntPtr outHandle)
    {
        if (outHandle == IntPtr.Zero) return AowlStatus.ErrBadArg;
        try
        {
            var h = _services.Resolve(typeName.ToUtf8String());
            Marshal.WriteInt64(outHandle, (long)h);
            return AowlStatus.Ok;
        }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
        catch (MissingMemberException ex) { SetError(ex.Message); return AowlStatus.ErrNotFound; }
        catch (Exception ex) { SetError(ex.Message); return AowlStatus.ErrGeneric; }
    }

    private void HostHandleRelease(IntPtr ctx, ulong handle)
    {
        _handles.Remove(handle);
        try { _services.ReleaseHandle(handle); } catch (NotSupportedException) { }
    }

    private int HostPatchRegister(IntPtr ctx, AowlSlice target, int kind, IntPtr handler, IntPtr user)
    {
        var mod = FromCtx(ctx);
        if (mod is null || handler == IntPtr.Zero) return AowlStatus.ErrBadArg;
        var spec = target.ToUtf8String();
        var fn = Marshal.GetDelegateForFunctionPointer<AowlPatchFn>(handler);
        mod.Keep(fn);
        try
        {
            _services.RegisterPatch(spec, (AowlPatchKind)kind, (t, argsJson) =>
                CallPatch(mod, fn, user, t, argsJson));
            _services.Log(AowlLogLevel.Debug, mod.Descriptor.Guid, $"patched {spec} ({(AowlPatchKind)kind})");
            return AowlStatus.Ok;
        }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
        catch (MissingMemberException ex) { SetError(ex.Message); return AowlStatus.ErrNotFound; }
        catch (Exception ex) { SetError(ex.Message); return AowlStatus.ErrGeneric; }
    }

    private PatchOutcome CallPatch(LoadedMod mod, AowlPatchFn fn, IntPtr user,
                                   string target, string argsJson)
    {
        using var pinTarget = new PinnedUtf8(target);
        using var pinArgs = new PinnedUtf8(argsJson);
        var outPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AowlBuffer>());
        try
        {
            Marshal.StructureToPtr(AowlBuffer.Empty, outPtr, false);
            var st = fn(user, pinTarget.Slice, pinArgs.Slice, outPtr);
            var buf = Marshal.PtrToStructure<AowlBuffer>(outPtr);
            var text = buf.ToUtf8String();
            FreeModBuffer(buf);

            if (st == AowlStatus.PatchSkip) return PatchOutcome.Replace(text);
            if (st != AowlStatus.Ok)
            {
                _services.Log(AowlLogLevel.Error, mod.Descriptor.Guid,
                    $"patch {target} returned {AowlStatus.Describe(st)} — running the original");
                return PatchOutcome.Continue;
            }
            return PatchOutcome.Continue;
        }
        finally { Marshal.FreeHGlobal(outPtr); }
    }

    private int HostSchedule(IntPtr ctx, int delayMs, IntPtr cb, IntPtr user)
    {
        var mod = FromCtx(ctx);
        if (mod is null || cb == IntPtr.Zero) return AowlStatus.ErrBadArg;
        var fn = Marshal.GetDelegateForFunctionPointer<AowlCallbackFn>(cb);
        mod.Keep(fn);
        try
        {
            _services.Schedule(delayMs, () => Invoke(mod, "scheduled callback",
                () => fn(user, AowlSlice.Empty, IntPtr.Zero)));
            return AowlStatus.Ok;
        }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
    }

    private int HostInvokeMain(IntPtr ctx, IntPtr cb, IntPtr user)
    {
        var mod = FromCtx(ctx);
        if (mod is null || cb == IntPtr.Zero) return AowlStatus.ErrBadArg;
        var fn = Marshal.GetDelegateForFunctionPointer<AowlCallbackFn>(cb);
        mod.Keep(fn);
        try
        {
            _services.InvokeMain(() => Invoke(mod, "main-thread callback",
                () => fn(user, AowlSlice.Empty, IntPtr.Zero)));
            return AowlStatus.Ok;
        }
        catch (NotSupportedException ex) { SetError(ex.Message); return AowlStatus.ErrUnsupported; }
    }

    private long HostNowMs(IntPtr ctx) => _clock.ElapsedMilliseconds;

    // ------------------------------------------------------------ plumbing

    /// <summary>
    /// Call into a mod with a net around it. A mod that faults is taken out of
    /// dispatch rather than allowed to fault again every tick.
    /// </summary>
    private void Invoke(LoadedMod mod, string what, Func<int> body)
    {
        try
        {
            var st = body();
            if (st != AowlStatus.Ok && st != AowlStatus.PatchSkip)
                _services.Log(AowlLogLevel.Error, mod.Descriptor.Guid,
                    $"{what} returned {AowlStatus.Describe(st)}");
        }
        catch (Exception ex)
        {
            mod.Faulted = true;
            _services.Log(AowlLogLevel.Error, mod.Descriptor.Guid,
                $"{what} faulted, mod disabled: {ex.Message}");
        }
    }

    private void LoadConfig(LoadedMod mod)
    {
        mod.ConfigPath = Path.Combine(mod.Directory, "config.json");
        if (!File.Exists(mod.ConfigPath)) { mod.Config = JsonValue.Object(); return; }
        try
        {
            if (JsonValue.TryParse(File.ReadAllText(mod.ConfigPath), out var cfg))
                mod.Config = cfg;
            else
                _services.Log(AowlLogLevel.Warn, mod.Descriptor.Guid,
                    "config.json is not valid JSON — starting from an empty config");
        }
        catch (IOException ex)
        {
            _services.Log(AowlLogLevel.Warn, mod.Descriptor.Guid, $"config unreadable: {ex.Message}");
        }
    }

    private static string EnsureDataDir(LoadedMod mod)
    {
        var dir = Path.Combine(mod.Directory, "data");
        try { System.IO.Directory.CreateDirectory(dir); } catch (IOException) { }
        return dir;
    }

    private string ShadowCopy(string libraryPath)
    {
        // Windows locks a mapped DLL, so building over a loaded mod fails with a
        // sharing violation. Loading a copy keeps the original writable, which is
        // what makes rebuild-and-reload possible at all.
        try
        {
            System.IO.Directory.CreateDirectory(_shadowRoot);
            var stamp = DateTime.UtcNow.Ticks.ToString("x");
            var name = Path.GetFileNameWithoutExtension(libraryPath) + "-" + stamp +
                       Path.GetExtension(libraryPath);
            var dest = Path.Combine(_shadowRoot, name);
            File.Copy(libraryPath, dest, true);

            // Debug symbols must travel with the copy or breakpoints in the mod
            // will not bind — see docs/DEBUGGING.md.
            foreach (var ext in new[] { ".pdb", ".debug" })
            {
                var sym = Path.ChangeExtension(libraryPath, ext);
                if (File.Exists(sym))
                    File.Copy(sym, Path.ChangeExtension(dest, ext), true);
            }
            return dest;
        }
        catch (IOException)
        {
            // Better to load in place than not at all; rebuild-while-running is
            // the only thing lost.
            return libraryPath;
        }
    }

    private void SweepStaleShadows()
    {
        try
        {
            if (!System.IO.Directory.Exists(_shadowRoot)) return;
            foreach (var f in System.IO.Directory.GetFiles(_shadowRoot))
            {
                try { File.Delete(f); }
                catch (IOException) { /* another host still has it mapped */ }
                catch (UnauthorizedAccessException) { }
            }
        }
        catch (IOException) { }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        UnloadAll();
    }
}
