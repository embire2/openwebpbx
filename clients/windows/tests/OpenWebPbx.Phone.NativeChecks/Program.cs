// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") != "embire2/openwebpbx") throw new InvalidOperationException("Only a disposable native Windows runner may execute this fixture.");
if (args.Length != 1 || Path.GetDirectoryName(Path.GetFullPath(args[0])) != Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP")!).TrimEnd(Path.DirectorySeparatorChar) || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(args[0]), "^phone-native-result-[a-f0-9]{32}\\.json$")) throw new InvalidOperationException("Native receipt path differs.");
var root = Path.Combine(Environment.GetEnvironmentVariable("RUNNER_TEMP")!, "phone-native-" + Guid.NewGuid().ToString("N"));
var checks = 0;
NativeAuthStorageProof? authStorage = null;
void Observe(string stage) => File.WriteAllText(args[0], JsonSerializer.Serialize(new { schema = 1, producer = "OpenWebPbx.Phone.NativeChecks", state = "running", checks, stage, auth_storage = authStorage }));
void Check(bool value) { if (!value) throw new InvalidOperationException("Native control " + (checks + 1) + " failed."); checks++; }
try
{
    Observe("dpapi_start"); var store = new ProtectedProfileStore("direct", root); Check((await store.ReadAsync()).Count == 0);
    var profile = new PhoneProfile(Guid.NewGuid(), new("https://invented.openwebpbx.com"), new string('e', 64), Guid.NewGuid(), new("sip.example.invalid", "realm.example.invalid", "owm-invented", "owm-invented", "Invented-private-credential-no-network", 5061), new(Guid.NewGuid(), Guid.NewGuid(), "1000", "Invented", "Isolated check"), []);
    await store.SaveAsync([profile], profile.Id); var saved = (await store.ReadAsync()).Single(); Check(saved.Sip == profile.Sip); Check(saved.Token == profile.Token); Check(await store.SelectedAsync() == profile.Id);
    var file = Path.Combine(root, "accounts.dpapi"); var encrypted = File.ReadAllBytes(file);
    Check(!Encoding.UTF8.GetString(encrypted).Contains(profile.Sip.Password)); Check(!Encoding.UTF8.GetString(encrypted).Contains(profile.Token));
    var current = WindowsIdentity.GetCurrent().User!.Value; var acl = new FileInfo(file).GetAccessControl(); Check(acl.AreAccessRulesProtected);
    var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray(); Check(rules.Length == 2); Check(rules.All(r => r.AccessControlType == AccessControlType.Allow && (r.IdentityReference.Value == current || r.IdentityReference.Value == "S-1-5-18")));
    var changed = encrypted.ToArray(); changed[^1] ^= 1; File.WriteAllBytes(file, changed); var refused = false; try { await store.ReadAsync(); } catch (PhoneInputException) { refused = true; } Check(refused); File.WriteAllBytes(file, encrypted);
    await store.SaveAsync([], null); Check((await store.ReadAsync()).Count == 0); Check(await store.SelectedAsync() is null);
    foreach (var entry in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) { var content = Encoding.UTF8.GetString(File.ReadAllBytes(entry)); Check(!content.Contains(profile.Sip.Password) && !content.Contains(profile.Token)); }
    Observe("native_start"); using (var native = new NativePhone(stage => Observe("native_" + stage))) { Check(!native.Busy); Check(native.Calls.Count == 0); native.Iterate(); Check(native.Registrations.Count == 0); Observe("native_auth_inspection"); var valid = native.VerifyVolatileAuth(profile.Sip.Password); authStorage = native.AuthStorageProof; Observe("native_auth_inspection"); Check(valid); }
    using var output = new FileStream(args[0], FileMode.Create, FileAccess.Write, FileShare.Read);
    JsonSerializer.Serialize(output, new { schema = 1, producer = "OpenWebPbx.Phone.NativeChecks", state = "passed", checks, actual_native_windows = true, actual_current_user_dpapi = true, actual_native_core = true, calls_placed = false, hardware_media_tested = false, auth_storage = authStorage });
    Console.WriteLine("PASS native protected-storage/core component; no calling/hardware qualification");
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
