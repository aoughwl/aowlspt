// The C# mirror of abi/aowlspt_abi.h. Layouts here are load-bearing: every
// struct must match the header field for field, in order. See abi/ABI.md.

using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Aowlspt.Abi;

/// <summary>Status codes. Mirrors AOWLSPT_* in the header.</summary>
public static class AowlStatus
{
    public const int Ok = 0;
    public const int ErrGeneric = -1;
    public const int ErrAbi = -2;
    public const int ErrNotFound = -3;
    public const int ErrBadArg = -4;
    public const int ErrDecode = -5;
    public const int ErrUnsupported = -6;
    public const int ErrWrongThread = -7;
    public const int ErrDisposed = -8;
    public const int ErrModFault = -9;

    /// <summary>Returned by a prefix patch that wants the original suppressed.</summary>
    public const int PatchSkip = 1;

    public static string Describe(int status) => status switch
    {
        Ok => "ok",
        ErrGeneric => "generic failure",
        ErrAbi => "ABI mismatch",
        ErrNotFound => "not found",
        ErrBadArg => "bad argument",
        ErrDecode => "decode failure",
        ErrUnsupported => "unsupported by this host",
        ErrWrongThread => "wrong thread",
        ErrDisposed => "handle disposed",
        ErrModFault => "mod fault",
        PatchSkip => "patch: skip original",
        _ => $"unknown status {status}",
    };
}

public enum AowlEncoding
{
    Json = 0,
    Cbor = 1,
    Raw = 2,
    Nif = 3,
}

public enum AowlLogLevel
{
    Trace = 0,
    Debug = 1,
    Info = 2,
    Success = 3,
    Warn = 4,
    Error = 5,
}

public enum AowlSide
{
    Server = 1,
    Client = 2,
    Sim = 3,
}

public enum AowlPatchKind
{
    Prefix = 0,
    Postfix = 1,
    Finalizer = 2,
}

public enum AowlRouteKind
{
    Static = 0,
    Dynamic = 1,
}

[Flags]
public enum AowlModFlags : uint
{
    None = 0,
    HotReloadable = 1u << 0,
    ThreadSafe = 1u << 1,
}

/// <summary>
/// A borrowed view of native bytes. Valid only for the duration of the call it
/// was passed to — copy with <see cref="ToUtf8String"/> or <see cref="ToArray"/>
/// before storing.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct AowlSlice
{
    public IntPtr Ptr;
    public int Len;

    public static readonly AowlSlice Empty = new() { Ptr = IntPtr.Zero, Len = 0 };

    public bool IsEmpty => Len <= 0 || Ptr == IntPtr.Zero;

    public byte[] ToArray()
    {
        if (IsEmpty) return Array.Empty<byte>();
        var bytes = new byte[Len];
        Marshal.Copy(Ptr, bytes, 0, Len);
        return bytes;
    }

    public string ToUtf8String()
    {
        if (IsEmpty) return string.Empty;
        unsafe { return Encoding.UTF8.GetString((byte*)Ptr, Len); }
    }
}

/// <summary>
/// An owned native buffer. Whoever receives one frees it through the host
/// allocator — never through the local runtime's heap.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct AowlBuffer
{
    public IntPtr Ptr;
    public int Len;

    public static readonly AowlBuffer Empty = new() { Ptr = IntPtr.Zero, Len = 0 };

    public bool IsEmpty => Len <= 0 || Ptr == IntPtr.Zero;

    public byte[] ToArray()
    {
        if (IsEmpty) return Array.Empty<byte>();
        var bytes = new byte[Len];
        Marshal.Copy(Ptr, bytes, 0, Len);
        return bytes;
    }

    public string ToUtf8String()
    {
        if (IsEmpty) return string.Empty;
        unsafe { return Encoding.UTF8.GetString((byte*)Ptr, Len); }
    }
}

/// <summary>
/// Pins UTF-8 bytes for the lifetime of a call so they can be handed across as
/// an <see cref="AowlSlice"/>. Native code must not retain the slice past the
/// call, which is exactly what the ABI's "borrowed in" rule promises.
/// </summary>
public sealed class PinnedUtf8 : IDisposable
{
    private GCHandle _handle;
    private readonly int _len;

    public PinnedUtf8(string? text)
    {
        var bytes = string.IsNullOrEmpty(text) ? Array.Empty<byte>() : Encoding.UTF8.GetBytes(text);
        _len = bytes.Length;
        _handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
    }

    public PinnedUtf8(byte[]? bytes)
    {
        bytes ??= Array.Empty<byte>();
        _len = bytes.Length;
        _handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
    }

    public AowlSlice Slice => _len == 0
        ? AowlSlice.Empty
        : new AowlSlice { Ptr = _handle.AddrOfPinnedObject(), Len = _len };

    public void Dispose()
    {
        if (_handle.IsAllocated) _handle.Free();
    }
}
