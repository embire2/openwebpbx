// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenWebPbx.Phone.Core;
namespace OpenWebPbx.Phone.Windows;
public sealed record PendingCall(Guid Id, Guid Profile, string Number, string Direction, DateTimeOffset Started, int Duration, bool Answered)
{
    public JsonObject Body() => new() { ["id"] = Id.ToString(), ["number"] = Number, ["direction"] = Direction, ["started_at"] = Started.ToString("O"), ["duration"] = Duration, ["answered"] = Answered };
}
public sealed class PendingHistory
{
    private readonly string path;
    public PendingHistory(string channel)
    {
        if (channel is not ("direct" or "store")) throw new ArgumentException();
        path = Path.Combine(StoragePaths.Channel(channel), "pending-calls.dpapi");
    }
    private PendingCall[] Read()
    {
        try
        {
            if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || new FileInfo(path).Length > 2 * 1024 * 1024) throw new PhoneInputException("Saved recent calls are unavailable.");
            var data = Dpapi.Unprotect(File.ReadAllBytes(path));
            try { var rows = JsonSerializer.Deserialize<PendingCall[]>(data) ?? []; if (rows.Length > 500 || rows.Select(x => x.Id).Distinct().Count() != rows.Length) throw new PhoneInputException("Saved recent calls are unavailable."); return rows; }
            finally { CryptographicOperations.ZeroMemory(data); }
        }
        catch (FileNotFoundException) { return []; }
    }
    private void Save(PendingCall[] rows)
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(rows); byte[] encrypted;
        try { encrypted = Dpapi.Protect(data); } finally { CryptographicOperations.ZeroMemory(data); }
        var parent = Path.GetDirectoryName(path)!; if ((File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0) throw new PhoneInputException("Saved recent calls are unavailable.");
        var temp = Path.Combine(parent, Guid.NewGuid().ToString("N") + ".tmp");
        try { using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { output.Write(encrypted); output.Flush(true); } File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public void Enqueue(PendingCall call)
    {
        var rows = Read().Where(x => x.Started > DateTimeOffset.UtcNow.AddDays(-29)).ToArray(); if (rows.Length >= 500) throw new PhoneInputException("Connect to sync recent calls before saving more local history."); Save([.. rows, call]);
    }
    public IReadOnlyList<PendingCall> For(Guid profile) => Read().Where(x => x.Profile == profile).ToArray();
    public void Acknowledge(Guid profile, Guid call) => Save(Read().Where(x => !(x.Profile == profile && x.Id == call)).ToArray());
    public void Remove(Guid profile) => Save(Read().Where(x => x.Profile != profile).ToArray());
}
