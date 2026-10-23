// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
namespace OpenWebPbx.Phone.MediaChecks;

internal static partial class ProcessImage
{
    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, char* output, ref uint length);

    internal static unsafe string Require(Process process, string expectedPath, DateTime expectedStart, string expectedHash)
    {
        if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Native process image acquisition requires Windows.");
        var pid = process.Id; process.Refresh();
        Span<char> buffer = stackalloc char[32768]; uint length = (uint)buffer.Length;
        fixed (char* output = buffer)
        {
            // Unlike MainModule, this queries the held process image directly and
            // does not depend on the child's user-mode module loader being ready.
            if (!QueryFullProcessImageName(process.SafeHandle, 0, output, ref length) || length is 0 or >= 32768)
                throw new InvalidDataException("The owned process image could not be acquired.");
        }
        var actual = Validate(expectedPath, expectedStart.ToUniversalTime().Ticks, pid, new string(buffer[..(int)length]), process.StartTime.ToUniversalTime().Ticks, process.Id, process.HasExited);
        VerifyFile(actual, expectedHash); return actual;
    }

    internal static string HashFile(string path)
    {
        if (!Path.IsPathFullyQualified(path) || (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new InvalidDataException("An ordinary executable is required.");
        for (var parent = new DirectoryInfo(Path.GetDirectoryName(path)!); parent is not null; parent = parent.Parent)
            if (!parent.Exists || (parent.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Executable ancestry is linked or absent.");
        using var file = File.OpenRead(path); if (file.Length is <= 0 or > 67108864) throw new InvalidDataException("A bounded executable is required.");
        return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant();
    }
    internal static void VerifyFile(string path, string expectedHash)
    {
        if (expectedHash.Length != 64 || expectedHash.Any(c => !"0123456789abcdef".Contains(c)) || HashFile(path) != expectedHash) throw new InvalidDataException("The originally launched executable hash differs.");
    }
    internal static string Validate(string expectedPath, long expectedStart, int expectedPid, string actualPath, long actualStart, int actualPid, bool exited)
    {
        if (expectedPid <= 0 || actualPid != expectedPid || expectedStart <= 0 || actualStart != expectedStart || exited || !Path.IsPathFullyQualified(expectedPath) || !Path.IsPathFullyQualified(actualPath) || !expectedPath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !string.Equals(actualPath, expectedPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The owned process image identity differs.");
        return actualPath;
    }
}
