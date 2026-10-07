using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace OpenWebPbx_Desktop;

public sealed partial class MainPage : Page
{
    private readonly HttpClient client = new() { Timeout = TimeSpan.FromSeconds(4) };
    private static readonly string SettingsFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenWebPBX", "manager.json");
    private string address = "";
    private bool loaded;
    private static readonly string Installer = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "InstallFromManager.ps1"));
    public MainPage()
    {
        InitializeComponent();
        try {
            var file = File.Exists(SettingsFile) ? SettingsFile : Path.Combine(AppContext.BaseDirectory, "server.json");
            if (File.Exists(file)) address = JsonSerializer.Deserialize<ManagerSettings>(File.ReadAllText(file))?.Address ?? "";
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { address = ""; }
        AddressInput.Text = address; ServerAddress.Text = address.Length > 0 ? address : "Choose your PBX address in Setup.";
        InstallPanel.Visibility = File.Exists(Installer) ? Visibility.Visible : Visibility.Collapsed;
        InstallUnavailable.Visibility = File.Exists(Installer) ? Visibility.Collapsed : Visibility.Visible;
        try
        {
            using var certificates = new X509Store(StoreName.My, StoreLocation.LocalMachine);
            certificates.Open(OpenFlags.ReadOnly);
            InstalledCertificate.ItemsSource = certificates.Certificates.Where(c => c.HasPrivateKey && c.NotAfter > DateTime.Now && c.NotBefore <= DateTime.Now)
                .Select(c => new CertificateOption(c.GetNameInfo(X509NameType.DnsName, false) + " · expires " + c.NotAfter.ToString("d"), c.Thumbprint)).ToArray();
            if (InstalledCertificate.Items.Count > 0) InstalledCertificate.SelectedIndex = 0;
        }
        catch (CryptographicException) { }
        Loaded += async (_, _) => { loaded = true; await RefreshStatus(); };
    }
    private async Task RefreshStatus()
    {
        try
        {
            var status = await client.GetFromJsonAsync<ServerHealth>("http://127.0.0.1:8087/health");
            StatusBanner.Title = status?.State ?? "Unavailable";
            StatusBanner.Message = status?.State == "Running" ? "Callbacks and wake-up calls are running on this server." : "Complete the server installation to enable background calls.";
            StatusBanner.Severity = status?.State == "Running" ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            ServiceDetails.Text = $"Service version {status?.Version} · {status?.OperatingSystem}";
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            StatusBanner.Title = "Service is not running on this computer";
            StatusBanner.Message = "You can still open and manage a PBX at the address saved in Setup.";
            StatusBanner.Severity = InfoBarSeverity.Warning; ServiceDetails.Text = "";
        }
    }
    private async void Refresh(object sender, RoutedEventArgs args) => await RefreshStatus();
    private void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!loaded || args.SelectedItem is not NavigationViewItem item) return;
        var page = item.Tag?.ToString();
        if (page is "admin" or "callbacks" or "hotel") { OpenConsole(page); return; }
        DashboardPanel.Visibility = page == "dashboard" ? Visibility.Visible : Visibility.Collapsed;
        SetupPanel.Visibility = page == "setup" ? Visibility.Visible : Visibility.Collapsed;
    }
    private void SaveAddress(object sender, RoutedEventArgs args)
    {
        if (!Uri.TryCreate(AddressInput.Text.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo != "" || uri.Query != "" || uri.Fragment != "")
        {
            SetupMessage.Title = "Enter a secure PBX address, starting with https://"; SetupMessage.Severity = InfoBarSeverity.Error; SetupMessage.IsOpen = true; return;
        }
        address = uri.GetLeftPart(UriPartial.Authority);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsFile)!);
            File.WriteAllText(SettingsFile, JsonSerializer.Serialize(new ManagerSettings(address)));
            ServerAddress.Text = address; SetupMessage.Title = "PBX address saved"; SetupMessage.Severity = InfoBarSeverity.Success;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { SetupMessage.Title = "The address could not be saved. Check your profile folder."; SetupMessage.Severity = InfoBarSeverity.Error; }
        SetupMessage.IsOpen = true;
    }
    private void OpenAdmin(object sender, RoutedEventArgs args) => OpenConsole("admin");
    private void OpenConsole(string page)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https")
        {
            DashboardPanel.Visibility = Visibility.Collapsed; SetupPanel.Visibility = Visibility.Visible; Navigation.SelectedItem = Navigation.MenuItems[4]; return;
        }
        Launch(address + "/app/pbx_setup/" + (page == "admin" ? "" : "?view=" + page));
    }
    private void OpenFolder(object sender, RoutedEventArgs args) => Launch(AppContext.BaseDirectory);
    private void CertificateModeChanged(object sender, SelectionChangedEventArgs args)
    { if (InstalledCertificate is not null) InstalledCertificate.Visibility = CertificateChoice.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed; }
    private async void InstallServer(object sender, RoutedEventArgs args)
    {
        InstallMessage.IsOpen = true; InstallMessage.Severity = InfoBarSeverity.Error;
        if (!Regex.IsMatch(InstallDomain.Text, "^[a-zA-Z0-9.-]+$") || !System.Net.Mail.MailAddress.TryCreate(InstallEmail.Text, out var email) || email.Address != InstallEmail.Text || InstallPassword.Password.Length < 8)
        { InstallMessage.Title = "Enter a server name, email and password of at least eight characters."; return; }
        var certificate = InstalledCertificate.SelectedItem as CertificateOption;
        if (CertificateChoice.SelectedIndex == 1 && certificate is null)
        { InstallMessage.Title = "Choose a certificate installed on this server, or use a local setup certificate."; return; }
        string? requestFile = null;
        InstallButton.IsEnabled = false; InstallProgress.Visibility = Visibility.Visible; InstallProgress.IsActive = true;
        try
        {
            var directory = Path.Combine(Path.GetDirectoryName(SettingsFile)!, "setup", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
            foreach (var sid in new[] { WindowsIdentity.GetCurrent().User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(directory).SetAccessControl(security);
            requestFile = Path.Combine(directory, "request.json");
            File.WriteAllText(requestFile, JsonSerializer.Serialize(new { DomainName = InstallDomain.Text, AdminEmail = InstallEmail.Text, AdminPassword = InstallPassword.Password, LocalCertificate = CertificateChoice.SelectedIndex == 0, CertificateThumbprint = CertificateChoice.SelectedIndex == 1 ? certificate!.Thumbprint : "" }));
            InstallPassword.Password = "";
            var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden, WorkingDirectory = Path.GetDirectoryName(Installer)! };
            start.Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{Installer}\" -RequestFile \"{requestFile}\"";
            InstallMessage.Severity = InfoBarSeverity.Informational; InstallMessage.Title = "Installing. Keep this window open; setup may take several minutes.";
            using var process = Process.Start(start) ?? throw new IOException("Windows could not start setup.");
            await process.WaitForExitAsync();
            if (process.ExitCode != 0) throw new IOException("Setup did not finish. Its private log is in " + directory);
            AddressInput.Text = "https://" + InstallDomain.Text + ":8443"; SaveAddress(sender, args);
            InstallMessage.Severity = InfoBarSeverity.Success; InstallMessage.Title = "Your phone system is ready. Open Admin to sign in.";
            await RefreshStatus();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        { InstallMessage.Severity = InfoBarSeverity.Error; InstallMessage.Title = ex is System.ComponentModel.Win32Exception ? "Windows setup was cancelled or could not start." : ex.Message; }
        finally
        {
            if (requestFile is not null) { try { File.Delete(requestFile); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
            InstallButton.IsEnabled = true; InstallProgress.IsActive = false; InstallProgress.Visibility = Visibility.Collapsed;
        }
    }
    private void Launch(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        { SetupMessage.Title = "Windows could not open this location."; SetupMessage.Severity = InfoBarSeverity.Error; SetupMessage.IsOpen = true; }
    }
    private sealed record ManagerSettings(string Address);
    private sealed record CertificateOption(string Label, string Thumbprint);
    private sealed record ServerHealth(string Version, string State, string OperatingSystem);
}
