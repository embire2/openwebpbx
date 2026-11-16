using System.Security.Cryptography;
using System.Text.Json;
using OpenWebPbx.Updater;

public static class WindowsUpgradePlanChecks
{
    public static async Task<int> Run()
    {
        var checks = 0;
        void Check(bool value, string message) { checks++; if (!value) throw new Exception(message); }
        void Reject(Action action, string message)
        {
            try { action(); }
            catch (Exception error) when (error is InvalidDataException or JsonException or CryptographicException or FormatException or InvalidOperationException or KeyNotFoundException or ArgumentException)
            { checks++; return; }
            throw new Exception(message);
        }
        async Task RejectAsync(Func<Task> action, string message)
        {
            try { await action(); }
            catch (Exception error) when (error is InvalidDataException or JsonException or CryptographicException or FormatException or InvalidOperationException or KeyNotFoundException or ArgumentException)
            { checks++; return; }
            throw new Exception(message);
        }

        using var key = RSA.Create(2048);
        var publicKey = key.ExportSubjectPublicKeyInfoPem();
        var verifier = new ReleaseVerifier(publicKey);
        var planner = new WindowsUpgradePlanner(publicKey);
        var now = DateTimeOffset.UtcNow;
        byte[] Sign(object value)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
            return JsonSerializer.SerializeToUtf8Bytes(new { key_id = "release-2026-a", payload = Convert.ToBase64String(bytes), signature = Convert.ToBase64String(key.SignData(bytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) });
        }
        string Digest(byte[] value) => Convert.ToHexStringLower(SHA256.HashData(value));
        Dictionary<string, object?> Release(string version, string minimum, long sequence) => new()
        {
            ["schema"] = 1, ["product"] = "openwebpbx", ["channel"] = "stable",
            ["sequence"] = sequence, ["version"] = version,
            ["published_at"] = now.AddDays(-1), ["expires_at"] = now.AddDays(5),
            ["assets"] = new[] { new { platform = "windows-x64", name = $"openwebpbx-{version}-windows-x64.zip", url = $"https://github.com/embire2/openwebpbx/releases/download/v{version}/openwebpbx-{version}-windows-x64.zip", bytes = 100, sha256 = new string('a', 64), minimum_version = minimum } }
        };
        var envelopes = new Dictionary<string, byte[]>
        {
            ["1.0.21"] = Sign(Release("1.0.21", "1.0.20", 121)),
            ["1.0.22"] = Sign(Release("1.0.22", "1.0.21", 122)),
            ["1.0.23"] = Sign(Release("1.0.23", "1.0.22", 123))
        };
        var latestEnvelope = envelopes["1.0.23"];
        var latest = verifier.Verify(latestEnvelope, "windows-x64", null, now);
        var ordinaryFloor = new TrustState(latest.Sequence, latest.PayloadSha256);
        Dictionary<string, object?> Entry(string from, string version) => new() { ["previous_version"] = from, ["version"] = version, ["envelope_sha256"] = Digest(envelopes[version]) };
        Dictionary<string, object?> Catalogue() => new()
        {
            ["schema"] = 1, ["kind"] = "windows-upgrade-path", ["product"] = "openwebpbx",
            ["channel"] = "stable", ["platform"] = "windows-x64", ["sequence"] = 501L,
            ["published_at"] = now.AddMinutes(-1), ["expires_at"] = now.AddDays(1),
            ["minimum_installed_version"] = "1.0.20", ["latest_version"] = latest.Version,
            ["latest_payload_sha256"] = latest.PayloadSha256, ["latest_sequence"] = latest.Sequence,
            ["steps"] = new[] { Entry("1.0.20", "1.0.21"), Entry("1.0.21", "1.0.22"), Entry("1.0.22", "1.0.23") }
        };
        var signedCatalogue = Sign(Catalogue());
        var requests = new List<string>();
        Task<byte[]> Fetch(string url, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested(); requests.Add(url);
            var match = envelopes.Single(row => WindowsUpgradePlanner.PlatformFeedUrl(row.Key) == url);
            return Task.FromResult(match.Value);
        }
        Task<VerifiedWindowsUpgradePlan> Resolve(string installed, byte[]? catalogue = null, TrustState? floor = null, UpgradeCatalogueTrust? history = null, DateTimeOffset? at = null)
            => planner.Resolve(installed, latestEnvelope, catalogue ?? signedCatalogue, floor ?? ordinaryFloor, history, at ?? now, Fetch, default);

        var plan = await Resolve("1.0.21");
        Check(WindowsUpgradePlanner.PlatformFeedUrl("1.0.21") == "https://github.com/embire2/openwebpbx/releases/download/v1.0.21/windows-update-manifest.json" &&
            WindowsUpgradePlanner.PlatformFeedUrl("1.0.22").Contains("/windows-v1.0.22/", StringComparison.Ordinal), "Historical21 feed did not use its published canonical tag");
        Check(plan.Steps.Select(step => step.Release.Version).SequenceEqual(new[] { "1.0.22", "1.0.23" }), "21 did not select22then23");
        Check(requests.SequenceEqual(new[] { WindowsUpgradePlanner.PlatformFeedUrl("1.0.22") }), "Planner used a stale canonical feed or fetched the final feed twice");
        Check(plan.Steps[0].Release.Sequence < ordinaryFloor.Sequence && plan.OrdinaryTrustFloor == ordinaryFloor, "Historical step lowered ordinary anti-rollback history");
        Check(plan.CatalogueTrust.Sequence == 501, "Catalogue trust was not returned separately");
        Check(plan.Steps[0].Envelope.SequenceEqual(envelopes["1.0.22"]) && plan.LatestEnvelope.SequenceEqual(latestEnvelope), "Exact signed envelopes were lost");
        requests.Clear();
        var oldest = await Resolve("1.0.20");
        Check(oldest.Steps.Select(step => step.Release.Version).SequenceEqual(new[] { "1.0.21", "1.0.22", "1.0.23" }), "20 skipped a required version");
        Check(requests.SequenceEqual(new[] { WindowsUpgradePlanner.PlatformFeedUrl("1.0.21"), WindowsUpgradePlanner.PlatformFeedUrl("1.0.22") }), "Historical fetches were not ordered Windows platform tags");
        requests.Clear();
        Check((await Resolve("1.0.22")).Steps.Single().Release.Version == "1.0.23" && requests.Count == 0, "22 did not use the verified latest envelope");
        Check((await Resolve("1.0.23")).Steps.Count == 0 && (await Resolve("1.0.24")).Steps.Count == 0, "Current/newer server was downgraded");
        await RejectAsync(() => Resolve("1.0.19"), "Unsupported legacy server was admitted");
        Check(requests.Count == 0, "Unsupported legacy server reached the network");

        var step = planner.VerifyNextStep("1.0.21", "1.0.22", envelopes["1.0.22"], latestEnvelope, signedCatalogue, ordinaryFloor, plan.CatalogueTrust, now);
        Check(step.Release.Version == "1.0.22", "Next-step installer admission failed");
        Check(planner.VerifyNextStep("1.0.22", "1.0.23", latestEnvelope, latestEnvelope, signedCatalogue, ordinaryFloor, plan.CatalogueTrust, now).Release.Version == "1.0.23", "Final installer admission failed");
        Reject(() => planner.VerifyNextStep("1.0.21", "1.0.23", latestEnvelope, latestEnvelope, signedCatalogue, ordinaryFloor, plan.CatalogueTrust, now), "Installer skipped22");
        Reject(() => planner.VerifyNextStep("1.0.23", "1.0.23", latestEnvelope, latestEnvelope, signedCatalogue, ordinaryFloor, plan.CatalogueTrust, now), "Installer reinstalled an equal version");
        Reject(() => planner.VerifyNextStep("1.0.22", "1.0.21", envelopes["1.0.21"], latestEnvelope, signedCatalogue, ordinaryFloor, plan.CatalogueTrust, now), "Installer accepted a downgrade");
        Reject(() => verifier.Verify(envelopes["1.0.22"], "windows-x64", ordinaryFloor, now), "Ordinary verifier was weakened for historical steps");
        await RejectAsync(() => Resolve("1.0.21", history: new(502, plan.CatalogueTrust.PayloadSha256)), "Older catalogue sequence was accepted");
        await RejectAsync(() => Resolve("1.0.21", history: new(501, new string('b', 64))), "Conflicting repeated catalogue sequence was accepted");
        Check((await Resolve("1.0.21", history: plan.CatalogueTrust)).CatalogueTrust == plan.CatalogueTrust, "Identical repeated catalogue was refused");
        await RejectAsync(() => Resolve("1.0.21", floor: new(124, latest.PayloadSha256)), "Catalogue bypassed an advanced ordinary watermark");
        await RejectAsync(() => Resolve("1.0.21", floor: new(123, new string('b', 64))), "Catalogue bypassed conflicting ordinary release metadata");
        await RejectAsync(() => Resolve("1.0.21", floor: new(0, latest.PayloadSha256)), "Corrupt ordinary trust state was silently ignored");
        await RejectAsync(() => Resolve("1.0.21", history: new(0, plan.CatalogueTrust.PayloadSha256)), "Corrupt catalogue trust state was silently ignored");
        await RejectAsync(() => Resolve("1.0.21", history: new(500, "not-a-sha256")), "Malformed catalogue trust digest was silently ignored");

        foreach (var (field, value) in new (string, object?)[]
        {
            ("schema", 2), ("kind", "other"), ("product", "foreign"), ("channel", "beta"), ("platform", "debian13-amd64"),
            ("sequence", 0L), ("latest_version", "1.0.22"), ("latest_sequence", 122L), ("latest_payload_sha256", new string('b', 64)),
            ("published_at", now.AddHours(1)), ("expires_at", now.AddSeconds(-1)), ("minimum_installed_version", "1.0.021")
        })
        {
            var catalogue = Catalogue(); catalogue[field] = value;
            await RejectAsync(() => Resolve("1.0.21", Sign(catalogue)), "Invalid catalogue field accepted: " + field);
        }
        var extra = Catalogue(); extra["command"] = "anything";
        await RejectAsync(() => Resolve("1.0.21", Sign(extra)), "Unknown catalogue fields were accepted");
        var skipped = Catalogue(); skipped["steps"] = new[] { Entry("1.0.20", "1.0.21"), Entry("1.0.21", "1.0.23") };
        await RejectAsync(() => Resolve("1.0.21", Sign(skipped)), "A signed path omitted an intermediate patch");
        var repeated = Catalogue(); repeated["steps"] = new[] { Entry("1.0.20", "1.0.21"), Entry("1.0.20", "1.0.21"), Entry("1.0.21", "1.0.22"), Entry("1.0.22", "1.0.23") };
        await RejectAsync(() => Resolve("1.0.21", Sign(repeated)), "A duplicate or disconnected step was accepted");
        var hashMismatch = Catalogue(); var entries = (Dictionary<string, object?>[])hashMismatch["steps"]!; entries[1]["envelope_sha256"] = new string('b', 64);
        await RejectAsync(() => Resolve("1.0.21", Sign(hashMismatch)), "Different historical bytes were admitted");
        var wrongFinal = Catalogue(); var finalEntries = (Dictionary<string, object?>[])wrongFinal["steps"]!; finalEntries[^1]["envelope_sha256"] = new string('b', 64);
        await RejectAsync(() => Resolve("1.0.21", Sign(wrongFinal)), "Final catalogue envelope was not bound exactly");

        // A catalogue signature alone cannot bless an invalid old release or
        // silently change the previously qualified minimum installation version.
        var original = envelopes["1.0.22"];
        try
        {
            envelopes["1.0.22"] = envelopes["1.0.21"];
            await RejectAsync(() => Resolve("1.0.21", Sign(Catalogue())), "A historical canonical22 feed advertising21 was accepted as22");
            var invalidMinimum = Release("1.0.22", "1.0.22", 122);
            envelopes["1.0.22"] = Sign(invalidMinimum);
            await RejectAsync(() => Resolve("1.0.21", Sign(Catalogue())), "A step bypassed its own release minimum");
            var expired = Release("1.0.22", "1.0.21", 122); expired["expires_at"] = now.AddSeconds(-1);
            envelopes["1.0.22"] = Sign(expired);
            await RejectAsync(() => Resolve("1.0.21", Sign(Catalogue())), "An expired historical step was admitted");
            var corrupt = (byte[])original.Clone(); corrupt[^10] ^= 1; envelopes["1.0.22"] = corrupt;
            await RejectAsync(() => Resolve("1.0.21", Sign(Catalogue())), "A catalogue blessed a corrupt historical signature");
        }
        finally { envelopes["1.0.22"] = original; }
        var corruptedCatalogue = (byte[])signedCatalogue.Clone(); corruptedCatalogue[^10] ^= 1;
        await RejectAsync(() => Resolve("1.0.21", corruptedCatalogue), "Corrupt catalogue signature was accepted");
        using (var other = RSA.Create(2048))
            await RejectAsync(() => new WindowsUpgradePlanner(other.ExportSubjectPublicKeyInfoPem()).Resolve("1.0.21", latestEnvelope, signedCatalogue, ordinaryFloor, null, now, Fetch, default), "A foreign signing key was accepted");
        await RejectAsync(() => Resolve("1.0.21", at: now.AddDays(2)), "Expired catalogue was accepted");
        Reject(() => WindowsUpgradePlanner.PlatformFeedUrl("1.0.22/../other"), "Path traversal reached historical feed resolution");
        Reject(() => WindowsUpgradePlanner.PlatformFeedUrl("1.0.022"), "Non-canonical release string was accepted");
        Reject(() => WindowsUpgradePlanner.PlatformFeedUrl("1.0.22\n"), "A newline reached historical feed resolution");
        await RejectAsync(() => Resolve("1.0.21\n"), "A non-canonical installed version was accepted");

        var duplicatePayload = System.Text.Encoding.UTF8.GetBytes("{\"schema\":1,\"schema\":1}");
        var duplicate = JsonSerializer.SerializeToUtf8Bytes(new { key_id = "release-2026-a", payload = Convert.ToBase64String(duplicatePayload), signature = Convert.ToBase64String(key.SignData(duplicatePayload, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) });
        await RejectAsync(() => Resolve("1.0.21", duplicate), "Duplicate signed catalogue properties were accepted");

        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            try { await planner.Resolve("1.0.21", latestEnvelope, signedCatalogue, ordinaryFloor, null, now, Fetch, cancelled.Token); throw new Exception("Cancelled resolution continued"); }
            catch (OperationCanceledException) { checks++; }
        }
        Check(ordinaryFloor == new TrustState(123, latest.PayloadSha256), "Planner modified the caller's ordinary trust value");
        var previousLatestEnvelope = latestEnvelope;
        var previousLatest = latest;
        try
        {
            envelopes["1.0.26"] = Sign(Release("1.0.26", "1.0.23", 126));
            latestEnvelope = envelopes["1.0.26"];
            latest = verifier.Verify(latestEnvelope, "windows-x64", null, now);
            var catalogue = Catalogue();
            catalogue["steps"] = new[] { Entry("1.0.20", "1.0.21"), Entry("1.0.21", "1.0.22"), Entry("1.0.22", "1.0.23"), Entry("1.0.23", "1.0.26") };
            var forwardGap = await Resolve("1.0.23", Sign(catalogue));
            Check(forwardGap.Steps.Single().Release.Version == "1.0.26", "Publisher-declared Windows release gap was rejected");
        }
        finally { latest = previousLatest; latestEnvelope = previousLatestEnvelope; }
        return checks;
    }
}
