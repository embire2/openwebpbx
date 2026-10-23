// SPDX-License-Identifier: AGPL-3.0-or-later
#if PHONE_MEDIA_FIXTURE
using System.Security.AccessControl;
using System.Security.Principal;
namespace OpenWebPbx.Phone.Windows;
internal sealed record NativeMediaFixture(string Root, string CaPem, string InputWav, string OutputWav, string? StaticImage = null)
{
    internal void Validate()
    {
        var runner = Environment.GetEnvironmentVariable("RUNNER_TEMP"); var path = Path.GetFullPath(Root);
        if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") != "embire2/openwebpbx" || runner is null ||
            !Path.GetDirectoryName(path)!.Equals(Path.GetFullPath(runner).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(path), "^phone-media-[a-f0-9]{32}$") || !Directory.Exists(path)) throw new InvalidOperationException("Only a disposable isolated media root is allowed.");
        for (var parent = new DirectoryInfo(path); parent is not null; parent = parent.Parent) if ((parent.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Fixture ancestry is linked.");
        var acl = new DirectoryInfo(path).GetAccessControl(); var user = WindowsIdentity.GetCurrent().User!.Value;
        var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (!acl.AreAccessRulesProtected || rules.Length != 2 || rules.Any(r => r.AccessControlType != AccessControlType.Allow || r.IdentityReference.Value != user && r.IdentityReference.Value != "S-1-5-18" || (r.FileSystemRights & FileSystemRights.FullControl) != FileSystemRights.FullControl)) throw new InvalidOperationException("Fixture root must be private to its user and SYSTEM.");
        if (CaPem.Length is < 100 or > 262144 || !CaPem.Contains("-----BEGIN CERTIFICATE-----", StringComparison.Ordinal) || CaPem.Contains("PRIVATE KEY", StringComparison.Ordinal)) throw new InvalidOperationException("Only a public fixture CA is allowed.");
        FilePath(InputWav, true); FilePath(OutputWav, false); if (StaticImage is not null) FilePath(StaticImage, true);
    }
    internal void NewOutput(string value)
    {
        FilePath(value, false); if (!value.EndsWith(".wav", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Only WAV fixture outputs are allowed.");
        try { _ = File.GetAttributes(value); throw new InvalidOperationException("Fixture output already exists."); } catch (FileNotFoundException) { }
    }
    private void FilePath(string value, bool required)
    {
        var path = Path.GetFullPath(value); if (!path.StartsWith(Path.GetFullPath(Root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Fixture media escaped its root.");
        for (var parent = new DirectoryInfo(Path.GetDirectoryName(path)!); parent is not null && parent.FullName.StartsWith(Path.GetFullPath(Root), StringComparison.OrdinalIgnoreCase); parent = parent.Parent) if (!parent.Exists || (parent.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Fixture media ancestry is unavailable.");
        if (File.Exists(path)) { if ((File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || new FileInfo(path).Length > 16 * 1024 * 1024) throw new InvalidOperationException("Fixture media is linked or oversized."); }
        else if (required) throw new InvalidOperationException("Fixture input is missing.");
    }
}
internal sealed record NativeMediaCallSnapshot(Guid Id, string State, string Encryption, string SrtpSuite, string VideoCodec, int DecodedVideoFrames, int Width, int Height, float ReceivedFps, string AudioCodec, int AudioClockRate, int AudioChannels);
internal sealed record NativeLocalPlaybackSnapshot(string State, int Duration, int Position, bool OwnedFilePresent);
internal sealed record NativeMediaCallSignal(int State, int Reason, int ProtocolCode, bool Observed);
internal sealed record NativeFixtureSnapshot(bool TlsCaAndHostname, bool MandatorySrtp, NativeMediaCallSnapshot[] Calls, string[] Dtmf, NativeMediaCallSignal[] Signals);
#endif
