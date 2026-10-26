// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.MediaChecks;

// Failure-only measurements of the already decoded failed tail. No file/call I/O,
// sample changes, qualification decision or retry is performed by this observer.
internal sealed record ToneFailureObservation(string source, string phase, int sample_rate, int sample_count,
    int[] expected_tones, int first_frame, int candidate_windows, int frames_per_window, int best_good_frames,
    int minimum_ratio_ppm, int maximum_ratio_ppm, int minimum_rms, int maximum_rms,
    int low_rms_frames, int clipped_frames, int low_ratio_frames, int low_component_frames,
    int best_window_start_frame, int good_frame_mask, int[] fixture_tone_masks);
internal static class ToneObservation
{
    internal static string Phase(string phase, bool left) => phase is "initial" or "resumed" ? phase + (left ? "_left" : "_right") : "other";
    internal static ToneFailureObservation Capture(PcmWave wave, IReadOnlyList<double> tones, string phase)
    {
        if (phase is not ("initial_left" or "initial_right" or "held_party" or "resumed_left" or "resumed_right" or "other") || wave.Rate is < 8000 or > 48000 || wave.Samples.Length > 67108864 || tones.Count is < 1 or > 3 || tones.Any(tone => tone is not (425 or 733 or 1013 or 1553)) || tones.Distinct().Count() != tones.Count || wave.Duration < 3.2) throw new InvalidDataException("Closed tone observation scope required.");
        // These are the unchanged Tail/Find candidate bounds. Every candidate is
        // evaluated against the same finite decoded array used by the failed call.
        var frame = wave.Rate / 10; const int frames = 30;
        var after = Math.Floor((wave.Duration - 3 - .1) * 10) / 10;
        var first = checked((int)Math.Ceiling(after * 10)); var total = wave.Samples.Length / frame;
        var candidates = total - first - frames + 1;
        if (first < 0 || candidates is < 1 or > 3) throw new InvalidDataException("Bounded current tail required.");
        var bestStart = -1; var bestMask = 0; int[] bestFixtureMasks = [0, 0, 0, 0];
        var bestGood = -1; int minRatio = 0, maxRatio = 0, minRms = 0, maxRms = 0, lowRms = 0, clippedFrames = 0, lowRatio = 0, lowComponent = 0;
        for (var start = first; start + frames <= total; start++)
        {
            var goodMask = 0; int[] fixtureMasks = [0, 0, 0, 0];
            var good = 0; var currentMinRatio = 3000000; var currentMaxRatio = 0; var currentMinRms = 65536; var currentMaxRms = 0;
            int currentLowRms = 0, currentClipped = 0, currentLowRatio = 0, currentLowComponent = 0;
            for (var block = start; block < start + frames; block++)
            {
                var at = block * frame; double sum = 0, energy = 0; var clipped = 0;
                for (var n = 0; n < frame; n++) sum += wave.Samples[at + n]; var mean = sum / frame;
                for (var n = 0; n < frame; n++) { var value = wave.Samples[at + n] - mean; energy += value * value; if (Math.Abs(wave.Samples[at + n]) >= 32700) clipped++; }
                var rms = Math.Sqrt(energy / frame); var ratios = new List<double>();
                foreach (var tone in tones)
                {
                    double sine = 0, cosine = 0;
                    for (var n = 0; n < frame; n++) { var value = wave.Samples[at + n] - mean; var angle = 2 * Math.PI * tone * n / wave.Rate; sine += value * Math.Sin(angle); cosine += value * Math.Cos(angle); }
                    ratios.Add(energy == 0 ? 0 : Math.Min(1, 2 * (sine * sine + cosine * cosine) / (frame * energy)));
                }
                var combined = ratios.Sum();
                if (!double.IsFinite(combined) || !double.IsFinite(rms) || rms > 65536) throw new InvalidDataException("Finite decoded measurement required.");
                if (rms < 500) currentLowRms++;
                if (clipped > frame / 1000) currentClipped++;
                if (combined < .65) currentLowRatio++;
                if (tones.Count != 1 && ratios.Any(value => value < .12)) currentLowComponent++;
                if (rms >= 500 && clipped <= frame / 1000 && combined >= .65 && (tones.Count == 1 || ratios.All(value => value >= .12))) { good++; goodMask |= 1 << (block - start); }
                // Thirty fixed bits, earliest block first. The four masks describe
                // only single-fixture-tone coherence, not a qualification decision.
                int[] fixtureTones = [425, 733, 1013, 1553];
                for (var index = 0; index < fixtureTones.Length; index++)
                {
                    double ratio = -1;
                    for (var known = 0; known < tones.Count; known++) if (tones[known] == fixtureTones[index]) ratio = ratios[known];
                    if (ratio < 0)
                    {
                        double sine = 0, cosine = 0;
                        for (var n = 0; n < frame; n++) { var value = wave.Samples[at + n] - mean; var angle = 2 * Math.PI * fixtureTones[index] * n / wave.Rate; sine += value * Math.Sin(angle); cosine += value * Math.Cos(angle); }
                        ratio = energy == 0 ? 0 : Math.Min(1, 2 * (sine * sine + cosine * cosine) / (frame * energy));
                    }
                    if (!double.IsFinite(ratio)) throw new InvalidDataException("Finite fixed-tone measurement required.");
                    if (ratio >= .65) fixtureMasks[index] |= 1 << (block - start);
                }
                var ratioPpm = checked((int)Math.Round(combined * 1000000)); var rmsUnits = checked((int)Math.Round(rms));
                currentMinRatio = Math.Min(currentMinRatio, ratioPpm); currentMaxRatio = Math.Max(currentMaxRatio, ratioPpm);
                currentMinRms = Math.Min(currentMinRms, rmsUnits); currentMaxRms = Math.Max(currentMaxRms, rmsUnits);
            }
            if (good > bestGood) { bestStart = start; bestMask = goodMask; bestFixtureMasks = fixtureMasks; bestGood = good; minRatio = currentMinRatio; maxRatio = currentMaxRatio; minRms = currentMinRms; maxRms = currentMaxRms; lowRms = currentLowRms; clippedFrames = currentClipped; lowRatio = currentLowRatio; lowComponent = currentLowComponent; }
        }
        return new("same_failed_decoded_buffer", phase, wave.Rate, wave.Samples.Length, tones.Select(value => checked((int)value)).ToArray(), first, candidates, frames, bestGood, minRatio, maxRatio, minRms, maxRms, lowRms, clippedFrames, lowRatio, lowComponent, bestStart, bestMask, bestFixtureMasks);
    }
}
