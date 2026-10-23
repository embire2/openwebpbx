// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Core;
public sealed record UpdateRequirement(bool Available, bool Required, Version Version)
{
    public static UpdateRequirement Evaluate(Version installed, Version verifiedRelease, IEnumerable<WindowsPhonePolicy> policies)
    {
        var values = policies.ToArray();
        if (values.Any(x => x.Published && x.Latest! > verifiedRelease)) throw new PhoneInputException("The published Windows phone release is not available yet. Your current phone has been kept.");
        return new(verifiedRelease > installed, verifiedRelease > installed && values.Any(x => x.Requires(installed)), verifiedRelease);
    }
    public void RequireNewCall() { if (Required) throw new PhoneInputException("Install the required Windows phone update before starting a new call. Current and incoming calls can continue."); }
    public static void RequireInstallationIdle(int activeCalls) => ConnectionRules.RequireIdle(activeCalls);
}
