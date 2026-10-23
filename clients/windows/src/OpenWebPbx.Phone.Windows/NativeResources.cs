// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json;
using OpenWebPbx.Phone.Core;
namespace OpenWebPbx.Phone.Windows;
internal static class NativeResources
{
    public static void Verify()
    {
        using var input = typeof(NativeResources).Assembly.GetManifestResourceStream("OpenWebPbx.Phone.RuntimeResources.json") ?? throw new InvalidOperationException("Native resource manifest is missing.");
        using var json = JsonDocument.Parse(input); var root = json.RootElement;
        if (root.GetProperty("schema").GetInt32() != 1 || root.GetProperty("sdk").GetString() != "5.5.23" || root.GetProperty("sdk_sha256").GetString() != "9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297") throw new InvalidOperationException("Native resource manifest differs.");
        var files = root.GetProperty("files").EnumerateArray().Select(x => new RuntimeResource(x.GetProperty("path").GetString()!, x.GetProperty("bytes").GetInt64(), x.GetProperty("sha256").GetString()!)).ToArray();
        if (files.Length != 8 || files.Any(x => !x.Path.StartsWith("belr/grammars/", StringComparison.Ordinal) || !x.Path.EndsWith(".belr", StringComparison.Ordinal))) throw new InvalidOperationException("Native grammar manifest differs.");
        RuntimeResources.Verify(System.IO.Path.Combine(AppContext.BaseDirectory, "native", "share"), files);
    }
}
