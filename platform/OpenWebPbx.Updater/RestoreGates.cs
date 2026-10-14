using System.Text.Json;

namespace OpenWebPbx.Updater;

public static class RestoreGates
{
    public static bool BlocksUpdate(string stateRoot)
    {
        var directory = Path.Combine(stateRoot, "backup-restore");
        if (new[] { "calls", "jobs", "updates", "backups" }.Any(name =>
            File.Exists(Path.Combine(directory, "hold-" + name)) || Directory.Exists(Path.Combine(directory, "hold-" + name)))) return true;
        var journal = Path.Combine(directory, "journal.json");
        if (!File.Exists(journal)) return Directory.Exists(journal);
        try
        {
            using var document = JsonDocument.Parse(UpdateJson.ReadBytes(journal, 1048576));
            var root = document.RootElement;
            return root.GetProperty("schema").GetInt32() != 1 ||
                   root.GetProperty("state").GetString() is not ("restored" or "recovered");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or KeyNotFoundException)
        { return true; }
    }
}
