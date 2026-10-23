// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
using Windows.Management.Deployment;
string? requestPath = null; string? readyPath = null; bool ownedRequest = false;
try
{
    if (args.Length != 1) throw new InvalidOperationException(); var storage = new UpdateStorage("direct"); requestPath = Path.GetFullPath(args[0]);
    if (Path.GetDirectoryName(requestPath) != storage.Directory || !Regex.IsMatch(Path.GetFileName(requestPath), "^install-[a-f0-9]{32}\\.json$") || (File.GetAttributes(requestPath) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || new FileInfo(requestPath).Length > 524288) throw new InvalidOperationException();
    var request = JsonSerializer.Deserialize<InstallRequest>(File.ReadAllBytes(requestPath)) ?? throw new InvalidOperationException();
    var installedBefore = new PackageManager().FindPackagesForUser("").Single(x => x.Id.FullName == request.InstalledFullName);
    var identity = (Name: installedBefore.Id.Name, Publisher: installedBefore.Id.Publisher, FullName: installedBefore.Id.FullName);
    if (request.ParentId < 1 || !request.ParentPath.Equals(Path.Combine(installedBefore.InstalledLocation.Path, "OpenWebPbx.Phone.App.exe"), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException();
    var helperRoot = Path.GetDirectoryName(Environment.ProcessPath!)!;
    if (!Path.GetDirectoryName(helperRoot)!.Equals(storage.Directory, StringComparison.OrdinalIgnoreCase) || !Regex.IsMatch(Path.GetFileName(helperRoot), "^helper-[a-f0-9]{32}$")) throw new InvalidOperationException();
    using var parent = Process.GetProcessById(request.ParentId);
    if (parent.StartTime.ToUniversalTime().Ticks != request.ParentStartedUtcTicks || !string.Equals(parent.MainModule?.FileName, request.ParentPath, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException();
    uint packageNameLength = 0; var code = GetPackageFullName(parent.Handle, ref packageNameLength, null); if (code != 122 || packageNameLength is < 3 or > 1024) throw new InvalidOperationException();
    var packageName = new System.Text.StringBuilder((int)packageNameLength); if (GetPackageFullName(parent.Handle, ref packageNameLength, packageName) != 0 || packageName.ToString() != identity.FullName) throw new InvalidOperationException();
    var floor = storage.Read(); using var key = ClientUpdateTrust.Open(); var release = ClientRelease.Verify(Convert.FromBase64String(request.Envelope), key, floor.Sequence, identity.Name, identity.Publisher, floor.Sequence == 0 ? null : floor.PayloadSha256);
    var package = Path.GetFullPath(request.PackagePath);
    if (Path.GetDirectoryName(package) != storage.Directory || (File.GetAttributes(package) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new InvalidOperationException();
    await using var locked = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read);
    if (locked.Length != release.Bytes || !Convert.ToHexString(SHA256.HashData(locked)).Equals(release.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException(); locked.Position = 0; ClientPackage.ValidateBundle(locked, release);
    ownedRequest = true; readyPath = requestPath + ".ready";
    using (var ready = new FileStream(readyPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough)) { var value = System.Text.Encoding.ASCII.GetBytes(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture)); ready.Write(value); ready.Flush(true); }
    File.Delete(requestPath); requestPath = null;
    Console.WriteLine("Updating OpenWebPBX Free Phone. Your accounts and settings are kept.");
    using (var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30))) await parent.WaitForExitAsync(deadline.Token);
    var result = await new PackageManager().AddPackageAsync(new Uri(package), null, DeploymentOptions.None);
    if (result.ExtendedErrorCode is not null) throw new InvalidOperationException();
    var installed = new PackageManager().FindPackagesForUser("").Single(x => x.Id.Name == identity.Name && x.Id.Publisher == identity.Publisher);
    var app = (await installed.GetAppListEntriesAsync()).Single(x => x.AppUserModelId.EndsWith("!App", StringComparison.Ordinal));
    if (!await app.LaunchAsync()) throw new InvalidOperationException();
}
catch
{
    // Never force-close the parent, replace app files or alter Windows trust. Windows deployment owns transactional rollback.
    Console.Error.WriteLine("Windows could not complete this phone update. Open your current phone and try again. Your accounts and settings have been kept."); Environment.ExitCode = 1;
}
finally { if (ownedRequest) { if (requestPath is not null) try { File.Delete(requestPath); } catch { } if (readyPath is not null) try { File.Delete(readyPath); } catch { } } }

[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
static extern int GetPackageFullName(IntPtr process, ref uint length, System.Text.StringBuilder? name);
