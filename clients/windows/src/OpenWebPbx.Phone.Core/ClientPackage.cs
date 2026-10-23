// SPDX-License-Identifier: AGPL-3.0-or-later
using System.IO.Compression;
using System.Xml;
using System.Xml.Linq;
namespace OpenWebPbx.Phone.Core;
public static class ClientPackage
{
    public static void ValidateBundle(Stream input, ClientRelease release)
    {
        try
        {
            using var zip = new ZipArchive(input, ZipArchiveMode.Read, true);
            if (zip.Entries.Count is < 2 or > 256 || zip.Entries.Select(x => x.FullName).Distinct(StringComparer.OrdinalIgnoreCase).Count() != zip.Entries.Count) throw Invalid();
            var manifest = zip.GetEntry("AppxMetadata/AppxBundleManifest.xml") ?? throw Invalid();
            if (manifest.Length is < 64 or > 65536 || zip.GetEntry("AppxSignature.p7x") is null) throw Invalid();
            using var bytes = manifest.Open(); using var reader = XmlReader.Create(bytes, new() { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 65536 });
            var root = XDocument.Load(reader).Root ?? throw Invalid(); XNamespace ns = "http://schemas.microsoft.com/appx/2013/bundle";
            if (root.Name != ns + "Bundle") throw Invalid(); var identity = root.Elements(ns + "Identity").Single();
            if ((string?)identity.Attribute("Name") != release.Identity || (string?)identity.Attribute("Publisher") != release.Publisher || (string?)identity.Attribute("Version") != release.ReleaseVersion + ".0") throw Invalid();
            var packages = root.Elements(ns + "Packages").Single().Elements(ns + "Package").ToArray();
            var app = packages.Where(x => (string?)x.Attribute("Type") == "application").Single(); var name = (string?)app.Attribute("FileName") ?? "";
            if ((string?)app.Attribute("Architecture") != "x64" || name.Length is < 6 or > 200 || name.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '-' or '_')) || !name.EndsWith(".msix", StringComparison.OrdinalIgnoreCase) && !name.EndsWith(".appx", StringComparison.OrdinalIgnoreCase) || zip.GetEntry(name) is null) throw Invalid();
            // This is identity/scope validation only. Windows deployment must still validate the real package signature and trust.
        }
        catch (Exception e) when (e is InvalidDataException or XmlException or InvalidOperationException or ArgumentException) { throw Invalid(); }
    }
    private static PhoneInputException Invalid() => new("The Windows phone package identity could not be verified. The current app has been kept.");
}
