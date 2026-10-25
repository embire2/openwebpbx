// SPDX-License-Identifier: AGPL-3.0-or-later
// Private fixture proposal only. No parser, samples or acceptance threshold changes.
using System.Buffers.Binary;
namespace OpenWebPbx.Phone.MediaChecks;
internal static class FirstDataReadiness
{
    internal static bool Ready(string path)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        if (input.Length == 0) return false;
        if (input.Length != 44) return true; // malformed/oversized/partial forms go to the original strict reader
        Span<byte> h = stackalloc byte[44]; input.ReadExactly(h);
        int channels = BinaryPrimitives.ReadUInt16LittleEndian(h[22..]);
        uint rate = BinaryPrimitives.ReadUInt32LittleEndian(h[24..]);
        bool initializedEmptyPcm = h[..4].SequenceEqual("RIFF"u8) && h.Slice(8, 8).SequenceEqual("WAVEfmt "u8) &&
            h.Slice(36, 4).SequenceEqual("data"u8) && BinaryPrimitives.ReadUInt32LittleEndian(h[4..]) == 36 &&
            BinaryPrimitives.ReadUInt32LittleEndian(h[16..]) == 16 && BinaryPrimitives.ReadUInt16LittleEndian(h[20..]) == 1 &&
            channels is 1 or 2 && rate is >= 8000 and <= 48000 && BinaryPrimitives.ReadUInt16LittleEndian(h[34..]) == 16 &&
            BinaryPrimitives.ReadUInt16LittleEndian(h[32..]) == channels * 2 &&
            BinaryPrimitives.ReadUInt32LittleEndian(h[28..]) == rate * (uint)channels * 2 &&
            BinaryPrimitives.ReadUInt32LittleEndian(h[40..]) == 0;
        return !initializedEmptyPcm; // pending never means accepted media
    }
}
