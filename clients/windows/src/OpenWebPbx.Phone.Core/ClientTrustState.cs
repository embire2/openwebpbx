// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Core;
public sealed record ClientTrustState(long Sequence = 0, string PayloadSha256 = "")
{
    public ClientTrustState Advance(ClientRelease release)
    {
        if (Sequence < 0 || release.Sequence < 1 || release.Sequence < Sequence || release.PayloadSha256.Length != 64 || release.PayloadSha256.Any(c => !char.IsAsciiHexDigit(c)) ||
            release.Sequence == Sequence && !release.PayloadSha256.Equals(PayloadSha256, StringComparison.Ordinal)) throw new PhoneInputException("An older or replaced Windows phone release was refused. The current app has been kept.");
        return new(release.Sequence, release.PayloadSha256);
    }
}
