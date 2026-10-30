using OpenWebPbx_Desktop;

var checks = 0;
void Check(bool value, string message)
{
    checks++;
    if (!value) throw new InvalidOperationException(message);
}

const string code = "A1B2C-D3E4F";
const string wizard = "https://openwebpbx.com/wizard#code=" + code;
Check(ManagedSetupLink.VerifiedWizard(wizard, code) == wizard, "Actual managed wizard link was refused.");
foreach (var invalid in new string?[] { null, "", "a1b2c-d3e4f", code + "\n", code + "\r", " " + code, code + " ", "A1B2G-D3E4F", "A1B2CD3E4F" })
    Check(ManagedSetupLink.VerifiedWizard("https://openwebpbx.com/wizard#code=" + invalid, invalid) is null, "Invalid setup code was accepted.");
foreach (var invalid in new string?[] { null, "http://openwebpbx.com/wizard#code=" + code, "https://foreign.invalid/wizard#code=" + code,
    "https://openwebpbx.com.foreign.invalid/wizard#code=" + code, "https://openwebpbx.com/wizard?code=" + code,
    wizard + "&redirect=https://foreign.invalid", wizard + "\n", "https://openwebpbx.com/wizard#code=FFFFF-FFFFF" })
    Check(ManagedSetupLink.VerifiedWizard(invalid, code) is null, "An unbound or foreign wizard URL was accepted.");

const string canonical = "https://node-0123456789abcdef0123456789abcdef.openwebpbx.com";
Check(ManagedSetupLink.IsCanonicalAddress(canonical), "Fresh managed address was not recognized.");
Check(ManagedSetupLink.IsCanonicalAddress(canonical + ":443"), "Installer's explicit HTTPS port was refused.");
foreach (var invalid in new string?[] { null, "", "http://node-0123456789abcdef0123456789abcdef.openwebpbx.com", canonical + ":8443",
    canonical + "/app/pbx_onboarding/", canonical + "?code=123", canonical + "#setup", canonical.Replace("https://", "https://user@"),
    "https://customer.openwebpbx.com", "https://windows-test.openwebpbx.com", canonical + ".foreign.invalid" })
    Check(!ManagedSetupLink.IsCanonicalAddress(invalid), "A legacy, foreign or noncanonical address was treated as fresh bootstrap.");

Console.WriteLine($"Managed setup links: {checks} controls passed.");
