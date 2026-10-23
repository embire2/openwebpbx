// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.UI.Xaml.Controls;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
using Windows.Services.Store;
namespace OpenWebPbx.Phone.App;
public sealed partial class MainPage
{
    private static Version ClientVersion => ClientInstallation.CurrentVersion;
    private UpdateRequirement? updateRequirement;
    private ClientRelease? updateRelease;
    private byte[]? updateEnvelope;
    private string? downloadedUpdate;
    private bool checkingUpdate;
    private DateTimeOffset updateChecked;
    private StoreContext? storeUpdates;
    private IReadOnlyList<StorePackageUpdate> storePackages = [];
    private bool storeDownloaded;
    private void RequireNewCall() => updateRequirement?.RequireNewCall();
    private void Dial(string number) { RequireNewCall(); phone!.Dial(number); }
    private async Task TryCheckUpdates()
    {
        if (checkingUpdate || saved.Count == 0 || DateTimeOffset.UtcNow - updateChecked < TimeSpan.FromMinutes(30)) return;
        try { await CheckUpdates(); } catch { /* A failed optional check never replaces active calling or a known required notice. */ }
    }
    private async Task CheckUpdates()
    {
        if (checkingUpdate) return; checkingUpdate = true;
        try
        {
            var policies = new List<WindowsPhonePolicy>();
#if PHONE_PACKAGE_FIXTURE
            policies.Add(new("required", "required", false, new(1,0,1), new(1,0,1), true));
#else
            foreach (var account in saved.ToArray()) { using var api = new PhoneApi(account.Server, account.Token); policies.Add(WindowsPhonePolicy.Parse(await api.JsonAsync("windows_updates"))); }
#endif
#if STORE
            storeUpdates ??= StoreContext.GetDefault(); WinRT.Interop.InitializeWithWindow.Initialize(storeUpdates, App.WindowHandle);
            storePackages = (await storeUpdates.GetAppAndOptionalStorePackageUpdatesAsync()).ToArray();
            // Store owns package discovery, authenticity and delivery; the direct release feed is never consulted.
            var required = policies.Any(x => x.Requires(ClientVersion)) || storePackages.Any(x => x.Mandatory);
            updateRequirement = new(storePackages.Count != 0, required && storePackages.Count != 0, ClientVersion);
#else
            if (policies.Count > 0 && policies.All(x => !x.Published)) { updateChecked = DateTimeOffset.UtcNow; Show("Your Windows phone is up to date. No newer Windows phone release has been published.", false); return; }
            var identity = ClientInstallation.Identity(); var trust = new UpdateStorage(Distribution.Channel); var floor = trust.Read();
            using var download = new ReleaseDownload(); var envelope = await download.CatalogueBytes(); using var key = ClientUpdateTrust.Open();
            var release = ClientRelease.Verify(envelope, key, floor.Sequence, identity.Name, identity.Publisher, floor.Sequence == 0 ? null : floor.PayloadSha256);
            var requirement = UpdateRequirement.Evaluate(ClientVersion, ClientRelease.Version(release.ReleaseVersion), policies);
            trust.Accept(release); updateRelease = release; updateEnvelope = envelope; updateRequirement = requirement;
#endif
            updateChecked = DateTimeOffset.UtcNow; RefreshUpdateNotice();
            if (updateRequirement?.Available != true) Show("Your Windows phone is up to date.", false);
        }
        finally { checkingUpdate = false; }
    }
    private void RefreshUpdateNotice()
    {
        if (updateRequirement?.Available != true) { UpdateNotice.IsOpen = false; return; }
        UpdateNotice.Severity = updateRequirement.Required ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
        UpdateNotice.Title = updateRequirement.Required ? "Required Windows phone update" : "Windows phone update available";
        UpdateNotice.Message = updateRequirement.Required ? "Finish your current calls, then install the update. Incoming calls remain available." : "Install the latest Windows phone when you are ready. Your accounts and settings are kept.";
        UpdateNotice.IsClosable = !updateRequirement.Required;
        UpdateNotice.ActionButton = AsyncButton(downloadedUpdate is null ? "Get update" : "Install and restart", ApplyUpdate, true); UpdateNotice.IsOpen = true;
    }
    private async Task ApplyUpdate()
    {
#if STORE
        if (storeUpdates is null || storePackages.Count == 0) { await CheckUpdates(); return; }
        if (!storeDownloaded)
        {
            var download = await storeUpdates.RequestDownloadStorePackageUpdatesAsync(storePackages);
            if (download.OverallState != StorePackageUpdateState.Completed) throw new PhoneInputException("Microsoft Store did not finish downloading the update. Your current phone has been kept.");
            storeDownloaded = true;
        }
        UpdateRequirement.RequireInstallationIdle(phone!.Calls.Count);
        var confirm = new ContentDialog { XamlRoot = XamlRoot, Title = "Update Windows phone?", Content = "The Microsoft Store will install the update. Your accounts and settings are kept.", PrimaryButtonText = "Update", CloseButtonText = "Later" };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        UpdateRequirement.RequireInstallationIdle(phone.Calls.Count);
        // Stop accepting new calls only after the completed download and idle confirmation;
        // a long Store download must never finish by closing a newly answered call.
        var stopped = phone; timer.Stop(); phone = null;
        try
        {
            stopped.Dispose();
            var result = await storeUpdates.RequestDownloadAndInstallStorePackageUpdatesAsync(storePackages);
            if (result.OverallState != StorePackageUpdateState.Completed) throw new PhoneInputException("Microsoft Store did not complete the update. Your current phone has been kept.");
            App.PhoneWindow!.ExitForUpdate();
        }
        catch
        {
            StartPhone(); phone!.Synchronize(saved, current?.Id); timer.Start(); throw;
        }
#else
        if (updateRelease is null || updateEnvelope is null) { await CheckUpdates(); return; }
        var storage = new UpdateStorage(Distribution.Channel);
        if (downloadedUpdate is null)
        {
            Show("Downloading the verified Windows phone update. Current calls can continue.", false);
            using var download = new ReleaseDownload(); downloadedUpdate = await download.Package(updateRelease, storage.Directory); RefreshUpdateNotice();
        }
        UpdateRequirement.RequireInstallationIdle(phone!.Calls.Count);
        var confirm = new ContentDialog { XamlRoot = XamlRoot, Title = "Install Windows phone update?", Content = "The phone will close while Windows installs the verified update, then reopen. Your accounts and settings are kept.", PrimaryButtonText = "Install and restart", CloseButtonText = "Later" };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        UpdateRequirement.RequireInstallationIdle(phone.Calls.Count);
        await ClientInstallation.StartUpdate(downloadedUpdate, updateEnvelope, storage);
        UpdateRequirement.RequireInstallationIdle(phone.Calls.Count);
        // The helper waits for our exact process to exit and never force-closes an active call.
        App.PhoneWindow!.ExitForUpdate();
#endif
    }
}
