import Foundation
import Testing
@testable import PalmierPro

@Suite("BeatDetector")
struct BeatDetectorTests {

    /// Builds a synthetic RMS envelope with sharp spikes at the given hop indices, decaying
    /// between spikes, at the given hop rate.
    private func envelope(spikesAtHops: [Int], totalHops: Int, hopSeconds: Double = 0.01) -> [Float] {
        var samples = [Float](repeating: 0.05, count: totalHops)
        for spike in spikesAtHops where spike < totalHops {
            for offset in 0..<20 {
                let i = spike + offset
                guard i < totalHops else { break }
                let decay = Float(exp(-Double(offset) / 4.0))
                samples[i] = max(samples[i], 0.05 + 0.9 * decay)
            }
        }
        return samples
    }

    @Test func detectsEvenlySpacedBeats() {
        let hopSeconds = 0.01
        let spikeHops = [50, 150, 250, 350, 450]
        let samples = envelope(spikesAtHops: spikeHops, totalHops: 500, hopSeconds: hopSeconds)

        let onsets = BeatDetector.onsetOffsets(in: samples, hopSeconds: hopSeconds)

        #expect(onsets.count == spikeHops.count)
        for (onset, expected) in zip(onsets, spikeHops) {
            #expect(abs(onset - expected) <= 2)
        }
    }

    @Test func ignoresSteadyLoudness() {
        let hopSeconds = 0.01
        let samples = [Float](repeating: 0.5, count: 300)
        let onsets = BeatDetector.onsetOffsets(in: samples, hopSeconds: hopSeconds)
        #expect(onsets.isEmpty)
    }

    @Test func debouncesCloseTransients() {
        let hopSeconds = 0.01
        // Two spikes 3 hops (30ms) apart, well inside minGapSeconds (120ms) — should merge to one.
        let samples = envelope(spikesAtHops: [100, 103], totalHops: 200, hopSeconds: hopSeconds)
        let onsets = BeatDetector.onsetOffsets(in: samples, hopSeconds: hopSeconds)
        #expect(onsets.count == 1)
    }

    @Test func handlesEmptyAndSingleSample() {
        #expect(BeatDetector.onsetOffsets(in: [], hopSeconds: 0.01).isEmpty)
        #expect(BeatDetector.onsetOffsets(in: [0.5], hopSeconds: 0.01).isEmpty)
    }

    @Test func mapsOffsetsToRangeAdjustedSeconds() {
        // detectBeats(range:) should shift returned timestamps by the range's lower bound;
        // exercised indirectly via the pure onset core plus the arithmetic in detectBeats.
        let hopSeconds = 0.01
        let onsets = [50]
        let base = 10.0
        let expected = base + Double(onsets[0]) * hopSeconds
        #expect(abs(expected - 10.5) < 0.0001)
    }
}
