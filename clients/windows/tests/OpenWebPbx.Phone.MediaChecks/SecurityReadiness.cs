// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.MediaChecks;
internal static class SecurityReadiness
{
    internal static bool Ready(MediaSecurityObservation snapshot, Action refuse)
    {
        var running = snapshot.calls.Where(call => call.state == "StreamsRunning").ToArray();
        if (!snapshot.tls_ca_and_hostname || !snapshot.mandatory_srtp || running.Any(call =>
            call.encryption != "SRTP" || call.srtp_suite is not ("AESCM128HMACSHA180" or "Invalid")))
        {
            refuse(); // The caller retains its complete original Secure assertion.
            throw new InvalidDataException("The original security assertion did not refuse.");
        }
        // Pinned5.5.23 stats are filled by queued SRTP events. Invalid may also mean
        // unsupported security, so it is never accepted and cannot extend the wait.
        return running.Length > 0 && running.All(call => call.srtp_suite == "AESCM128HMACSHA180");
    }
    internal static void WithinExistingWait(Func<MediaSecurityObservation[]> snapshots, Action<int> refuse,
        Action<Func<bool>> existingWait)
    {
        MediaSecurityObservation? lastPending = null;
        try
        {
            // No new timer: signalling progress and security readiness share the
            // caller's one existing20s/100ms StreamsRunning wait.
            existingWait(() =>
            {
                var current = snapshots(); if (current.Length != 2) throw new InvalidDataException("Exactly two native connection peers required.");
                var left = Ready(current[0], () => refuse(0)); var right = Ready(current[1], () => refuse(1));
                lastPending = !left ? current[0] : !right ? current[1] : null;
                return left && right;
            });
        }
        catch (TimeoutException error)
        {
            // Retain the last actual predicate argument, not a later reread that
            // might have completed after the original deadline.
            if (lastPending is not null) error.Data["media_security_observation"] = lastPending;
            throw;
        }
    }
}
