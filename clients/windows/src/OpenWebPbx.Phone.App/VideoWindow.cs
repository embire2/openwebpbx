// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
using System.Text;
namespace OpenWebPbx.Phone.App;
public sealed class VideoWindow : Window
{
    private readonly NativePhone phone;
    private readonly VideoSurface remote, preview;
    public VideoWindow(NativePhone phone)
    {
        this.phone = phone; Title = "OpenWebPBX · Video call"; AppWindow.Resize(new(900, 680));
        var content = new StackPanel { Spacing = 12, Padding = new(20, 580, 20, 12) }; var stop = new Button { Content = "Stop camera" }; stop.Click += (_, _) => phone.StopCamera(); content.Children.Add(stop); Content = content;
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        remote = new(handle, 0, 0, 880, 540); preview = new(handle, 650, 20, 200, 150); phone.AttachVideo(remote.Handle, preview.Handle);
        Activated += (_, args) => { if (args.WindowActivationState == WindowActivationState.Deactivated) phone.StopCamera(); };
        Closed += (_, _) => { phone.StopCamera(); phone.AttachVideo(IntPtr.Zero, IntPtr.Zero); preview.Dispose(); remote.Dispose(); };
    }
}

public sealed class QrScanner
{
    public async Task<SetupInvitation?> Scan(IntPtr parent, NativePhone phone)
    {
        var done = new TaskCompletionSource<SetupInvitation?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = new Window { Title = "Scan your OpenWebPBX setup QR code" }; window.AppWindow.Resize(new(640, 560));
        var content = new StackPanel { Padding = new(20, 440, 20, 20), Spacing = 12 }; content.Children.Add(new TextBlock { Text = "Show the extension’s QR code to your webcam. No image is saved." }); var cancel = new Button { Content = "Cancel" }; content.Children.Add(cancel); window.Content = content;
        var surface = new VideoSurface(WinRT.Interop.WindowNative.GetWindowHandle(window), 0, 0, 620, 420);
        var timeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) }; timeout.Tick += (_, _) => done.TrySetResult(null);
        cancel.Click += (_, _) => done.TrySetResult(null); window.Closed += (_, _) => done.TrySetResult(null);
        window.Activated += (_, args) => { if (args.WindowActivationState == WindowActivationState.Deactivated) done.TrySetResult(null); };
        try
        {
            window.Activate(); phone.BeginQrScan(surface.Handle, result => { try { var invitation = result.StartsWith("openwebpbx://", StringComparison.Ordinal) ? SetupInvitation.FromUri(new Uri(result)) : SetupInvitation.Parse(Encoding.UTF8.GetBytes(result)); done.TrySetResult(invitation); } catch (PhoneInputException) { /* Ignore QR codes from other applications. */ } });
            timeout.Start(); return await done.Task;
        }
        finally { timeout.Stop(); phone.EndQrScan(); surface.Dispose(); window.Close(); }
    }
}
