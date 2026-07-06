import Foundation

struct BeatStoreStaleAnalysisError: Error {}

@MainActor
@Observable
final class BeatStore {
    private var analyses: [String: BeatAnalysis] = [:]
    private var failed: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<BeatAnalysis, Error>] = [:]
    @ObservationIgnored private var epoch: [String: Int] = [:]

    @ObservationIgnored var onBeatsReady: (() -> Void)?

    nonisolated func analysis(for mediaRef: String) -> BeatAnalysis? {
        MainActor.assumeIsolated { analyses[mediaRef] }
    }

    func isAnalyzing(_ mediaRef: String) -> Bool { tasks[mediaRef] != nil }
    func hasFailed(_ mediaRef: String) -> Bool { failed.contains(mediaRef) }

    func generate(for asset: MediaAsset, force: Bool = false, completion: (@MainActor (BeatAnalysis?) -> Void)? = nil) {
        if !force, let existing = analyses[asset.id] {
            completion?(existing)
            return
        }
        let task = detectionTask(for: asset, force: force)
        guard let completion else { return }
        Task { completion(try? await task.value) }
    }

    func analysisAwaiting(for asset: MediaAsset) async throws -> BeatAnalysis {
        // Join any in-flight detection so a forced redetect never answers with the stale cache.
        if tasks[asset.id] == nil, let existing = analyses[asset.id] { return existing }
        do {
            return try await detectionTask(for: asset, force: false).value
        } catch {
            if let existing = analyses[asset.id] { return existing }
            throw error
        }
    }

    /// One in-flight task per mediaRef; every caller joins it. Results are dropped
    /// when `invalidate`/`reset` bumped `epoch` while the analysis was running.
    private func detectionTask(for asset: MediaAsset, force: Bool) -> Task<BeatAnalysis, Error> {
        let key = asset.id
        if let existing = tasks[key] { return existing }
        failed.remove(key)
        let startEpoch = epoch[key, default: 0]

        let url = asset.url
        let task = Task(priority: .utility) { @MainActor [weak self] in
            do {
                let analysis = try await BeatDetector.analysis(for: url, mediaRef: key, force: force)
                guard let self, self.epoch[key, default: 0] == startEpoch else {
                    throw BeatStoreStaleAnalysisError()
                }
                self.tasks[key] = nil
                self.analyses[key] = analysis
                self.onBeatsReady?()
                return analysis
            } catch {
                if !(error is BeatStoreStaleAnalysisError) {
                    Log.preview.error("beats failed mediaRef=\(key): \(Log.detail(error))")
                }
                if let self, self.epoch[key, default: 0] == startEpoch {
                    self.tasks[key] = nil
                    self.failed.insert(key)
                }
                throw error
            }
        }
        tasks[key] = task
        return task
    }

    func reset() {
        for key in tasks.keys { epoch[key, default: 0] += 1 }
        tasks.removeAll()
        analyses.removeAll()
        failed.removeAll()
    }

    func invalidate(_ mediaRef: String) {
        epoch[mediaRef, default: 0] += 1
        tasks.removeValue(forKey: mediaRef)
        analyses.removeValue(forKey: mediaRef)
        failed.remove(mediaRef)
    }
}

extension EditorViewModel {
    func beatSnapFrames(for clip: Clip) -> [Int] {
        guard clip.sourceClipType != .sequence,
              let analysis = mediaVisualCache.beats.analysis(for: clip.mediaRef) else { return [] }
        let fps = timeline.fps
        return analysis.beats.compactMap { clip.timelineFrame(sourceSeconds: $0, fps: fps) }
    }
}
