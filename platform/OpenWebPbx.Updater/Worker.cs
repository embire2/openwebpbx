using System.Text.Json;
using OpenWebPbx.Server;

namespace OpenWebPbx.Updater;

public sealed class Worker(UpdateRepository repository, UpdaterPaths paths, ReleaseVerifier verifier, DownloadClient downloads,
    PlatformInstaller installer, SwitchClient engine, ILogger<Worker> logger, TimeProvider? time = null) : BackgroundService
{
    private readonly TimeProvider clock = time ?? TimeProvider.System;
    private UpdateCommand? command;
    private VerifiedRelease? candidate;
    private DateTimeOffset nextCheck = DateTimeOffset.MinValue;
    private string? lastSuccess;
    private bool restartPending;
    private string? verifiedArchive;
    private bool preflightPassed;
    private bool retryAfterFailure;
    private VerifiedWindowsUpgradePlan? windowsPlan;
    private WindowsUpgradeJourney? windowsJourney;
    private string? selectedFeed;
    private WindowsUpgradePathContext? selectedContext;
    public bool OneShot { get; set; }
    public bool CheckOnly { get; set; }
    public bool SkipRecovery { get; set; }
    private async Task Status(string state, string message, string installed, CancellationToken ct, long bytes = 0)
    {
        var required = paths.Platform == "windows-x64" && candidate is not null && UpdateJson.Version(candidate.Version) > UpdateJson.Version(installed);
        var status = new UpdateStatus(state, message, installed, candidate?.Version, bytes, candidate?.Asset.Bytes ?? 0, DateTimeOffset.UtcNow, lastSuccess,
            paths.Platform, required, required && preflightPassed && verifiedArchive is not null && state is not ("error" or "recovery_required" or "rolled_back"),
            required ? ServerUpdateBehaviour.Notice(candidate!.Version) : null);
        UpdateJson.Write(paths.Status, status); UpdateJson.Write(paths.PublicStatus, status);
        if (!OperatingSystem.IsWindows()) {
            File.SetUnixFileMode(Path.GetDirectoryName(paths.PublicStatus)!, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
            File.SetUnixFileMode(paths.PublicStatus, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);
        }
        await repository.Status(status, ct);
    }
    private void Journal(string state, string? version = null) => UpdateJson.Write(paths.Journal, new WorkerJournal(command?.Id, command?.Action, version ?? candidate?.Version, state, DateTimeOffset.UtcNow, candidate?.Asset.Sha256));
    public async Task Initialize(CancellationToken ct)
    {
        if (!await InitializeAttempt(ct)) throw new IOException("Another update is still completing.");
    }
    private async Task<bool> InitializeAttempt(CancellationToken ct)
    {
        paths.Prepare();
        // Reverify the retained signed offer after a restart; never trust the public status as an installation input.
        if (paths.Platform == "windows-x64" && File.Exists(paths.Feed)) {
            try {
                candidate = verifier.Verify(UpdateJson.ReadBytes(paths.Feed, 262144), paths.Platform,
                    File.Exists(paths.Trust) ? UpdateJson.Read<TrustState>(paths.Trust) : null, DateTimeOffset.UtcNow);
            } catch (Exception e) when (e is IOException or InvalidDataException or JsonException or FormatException or System.Security.Cryptography.CryptographicException or KeyNotFoundException) { candidate = null; }
        }
        WorkerJournal? journal = File.Exists(paths.Journal) ? UpdateJson.Read<WorkerJournal>(paths.Journal) : null;
        if (File.Exists(paths.Status)) { try { lastSuccess = UpdateJson.Read<UpdateStatus>(paths.Status).LastSuccessVersion; } catch (Exception e) when (e is IOException or JsonException) { } }
        if (!SkipRecovery)
        {
            var recovery = await installer.Run(null, null, null, false, true, ct);
            if (recovery != 0) {
                if (recovery != 75 && journal is { State: "installing", TargetVersion: not null, AssetSha256: not null }) UpdateJson.Write(paths.FailedInstall, new FailedInstall(journal.TargetVersion, journal.AssetSha256));
                try { await Status(recovery == 75 ? "installing" : "recovery_required", recovery == 75 ? "Another update is still completing" : "An interrupted update needs administrator recovery. Check the private update log", paths.InstalledVersion(), ct); }
                catch (Npgsql.NpgsqlException) { }
                if (recovery == 75) return false;
                throw new IOException("An interrupted update needs recovery before continuing.");
            }
        }
        var installState = installer.JournalState();
        if (paths.Platform == "windows-x64" && File.Exists(paths.WindowsJourney))
        {
            windowsJourney = UpdateJson.Read<WindowsUpgradeJourney>(paths.WindowsJourney, 16384);
            if (windowsJourney.CommandId == Guid.Empty || windowsJourney.ExpiresAt > windowsJourney.RequestedAt.AddHours(24) ||
                windowsJourney.ExpiresAt <= windowsJourney.RequestedAt ||
                UpdateJson.Version(windowsJourney.TargetVersion) <= UpdateJson.Version(windowsJourney.FromVersion))
                throw new InvalidDataException("The saved Windows upgrade approval is invalid.");
            if (windowsJourney.State != "active" || windowsJourney.ExpiresAt <= DateTimeOffset.UtcNow ||
                !await repository.ActiveInstallation(windowsJourney.CommandId, windowsJourney.RequestedAt, ct))
                windowsJourney = null;
        }
        if (installState is "rolled_back" or "recovery_required" && journal is { State: "installing", TargetVersion: not null, AssetSha256: not null }) UpdateJson.Write(paths.FailedInstall, new FailedInstall(journal.TargetVersion, journal.AssetSha256));
        foreach (var old in await repository.Running(ct))
        {
            // A rollback can restore a pre-install worker journal while the
            // database still contains this installation request. Do not replay
            // it as a resumable download. A newer explicit request remains valid.
            if (paths.Platform == "windows-x64" && installState == "rolled_back" &&
                journal is { Action: "install", TargetVersion: not null, AssetSha256: not null } &&
                WasRolledBack(old, journal))
            {
                UpdateJson.Write(paths.FailedInstall, new FailedInstall(journal.TargetVersion, journal.AssetSha256));
                await repository.Finish(old, false, "The previous version was restored after this interrupted update; request installation again when ready", ct);
                UpdateJson.Write(paths.Journal, journal with { State = "failed", UpdatedAt = clock.GetUtcNow() });
                if (windowsJourney?.CommandId == old.Id)
                {
                    UpdateJson.Write(paths.WindowsJourney, windowsJourney with { State = "failed" });
                    windowsJourney = null;
                }
                continue;
            }
            if (windowsJourney?.CommandId == old.Id && installState == "completed" &&
                UpdateJson.Version(paths.InstalledVersion()) < UpdateJson.Version(windowsJourney.TargetVersion))
                await repository.Retry(old, "Continuing with the next required signed Windows release", ct);
            else if (old.Action != "install" || journal?.CommandId == old.Id && journal.State is "checking" or "downloading" or "ready" or "waiting_calls" or "waiting_window" or "between_steps")
                await repository.Retry(old, "Resuming an interrupted update request", ct);
            else if (installState == "completed" && journal?.TargetVersion == paths.InstalledVersion())
                await repository.Finish(old, true, "The update completed successfully", ct);
            else await repository.Finish(old, false, installState == "rolled_back" ? "The previous version was restored after an interrupted update" : "Review the update recovery status before trying again", ct);
        }
        return true;
    }

    private bool WasRolledBack(UpdateCommand request, WorkerJournal journal)
    {
        if (request.Action != "install" || request.Id != journal.CommandId || request.CreatedAt == default ||
            journal.AssetSha256 is not { Length: 64 } ||
            !journal.AssetSha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')) return false;
        using var document = JsonDocument.Parse(UpdateJson.ReadBytes(paths.InstallJournal, 262144));
        var root = document.RootElement;
        if (!root.TryGetProperty("state", out var state) || state.ValueKind != JsonValueKind.String || state.GetString() != "rolled_back") return false;
        if (!root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("Review the recovered Windows update before resuming its request.");
        if (version.GetString() != journal.TargetVersion) return false;
        if (!root.TryGetProperty("updated_at", out var updated) || updated.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("The recovered Windows update has no valid completion time.");
        var timestamp = updated.GetString()!;
        if (!(timestamp.EndsWith('Z') || timestamp.Length >= 6 && (timestamp[^6] is '+' or '-') && timestamp[^3] == ':') ||
            !updated.TryGetDateTimeOffset(out var recoveredAt))
            throw new InvalidDataException("The recovered Windows update has no valid completion time.");
        return recoveredAt >= request.CreatedAt;
    }

    private void EndJourney(string state)
    {
        if (windowsJourney is null || windowsJourney.CommandId != command?.Id) return;
        windowsJourney = windowsJourney with { State = state };
        UpdateJson.Write(paths.WindowsJourney, windowsJourney);
    }

    private async Task SelectWindowsStep(string installed, byte[] latestBytes, VerifiedRelease latest, DateTimeOffset now, bool continuing, CancellationToken ct)
    {
        byte[] catalogue;
        try { catalogue = continuing ? WindowsUpgradePathContext.ReadProtected(paths.WindowsCatalogue) : await downloads.WindowsCatalogue(ct); }
        catch (HttpRequestException error) when (!continuing && error.StatusCode == System.Net.HttpStatusCode.NotFound &&
            !File.Exists(paths.WindowsCatalogueTrust) && !File.Exists(paths.WindowsCatalogue) &&
            UpdateJson.Version(installed) >= UpdateJson.Version(latest.Asset.MinimumVersion))
        {
            windowsPlan = null; selectedContext = null; selectedFeed = null;
            if (candidate?.Asset.Sha256 != latest.Asset.Sha256) { verifiedArchive = null; preflightPassed = false; }
            candidate = latest; return; // Compatibility with a publisher that has not enabled a catalogue.
        }
        var ordinary = File.Exists(paths.Trust) ? UpdateJson.Read<TrustState>(paths.Trust) : null;
        var catalogueHistory = File.Exists(paths.WindowsCatalogueTrust) ? UpdateJson.Read<UpgradeCatalogueTrust>(paths.WindowsCatalogueTrust) : null;
        async Task<byte[]> Fetch(string url, CancellationToken token)
        {
            var tag = new Uri(url).Segments[^2].TrimEnd('/');
            var version = tag.StartsWith("windows-v", StringComparison.Ordinal) ? tag["windows-v".Length..] : tag[1..];
            var cached = Path.Combine(paths.Data, "windows-upgrade-feeds", version + ".json");
            return continuing && File.Exists(cached) ? WindowsUpgradePathContext.ReadProtected(cached) : await downloads.HistoricalWindowsFeed(version, token);
        }
        var plan = await verifier.WindowsPlanner().Resolve(installed, latestBytes, catalogue, ordinary, catalogueHistory, now, Fetch, ct);
        if (continuing && (windowsJourney is null || plan.Latest.Version != windowsJourney.TargetVersion ||
            plan.Latest.PayloadSha256 != windowsJourney.LatestPayloadSha256 || plan.CatalogueTrust != windowsJourney.CatalogueTrust))
            throw new InvalidDataException("The approved Windows upgrade path changed; request a fresh update.");
        // Store complete, verified authorisation before exposing a ready step.
        UpdateJson.WriteBytes(paths.WindowsCatalogue, catalogue);
        UpdateJson.Write(paths.WindowsCatalogueTrust, plan.CatalogueTrust);
        foreach (var step in plan.Steps)
            UpdateJson.WriteBytes(Path.Combine(paths.Data, "windows-upgrade-feeds", step.Release.Version + ".json"), step.Envelope);
        windowsPlan = plan;
        var selected = plan.Steps.FirstOrDefault();
        var next = selected?.Release ?? latest;
        if (candidate?.Asset.Sha256 != next.Asset.Sha256) { verifiedArchive = null; preflightPassed = false; }
        candidate = next;
        if (selected is not null)
        {
            UpdateJson.WriteBytes(paths.WindowsStepFeed, selected.Envelope);
            selectedFeed = paths.WindowsStepFeed;
            selectedContext = new(paths.WindowsCatalogue, paths.Feed);
        }
        else { selectedFeed = null; selectedContext = null; }
    }
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        paths.Prepare();
        using var single = new FileStream(Path.Combine(paths.Data, "worker.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        using var heartbeatStop = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        var heartbeat = Task.Run(async () => {
            while (!heartbeatStop.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(30), heartbeatStop.Token); await repository.Heartbeat(heartbeatStop.Token); }
                catch (OperationCanceledException) { break; }
                catch (Exception e) when (e is Npgsql.NpgsqlException or IOException) { logger.LogWarning("Update heartbeat could not reach the instance database."); }
            }
        }, CancellationToken.None);
        try
        {
            if (OneShot || CheckOnly) await Initialize(stoppingToken);
            else
            {
                while (true)
                {
                    stoppingToken.ThrowIfCancellationRequested();
                    if (await InitializeAttempt(stoppingToken)) break;
                    await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
                }
            }
            do
            {
                await Tick(stoppingToken);
                if (OneShot) break;
                await Task.Delay(TimeSpan.FromSeconds(20), stoppingToken);
            } while (!stoppingToken.IsCancellationRequested);
        }
        finally { heartbeatStop.Cancel(); await heartbeat; }
    }
    public async Task Tick(CancellationToken ct)
    {
        if (restartPending) return;
        var installed = paths.InstalledVersion();
        if (OperatingSystem.IsWindows() && RestoreGates.BlocksUpdate(Path.GetDirectoryName(paths.Data)!))
        {
            await Status("maintenance", "Server updates are paused while backup restore services await activation", installed, ct);
            return;
        }
        if (!OneShot && installer.JournalState() == "completed" && UpdateJson.Version(installed) > (typeof(Worker).Assembly.GetName().Version ?? new Version(0,0,0))) {
            restartPending = true; installer.RestartUpdater(); return;
        }
        var installing = false;
        try
        {
            bool newlyClaimed = false;
            if (!CheckOnly && command is null) { command = await repository.Claim(ct); newlyClaimed = command is not null; }
            if (command?.Action == "install" && command.CreatedAt < DateTimeOffset.UtcNow.AddHours(-24)) {
                await Finish(false, "This installation request expired. Request the update again when ready", ct);
                await Status("error", "This installation request expired. Request the update again when ready", installed, ct); return;
            }
            var policy = ServerUpdateBehaviour.EffectivePolicy(paths.Platform, await repository.Policy(ct));
            var now = clock.GetUtcNow();
            if (command is null && now < nextCheck && (retryAfterFailure || candidate is null || policy.Mode == "notify" || policy.Mode == "download" && preflightPassed)) return;
            if (newlyClaimed || now >= nextCheck || CheckOnly)
            {
                Journal("checking"); await Status("checking", "Checking for a signed release", installed, ct);
                var continuing = paths.Platform == "windows-x64" && windowsJourney is { State: "active" } &&
                    windowsJourney.CommandId == command?.Id && windowsJourney.ExpiresAt > now;
                var envelope = continuing ? WindowsUpgradePathContext.ReadProtected(paths.Feed) : await downloads.Feed(paths.Platform, ct);
                var previous = File.Exists(paths.Trust) ? UpdateJson.Read<TrustState>(paths.Trust) : null;
                var nextCandidate = verifier.Verify(envelope, paths.Platform, previous, now);
                if (paths.Platform == "windows-x64" && UpdateJson.Version(nextCandidate.Version) > UpdateJson.Version(installed))
                    await SelectWindowsStep(installed, envelope, nextCandidate, now, continuing, ct);
                else
                {
                    windowsPlan = null; selectedContext = null; selectedFeed = null;
                    if (candidate?.Asset.Sha256 != nextCandidate.Asset.Sha256) { verifiedArchive = null; preflightPassed = false; }
                    candidate = nextCandidate;
                }
                UpdateJson.Write(paths.Trust, new TrustState(nextCandidate.Sequence, nextCandidate.PayloadSha256));
                UpdateJson.WriteBytes(paths.Feed, envelope);
                nextCheck = now.Add(ServerUpdateBehaviour.CheckInterval(paths.Platform));
                retryAfterFailure = false;
            }
            var release = candidate!;
            if (UpdateJson.Version(release.Version) <= UpdateJson.Version(installed))
            {
                await Status("up_to_date", "This server is up to date", installed, ct); await Finish(true, "This server is up to date", ct); candidate = null; return;
            }
            ReleaseVerifier.RequireUpgrade(release, installed);
            if (command?.Action == "install" && windowsPlan is { Steps.Count: > 0 } &&
                (windowsJourney is not { State: "active" } || windowsJourney.CommandId != command.Id))
            {
                windowsJourney = new(command.Id, installed, windowsPlan.Latest.Version, windowsPlan.Latest.PayloadSha256,
                    windowsPlan.CatalogueTrust, command.CreatedAt, command.CreatedAt.AddHours(24));
                UpdateJson.Write(paths.WindowsJourney, windowsJourney);
            }
            var previousFailure = File.Exists(paths.FailedInstall) && UpdateJson.Read<FailedInstall>(paths.FailedInstall).AssetSha256 == release.Asset.Sha256;
            if (previousFailure && command is null && policy.Mode == "automatic") {
                await Status("error", "This update previously failed. Automatic retry is paused; an administrator can request installation again", installed, ct);
                return;
            }
            if (CheckOnly || command?.Action == "check" && paths.Platform != "windows-x64" || command is null && policy.Mode == "notify")
            {
                await Status("available", previousFailure ? "A verified update is available, but its previous installation failed. Review recovery before retrying" : "A verified update is available", installed, ct); await Finish(true, "A verified update is available", ct); return;
            }
            if (verifiedArchive is null) {
                Journal("downloading");
                await Status("downloading", "Downloading the update; your phone system remains available", installed, ct);
                verifiedArchive = await downloads.Download(release.Asset, paths.Downloads, async bytes => await Status("downloading", "Downloading and verifying the update", installed, ct, bytes), ct);
            }
            var archive = verifiedArchive;
            // The currently installed helper verifies the signed feed, complete archive,
            // safe extraction and manifest before any manager/service may be stopped.
            var preflight = preflightPassed ? 0 : await installer.Run(archive, selectedFeed ?? paths.Feed, release.Version, true, false, ct, upgradeContext: selectedContext);
            if (preflight == 75) { Journal("waiting_calls"); await Status("waiting_calls", "The update is ready and will wait for calls to finish", installed, ct, release.Asset.Bytes); return; }
            if (preflight != 0) throw new InvalidDataException("The verified update did not pass installation checks. The current server remains available.");
            preflightPassed = true;
            Journal("ready");
            if (command?.Action == "download" || command?.Action == "check" || command is null && policy.Mode == "download")
            {
                await Status("ready", "The update is downloaded and verified", installed, ct, release.Asset.Bytes); await Finish(true, "The update is downloaded and verified", ct); return;
            }
            if (command?.Action != "install" && !UpdateJson.InWindow(policy, now))
            {
                Journal("waiting_window"); await Status("waiting_window", "The update is ready for the daily maintenance window", installed, ct, release.Asset.Bytes); return;
            }
            using var calls = JsonDocument.Parse(await engine.Execute("show channels as json", ct));
            if (calls.RootElement.GetProperty("row_count").ToString() != "0")
            {
                Journal("waiting_calls"); await Status("waiting_calls", "The update is ready and will wait for calls to finish", installed, ct, release.Asset.Bytes); return;
            }
            Journal("installing"); await Status("installing", "Saving a backup and installing the verified update", installed, ct, release.Asset.Bytes);
            installing = true;
            var result = await installer.Run(archive, selectedFeed ?? paths.Feed, release.Version, false, false, ct, command?.Action != "install", selectedContext);
            if (result == 75) { Journal("waiting_calls"); await Status("waiting_calls", "The update was deferred; the phone system remains available", installed, ct); return; }
            if (result != 0)
            {
                UpdateJson.Write(paths.FailedInstall, new FailedInstall(release.Version, release.Asset.Sha256)); installing = false;
                var recovered = result == 1 && installer.JournalState() == "rolled_back";
                await Status(recovered ? "rolled_back" : "recovery_required", recovered ? "The update failed; the previous version was restored" : "The update needs administrator recovery. Check the private update log", paths.InstalledVersion(), ct);
                await Finish(false, recovered ? "The previous version was restored" : "Administrator recovery is required", ct); retryAfterFailure = true; nextCheck = now.Add(ServerUpdateBehaviour.CheckInterval(paths.Platform)); return;
            }
            if (paths.InstalledVersion() != release.Version) throw new IOException("The installer did not report the expected installed version.");
            installing = false; File.Delete(paths.FailedInstall);
            if (windowsJourney is { State: "active" } && windowsJourney.CommandId == command?.Id &&
                UpdateJson.Version(release.Version) < UpdateJson.Version(windowsJourney.TargetVersion))
            {
                lastSuccess = release.Version;
                await Status("checking", "This Windows release is installed; continuing with the next required signed release", release.Version, ct, release.Asset.Bytes);
                Journal("between_steps"); candidate = null; windowsPlan = null; selectedFeed = null; selectedContext = null;
                verifiedArchive = null; preflightPassed = false; nextCheck = DateTimeOffset.MinValue;
                if (!OneShot) { restartPending = true; installer.RestartUpdater(); }
                return;
            }
            lastSuccess = release.Version; await Status("completed", "The update is installed and the phone system is running", release.Version, ct, release.Asset.Bytes);
            await Finish(true, "The update completed successfully", ct); candidate = null; nextCheck = now.Add(ServerUpdateBehaviour.CheckInterval(paths.Platform));
            if (!OneShot) { restartPending = true; installer.RestartUpdater(); }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception e) when (e is IOException or InvalidDataException or JsonException or FormatException or System.Security.Cryptography.CryptographicException or HttpRequestException or OperationCanceledException or Npgsql.NpgsqlException or InvalidOperationException or KeyNotFoundException)
        {
            if (installing && candidate is not null) UpdateJson.Write(paths.FailedInstall, new FailedInstall(candidate.Version, candidate.Asset.Sha256));
            verifiedArchive = null; preflightPassed = false;
            logger.LogWarning("An update attempt failed during verification, download, or installation. Review the private updater status.");
            var message = e is InvalidDataException ? e.Message : "The update could not finish. Your download can be retried; check the connection and update status";
            try { await Status("error", message, paths.InstalledVersion(), ct); await Finish(false, message, ct); } catch (Exception failure) when (failure is IOException or Npgsql.NpgsqlException) { }
            verifiedArchive = null; preflightPassed = false; retryAfterFailure = true;
            nextCheck = clock.GetUtcNow().Add(paths.Platform == "windows-x64" ? TimeSpan.FromMinutes(5) : TimeSpan.FromMinutes(15));
        }
    }
    private async Task Finish(bool success, string message, CancellationToken ct)
    {
        if (command is not null) { await repository.Finish(command, success, message, ct); EndJourney(success ? "completed" : "failed"); Journal(success ? "completed" : "failed"); command = null; }
    }
}
