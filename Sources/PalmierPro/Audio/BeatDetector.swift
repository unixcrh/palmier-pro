import Accelerate
import Foundation

/// Detects beat onsets from an audio file's RMS envelope: local energy spikes above a
/// smoothed baseline, debounced to one onset per transient. No tempo/BPM estimation —
/// just discrete timestamps, which is enough to snap edits or draw markers to the beat.
enum BeatDetector {
    /// Multiple of the smoothed local baseline a flux value must exceed to count as an onset.
    static let sensitivity: Float = 1.5
    /// Window used to compute the local baseline flux, smoothing out sustained loud sections.
    static let baselineWindowSeconds: Double = 0.5
    /// Minimum spacing between onsets, to avoid double-triggering on one transient.
    static let minGapSeconds: Double = 0.12

    static func detectBeats(from url: URL, range: ClosedRange<Double>? = nil) async throws -> [Double] {
        let envelope = try await AudioEnvelopeExtractor.extract(from: url, range: range)
        let offsets = onsetOffsets(in: envelope.samples, hopSeconds: envelope.hopSeconds)
        let base = range?.lowerBound ?? 0
        return offsets.map { base + Double($0) * envelope.hopSeconds }
    }

    /// Pure onset-detection core, kept separate from file I/O so it's easy to test on synthetic envelopes.
    static func onsetOffsets(in samples: [Float], hopSeconds: Double) -> [Int] {
        guard samples.count > 1 else { return [] }

        var flux = [Float](repeating: 0, count: samples.count)
        for i in 1..<samples.count {
            flux[i] = max(0, samples[i] - samples[i - 1])
        }

        let windowHops = max(1, Int((baselineWindowSeconds / hopSeconds).rounded()))
        let baseline = movingAverage(flux, windowHops: windowHops)

        var candidates: [Int] = []
        for i in 0..<flux.count where flux[i] > baseline[i] * sensitivity && flux[i] > 0 {
            candidates.append(i)
        }

        let minGapHops = max(1, Int((minGapSeconds / hopSeconds).rounded()))
        return peakPick(candidates, values: flux, minGapHops: minGapHops)
    }

    private static func movingAverage(_ values: [Float], windowHops: Int) -> [Float] {
        guard windowHops > 1 else { return values }
        var result = [Float](repeating: 0, count: values.count)
        var sum: Float = 0
        for i in 0..<values.count {
            sum += values[i]
            if i >= windowHops { sum -= values[i - windowHops] }
            let count = min(i + 1, windowHops)
            result[i] = sum / Float(count)
        }
        return result
    }

    /// Collapses a run of nearby candidate indices to their local maximum, enforcing minGapHops
    /// between kept onsets.
    private static func peakPick(_ candidates: [Int], values: [Float], minGapHops: Int) -> [Int] {
        var result: [Int] = []
        var i = 0
        while i < candidates.count {
            var groupEnd = i
            while groupEnd + 1 < candidates.count && candidates[groupEnd + 1] - candidates[groupEnd] <= minGapHops {
                groupEnd += 1
            }
            var peak = candidates[i]
            for j in (i + 1)...groupEnd where values[candidates[j]] > values[peak] {
                peak = candidates[j]
            }
            if let last = result.last, peak - last < minGapHops {
                if values[peak] > values[last] { result[result.count - 1] = peak }
            } else {
                result.append(peak)
            }
            i = groupEnd + 1
        }
        return result
    }
}
