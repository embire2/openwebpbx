// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json;
using OpenWebPbx.Phone.Core;
namespace OpenWebPbx.Phone.Windows;
public sealed class PreferencesStore
{
    private readonly string path;
    public PreferencesStore(string channel)
    {
        if (channel is not ("direct" or "store")) throw new ArgumentException("Choose a supported distribution.");
        path = Path.Combine(StoragePaths.Channel(channel), "preferences.json");
    }
    public PersonalPreferences Read()
    {
        try
        {
            if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || new FileInfo(path).Length > 16384) throw new PhoneInputException("Saved personal settings are unavailable.");
            return (JsonSerializer.Deserialize<PersonalPreferences>(File.ReadAllBytes(path)) ?? new()).Validated();
        }
        catch (FileNotFoundException) { return new(); }
        catch (JsonException) { return new(); }
    }
    public void Save(PersonalPreferences preferences)
    {
        preferences.Validated(); var parent = Path.GetDirectoryName(path)!;
        if (!Directory.Exists(parent) || (File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0) throw new PhoneInputException("Open your accounts before changing settings.");
        var temp = Path.Combine(parent, Guid.NewGuid().ToString("N") + ".tmp");
        try { using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { JsonSerializer.Serialize(file, preferences); file.Flush(true); } File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
