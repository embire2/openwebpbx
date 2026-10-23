// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.UI.Xaml;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
namespace OpenWebPbx.Phone.App;
public sealed partial class MainWindow : Window
{
    private MainPage Page => (MainPage)RootFrame.Content;
    private readonly TrayIcon? tray;
    private bool exiting;
    public MainWindow()
    {
        InitializeComponent(); ExtendsContentIntoTitleBar = true; SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets/AppIcon.ico")); var work = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea; AppWindow.Resize(new(Math.Min(1120, Math.Max(320, work.Width - 40)), Math.Min(900, Math.Max(320, work.Height - 40)))); AppWindow.Move(new(work.X + 20, work.Y + 20)); RootFrame.Navigate(typeof(MainPage));
        try { tray = new TrayIcon(Path.Combine(AppContext.BaseDirectory, "Assets/AppIcon.ico"), Show, Exit, () => Page.StopCamera(), () => Page.NetworkChanged()); } catch { Page.ShowMessage("The Windows tray is unavailable. Keep this window open to receive calls."); }
        AppWindow.Closing += (_, args) => { if (!exiting && (tray is not null || !Page.CanExit)) { args.Cancel = true; Page.StopCamera(); if (tray is not null) AppWindow.Hide(); else ShowMessage("Finish your call or current request before closing the phone."); } };
        Closed += (_, _) => { tray?.Dispose(); Page.Shutdown(); };
    }
    public void Show() { AppWindow.Show(); Activate(); }
    public void Exit() { if (!Page.CanExit) { Show(); ShowMessage("Finish your call or current request before exiting. You can close the window and keep receiving calls in the tray."); return; } exiting = true; Close(); }
    internal void ExitForUpdate() { exiting = true; Close(); }
    public Task Import(SetupInvitation invitation) => Page.WaitAndImport(invitation);
    public void ShowMessage(string message) => Page.ShowMessage(message);
}
