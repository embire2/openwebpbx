// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.App;
internal static class ComponentDiagnostics
{
    public static string? Receipt
    {
        get
        {
            var args = Environment.GetCommandLineArgs(); if (args.Length != 3 || args[1] != "--component-receipt") return null;
            if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") != "embire2/openwebpbx") return null;
            var root = Environment.GetEnvironmentVariable("RUNNER_TEMP"); if (root is null) return null; var path = Path.GetFullPath(args[2]);
            return Path.GetDirectoryName(path)!.Equals(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) && Path.GetFileName(path).StartsWith("phone-ui-", StringComparison.Ordinal) ? path : null;
        }
    }
    public static void Failure(string stage, Exception error)
    {
        var path = Receipt; if (path is null) return;
        try { File.WriteAllText(path + ".failure.json", System.Text.Json.JsonSerializer.Serialize(new { schema = 1, stage, error_type = error.GetType().Name, hresult = error.HResult })); } catch { /* Diagnostic writing never replaces the actual failure. */ }
    }
}
