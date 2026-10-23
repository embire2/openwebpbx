// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.App;
internal static class Distribution
{
#if STORE
    public const string Channel = "store";
#else
    public const string Channel = "direct";
#endif
}
