// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.App;
internal static class Distribution
{
#if STORE
    public const string Channel = "store";
#else
    public const string Channel = "direct";
#endif
    public static string InstanceKey =>
#if PHONE_PACKAGE_FIXTURE
        OpenWebPbx.Phone.Core.PackageFixture.InstanceKey;
#else
        "OpenWebPBX-FreePhone-1";
#endif
    public static string StartupTaskId =>
#if PHONE_PACKAGE_FIXTURE
        OpenWebPbx.Phone.Core.PackageFixture.StartupTaskId;
#else
        "OpenWebPBXFreePhone";
#endif
}
