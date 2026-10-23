// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Diagnostics;
using System.Text.Json;
using OpenWebPbx.Phone.Core;
namespace OpenWebPbx.Phone.Windows;
public sealed record InstallRequest(int ParentId, long ParentStartedUtcTicks, string ParentPath, string InstalledFullName, string PackagePath, string Envelope);
public static class ClientInstallation
{
    public static Version CurrentVersion { get { try { var version = global::Windows.ApplicationModel.Package.Current.Id.Version; return new(version.Major, version.Minor, version.Build); } catch { return new(1, 0, 0); } } }
    public static bool IsPackaged { get { try { _ = global::Windows.ApplicationModel.Package.Current.Id; return true; } catch { return false; } } }
    public static (string Name, string Publisher, string FullName) Identity()
    {
        try { var id = global::Windows.ApplicationModel.Package.Current.Id; return (id.Name, id.Publisher, id.FullName); }
        catch { throw new PhoneInputException("This development build cannot install updates. Install the signed Windows phone package first."); }
    }
    public static async Task StartUpdate(string package, byte[] envelope, UpdateStorage storage)
    {
        var identity = Identity(); var floor = storage.Read(); using var key = ClientUpdateTrust.Open();
        var release = ClientRelease.Verify(envelope, key, floor.Sequence, identity.Name, identity.Publisher, floor.Sequence == 0 ? null : floor.PayloadSha256);
        package = Path.GetFullPath(package); if (Path.GetDirectoryName(package) != storage.Directory || (File.GetAttributes(package) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw new PhoneInputException("The private Windows update file changed.");
        using (var input = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read))
        { if (input.Length != release.Bytes || !Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(input)).Equals(release.Sha256, StringComparison.OrdinalIgnoreCase)) throw new PhoneInputException("The Windows update file changed. Download it again."); input.Position = 0; ClientPackage.ValidateBundle(input, release); }
        var executable = UpdateHelperCache.Stage(Path.Combine(AppContext.BaseDirectory, "updater"), storage); if (!File.Exists(executable)) throw new PhoneInputException("The Windows update helper is missing. Reinstall the official phone package.");
        using var parent = Process.GetCurrentProcess(); var request = new InstallRequest(parent.Id, parent.StartTime.ToUniversalTime().Ticks, Environment.ProcessPath!, identity.FullName, package, Convert.ToBase64String(envelope));
        var path = Path.Combine(storage.Directory, "install-" + Guid.NewGuid().ToString("N") + ".json");
        using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { JsonSerializer.Serialize(output, request); output.Flush(true); }
        var started = false;
        try
        {
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = AppContext.BaseDirectory }; start.ArgumentList.Add(path);
            using var child = Process.Start(start) ?? throw new InvalidOperationException(); started = true;
            var ready = path + ".ready"; using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            while (true)
            {
                deadline.Token.ThrowIfCancellationRequested(); if (child.HasExited) throw new InvalidOperationException();
                try
                {
                    if ((File.GetAttributes(ready) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || new FileInfo(ready).Length > 64) throw new InvalidOperationException();
                    if (File.ReadAllText(ready) != child.Id.ToString(System.Globalization.CultureInfo.InvariantCulture)) throw new InvalidOperationException(); return;
                }
                catch (FileNotFoundException) { await Task.Delay(50, deadline.Token); }
            }
        }
        catch { if (!started) File.Delete(path); throw new PhoneInputException("The Windows update helper could not become ready. Your current phone has been kept."); }
    }
}
