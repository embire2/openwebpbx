// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Core;
public sealed record PersonalPreferences
{
    public string Theme { get; init; } = "System";
    public string StartupPage { get; init; } = "Keypad";
    public string ContactOrder { get; init; } = "Name";
    public string Microphone { get; init; } = "";
    public string Speaker { get; init; } = "";
    public string Camera { get; init; } = "";
    public string Ringtone { get; init; } = "";
    public bool Notifications { get; init; } = true;
    public bool HideCallerInNotifications { get; init; }
    public bool LaunchAtLogin { get; init; }
    public PersonalPreferences Validated()
    {
        if (Theme is not ("System" or "Light" or "Dark") || StartupPage is not ("Keypad" or "Contacts" or "Recents" or "Voicemail") || ContactOrder is not ("Name" or "Extension") ||
            new[] { Microphone, Speaker, Camera }.Any(x => x.Length > 500 || x.Any(char.IsControl)) || Ringtone.Length > 2048 || Ringtone.Any(char.IsControl))
            throw new PhoneInputException("Choose an available personal setting.");
        // Connection, encryption, codecs, routes and update trust are deliberately absent.
        return this;
    }
}
