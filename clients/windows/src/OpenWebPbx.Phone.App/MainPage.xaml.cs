// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
using Windows.Storage.Pickers;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;
using Linphone;
namespace OpenWebPbx.Phone.App;

public sealed partial class MainPage : Page
{
    private NativePhone? phone;
    private readonly ProtectedProfileStore store = new(Distribution.Channel);
    private readonly PendingHistory pendingHistory = new(Distribution.Channel);
    private readonly SemaphoreSlim historyGate = new(1, 1);
    private readonly PreferencesStore preferenceStore = new(Distribution.Channel);
    private PersonalPreferences preferences = new();
    private ProfileManager? profiles;
    private PhoneProfile? current;
    private IReadOnlyList<PhoneProfile> saved = [];
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(20) };
    private MediaPlayer? player;
    private readonly IncomingNotifications notifications = new();
    private readonly HashSet<Guid> notified = [];
    private string section = "Keypad";
    private bool loading, initialized, operationInFlight;
    private Task? initialization;
    private Task EnsureInitialized() => initialization ??= Initialize();
    public MainPage()
    {
        InitializeComponent(); Loaded += async (_, _) => await Execute(EnsureInitialized);
        timer.Tick += (_, _) => { try { phone?.Iterate(); } catch { Show("The phone needs to reconnect. Finish your call and open Settings to check the connection."); } };
    }
    private async Task Initialize()
    {
        if (initialized) return;
        phone = new NativePhone(); profiles = new(store, () => phone.Calls.Count, () => false);
        phone.Changed += RefreshCalls;
        phone.CallFinished += async (id, number, incoming, started, duration, answered) =>
        {
            var account = saved.FirstOrDefault(p => p.Id == id); if (account is null) return;
            try
            {
                string safeNumber; try { safeNumber = ConnectionRules.Number(number); } catch (PhoneInputException) { safeNumber = ""; }
                pendingHistory.Enqueue(new(Guid.NewGuid(), id, safeNumber, incoming ? answered ? "incoming" : "missed" : "outgoing", started, duration, answered));
                await FlushHistory(account);
            }
            catch { Show("Your call ended. Recent calls will sync when the connection returns."); }
        };
        global::Windows.Networking.Connectivity.NetworkInformation.NetworkStatusChanged += NetworkStatusChanged;
        initialized = true; WriteComponentReceipt(); timer.Start(); await Reload(); preferences = preferenceStore.Read(); ApplyPreferences(); section = preferences.StartupPage; Navigation.SelectedItem = Navigation.MenuItems.Cast<NavigationViewItem>().First(x => x.Tag?.ToString() == section); await Draw();
    }
    private async Task Reload()
    {
        saved = await store.ReadAsync(); var id = await store.SelectedAsync(); current = saved.FirstOrDefault(p => p.Id == id);
        if (phone?.Busy == true) throw new PhoneInputException("Finish your calls before changing accounts.");
        phone?.Synchronize(saved, id); loading = true; AccountChoice.ItemsSource = saved; AccountChoice.DisplayMemberPath = "Label"; AccountChoice.SelectedItem = current; loading = false; RefreshCalls();
    }
    private async void ChooseAccount(object sender, SelectionChangedEventArgs args)
    {
        if (loading || AccountChoice.SelectedItem is not PhoneProfile profile || profiles is null) return;
        await Execute(async () => { StopPlayback(); await profiles.SelectAsync(profile.Id); await Reload(); await Draw(); });
    }
    private async void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!initialized) return;
        section = args.IsSettingsSelected ? "Settings" : (args.SelectedItem as NavigationViewItem)?.Tag?.ToString() ?? "Keypad";
        StopPlayback(); await Execute(Draw);
    }
    private void Show(string message, bool error = true) { Notice.Message = message; Notice.Severity = error ? InfoBarSeverity.Warning : InfoBarSeverity.Success; Notice.IsOpen = true; }
    private async Task Execute(Func<Task> action)
    {
        if (operationInFlight) { Show("Please wait for the current request to finish."); return; }
        operationInFlight = true; AccountChoice.IsEnabled = false; BodyControls.IsEnabled = false;
        try { await action(); } catch (PhoneInputException e) { Show(e.Message); } catch (PhoneApiException e) { Show(e.Message); } catch (OperationCanceledException) { Show("The connection timed out. Please try again."); } catch (Exception e) { if (!initialized) ComponentDiagnostics.Failure("initialization", e); Show("This action could not finish. Check your connection and try again."); }
        finally { operationInFlight = false; AccountChoice.IsEnabled = true; BodyControls.IsEnabled = true; }
    }
    private void Act(Action action) { try { action(); } catch (PhoneInputException e) { Show(e.Message); } catch { Show("The phone could not complete that action. Wait for the call to settle and try again."); } }
    private Button Button(string title, Action action, bool accent = false)
    {
        var button = new Button { Content = title, MinHeight = 42, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(button, title); if (accent) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        button.Click += (_, _) => Act(action); return button;
    }
    private Button AsyncButton(string title, Func<Task> action, bool accent = false) { var button = Button(title, () => { }, accent); button.Click += async (_, _) => { button.IsEnabled = false; try { await Execute(action); } finally { button.IsEnabled = true; } }; return button; }
    private TextBlock Text(string text, double size = 16) => new() { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap };
    private TextBox Field(string title, string value = "") { var field = new TextBox { Header = title, Text = value, MaxLength = 200, MinHeight = 44 }; AutomationProperties.SetName(field, title); Body.Children.Add(field); return field; }
    private StackPanel Row() => new() { Orientation = Orientation.Horizontal, Spacing = 10 };
    private PhoneApi Api() => current is null ? throw new PhoneInputException("Connect an account first.") : new PhoneApi(current.Server, current.Token);
    private async Task Draw()
    {
        if (!initialized) return; Body.Children.Clear(); Body.Children.Add(Text(section, 28));
        switch (section)
        {
            case "Keypad": DrawKeypad(); break;
            case "Accounts": await DrawAccounts(); break;
            case "Contacts": await DrawContacts(); break;
            case "Recents": await DrawRecents(); break;
            case "Voicemail": await DrawVoicemail(); break;
            case "Availability": await DrawAvailability(); break;
            case "Settings": DrawSettings(); break;
        }
    }
    private void DrawKeypad()
    {
        if (current is null) { Body.Children.Add(Text("Use your tenant address and extension, or open the setup file in your welcome email.")); Body.Children.Add(AsyncButton("Connect an account", async () => { section = "Accounts"; await Draw(); }, true)); return; }
        var number = Field("Phone number or extension"); number.MaxLength = 32; number.FontSize = 30;
        var pad = new Grid { ColumnSpacing = 10, RowSpacing = 10, MaxWidth = 420, HorizontalAlignment = HorizontalAlignment.Left };
        for (var i = 0; i < 3; i++) pad.ColumnDefinitions.Add(new() { Width = new GridLength(110) });
        for (var i = 0; i < 4; i++) pad.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var keys = "123456789*0#";
        for (var i = 0; i < keys.Length; i++) { var key = keys[i]; var button = Button(key.ToString(), () => { if (phone?.Busy == true) phone.Dtmf(key); else number.Text += key; }); button.FontSize = 28; button.MinHeight = 68; Grid.SetRow(button, i / 3); Grid.SetColumn(button, i % 3); pad.Children.Add(button); }
        Body.Children.Add(pad); var actions = Row(); actions.Children.Add(Button("Call", () => phone!.Dial(number.Text), true)); actions.Children.Add(AsyncButton("Video call", async () => await StartVideo(number.Text))); Body.Children.Add(actions);
        Body.Children.Add(Button("Voicemail · 121", () => phone!.Dial("121")));
    }
    private void RefreshCalls()
    {
        if (phone is null) return;
        ConnectionStatus.Text = current is null ? "Connect an account to get started" : phone.Registrations.GetValueOrDefault(current.Id, "Offline") + " · " + current.Label;
        LiveCalls.Children.Clear();
        foreach (var call in phone.Calls)
        {
            var line = Row(); line.Children.Add(Text($"{call.Name} · {call.Number} · {Friendly(call.State)}"));
            if (call.State is CallState.IncomingReceived or CallState.IncomingEarlyMedia)
            {
                if (notified.Add(call.Id) && preferences.Notifications) notifications.Show(call.Id, call.Name, preferences.HideCallerInNotifications);
                line.Children.Add(Button("Answer", () => phone.Answer(call.Id, false), true));
                if (call.Video) line.Children.Add(Button("Answer with video", () => phone.Answer(call.Id, true)));
                line.Children.Add(Button("Decline", () => phone.Hangup(call.Id)));
            }
            else { line.Children.Add(Button("Choose call", () => phone.Select(call.Id))); line.Children.Add(Button("End call", () => phone.Hangup(call.Id))); }
            LiveCalls.Children.Add(line);
        }
        if (!phone.Busy) { LiveCalls.Visibility = Visibility.Collapsed; player?.Pause(); return; }
        StopPlayback(); LiveCalls.Visibility = Visibility.Visible;
        var controls = Row(); controls.Children.Add(Button(phone.Current?.State == CallState.Paused ? "Resume Call" : "Call Hold", phone.HoldResume, true)); controls.Children.Add(Button(phone.Current?.Muted == true ? "Unmute" : "Mute", phone.Mute)); controls.Children.Add(AsyncButton("Transfer", Transfer)); controls.Children.Add(Button("Merge calls", phone.Merge)); controls.Children.Add(Button("Video", () => { phone.SetVideo(true); OpenVideo(); })); controls.Children.Add(Button("Stop camera", phone.StopCamera)); LiveCalls.Children.Add(controls);
        if (phone.Current?.State == CallState.UpdatedByRemote) { var offer = Row(); offer.Children.Add(Button("Accept video", () => { phone.AcceptVideoOffer(true); OpenVideo(); })); offer.Children.Add(Button("Audio only", () => phone.AcceptVideoOffer(false))); LiveCalls.Children.Add(offer); }
        if (phone.Conferencing) foreach (var call in phone.Calls) LiveCalls.Children.Add(Button("Mute / unmute " + call.Name, () => phone.MuteParticipant(call.Id)));
    }
    private static string Friendly(CallState state) => state switch { CallState.Paused => "On hold", CallState.StreamsRunning => "Connected", CallState.IncomingReceived => "Incoming call", CallState.OutgoingRinging => "Ringing", CallState.PausedByRemote => "The other person placed you on hold", CallState.Error => "Unavailable", _ => "Connecting…" };
    private async Task Transfer()
    {
        var number = new TextBox { Header = "Extension or phone number", MaxLength = 32 }; var content = new StackPanel { Spacing = 12 }; content.Children.Add(number);
        content.Children.Add(Button("Complete attended transfer", () => phone!.CompleteTransfer())); content.Children.Add(Button("Cancel and return", () => phone!.CancelConsultation()));
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Transfer call", Content = content, PrimaryButtonText = "Transfer now", SecondaryButtonText = "Speak first", CloseButtonText = "Cancel" };
        var result = await dialog.ShowAsync(); if (result == ContentDialogResult.Primary) phone!.BlindTransfer(number.Text); if (result == ContentDialogResult.Secondary) phone!.Consult(number.Text);
    }
    private async Task DrawAccounts()
    {
        Body.Children.Add(Text("Add up to ten accounts. Each remains connected while the phone is running. Finish calls before changing accounts."));
        foreach (var profile in saved)
        {
            var row = Row(); row.Children.Add(Text(profile.Label + " · " + phone!.Registrations.GetValueOrDefault(profile.Id, "Offline")));
            row.Children.Add(AsyncButton("Rename", async () => { var name = new TextBox { Text = profile.Name }; var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Account name", Content = name, PrimaryButtonText = "Save", CloseButtonText = "Cancel" }; if (await dialog.ShowAsync() == ContentDialogResult.Primary) { await profiles!.RenameAsync(profile.Id, name.Text); await Reload(); await Draw(); } }));
            row.Children.Add(AsyncButton("Remove", async () => { ConnectionRules.RequireIdle(phone!.Calls.Count); var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Remove " + profile.Label + "?", Content = "This signs this Windows phone out. Your extension and other phones keep working.", PrimaryButtonText = "Remove", CloseButtonText = "Cancel" }; if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; using var api = new PhoneApi(profile.Server, profile.Token); await api.JsonAsync("revoke", new()); await profiles!.RemoveAsync(profile.Id); pendingHistory.Remove(profile.Id); await Reload(); await Draw(); })); Body.Children.Add(row);
        }
        var tenant = Field("Tenant address", ""); var extension = Field("Extension"); var password = new PasswordBox { Header = "App password chosen by your administrator", MaxLength = 1024 }; Body.Children.Add(password);
        Body.Children.Add(AsyncButton("Sign in", async () => { var secret = password.Password; password.Password = ""; var connection = new ConnectionService(profiles!, () => phone?.Busy == false); var added = await connection.LoginAsync(tenant.Text, extension.Text, secret, Environment.MachineName); await profiles!.SelectAsync(added.Id); await Reload(); await Draw(); }, true));
        Body.Children.Add(AsyncButton("Open welcome email setup file", ImportFile));
        Body.Children.Add(AsyncButton("Scan QR code with webcam", ScanQr));
        await Task.CompletedTask;
    }
    public async Task ImportInvitation(SetupInvitation invitation)
    {
        ConnectionRules.RequireIdle(phone!.Calls.Count); var preview = new ContentDialog { XamlRoot = XamlRoot, Title = "Connect this phone?", Content = invitation.Server.Host + (invitation.Extension is null ? "" : " · extension " + invitation.Extension), PrimaryButtonText = "Connect", CloseButtonText = "Cancel" };
        if (await preview.ShowAsync() != ContentDialogResult.Primary) return;
        var connected = await new ConnectionService(profiles!, () => phone?.Busy == false).EnrollAsync(invitation, Environment.MachineName); await profiles!.SelectAsync(connected.Id); await Reload(); await Draw();
    }
    private async Task ImportFile()
    {
        var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, App.WindowHandle); picker.FileTypeFilter.Add(".openwebpbx"); picker.FileTypeFilter.Add(".json");
        var file = await picker.PickSingleFileAsync(); if (file is null) return; await using var input = await file.OpenStreamForReadAsync(); await ImportInvitation(await SetupInvitation.ReadAsync(input));
    }
    private async Task DrawContacts()
    {
        using var api = Api(); var result = await api.JsonAsync("directory"); var items = result["contacts"]?.AsArray() ?? [];
        var search = Field("Search people or extensions"); var list = new StackPanel { Spacing = 8 }; Body.Children.Add(list);
        void Filter() { list.Children.Clear(); foreach (var item in items.OfType<JsonObject>().Where(x => ($"{x["name"]} {x["number"]}").Contains(search.Text, StringComparison.OrdinalIgnoreCase)).OrderBy(x => preferences.ContactOrder == "Name" ? x["name"]?.ToString() : x["number"]?.ToString())) { var number = item["number"]!.ToString(); var row = Row(); row.Children.Add(Button($"{item["name"]} · {number} · {item["status"]}", () => phone!.Dial(number))); if (item["id"]?.ToString() == "extension:" + number) row.Children.Add(AsyncButton("Video", () => StartVideo(number))); list.Children.Add(row); } }
        search.TextChanged += (_, _) => Filter(); Filter();
    }
    private async Task FlushHistory(PhoneProfile account)
    {
        await historyGate.WaitAsync();
        try { using var api = new PhoneApi(account.Server, account.Token); foreach (var row in pendingHistory.For(account.Id)) { if (saved.All(x => x.Id != account.Id)) return; await api.JsonAsync("call_log", row.Body()); pendingHistory.Acknowledge(account.Id, row.Id); } }
        finally { historyGate.Release(); }
    }
    private async Task DrawRecents()
    {
        await FlushHistory(current!); using var api = Api(); var result = await api.JsonAsync("calls"); foreach (var item in (result["calls"]?.AsArray() ?? []).OfType<JsonObject>()) { var number = item["number"]!.ToString(); Body.Children.Add(Button($"{item["name"]} · {number} · {item["direction"]} · {item["started_at"]} · {item["duration"]}s", () => phone!.Dial(number))); }
    }
    private void StopPlayback()
    {
        var old = player; player = null; if (old is null) return;
        try { old.Pause(); old.Source = null; } finally { old.Dispose(); }
    }
    private async Task DrawVoicemail()
    {
        using var api = Api(); var result = await api.JsonAsync("voicemail");
        foreach (var item in (result["messages"]?.AsArray() ?? []).OfType<JsonObject>())
        {
            var id = item["id"]!.ToString(); Body.Children.Add(Text($"{(item["read"]?.GetValue<bool>() == true ? "" : "New · ")}{item["caller_name"]} · {item["caller_number"]} · {item["created_at"]}")); var row = Row();
            row.Children.Add(AsyncButton("Play", async () => { ConnectionRules.RequireIdle(phone!.Calls.Count); using var request = Api(); var bytes = await request.VoicemailAsync(id); ConnectionRules.RequireIdle(phone!.Calls.Count); var stream = new InMemoryRandomAccessStream(); using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); } stream.Seek(0); StopPlayback(); try { player = new MediaPlayer(); player.Source = MediaSource.CreateFromStream(stream, "audio/wav"); player.Play(); } catch { StopPlayback(); stream.Dispose(); throw new PhoneInputException("Voicemail playback is unavailable on this Windows installation. Ask your administrator to enable Media Foundation, or dial 121 to listen through your phone."); } await request.JsonAsync("voicemail_read", new() { ["id"] = id }); }));
            row.Children.Add(AsyncButton("Mark read", async () => { using var request = Api(); await request.JsonAsync("voicemail_read", new() { ["id"] = id }); await Draw(); }));
            row.Children.Add(AsyncButton("Delete", async () => { var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Delete voicemail?", Content = "This removes the message from your mailbox.", PrimaryButtonText = "Delete", CloseButtonText = "Cancel" }; if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; StopPlayback(); using var request = Api(); await request.JsonAsync("voicemail_delete", new() { ["id"] = id }); await Draw(); })); Body.Children.Add(row);
        }
        Body.Children.Add(Button("Stop playback", () => { StopPlayback(); }));
    }
    private async Task DrawAvailability()
    {
        using var api = Api(); var status = await api.JsonAsync("availability"); var choice = new ComboBox { Header = "My availability", ItemsSource = status["statuses"]!.AsArray().Select(x => x!.ToString()).ToArray(), SelectedItem = status["status"]!.ToString() }; Body.Children.Add(choice);
        var duration = new ComboBox { Header = "Return to normal after", ItemsSource = new[] { "Until changed", "15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours", "8 hours" }, SelectedIndex = 0 }; Body.Children.Add(duration);
        Body.Children.Add(AsyncButton("Save availability", async () => { using var request = Api(); await request.JsonAsync("set_status", new() { ["status"] = choice.SelectedItem.ToString(), ["minutes"] = new[] { 0, 15, 30, 60, 120, 240, 480 }[duration.SelectedIndex] }); Show("Availability saved", false); }));
        foreach (var queue in (status["queues"]?.AsArray() ?? []).OfType<JsonObject>()) { var toggle = new ToggleSwitch { Header = queue["name"]?.ToString() ?? queue["number"]?.ToString(), IsOn = queue["joined"]?.GetValue<bool>() == true }; toggle.Toggled += async (_, _) => { toggle.IsEnabled = false; await Execute(async () => { using var request = Api(); await request.JsonAsync("queue_status", new() { ["number"] = queue["number"]!.ToString(), ["joined"] = toggle.IsOn }); }); toggle.IsEnabled = true; }; Body.Children.Add(toggle); }
    }
    private void DrawSettings()
    {
        Body.Children.Add(Text("Personal settings keep secure calling and your administrator’s routes intact."));
        Choice("Microphone", phone!.Microphones, device => { phone.SetMicrophone(device.Id); SavePreferences(preferences with { Microphone = device.Id }); }); Choice("Speaker or headset", phone.Speakers, device => { phone.SetSpeaker(device.Id); SavePreferences(preferences with { Speaker = device.Id }); });
        var cameras = new ComboBox { Header = "Camera", ItemsSource = phone.Cameras }; cameras.SelectionChanged += (_, _) => { if (cameras.SelectedItem is string camera) Act(() => { phone.SetCamera(camera); SavePreferences(preferences with { Camera = camera }); }); }; Body.Children.Add(cameras);
        Body.Children.Add(Button("Camera off", phone.StopCamera));
        var theme = new ComboBox { Header = "Theme", ItemsSource = new[] { "System", "Light", "Dark" }, SelectedItem = preferences.Theme }; theme.SelectionChanged += (_, _) => { SavePreferences(preferences with { Theme = theme.SelectedItem.ToString()! }); ApplyPreferences(); }; Body.Children.Add(theme);
        Body.Children.Add(AsyncButton("Choose WAV ringtone", async () => { var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, App.WindowHandle); picker.FileTypeFilter.Add(".wav"); var file = await picker.PickSingleFileAsync(); if (file is not null) { phone.SetRingtone(file.Path); SavePreferences(preferences with { Ringtone = file.Path }); } }));
        Body.Children.Add(AsyncButton("Check connection", async () => { using var api = Api(); await api.JsonAsync("bootstrap"); if (!phone.Busy) phone.Reconnect(); Show("Your PBX is reachable. Secure phone registration is shown above.", false); }));
        var startup = new ComboBox { Header = "Open on", ItemsSource = new[] { "Keypad", "Contacts", "Recents", "Voicemail" }, SelectedItem = preferences.StartupPage }; startup.SelectionChanged += (_, _) => SavePreferences(preferences with { StartupPage = startup.SelectedItem.ToString()! }); Body.Children.Add(startup);
        var sort = new ComboBox { Header = "Sort contacts by", ItemsSource = new[] { "Name", "Extension" }, SelectedItem = preferences.ContactOrder }; sort.SelectionChanged += (_, _) => SavePreferences(preferences with { ContactOrder = sort.SelectedItem.ToString()! }); Body.Children.Add(sort);
        var alerts = new ToggleSwitch { Header = "Incoming call notifications", IsOn = preferences.Notifications }; alerts.Toggled += (_, _) => SavePreferences(preferences with { Notifications = alerts.IsOn }); Body.Children.Add(alerts);
        var privacy = new ToggleSwitch { Header = "Hide caller in notifications", IsOn = preferences.HideCallerInNotifications }; privacy.Toggled += (_, _) => SavePreferences(preferences with { HideCallerInNotifications = privacy.IsOn }); Body.Children.Add(privacy);
        var launch = new ToggleSwitch { Header = "Start phone when I sign in to Windows", IsOn = preferences.LaunchAtLogin }; launch.Toggled += async (_, _) => await Execute(async () => {
#if STORE
            var startupTask = await global::Windows.ApplicationModel.StartupTask.GetAsync("OpenWebPBXFreePhone");
            if (launch.IsOn) { var state = await startupTask.RequestEnableAsync(); if (state != global::Windows.ApplicationModel.StartupTaskState.Enabled) throw new PhoneInputException("Windows did not enable startup. Check Startup Apps in Windows Settings."); } else startupTask.Disable();
#else
            LoginStartup.SetDirect(launch.IsOn, Path.Combine(AppContext.BaseDirectory, "OpenWebPbx.Phone.App.exe")); await Task.CompletedTask;
#endif
            SavePreferences(preferences with { LaunchAtLogin = launch.IsOn }); }); Body.Children.Add(launch);
        Body.Children.Add(AsyncButton("Change my app password", Password));
        Body.Children.Add(AsyncButton("Windows microphone privacy", () => Launch("ms-settings:privacy-microphone"))); Body.Children.Add(AsyncButton("Windows camera privacy", () => Launch("ms-settings:privacy-webcam")));
        foreach (var pair in new[] { ("Terms", "terms"), ("Privacy", "privacy"), ("Delete my account", "delete") }) Body.Children.Add(AsyncButton(pair.Item1, () => Launch("https://openwebpbx.com/" + pair.Item2)));
        Body.Children.Add(Text("OpenWebPBX Free Phone 1.0.0 · Native calling powered by Liblinphone 5.5.23 · AGPLv3 or later. A compatible OpenWebPBX account is required."));
    }
    private void SavePreferences(PersonalPreferences value) { preferenceStore.Save(value); preferences = value; }
    private void ApplyPreferences()
    {
        RequestedTheme = preferences.Theme switch { "Light" => ElementTheme.Light, "Dark" => ElementTheme.Dark, _ => ElementTheme.Default };
        if (phone is null) return;
        if (phone.Microphones.Any(x => x.Id == preferences.Microphone)) phone.SetMicrophone(preferences.Microphone);
        if (phone.Speakers.Any(x => x.Id == preferences.Speaker)) phone.SetSpeaker(preferences.Speaker);
        if (phone.Cameras.Contains(preferences.Camera)) phone.SetCamera(preferences.Camera);
        if (preferences.Ringtone != "") try { phone.SetRingtone(preferences.Ringtone); } catch (PhoneInputException) { /* Missing personal file keeps the native default. */ }
    }
    private void Choice(string title, IReadOnlyList<PhoneDevice> devices, Action<PhoneDevice> action) { var choice = new ComboBox { Header = title, ItemsSource = devices, DisplayMemberPath = "Name", MinWidth = 300 }; choice.SelectionChanged += (_, _) => { if (choice.SelectedItem is PhoneDevice device) Act(() => action(device)); }; Body.Children.Add(choice); }
    private async Task Password()
    {
        var content = new StackPanel { Spacing = 12 }; var old = new PasswordBox { Header = "Current app password" }; var fresh = new PasswordBox { Header = "New app password (12–128 characters)" }; var repeat = new PasswordBox { Header = "Repeat new password" }; content.Children.Add(old); content.Children.Add(fresh); content.Children.Add(repeat);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Change app password", Content = content, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; var oldValue = old.Password; var newValue = fresh.Password; var match = repeat.Password == newValue; old.Password = fresh.Password = repeat.Password = ""; ConnectionRules.AppPassword(newValue); if (!match) throw new PhoneInputException("The new passwords do not match.");
        using var api = Api(); await api.JsonAsync("change_password", new() { ["current_password"] = oldValue, ["new_password"] = newValue }); Show("App password changed. This phone remains connected; your desk-phone password is unchanged.", false);
    }
    private async Task StartVideo(string number)
    {
        using var api = Api(); var bootstrap = await api.JsonAsync("bootstrap"); if (!(bootstrap["features"]?.AsArray().Any(x => x?.ToString() == "video_calls") ?? false)) throw new PhoneInputException("Video is not enabled for this PBX yet.");
        var contacts = await api.JsonAsync("directory"); if (!(contacts["contacts"]?.AsArray().OfType<JsonObject>().Any(x => x["id"]?.ToString() == "extension:" + ConnectionRules.Number(number)) ?? false)) throw new PhoneInputException("Choose a colleague listed in Contacts for a video call."); phone!.Dial(number, true); OpenVideo();
    }
    private void OpenVideo() { var video = new VideoWindow(phone!); video.Activate(); }
    private async Task ScanQr() { var scanner = new QrScanner(); var invitation = await scanner.Scan(App.WindowHandle, phone!); if (invitation is not null) await ImportInvitation(invitation); }
    private static async Task Launch(string uri) { if (!await global::Windows.System.Launcher.LaunchUriAsync(new Uri(uri))) throw new PhoneInputException("Windows could not open that page."); }
    private static void WriteComponentReceipt()
    {
        var args = Environment.GetCommandLineArgs();
        if (args.Length != 3 || args[1] != "--component-receipt") return;
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") != "embire2/openwebpbx") throw new InvalidOperationException();
        var root = Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? throw new InvalidOperationException(); var target = Path.GetFullPath(args[2]);
        if (!Path.GetDirectoryName(target)!.Equals(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(target).StartsWith("phone-ui-", StringComparison.Ordinal)) throw new InvalidOperationException();
        using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        System.Text.Json.JsonSerializer.Serialize(output, new { schema = 1, version = "1.0.0", native_core_started = true, credentials_persisted = false, tls_ca_and_hostname = true, mandatory_srtp = true, calls_placed = false });
    }
    private void NetworkStatusChanged(object sender) => DispatcherQueue.TryEnqueue(NetworkChanged);
    public void NetworkChanged() => phone?.NetworkChanged(global::Windows.Networking.Connectivity.NetworkInformation.GetConnectionProfiles().Any(p => p.GetNetworkConnectivityLevel() != global::Windows.Networking.Connectivity.NetworkConnectivityLevel.None));
    public void ShowMessage(string message) => Show(message);
    public async Task WaitAndImport(SetupInvitation invitation) { await EnsureInitialized(); await Execute(() => ImportInvitation(invitation)); }
    public bool CanExit => phone?.Busy != true;
    public void StopCamera() => phone?.StopCamera();
    public void Shutdown() { global::Windows.Networking.Connectivity.NetworkInformation.NetworkStatusChanged -= NetworkStatusChanged; timer.Stop(); notifications.Dispose(); StopPlayback(); phone?.Dispose(); }
}
