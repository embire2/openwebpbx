// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
namespace OpenWebPbx.Phone.App;
internal sealed class IncomingNotifications : IDisposable
{
    private bool registered;
    public IncomingNotifications()
    {
        try { AppNotificationManager.Default.NotificationInvoked += Invoked; AppNotificationManager.Default.Register(); registered = true; }
        catch { /* Registration remains resident; Windows may disable notifications. */ }
    }
    private void Invoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) => App.PhoneWindow?.DispatcherQueue.TryEnqueue(() => App.PhoneWindow.Show());
    public void Show(Guid call, string name, bool hideCaller)
    {
        if (!registered) return;
        try { var notification = new AppNotificationBuilder().AddText("Incoming OpenWebPBX call").AddText(hideCaller ? "Open your phone to answer." : name).BuildNotification(); notification.Tag = call.ToString("N"); notification.Group = "calls"; AppNotificationManager.Default.Show(notification); }
        catch { /* Respect disabled or unavailable system notifications. */ }
    }
    public void Dispose() { if (!registered) return; AppNotificationManager.Default.NotificationInvoked -= Invoked; try { AppNotificationManager.Default.Unregister(); } catch { } registered = false; }
}
