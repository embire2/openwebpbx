// SPDX-License-Identifier: AGPL-3.0-or-later
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
using Windows.ApplicationModel.Activation;
namespace OpenWebPbx.Phone.App;
public partial class App : Application
{
    public static MainWindow? PhoneWindow { get; private set; }
    public static IntPtr WindowHandle => PhoneWindow is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(PhoneWindow);
    public App() { UnhandledException += (_, args) => ComponentDiagnostics.Failure("unhandled", args.Exception); try { InitializeComponent(); } catch (Exception e) { ComponentDiagnostics.Failure("application_constructor", e); throw; } }
    protected override async void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        var instance = AppInstance.FindOrRegisterForKey("OpenWebPBX-FreePhone-1");
        if (!instance.IsCurrent) { await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()); Environment.Exit(0); return; }
        PhoneWindow = new MainWindow(); instance.Activated += (_, activation) => PhoneWindow.DispatcherQueue.TryEnqueue(async () => await Activate(activation));
        PhoneWindow.Activate(); await Activate(AppInstance.GetCurrent().GetActivatedEventArgs(), true);
    }
    private static async Task Activate(AppActivationArguments args, bool initial = false)
    {
        PhoneWindow!.Show();
        try
        {
            if (args.Kind == ExtendedActivationKind.Protocol && args.Data is IProtocolActivatedEventArgs protocol) await PhoneWindow.Import(SetupInvitation.FromUri(protocol.Uri));
            else if (args.Kind == ExtendedActivationKind.File && args.Data is IFileActivatedEventArgs file && file.Files.Count == 1 && file.Files[0] is global::Windows.Storage.StorageFile storage)
                await PhoneWindow.Import(await InvitationFile(storage));
            else if (args.Kind == ExtendedActivationKind.Launch)
            {
                var values = args.Data is ILaunchActivatedEventArgs launch ? LaunchArguments.Parse(launch.Arguments) : initial ? Environment.GetCommandLineArgs().Skip(1).ToArray() : [];
                if (values.Length != 1) return; var argument = values[0];
                if (Uri.TryCreate(argument, UriKind.Absolute, out var uri) && uri.Scheme == "openwebpbx") await PhoneWindow.Import(SetupInvitation.FromUri(uri));
                else if (Path.IsPathFullyQualified(argument) && argument.EndsWith(".openwebpbx", StringComparison.OrdinalIgnoreCase)) { await using var input = new FileStream(argument, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan); await PhoneWindow.Import(await SetupInvitation.ReadAsync(input)); }
            }
        }
        catch (PhoneInputException e) { PhoneWindow.ShowMessage(e.Message); }
        catch { PhoneWindow.ShowMessage("This connection invitation could not be opened. Ask your administrator for a current welcome email."); }
    }
    private static async Task<SetupInvitation> InvitationFile(global::Windows.Storage.StorageFile file)
    {
        await using var input = await file.OpenStreamForReadAsync(); return await SetupInvitation.ReadAsync(input);
    }
}
