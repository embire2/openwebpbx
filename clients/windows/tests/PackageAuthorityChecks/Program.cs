// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.AccessControl;
using System.Security.Principal;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using F = OpenWebPbx.Phone.Core.PackageFixture;

if (args.Length == 1 && args[0] == "--host-child") { Console.ReadLine(); return; }
int checks = 0, nativeRoots = 0, nativeIdentity = 0, nativeHost = 0;
void Check(bool value) { if (!value) throw new InvalidOperationException($"Authority control {checks + 1} failed."); checks++; }
void Refuse(Action action) { bool refused = false; try { action(); } catch (Exception e) when (e is InvalidOperationException or InvalidDataException or JsonException) { refused = true; } Check(refused); }
string nonce = new('a', 32), root = Path.Combine(Path.GetTempPath(), "phone-package-" + nonce);
string sid = "S-1-5-21-123", machine = "fixture-host", executable = Path.Combine(root, "host.exe");
var options = new F.Options(nonce, root, new string('p', 400), "http://127.0.0.1:40000/", 42, 12345, executable, sid, machine, new string('b', 40));
var now = DateTimeOffset.UtcNow; string Stamp(DateTimeOffset time) => time.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
string family = "OpenWebPBX.FreePhone.Dev." + nonce[..16] + "_" + new string('c', 13);
var context = new F.HostContext(1, "PackageHostContext", nonce, root, options.SourceCommit, 42, 12345, executable, sid, machine, family, Path.Combine(root, family, "LocalState", "OpenWebPBX Free Phone"), new string('d', 64), new string('f', 64), new string('e', 64), Stamp(now.AddMinutes(-1)), Stamp(now.AddMinutes(59)));
F.ValidateContext(options, context, sid, machine, now); Check(true);
string contextJson = JsonSerializer.Serialize(context);
using (var input = new MemoryStream(Encoding.UTF8.GetBytes(contextJson))) Check(F.ReadContext(input) == context);
foreach (string changed in new[] { contextJson.Replace("\"Schema\":1,", "\"Schema\":1,\"Schema\":1,"), contextJson.Replace("\"Schema\":1,", "\"Unknown\":1,\"Schema\":1,"), contextJson.Replace("\"Schema\":1,", ""), contextJson.Replace("\"Schema\":1,", "\"Schema\":\"1\","), new string(' ', 16385) }) { using var input = new MemoryStream(Encoding.UTF8.GetBytes(changed)); Refuse(() => F.ReadContext(input)); }

foreach (var changed in new[] {
 context with { Schema = 2 }, context with { Producer = "foreign" }, context with { Nonce = new string('f', 32) }, context with { Root = root + "-other" }, context with { SourceCommit = new string('f', 40) },
 context with { HostProcessId = 43 }, context with { HostStartedUtcTicks = 12346 }, context with { HostExecutable = executable + ".other" }, context with { UserSid = sid + "0" }, context with { MachineName = "foreign" },
 context with { FamilyName = context.FamilyName + "0" }, context with { CoreSha256 = "not-a-hash" }, context with { HelperSha256 = "not-a-hash" }, context with { HelperCoreSha256 = "not-a-hash" }, context with { DataParent = "relative" }, context with { DataParent = Path.Combine(root, "foreign-data") },
 context with { IssuedUtc = Stamp(now.AddMinutes(2)) }, context with { ExpiresUtc = Stamp(now.AddSeconds(-1)) }, context with { ExpiresUtc = Stamp(now.AddHours(3)) }, context with { IssuedUtc = "2026-10-23" }, context with { ExpiresUtc = "private-time" }
}) Refuse(() => F.ValidateContext(options, changed, sid, machine, now));
Refuse(() => F.ValidateContext(options, context, sid + "0", machine, now)); Refuse(() => F.ValidateContext(options, context, sid, "foreign", now));
var observed = new Dictionary<string, string?> { ["GITHUB_ACTIONS"] = "true", ["RUNNER_ENVIRONMENT"] = "github-hosted", ["GITHUB_REPOSITORY"] = "embire2/openwebpbx", ["RUNNER_TEMP"] = Path.GetDirectoryName(root) };
Check(F.ValidateEnvironment(options, observed)); Check(!F.ValidateEnvironment(options, new Dictionary<string, string?>()));
foreach (string name in observed.Keys)
{
 var absent = new Dictionary<string, string?>(observed); absent.Remove(name); Check(!F.ValidateEnvironment(options, absent));
 var conflict = new Dictionary<string, string?>(observed) { [name] = "foreign" }; Refuse(() => F.ValidateEnvironment(options, conflict));
}
var identity = new F.NativeIdentity("OpenWebPBX.FreePhone.Dev." + nonce[..16], "CN=FreePhone Development " + nonce, context.FamilyName, Path.Combine(root, "installed"));
string app = Path.Combine(identity.InstalledPath, "OpenWebPbx.Phone.App.exe"); F.ValidateIdentity(options, context, identity, app); Check(true);
foreach (var changed in new[] { identity with { Name = "foreign" }, identity with { Publisher = "CN=foreign" }, identity with { FamilyName = "foreign" }, identity with { InstalledPath = "relative" } }) Refuse(() => F.ValidateIdentity(options, context, changed, app));
Refuse(() => F.ValidateIdentity(options, context, identity, app + ".foreign"));
foreach (int length in new[] { 0, 1, 8192 }) { using var input = new MemoryStream(new byte[length]); Check(F.ReadBounded(input, 8192).Length == length); }
using (var input = new MemoryStream(new byte[8193])) Refuse(() => F.ReadBounded(input, 8192));
using (var input = new FragmentedStream(new byte[8192])) Check(F.ReadBounded(input, 8192).Length == 8192);
if (OperatingSystem.IsWindows())
{
 string directory = Path.Combine(Path.GetTempPath(), "phone-authority-check-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
 try
 {
  string currentSid = WindowsIdentity.GetCurrent().User!.Value;
  var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
  foreach (string allowed in new[] { currentSid, "S-1-5-18" }) acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(allowed), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
  new DirectoryInfo(directory).SetAccessControl(acl); F.ProtectedRoot(directory, currentSid); Check(true); nativeRoots++;
  Refuse(() => F.ProtectedRoot(directory, "S-1-5-21-999")); nativeRoots++;
  string inherited = Path.Combine(directory, "inherited"); Directory.CreateDirectory(inherited); Refuse(() => F.ProtectedRoot(inherited, currentSid)); nativeRoots++;
  string link = directory + "-link"; Directory.CreateSymbolicLink(link, directory); try { Refuse(() => F.ProtectedRoot(link, currentSid)); nativeRoots++; } finally { Directory.Delete(link); }
  var changedAcl = new DirectorySecurity(); changedAcl.SetSecurityDescriptorSddlForm(acl.GetSecurityDescriptorSddlForm(AccessControlSections.All)); changedAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-1-0"), FileSystemRights.Read, AccessControlType.Allow));
  new DirectoryInfo(directory).SetAccessControl(changedAcl); try { Refuse(() => F.ProtectedRoot(directory, currentSid)); nativeRoots++; } finally { new DirectoryInfo(directory).SetAccessControl(acl); }
  Check(F.CurrentIdentity() is null); nativeIdentity++;
  var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, RedirectStandardInput = true, CreateNoWindow = true };
  if (Path.GetFileNameWithoutExtension(start.FileName).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(F).Assembly.Location);
  start.ArgumentList.Add("--host-child"); using var child = Process.Start(start) ?? throw new InvalidOperationException();
  var childStarted = child.StartTime.ToUniversalTime(); string childPath = child.MainModule!.FileName;
  try
  {
   var live = options with { HostProcessId = child.Id, HostStartedUtcTicks = childStarted.Ticks, HostExecutable = childPath, UserSid = currentSid, MachineName = Environment.MachineName };
   F.LiveHost(live); Check(true); nativeHost++;
   foreach (var changed in new[] { live with { HostProcessId = Environment.ProcessId }, live with { HostStartedUtcTicks = childStarted.Ticks + 1 }, live with { HostExecutable = childPath + ".foreign" }, live with { UserSid = "S-1-5-21-999" }, live with { MachineName = "foreign-machine" }, live with { SourceCommit = "not-a-source" } }) { Refuse(() => F.LiveHost(changed)); nativeHost++; }
   child.StandardInput.WriteLine("done"); child.StandardInput.Close(); Check(child.WaitForExit(10000) && child.ExitCode == 0); nativeHost++;
   bool refused = false; try { F.LiveHost(live); } catch (Exception error) when (error is ArgumentException or InvalidOperationException) { refused = true; } Check(refused); nativeHost++;
  }
  finally { if (!child.HasExited) { if (child.StartTime.ToUniversalTime() != childStarted || child.MainModule?.FileName != childPath) throw new InvalidOperationException("Child ownership changed."); child.Kill(); if (!child.WaitForExit(10000)) throw new InvalidOperationException("Owned child remains."); } }
 }
 finally { Directory.Delete(directory, true); }
}
Console.WriteLine($"PASS {checks} package authority controls; native_root_checks={nativeRoots}; native_identity_checks={nativeIdentity}; native_host_checks={nativeHost}");

sealed class FragmentedStream(byte[] bytes) : MemoryStream(bytes)
{
 public override int Read(byte[] buffer, int offset, int count) => base.Read(buffer, offset, Math.Min(count, 3));
}

// Explicit URL adapter: authority tests do not invoke update transport or PackageFixture.Map.
namespace OpenWebPbx.Phone.Core { public static class ReleaseDownload { public static Uri Catalogue => new("https://example.invalid/catalogue"); } }
