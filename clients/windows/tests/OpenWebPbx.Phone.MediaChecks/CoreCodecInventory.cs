// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json;
namespace OpenWebPbx.Phone.MediaChecks;

internal static class CoreCodecInventory
{
    // These interfaces are built into the pinned FreeSwitch.dll. Their exact
    // names/keys come from switch_pcm.c, switch_vpx.c and the core loader.
    internal static void Require(string inventory)
    {
        using var document = JsonDocument.Parse(inventory, new JsonDocumentOptions { MaxDepth = 4 });
        var rows = document.RootElement.GetProperty("rows").EnumerateArray().ToArray();
        if (rows.Length is < 3 or > 1024 || document.RootElement.GetProperty("row_count").GetInt32() != rows.Length)
            throw new InvalidDataException("Bounded actual codec inventory required.");
        foreach (var required in new[] { ("G.711 ulaw", "CORE_PCM_MODULE"), ("G.711 alaw", "CORE_PCM_MODULE"), ("VP8 Video", "CORE_VPX_MODULE") })
            if (rows.Count(row => row.GetProperty("type").GetString() == "codec" && row.GetProperty("name").GetString() == required.Item1 && row.GetProperty("ikey").GetString() == required.Item2) != 1)
                throw new InvalidDataException("Required actual built-in codec unavailable or ambiguous.");
    }
}
