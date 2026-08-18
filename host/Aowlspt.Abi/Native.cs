// Blittable mirrors of the header's structs, plus the delegate shapes used to
// build them.
//
// Every function-pointer field is declared as IntPtr rather than as a delegate
// field. That keeps these structs blittable — so they can be written straight to
// native memory with no marshaller in the middle — and it makes the delegate
// lifetime explicit: whoever fills the struct must also keep the delegates
// alive, which is what AowlHostApiBuilder is for.

using System;
using System.Runtime.InteropServices;

namespace Aowlspt.Abi;

public static class AowlAbi
{
    public const uint Version = 1;
    public const uint Revision = 1;

    public const string SymAbiVersion = "aowlspt_abi_version";
    public const string SymDescribe = "aowlspt_describe";
    public const string SymInit = "aowlspt_init";
}

// ---------------------------------------------------------------- structs

[StructLayout(LayoutKind.Sequential)]
public struct AowlHostInfoNative
{
    public int Size;
    public uint AbiVersion;
    public uint AbiRevision;
    public int Side;
    public AowlSlice HostName;
    public AowlSlice HostVersion;
    public AowlSlice SptVersion;
    public AowlSlice GameVersion;
    public uint Encodings;
    public AowlSlice ModDir;
    public AowlSlice DataDir;
}

[StructLayout(LayoutKind.Sequential)]
public struct AowlHostApiNative
{
    public int Size;
    public IntPtr Ctx;
    public IntPtr Info;

    public IntPtr Alloc;
    public IntPtr Free;
    public IntPtr Log;
    public IntPtr LastError;
    public IntPtr ConfigGet;
    public IntPtr ConfigSet;
    public IntPtr DbGet;
    public IntPtr DbPatch;
    public IntPtr RouteRegister;
    public IntPtr EventSubscribe;
    public IntPtr EventEmit;
    public IntPtr Call;
    public IntPtr Resolve;
    public IntPtr HandleRelease;
    public IntPtr Patch;
    public IntPtr Schedule;
    public IntPtr InvokeMain;
    public IntPtr NowMs;
}

[StructLayout(LayoutKind.Sequential)]
public struct AowlModInfoNative
{
    public int Size;
    public uint AbiVersion;
    public uint AbiRevision;
    public AowlSlice Guid;
    public AowlSlice Name;
    public AowlSlice Author;
    public AowlSlice Version;
    public AowlSlice SptRange;
    public uint Sides;
    public uint Flags;
}

[StructLayout(LayoutKind.Sequential)]
public struct AowlModApiNative
{
    public int Size;
    public IntPtr Self;
    public IntPtr OnLoad;
    public IntPtr OnUpdate;
    public IntPtr OnUnload;
    public IntPtr StateSave;
    public IntPtr StateLoad;
}

// ---------------------------------------------- host-side delegate shapes

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate IntPtr AowlAllocFn(IntPtr ctx, int bytes);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void AowlFreeFn(IntPtr ctx, IntPtr ptr);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void AowlLogFn(IntPtr ctx, int level, AowlSlice message);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void AowlLastErrorFn(IntPtr ctx, IntPtr outSlice);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlConfigGetFn(IntPtr ctx, AowlSlice key, IntPtr outBuffer);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlConfigSetFn(IntPtr ctx, AowlSlice key, AowlSlice valueJson);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlDbGetFn(IntPtr ctx, AowlSlice path, IntPtr outBuffer);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlDbPatchFn(IntPtr ctx, AowlSlice path, AowlSlice patchJson);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlRouteRegisterFn(IntPtr ctx, AowlSlice url, int kind, IntPtr handler, IntPtr user);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlEventSubscribeFn(IntPtr ctx, AowlSlice name, IntPtr handler, IntPtr user);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlEventEmitFn(IntPtr ctx, AowlSlice name, AowlSlice payload);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlCallFn(IntPtr ctx, AowlSlice target, AowlSlice args, IntPtr outBuffer);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlResolveFn(IntPtr ctx, AowlSlice typeName, IntPtr outHandle);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void AowlHandleReleaseFn(IntPtr ctx, ulong handle);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlPatchRegisterFn(IntPtr ctx, AowlSlice target, int kind, IntPtr handler, IntPtr user);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlScheduleFn(IntPtr ctx, int delayMs, IntPtr cb, IntPtr user);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlInvokeMainFn(IntPtr ctx, IntPtr cb, IntPtr user);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate long AowlNowMsFn(IntPtr ctx);

// ----------------------------------------------- mod-side delegate shapes

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate uint AowlAbiVersionFn();

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlDescribeFn(IntPtr outInfo);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlInitFn(IntPtr hostApi, IntPtr outModApi);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlLifecycleFn(IntPtr self);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlOnUpdateFn(IntPtr self, long elapsedMs);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlStateSaveFn(IntPtr self, IntPtr outBuffer);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlStateLoadFn(IntPtr self, AowlSlice state);

/// <summary>A generic mod callback: event handler, scheduled tick, main-thread work.</summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlCallbackFn(IntPtr user, AowlSlice payload, IntPtr outBuffer);

/// <summary>A mod HTTP route handler.</summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlRouteFn(IntPtr user, AowlSlice url, AowlSlice body, AowlSlice session, IntPtr outBuffer);

/// <summary>A mod patch handler.</summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int AowlPatchFn(IntPtr user, AowlSlice target, AowlSlice args, IntPtr outBuffer);
