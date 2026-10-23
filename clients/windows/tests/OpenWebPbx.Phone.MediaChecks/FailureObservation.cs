// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Diagnostics;
using System.Text.Json;
namespace OpenWebPbx.Phone.MediaChecks;

internal sealed record PeerFailureObservation(string progress, bool exited_before_cleanup, int? exit_code_before_cleanup, string error_type, bool stderr_observed);
internal sealed record MediaFailureObservation(string operation, string source_basename, int source_line, PeerFailureObservation? peer, MediaWaitObservation? wait, WaveReadObservation? wave);
internal static class FailureObservation
{
    internal static readonly string[] Operations = ["engine_construct", "engine_start", "case_prepare", "wrong_ca_create", "wrong_ca_wait", "wrong_ca_assert", "wrong_ca_dispose", "wrong_name_create", "wrong_name_wait", "wrong_name_assert", "wrong_name_dispose", "peer_0_create", "peer_1_create", "peer_2_create", "registration_wait", "security_assert", "case_execute", "peers_cleanup", "engine_idle", "engine_shutdown"];
    internal static readonly string[] SourceNames = ["LabCoordinator.cs", "LabServer.cs", "PeerRunner.cs", "PeerProtocol.cs", "CoreCodecInventory.cs", "ProcessImage.cs", "WaitObservation.cs", "AudioProof.cs", "NativePhone.cs", "NativeMediaFixture.cs", "external_component"];
    internal static readonly string[] Progress = ["none", "native_runtime_resources", "native_logging", "native_factory", "native_configuration", "native_create_core", "native_database", "native_encryption", "native_trusted_roots", "native_devices", "native_listeners", "native_start", "native_verify_policy", "ready", "unrecognised"];
    internal static readonly string[] ErrorTypes = ["none", "InvalidDataException", "InvalidOperationException", "JsonException", "IOException", "FileNotFoundException", "DirectoryNotFoundException", "UnauthorizedAccessException", "TimeoutException", "DllNotFoundException", "EntryPointNotFoundException", "BadImageFormatException", "TypeInitializationException", "ArgumentException", "ArgumentNullException", "NullReferenceException", "NotSupportedException", "AccessViolationException", "other", "unobserved"];
    internal static string TypeName(Exception error) => ErrorTypes.Contains(error.GetType().Name, StringComparer.Ordinal) ? error.GetType().Name : "other";
    internal static (string Type, bool Observed) ReadPeerError(string text, bool bounded)
    {
        if (!bounded || text.Length > 8192) return ("unobserved", false);
        if (text.Length == 0) return ("none", true);
        try
        {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 2 });
            var properties = document.RootElement.EnumerateObject().ToArray();
            if (properties.Length != 3 || properties.Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() != 3 || properties.Any(p => p.Name is not ("schema" or "state" or "error_type")) || document.RootElement.GetProperty("schema").GetInt32() != 1 || document.RootElement.GetProperty("state").GetString() != "refused_or_failed") return ("unobserved", false);
            var type = document.RootElement.GetProperty("error_type").GetString();
            return type is not null && ErrorTypes.Contains(type, StringComparer.Ordinal) && type is not ("none" or "unobserved") ? (type, true) : ("unobserved", false);
        }
        catch { return ("unobserved", false); }
    }
    internal static MediaFailureObservation Capture(Exception error, string operation)
    {
        // Never expose a path, message, stack, account or arbitrary stage text.
        var source = "external_component"; var line = 0;
        try
        {
            var frame = new StackTrace(error, true).GetFrames()?.FirstOrDefault(f => SourceNames.Contains(Path.GetFileName(f.GetFileName()), StringComparer.Ordinal) && f.GetFileLineNumber() is > 0 and <= 100000);
            if (frame is not null) { source = Path.GetFileName(frame.GetFileName())!; line = frame.GetFileLineNumber(); }
        }
        catch { }
        return new(Operations.Contains(operation, StringComparer.Ordinal) ? operation : "case_execute", source, line, error.Data["media_peer_observation"] as PeerFailureObservation, error.Data["media_wait_observation"] as MediaWaitObservation, error.Data["media_wave_observation"] as WaveReadObservation);
    }
}
