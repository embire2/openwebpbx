// SPDX-License-Identifier: AGPL-3.0-or-later
#if PHONE_MEDIA_FIXTURE
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
namespace OpenWebPbx.Phone.Windows;

// Test-only recorder attachment through the pinned SDK's PUBLIC Core.MsFactory.
// The actual NativePhone production build contains none of this type or its calls.
internal static class FixtureWavProducer
{
    private const string FileName = "libmsopenwebwav.dll";
    private static int attempted;
    private static FileStream? pinnedFile;
    private static nint pinnedLibrary;
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int FactoryOperation(nint factory);

    internal static FileStream OpenVerified(string appRoot, string runnerRoot, string expectedSha256)
    {
        if (!Regex.IsMatch(expectedSha256, "^[a-f0-9]{64}$")) throw new InvalidDataException("A pinned fixture recorder hash is required.");
        var app = Path.GetFullPath(appRoot).TrimEnd(Path.DirectorySeparatorChar);
        var runner = Path.GetFullPath(runnerRoot).TrimEnd(Path.DirectorySeparatorChar);
        if (!app.StartsWith(runner + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Fixture recorder must be in the owned runner application.");
        for (var parent = new DirectoryInfo(app); parent is not null; parent = parent.Parent)
            if (!parent.Exists || (parent.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Fixture recorder ancestry must be ordinary.");
        var path = Path.Combine(app, FileName); var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || info.Length is <= 0 or > 16777216) throw new InvalidDataException("An ordinary bounded fixture recorder is required.");
        var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            if (input.Length != info.Length || Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant() != expectedSha256) throw new InvalidDataException("The fixture recorder differs from its pinned input.");
            return input;
        }
        catch { input.Dispose(); throw; }
    }

    internal static void RequireSelected(nint factory, Func<nint, int> register, Func<nint, int> selected)
    {
        if (factory == 0) throw new InvalidDataException("The actual Core media factory is unavailable.");
        // Each export checks the exact version-pinned descriptor identity/name.
        // No fallback factory, private field, vtable patch or registry retry.
        if (register(factory) != 1 || selected(factory) != 1) throw new InvalidDataException("The actual Core did not select the fixture WAV recorder.");
    }

    internal static void Attach(Linphone.Core core, string expectedSha256)
    {
        if (!OperatingSystem.IsWindows() || RuntimeInformation.ProcessArchitecture != Architecture.X64 || Interlocked.Exchange(ref attempted, 1) != 0) throw new InvalidOperationException("Only one isolated Windows x64 Core recorder attachment is allowed.");
        pinnedFile = OpenVerified(AppContext.BaseDirectory, Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? throw new InvalidOperationException("The owned runner root is required."), expectedSha256);
        pinnedLibrary = NativeLibrary.Load(pinnedFile.Name);
        var register = Marshal.GetDelegateForFunctionPointer<FactoryOperation>(NativeLibrary.GetExport(pinnedLibrary, "openweb_fixture_wav_register"));
        var selected = Marshal.GetDelegateForFunctionPointer<FactoryOperation>(NativeLibrary.GetExport(pinnedLibrary, "openweb_fixture_wav_selected"));
        RequireSelected(core.MsFactory.nativePtr, register.Invoke, selected.Invoke);
        // Intentionally process-pinned: Core.Stop is not factory destruction.
        // Unloading would leave registered descriptor/function pointers dangling.
        // The exact owned peer process and all handles must close before cleanup.
        GC.KeepAlive(pinnedFile); GC.KeepAlive(pinnedLibrary);
    }
}
#endif
