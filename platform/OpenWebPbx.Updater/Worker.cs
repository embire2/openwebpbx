using System.Text.Json;
using OpenWebPbx.Server;

namespace OpenWebPbx.Updater;

public sealed class Worker(UpdateRepository repository, UpdaterPaths paths, ReleaseVerifier verifier, DownloadClient downloads,
    PlatformInstaller installer, SwitchClient engine, ILogger<Worker> logger) : BackgroundService
{
    private UpdateCommand? command;
    private VerifiedRelease? candidate;
    private DateTimeOffset nextCheck = DateTimeOffset.MinValue;
    private string? lastSuccess;
    private bool restartPending;
    private string? verifiedArchive;
    private bool preflightPassed;
    public bool OneShot { get; set; }
    public bool CheckOnly { get; set; }
    public bool SkipRecovery { get; set; }
    private async Task Status(string state, string message, string installed, CancellationToken ct, long bytes = 0)
    {
        var status = new UpdateStatus(state, message, installed, candidate?.Version, bytes, candidate?.Asset.Bytes ?? 0, DateTimeOffset.UtcNow, lastSuccess);
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
        paths.Prepare();
        WorkerJournal? journal = File.Exists(paths.Journal) ? UpdateJson.Read<WorkerJournal>(paths.Journal) : null;
        if (File.Exists(paths.Status)) { try { lastSuccess = UpdateJson.Read<UpdateStatus>(paths.Status).LastSuccessVersion; } catch (Exception e) when (e is IOException or JsonException) { } }
        if (!SkipRecovery)
        {
            var recovery = await installer.Run(null, null, null, false, true, ct);
            if (recovery != 0) {
                if (recovery != 75 && journal is { State: "installing", TargetVersion: not null, AssetSha256: not null }) UpdateJson.Write(paths.FailedInstall, new FailedInstall(journal.TargetVersion, journal.AssetSha256));
                try { await Status(recovery == 75 ? "installing" : "recovery_required", recovery == 75 ? "Another update is still completing" : "An interrupted update needs administrator recovery. Check the private update log", paths.InstalledVersion(), ct); }
                catch (Npgsql.NpgsqlException) { }
                throw new IOException(recovery == 75 ? "Another update is still completing." : "An interrupted update needs recovery before continuing.");
            }
        }
        var installState = installer.JournalState();
        if (installState is "rolled_back" or "recovery_required" && journal is { State: "installing", TargetVersion: not null, AssetSha256: not null }) UpdateJson.Write(paths.FailedInstall, new FailedInstall(journal.TargetVersion, journal.AssetSha256));
        foreach (var old in await repository.Running(ct))
        {
            if (old.Action != "install" || journal?.CommandId == old.Id && journal.State is "checking" or "downloading" or "ready" or "waiting_calls" or "waiting_window")
                await repository.Retry(old, "Resuming an interrupted update request", ct);
            else if (installState == "completed" && journal?.TargetVersion == paths.InstalledVersion())
                await repository.Finish(old, true, "The update completed successfully", ct);
            else await repository.Finish(old, false, installState == "rolled_back" ? "The previous version was restored after an interrupted update" : "Review the update recovery status before trying again", ct);
        }
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
            await Initialize(stoppingToken);
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
            var policy = await repository.Policy(ct);
            var now = DateTimeOffset.UtcNow;
            if (command is null && now < nextCheck && (candidate is null || policy.Mode == "notify" || policy.Mode == "download" && File.Exists(Path.Combine(paths.Downloads, candidate.Asset.Sha256 + ".archive")))) return;
            if (newlyClaimed || candidate is null || now >= nextCheck || CheckOnly)
            {
                Journal("checking"); await Status("checking", "Checking for a signed release", installed, ct);
                var envelope = await downloads.Feed(ct);
                var previous = File.Exists(paths.Trust) ? UpdateJson.Read<TrustState>(paths.Trust) : null;
                var nextCandidate = verifier.Verify(envelope, paths.Platform, previous, now);
                if (candidate?.Asset.Sha256 != nextCandidate.Asset.Sha256) { verifiedArchive = null; preflightPassed = false; }
                candidate = nextCandidate;
                UpdateJson.Write(paths.Trust, new TrustState(candidate.Sequence, candidate.PayloadSha256));
                UpdateJson.WriteBytes(paths.Feed, envelope);
                nextCheck = now.AddHours(6);
            }
            var release = candidate!;
            if (UpdateJson.Version(release.Version) <= UpdateJson.Version(installed))
            {
                await Status("up_to_date", "This server is up to date", installed, ct); await Finish(true, "This server is up to date", ct); candidate = null; return;
            }
            ReleaseVerifier.RequireUpgrade(release, installed);
            var previousFailure = File.Exists(paths.FailedInstall) && UpdateJson.Read<FailedInstall>(paths.FailedInstall).AssetSha256 == release.Asset.Sha256;
            if (previousFailure && command is null && policy.Mode == "automatic") {
                await Status("error", "This update previously failed. Automatic retry is paused; an administrator can request installation again", installed, ct);
                return;
            }
            if (CheckOnly || command?.Action == "check" || command is null && policy.Mode == "notify")
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
            var preflight = preflightPassed ? 0 : await installer.Run(archive, paths.Feed, release.Version, true, false, ct);
            if (preflight == 75) { Journal("waiting_calls"); await Status("waiting_calls", "The update is ready and will wait for calls to finish", installed, ct, release.Asset.Bytes); return; }
            if (preflight != 0) throw new InvalidDataException("The verified update did not pass installation checks. The current server remains available.");
            preflightPassed = true;
            Journal("ready");
            if (command?.Action == "download" || command is null && policy.Mode == "download")
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
            var result = await installer.Run(archive, paths.Feed, release.Version, false, false, ct, command?.Action != "install");
            if (result == 75) { Journal("waiting_calls"); await Status("waiting_calls", "The update was deferred; the phone system remains available", installed, ct); return; }
            if (result != 0)
            {
                UpdateJson.Write(paths.FailedInstall, new FailedInstall(release.Version, release.Asset.Sha256)); installing = false;
                var recovered = result == 1 && installer.JournalState() == "rolled_back";
                await Status(recovered ? "rolled_back" : "recovery_required", recovered ? "The update failed; the previous version was restored" : "The update needs administrator recovery. Check the private update log", paths.InstalledVersion(), ct);
                await Finish(false, recovered ? "The previous version was restored" : "Administrator recovery is required", ct); candidate = null; nextCheck = now.AddHours(6); return;
            }
            if (paths.InstalledVersion() != release.Version) throw new IOException("The installer did not report the expected installed version.");
            installing = false; File.Delete(paths.FailedInstall);
            lastSuccess = release.Version; await Status("completed", "The update is installed and the phone system is running", release.Version, ct, release.Asset.Bytes);
            await Finish(true, "The update completed successfully", ct); candidate = null; nextCheck = now.AddHours(6);
            if (!OneShot) { restartPending = true; installer.RestartUpdater(); }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception e) when (e is IOException or InvalidDataException or JsonException or FormatException or System.Security.Cryptography.CryptographicException or HttpRequestException or OperationCanceledException or Npgsql.NpgsqlException or InvalidOperationException or KeyNotFoundException)
        {
            if (installing && candidate is not null) UpdateJson.Write(paths.FailedInstall, new FailedInstall(candidate.Version, candidate.Asset.Sha256));
            logger.LogWarning("An update attempt failed during verification, download, or installation. Review the private updater status.");
            var message = e is InvalidDataException ? e.Message : "The update could not finish. Your download can be retried; check the connection and update status";
            try { await Status("error", message, paths.InstalledVersion(), ct); await Finish(false, message, ct); } catch (Exception failure) when (failure is IOException or Npgsql.NpgsqlException) { }
            candidate = null; nextCheck = DateTimeOffset.UtcNow.AddMinutes(15);
        }
    }
    private async Task Finish(bool success, string message, CancellationToken ct)
    {
        if (command is not null) { await repository.Finish(command, success, message, ct); Journal(success ? "completed" : "failed"); command = null; }
    }
}
