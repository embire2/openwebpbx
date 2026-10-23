// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.UI.Xaml;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
namespace OpenWebPbx.Phone.App;
public sealed partial class MainWindow : Window
{
    private MainPage Page => (MainPage)RootFrame.Content;
    private readonly TrayIcon tray;
    private bool exiting;
    public MainWindow()
    {
        InitializeComponent(); ExtendsContentIntoTitleBar = true; SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets/AppIcon.ico")); AppWindow.Resize(new(1120, 900)); RootFrame.Navigate(typeof(MainPage));
        tray = new TrayIcon(Path.Combine(AppContext.BaseDirectory, "Assets/AppIcon.ico"), Show, Exit, () => Page.StopCamera(), () => Page.NetworkChanged());
        AppWindow.Closing += (_, args) => { if (!exiting) { args.Cancel = true; Page.StopCamera(); AppWindow.Hide(); } };
        Closed += (_, _) => { tray.Dispose(); Page.Shutdown(); };
    }
    public void Show() { AppWindow.Show(); Activate(); }
    private void Exit() { if (!Page.CanExit) { Show(); ShowMessage("Finish your calls before exiting. You can close the window and keep receiving calls in the tray."); return; } exiting = true; Close(); }
    public Task Import(SetupInvitation invitation) => Page.WaitAndImport(invitation);
    public void ShowMessage(string message) => Page.ShowMessage(message);
}
