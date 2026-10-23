// SPDX-License-Identifier: AGPL-3.0-or-later
#if PHONE_PACKAGE_FIXTURE
using System.Security.Cryptography;
using System.Text.Json;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
using Windows.Management.Deployment;
internal static class PackageFixtureSeed
{
    internal static async Task<bool> Run(string[] args)
    {
        if (args.Length != 1) return false;
        if (args[0] == "--fixture-list-packages")
        {
            _ = PackageFixture.Enabled;
            var installed = new PackageManager().FindPackagesForUser("").OrderBy(x => x.Id.FullName, StringComparer.Ordinal).Select(x => new { name = x.Id.Name, publisher = x.Id.Publisher, full_name = x.Id.FullName, family_name = x.Id.FamilyName, framework = x.IsFramework, resource = x.IsResourcePackage }).ToArray();
            Console.WriteLine(JsonSerializer.Serialize(installed)); return true;
        }
        if (args[0] is "--fixture-install" or "--fixture-remove" or "--fixture-info" or "--fixture-launch")
        {
            _ = PackageFixture.Enabled; var manager = new PackageManager();
            if (args[0] == "--fixture-install")
            {
                var path = Path.Combine(PackageFixture.Root, "install.msix"); if ((File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new InvalidOperationException();
                var installed = await manager.AddPackageAsync(new Uri(path), null, DeploymentOptions.None); if (installed.ExtendedErrorCode is not null) throw installed.ExtendedErrorCode;
            }
            var packages = manager.FindPackagesForUser("").Where(x => x.Id.Name == PackageFixture.IdentityName).ToArray();
            if (args[0] == "--fixture-remove" && packages.Length == 0) { Console.WriteLine("{\"schema\":1,\"producer\":\"PackageFixtureOperations\",\"state\":\"absent\"}"); return true; }
            if (packages.Length != 1 || packages[0].Id.Publisher != PackageFixture.Publisher) throw new InvalidOperationException("The owned development package is absent or ambiguous.");
            var package = packages[0]; var version = package.Id.Version;
            var receipt = new { schema = 1, producer = "PackageFixtureOperations", full_name = package.Id.FullName, family_name = package.Id.FamilyName, version = $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}", installed_location = package.InstalledLocation.Path, data_parent = ClientInstallation.PrivateDirectoryForPackage(package.Id.FamilyName) };
            if (args[0] == "--fixture-remove") { var removed = await manager.RemovePackageAsync(package.Id.FullName); if (removed.ExtendedErrorCode is not null) throw removed.ExtendedErrorCode; if (manager.FindPackagesForUser("").Any(x => x.Id.Name == PackageFixture.IdentityName)) throw new InvalidOperationException(); }
            else if (args[0] == "--fixture-launch") { if (!await (await package.GetAppListEntriesAsync()).Single(x => x.AppUserModelId.EndsWith("!App", StringComparison.Ordinal)).LaunchAsync()) throw new InvalidOperationException(); }
            Console.WriteLine(JsonSerializer.Serialize(receipt)); return true;
        }
        if (args[0] is not ("--fixture-seed" or "--fixture-checkpoint")) return false;
        _ = PackageFixture.Enabled; var store = new ProtectedProfileStore("direct");
        if (args[0] == "--fixture-seed")
        {
            if ((await store.ReadAsync()).Count != 0) throw new InvalidOperationException("The development fixture data already exists.");
            var profile = new PhoneProfile(Guid.NewGuid(), new("https://unregistered-fixture.openwebpbx.com"), new string('e',64), Guid.NewGuid(), new("does-not-resolve.invalid", "owned.invalid", "owm-invented", "owm-invented", "Invented-test-only-no-network", 5061), new(Guid.NewGuid(), Guid.NewGuid(), "9100", "Development", "Invented user"), [], "Development preserved profile", true);
            await store.SaveAsync([profile], profile.Id); new PreferencesStore("direct").Save(new() { Theme = "Dark", Notifications = false, HideCallerInNotifications = true });
            new PendingHistory("direct").Enqueue(new(Guid.NewGuid(), profile.Id, "9101", "incoming", DateTimeOffset.UtcNow, 7, true));
        }
        var accounts = await store.ReadAsync(); if (accounts.Count != 1 || !accounts[0].NeedsLogin || accounts[0].Name != "Development preserved profile" || await store.SelectedAsync() != accounts[0].Id || new PendingHistory("direct").For(accounts[0].Id).Count != 1 || new PreferencesStore("direct").Read() is not { Theme: "Dark", Notifications: false, HideCallerInNotifications: true }) throw new InvalidOperationException("The development fixture data changed.");
        var packageForData = new PackageManager().FindPackagesForUser("").Single(x => x.Id.Name == PackageFixture.IdentityName && x.Id.Publisher == PackageFixture.Publisher);
        var parent = Path.Combine(ClientInstallation.PrivateDirectoryForPackage(packageForData.Id.FamilyName), "direct");
        var hashes = new[] { "accounts.dpapi", "preferences.json", "pending-calls.dpapi" }.ToDictionary(name => name, name => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(parent, name)))).ToLowerInvariant());
        Console.WriteLine(JsonSerializer.Serialize(new { schema = 1, producer = "PackageFixtureSeed", profiles = 1, pending_calls = 1, no_network_account = true, hashes })); return true;
    }
}
#endif
