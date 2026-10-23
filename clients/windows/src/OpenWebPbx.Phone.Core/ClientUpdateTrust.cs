// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.Cryptography;
namespace OpenWebPbx.Phone.Core;
/// <summary>Instance administrators never supply app trust. This public-only component key is built into every flavor.</summary>
public static class ClientUpdateTrust
{
    public const string KeyId = "windows-phone-release-1";
    public const string PublicPemSha256 = "608691b241a17352f58b13f7883b9409ddd9bd78c3d32e07ddbfb55b8fc721ed";
    public const string PublicSpkiSha256 = "b1744a9cc37ba194fe29d6953b0967bf63a52b9a1f4c3695e30c2abab3ca82e7";
    public static RSA Open()
    {
        using var input = typeof(ClientUpdateTrust).Assembly.GetManifestResourceStream("OpenWebPbx.Phone.ReleasePublicKey.pem") ?? throw new PhoneInputException("The Windows phone update trust is missing. Reinstall the official app.");
        using var memory = new MemoryStream(); input.CopyTo(memory); var bytes = memory.ToArray();
        if (bytes.Length > 2048 || Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != PublicPemSha256) throw new PhoneInputException("The Windows phone update trust differs. The current app has been kept.");
        var key = RSA.Create();
        try
        {
            key.ImportFromPem(System.Text.Encoding.ASCII.GetString(bytes));
            var parameters = key.ExportParameters(false);
            if (key.KeySize != 3072 || parameters.Exponent is not [1, 0, 1] || Convert.ToHexString(SHA256.HashData(key.ExportSubjectPublicKeyInfo())).ToLowerInvariant() != PublicSpkiSha256) throw new CryptographicException();
            return key;
        }
        catch { key.Dispose(); throw new PhoneInputException("The Windows phone update trust could not be opened. The current app has been kept."); }
    }
}
