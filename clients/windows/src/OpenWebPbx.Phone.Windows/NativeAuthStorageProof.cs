// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Windows;
internal sealed record NativeAuthStorageProof(int AuthCount, bool DatabaseDisabled, bool LimeDisabled, bool ChatDisabled,
    bool SaveAuthDisabled, bool StoreAuthDisabled, bool ConfigContainsSecret, bool ConfigContainsFixtureUsername,
    bool Stopped, int Files, int UnexpectedDatabases, int UnexpectedConfigs, bool FilesContainSecret, bool Complete)
{
    public bool Passed => AuthCount == 1 && DatabaseDisabled && LimeDisabled && ChatDisabled && SaveAuthDisabled && StoreAuthDisabled &&
        !ConfigContainsSecret && !ConfigContainsFixtureUsername && Stopped && UnexpectedDatabases == 0 && UnexpectedConfigs == 0 && !FilesContainSecret && Complete;
}
