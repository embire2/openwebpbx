// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.MediaChecks;
internal sealed record MediaSecurityCall(string state, string encryption, string srtp_suite);
internal sealed record MediaSecurityObservation(string source, bool tls_ca_and_hostname, bool mandatory_srtp, int call_count, MediaSecurityCall[] calls);
internal static class SecurityObservation
{
    internal static readonly string[] Sources = ["already_sampled_secure_argument", "last_connection_wait_argument"];
    internal static readonly string[] Encryptions = ["None", "SRTP", "ZRTP", "DTLS", "unrecognised"];
    internal static readonly string[] Suites = ["AESCM128HMACSHA180", "AESCM128HMACSHA132", "AES192CMHMACSHA180", "AES192CMHMACSHA132", "AES256CMHMACSHA180", "AES256CMHMACSHA132", "AEADAES128GCM", "AEADAES256GCM", "Invalid", "unrecognised"];
    internal static MediaSecurityCall Call(string state, string encryption, string suite) => new(
        WaitObservation.States.Contains(state, StringComparer.Ordinal) ? state : "unrecognised",
        Encryptions.Contains(encryption, StringComparer.Ordinal) ? encryption : "unrecognised",
        Suites.Contains(suite, StringComparer.Ordinal) ? suite : "unrecognised");
    internal static MediaSecurityObservation Capture(bool tls, bool mandatory, MediaSecurityCall[] calls, string source = "already_sampled_secure_argument")
    {
        if (!Sources.Contains(source, StringComparer.Ordinal) || calls.Length > 2 || calls.Any(call => !WaitObservation.States.Contains(call.state, StringComparer.Ordinal) && call.state != "unrecognised" || !Encryptions.Contains(call.encryption, StringComparer.Ordinal) || !Suites.Contains(call.srtp_suite, StringComparer.Ordinal))) throw new InvalidDataException("Bounded closed native security observation required.");
        return new(source, tls, mandatory, calls.Length, calls);
    }
}
