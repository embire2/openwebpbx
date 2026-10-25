namespace OpenWebPbx.Updater;

public static class ServerUpdateBehaviour
{
    public static TimeSpan CheckInterval(string platform) => platform == "windows-x64" ? TimeSpan.FromMinutes(5) : TimeSpan.FromHours(6);
    // Windows always prepares updates. Notification never means stopping the PBX.
    public static UpdatePolicy EffectivePolicy(string platform, UpdatePolicy policy) =>
        platform == "windows-x64" ? policy with { Mode = "download" } : policy;
    public static string Notice(string version) => $"Your Windows Server PBX system has a new update {version} - you must update in order to continue using the service.";
}
