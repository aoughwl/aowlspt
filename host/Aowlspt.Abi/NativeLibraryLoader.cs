// Loading a shared library, portably.
//
// System.Runtime.InteropServices.NativeLibrary would do this in one line. This
// hand-rolls it because the assembly used to target netstandard2.1 for the
// Unity-Mono client host, which had neither. That host is gone and the
// constraint with it; the code stays because it works, is three stable
// functions per platform, and reports LoadLibrary's failure modes better than
// NativeLibrary does. Replacing it is a change to how every mod is loaded, so
// it wants its own commit rather than riding along with a deletion.

using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Aowlspt.Abi;

public static class NativeLibraryLoader
{
    private static class Win32
    {
        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr LoadLibraryW(string path);

        [DllImport("kernel32", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FreeLibrary(IntPtr handle);

        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi, BestFitMapping = false)]
        public static extern IntPtr GetProcAddress(IntPtr handle, string name);

        [DllImport("kernel32")]
        public static extern uint GetLastError();
    }

    private static class Posix
    {
        public const int RTLD_NOW = 2;
        public const int RTLD_LOCAL = 0;

        [DllImport("libdl.so.2", EntryPoint = "dlopen")]
        public static extern IntPtr DlOpen(string path, int flags);

        [DllImport("libdl.so.2", EntryPoint = "dlclose")]
        public static extern int DlClose(IntPtr handle);

        [DllImport("libdl.so.2", EntryPoint = "dlsym")]
        public static extern IntPtr DlSym(IntPtr handle, string name);

        [DllImport("libdl.so.2", EntryPoint = "dlerror")]
        public static extern IntPtr DlError();
    }

    public static bool IsWindows =>
        RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

    /// <summary>The conventional file name for a mod library on this platform.</summary>
    public static string LibraryFileName(string stem) =>
        IsWindows ? stem + ".dll" : "lib" + stem + ".so";

    public static IntPtr Load(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException("native mod library not found", path);

        // An absolute path keeps the OS from searching, which is both faster and
        // the only way to be sure which copy got loaded when a shadow copy and
        // the original are both on disk.
        var full = Path.GetFullPath(path);

        if (IsWindows)
        {
            var handle = Win32.LoadLibraryW(full);
            if (handle == IntPtr.Zero)
            {
                var err = Win32.GetLastError();
                throw new InvalidOperationException(
                    $"LoadLibrary failed for '{full}' (error {err}). " +
                    "A missing transitive dependency reports the same code as a missing file — " +
                    "check the library's own DLL imports.");
            }
            return handle;
        }
        else
        {
            var handle = Posix.DlOpen(full, Posix.RTLD_NOW | Posix.RTLD_LOCAL);
            if (handle == IntPtr.Zero)
                throw new InvalidOperationException($"dlopen failed for '{full}': {LastPosixError()}");
            return handle;
        }
    }

    public static void Free(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return;
        if (IsWindows) Win32.FreeLibrary(handle);
        else Posix.DlClose(handle);
    }

    /// <summary>Resolve a symbol, or IntPtr.Zero when the library does not export it.</summary>
    public static IntPtr TryGetSymbol(IntPtr handle, string name) =>
        IsWindows ? Win32.GetProcAddress(handle, name) : Posix.DlSym(handle, name);

    public static IntPtr GetSymbol(IntPtr handle, string name)
    {
        var sym = TryGetSymbol(handle, name);
        if (sym == IntPtr.Zero)
            throw new EntryPointNotFoundException($"the mod library does not export '{name}'");
        return sym;
    }

    public static T GetDelegate<T>(IntPtr handle, string name) where T : Delegate =>
        (T)Marshal.GetDelegateForFunctionPointer(GetSymbol(handle, name), typeof(T));

    private static string LastPosixError()
    {
        var p = Posix.DlError();
        return p == IntPtr.Zero ? "(no error text)" : Marshal.PtrToStringAnsi(p) ?? "(unreadable)";
    }
}
