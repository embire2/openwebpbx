// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Runtime.InteropServices;
namespace OpenWebPbx.Phone.Windows;
public static class LaunchArguments
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
    /// <summary>Windows quoting only; never invokes a shell, expands variables or executes arguments.</summary>
    public static string[] Parse(string value)
    {
        if (value.Length > 20000 || value.Contains('\0')) throw new ArgumentException("The activation is too large.");
        var pointer = CommandLineToArgvW("phone.exe " + value, out var count); if (pointer == IntPtr.Zero) throw new ArgumentException("The activation could not be read.");
        try
        {
            if (count is < 1 or > 8) throw new ArgumentException("The activation has too many arguments.");
            return Enumerable.Range(1, count - 1).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, i * IntPtr.Size)) ?? "").ToArray();
        }
        finally { LocalFree(pointer); }
    }
}
