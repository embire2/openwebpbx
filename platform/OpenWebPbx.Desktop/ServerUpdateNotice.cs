using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenWebPbx_Desktop;

public sealed record ServerUpdateNotice(string Version, bool Ready)
{
    public string Message => $"Your Windows Server PBX system has a new update {Version} - you must update in order to continue using the service.";
    public static ServerUpdateNotice? Read(JsonElement status)
    {
        if (status.ValueKind != JsonValueKind.Object ||
            !status.TryGetProperty("platform", out var platform) || platform.ValueKind != JsonValueKind.String || platform.GetString() != "windows-x64" ||
            !status.TryGetProperty("update_required", out var required) || required.ValueKind != JsonValueKind.True ||
            !status.TryGetProperty("available_version", out var available) || available.ValueKind != JsonValueKind.String ||
            !status.TryGetProperty("installed_version", out var installed) || installed.ValueKind != JsonValueKind.String) return null;
        var version = available.GetString()!; var previous = installed.GetString()!;
        const string pattern = @"\A(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\z";
        if (!Regex.IsMatch(version, pattern, RegexOptions.CultureInvariant) || !Regex.IsMatch(previous, pattern, RegexOptions.CultureInvariant) ||
            !System.Version.TryParse(version, out var next) || !System.Version.TryParse(previous, out var current) || next <= current) return null;
        return new(version, status.TryGetProperty("download_ready", out var ready) && ready.ValueKind == JsonValueKind.True);
    }
}
