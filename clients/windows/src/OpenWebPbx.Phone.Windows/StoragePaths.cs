// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Windows;
internal static class StoragePaths
{
    private static string Parent
    {
        get
        {
#if PHONE_PACKAGE_FIXTURE
            return Path.Combine(OpenWebPbx.Phone.Core.PackageFixture.Root, "userdata");
#else
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenWebPBX Free Phone");
#endif
        }
    }
    internal static string Channel(string channel) => Path.Combine(Parent, channel);
    internal static string Native => Path.Combine(Parent, "native-runtime");
}
