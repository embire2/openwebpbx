// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Core;

/// <summary>Serialises profile changes without replacing the shared calling engine.</summary>
public sealed class ProfileManager(IProfileStore store, Func<int> activeCalls, Func<bool> installing)
{
    private readonly SemaphoreSlim mutex = new(1, 1);
    public async Task AddAsync(PhoneProfile profile, CancellationToken cancellation = default)
    {
        await mutex.WaitAsync(cancellation);
        try
        {
            RequireIdle(); var profiles = await store.ReadAsync(cancellation);
            if (profiles.Count >= ConnectionRules.MaximumProfiles) throw new PhoneInputException("Remove an account before adding another.");
            if (profiles.Any(x => x.SameAccount(profile) || x.Id == profile.Id || x.DeviceId == profile.DeviceId))
                throw new PhoneInputException("This account is already saved. Open Accounts to reconnect it.");
            var selected = await store.SelectedAsync(cancellation) ?? profile.Id; RequireIdle();
            await store.SaveAsync([.. profiles, profile], selected, cancellation);
        }
        finally { mutex.Release(); }
    }
    public async Task ReconnectAsync(Guid id, PhoneProfile connected, CancellationToken cancellation = default)
    {
        await mutex.WaitAsync(cancellation);
        try
        {
            RequireIdle(); var profiles = await store.ReadAsync(cancellation); var old = profiles.SingleOrDefault(x => x.Id == id) ?? throw new PhoneInputException("Choose the saved account to reconnect.");
            if (old.Server != connected.Server || old.Account.DomainId != connected.Account.DomainId || old.Account.ExtensionId != connected.Account.ExtensionId || old.Account.Extension != connected.Account.Extension || connected.NeedsLogin || profiles.Any(x => x.Id != id && (x.SameAccount(connected) || x.DeviceId == connected.DeviceId))) throw new PhoneInputException("This sign-in belongs to a different account. Add it as a new account instead.");
            var selected = await store.SelectedAsync(cancellation); RequireIdle(); await store.SaveAsync(profiles.Select(x => x.Id == id ? connected with { Id = id, Name = old.Name } : x).ToArray(), selected, cancellation);
        }
        finally { mutex.Release(); }
    }
    public async Task SelectAsync(Guid id, CancellationToken cancellation = default)
    {
        await mutex.WaitAsync(cancellation);
        try
        {
            RequireIdle(); var profiles = await store.ReadAsync(cancellation);
            if (!profiles.Any(x => x.Id == id)) throw new PhoneInputException("Choose a saved account.");
            RequireIdle(); await store.SaveAsync(profiles, id, cancellation);
        }
        finally { mutex.Release(); }
    }
    public async Task RenameAsync(Guid id, string name, CancellationToken cancellation = default)
    {
        name = name.Trim();
        if (name.Length is < 1 or > 80 || name.Any(char.IsControl)) throw new PhoneInputException("Use an account name between 1 and 80 characters.");
        await mutex.WaitAsync(cancellation);
        try
        {
            RequireIdle(); var profiles = await store.ReadAsync(cancellation);
            if (!profiles.Any(x => x.Id == id)) throw new PhoneInputException("Choose a saved account.");
            var selected = await store.SelectedAsync(cancellation); RequireIdle();
            await store.SaveAsync(profiles.Select(x => x.Id == id ? x with { Name = name } : x).ToArray(), selected, cancellation);
        }
        finally { mutex.Release(); }
    }
    public async Task RemoveAsync(Guid id, CancellationToken cancellation = default)
    {
        await mutex.WaitAsync(cancellation);
        try
        {
            RequireIdle(); var profiles = await store.ReadAsync(cancellation);
            var kept = profiles.Where(x => x.Id != id).ToArray();
            if (kept.Length == profiles.Count) throw new PhoneInputException("Choose a saved account.");
            var selected = await store.SelectedAsync(cancellation);
            RequireIdle(); await store.SaveAsync(kept, selected == id ? kept.FirstOrDefault()?.Id : selected, cancellation);
        }
        finally { mutex.Release(); }
    }
    /// <summary>Presentation/password-state metadata may refresh during calls; identity and SIP/device credentials cannot change.</summary>
    public async Task UpdateAccountAsync(Guid id, AccountIdentity account, CancellationToken cancellation = default)
    {
        await mutex.WaitAsync(cancellation);
        try
        {
            var profiles = await store.ReadAsync(cancellation); var existing = profiles.SingleOrDefault(x => x.Id == id) ?? throw new PhoneInputException("Choose a saved account.");
            if (account.DomainId != existing.Account.DomainId || account.ExtensionId != existing.Account.ExtensionId || account.Extension != existing.Account.Extension) throw new PhoneInputException("The PBX account does not match this saved phone.");
            var selected = await store.SelectedAsync(cancellation); await store.SaveAsync(profiles.Select(x => x.Id == id ? x with { Account = account } : x).ToArray(), selected, cancellation);
        }
        finally { mutex.Release(); }
    }
    private void RequireIdle() => ConnectionRules.RequireIdle(activeCalls(), installing());
}
