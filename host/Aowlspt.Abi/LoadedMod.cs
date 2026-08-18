// One loaded native mod: the library handle, the two API structs, and every
// piece of native memory whose lifetime is tied to it.
//
// The delegates matter as much as the pointers. A delegate handed to native code
// via Marshal.GetFunctionPointerForDelegate is not rooted by the native side —
// if the managed object is collected, the pointer becomes a jump into freed
// memory, and the crash surfaces later, somewhere else, usually mid-raid. So
// every delegate that native code can still call is held in _keepAlive for as
// long as the mod is loaded.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace Aowlspt.Abi;

public sealed class ModDescriptor
{
    public string Guid = "";
    public string Name = "";
    public string Author = "";
    public string Version = "";
    public string SptRange = "";
    public uint Sides;
    public AowlModFlags Flags;

    public bool SupportsSide(AowlSide side) => (Sides & (1u << (int)side)) != 0;
    public bool HotReloadable => (Flags & AowlModFlags.HotReloadable) != 0;

    public override string ToString() => $"{Name} ({Guid}) v{Version}";
}

public sealed class LoadedMod : IDisposable
{
    public string Directory { get; }
    public string SourceLibraryPath { get; }
    public string LoadedLibraryPath { get; }
    public ModDescriptor Descriptor { get; internal set; } = new();
    public bool Faulted { get; internal set; }

    internal IntPtr Library;
    internal AowlModApiNative ModApi;
    internal IntPtr HostApiPtr;
    internal IntPtr HostInfoPtr;
    internal GCHandle CtxHandle;

    internal JsonValue Config = JsonValue.Object();
    internal string ConfigPath = "";

    /// <summary>Thread-local so two mods faulting at once cannot overwrite each other.</summary>
    [ThreadStatic] internal static string? LastErrorText;
    internal GCHandle LastErrorPin;

    private readonly List<object> _keepAlive = new();
    private readonly List<IntPtr> _nativeAllocations = new();
    private bool _disposed;

    internal LoadedMod(string directory, string sourceLibraryPath, string loadedLibraryPath)
    {
        Directory = directory;
        SourceLibraryPath = sourceLibraryPath;
        LoadedLibraryPath = loadedLibraryPath;
    }

    /// <summary>Root a delegate for as long as native code can call it.</summary>
    internal T Keep<T>(T d) where T : Delegate
    {
        _keepAlive.Add(d);
        return d;
    }

    internal IntPtr TrackAlloc(int bytes)
    {
        var p = Marshal.AllocHGlobal(bytes);
        _nativeAllocations.Add(p);
        return p;
    }

    /// <summary>Copy a string into native memory owned by this mod's lifetime.</summary>
    internal AowlSlice NativeString(string? text)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(text ?? "");
        if (bytes.Length == 0) return AowlSlice.Empty;
        var p = TrackAlloc(bytes.Length);
        Marshal.Copy(bytes, 0, p, bytes.Length);
        return new AowlSlice { Ptr = p, Len = bytes.Length };
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        // Order matters: unload the library before releasing the memory it was
        // handed, so nothing it does on detach touches a freed pointer.
        if (Library != IntPtr.Zero)
        {
            NativeLibraryLoader.Free(Library);
            Library = IntPtr.Zero;
        }

        foreach (var p in _nativeAllocations)
            Marshal.FreeHGlobal(p);
        _nativeAllocations.Clear();

        if (HostApiPtr != IntPtr.Zero) { Marshal.FreeHGlobal(HostApiPtr); HostApiPtr = IntPtr.Zero; }
        if (HostInfoPtr != IntPtr.Zero) { Marshal.FreeHGlobal(HostInfoPtr); HostInfoPtr = IntPtr.Zero; }
        if (CtxHandle.IsAllocated) CtxHandle.Free();
        if (LastErrorPin.IsAllocated) LastErrorPin.Free();

        _keepAlive.Clear();

        // The shadow copy exists so the original stays writable for a rebuild;
        // it is this host's litter and goes away with the mod.
        TryDeleteShadow();
    }

    private void TryDeleteShadow()
    {
        if (LoadedLibraryPath == SourceLibraryPath) return;
        try { if (File.Exists(LoadedLibraryPath)) File.Delete(LoadedLibraryPath); }
        catch (IOException) { /* still mapped; the next run's sweep gets it */ }
        catch (UnauthorizedAccessException) { }
    }
}
