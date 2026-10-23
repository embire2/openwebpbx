// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.UI.Xaml.Controls;
using OpenWebPbx.Phone.Core;
namespace OpenWebPbx.Phone.App;
public sealed partial class MainPage
{
    private async Task ReconnectAccount(PhoneProfile profile)
    {
        ConnectionRules.RequireIdle(phone!.Calls.Count); var password = new PasswordBox { Header = "App password", MaxLength = 1024 };
        var fields = new StackPanel { Spacing = 12 }; fields.Children.Add(Text(profile.Server.Host + " · extension " + profile.Account.Extension)); fields.Children.Add(password);
        var confirm = new ContentDialog { XamlRoot = XamlRoot, Title = "Sign in again", Content = fields, PrimaryButtonText = "Sign in", CloseButtonText = "Cancel" };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return; var secret = password.Password; password.Password = "";
        await new ConnectionService(profiles!, () => phone?.Busy == false).LoginAsync(profile.Server.AbsoluteUri, profile.Account.Extension, secret, Environment.MachineName, reconnectId: profile.Id);
        // Revoke only this replaced app device; every other saved profile and desk phone is untouched.
        try { using var old = new PhoneApi(profile.Server, profile.Token); await old.JsonAsync("revoke", new()); } catch { }
        await Reload(); await Draw();
    }
    private async Task RemoveAccount(PhoneProfile profile)
    {
        ConnectionRules.RequireIdle(phone!.Calls.Count); var confirm = new ContentDialog { XamlRoot = XamlRoot, Title = "Remove " + profile.Label + "?", Content = "This signs this Windows phone out. Your extension and other phones keep working.", PrimaryButtonText = "Remove", CloseButtonText = "Cancel" };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return; ConnectionRules.RequireIdle(phone.Calls.Count);
        try { using var api = new PhoneApi(profile.Server, profile.Token); await api.JsonAsync("revoke", new()); }
        catch (PhoneApiException error) when (error.Status is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden) { /* An already revoked device can still be removed locally. */ }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException)
        {
            var local = new ContentDialog { XamlRoot = XamlRoot, Title = "Remove from this phone only?", Content = "The server could not be reached. This removes the saved connection and local call history. Your PBX may still list this device; ask your administrator to revoke it later.", PrimaryButtonText = "Remove from this phone", CloseButtonText = "Keep account" };
            if (await local.ShowAsync() != ContentDialogResult.Primary) return;
        }
        ConnectionRules.RequireIdle(phone.Calls.Count); await profiles!.RemoveAsync(profile.Id); pendingHistory.Remove(profile.Id); await Reload(); await Draw();
    }
}
