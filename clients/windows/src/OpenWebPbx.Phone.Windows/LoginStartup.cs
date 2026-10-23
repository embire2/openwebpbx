// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.Win32;
namespace OpenWebPbx.Phone.Windows;
public static class LoginStartup
{
    private const string Name = "OpenWebPBX Free Phone";
    public static void SetDirect(bool enabled, string executable)
    {
        var path = Path.GetFullPath(executable); if (!File.Exists(path) || !path.EndsWith("OpenWebPbx.Phone.App.exe", StringComparison.OrdinalIgnoreCase) || path.Contains('"')) throw new ArgumentException("The phone executable differs.");
        using var run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
        var expected = "\"" + path + "\" --startup"; var existing = run.GetValue(Name);
        if (existing is not null && existing is not string) throw new InvalidOperationException("An existing startup entry is not owned by this phone.");
        if (existing is string text && !text.Equals(expected, StringComparison.Ordinal)) throw new InvalidOperationException("An existing startup entry is not owned by this phone.");
        if (enabled) run.SetValue(Name, expected, RegistryValueKind.String); else if (existing is not null) run.DeleteValue(Name);
    }
}
