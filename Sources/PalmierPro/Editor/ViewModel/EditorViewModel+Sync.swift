import Foundation

extension EditorViewModel {
    enum SyncMode: String, Sendable { case auto, audio, timecode }
    enum SyncMethod: String, Sendable { case timecode, audio }

    struct SyncBatchReport: Sendable {
        var synced: [(clipId: String, offsetFrames: Int, confidence: Double, method: SyncMethod)] = []
        var failures: [(clipId: String, message: String)] = []
        /// Frames the whole group (reference included) moved right so no target lands before frame 0.
        var shiftedFrames: Int = 0
    }

    enum SyncDefaults {
        static let searchWindowSeconds: Double = 30
        static let minConfidence: Double = 0.5
        static let minSpeed: Double = 0.0001
        /// ± window around a capture-date seed; covers typical device clock skew.
        static let dateSeedWindowSeconds: Double = 3
        /// Matches on thinner overlaps are spurious edge artifacts, not alignments.
        static let minOverlapSeconds: Double = 3
    }

    /// Timeline start frame that aligns the target's first frame to the reference by wall-clock timecode.
    nonisolated static func timecodeAlignedStart(
        refStartFrame: Int, refTrimStartFrame: Int, refSpeed: Double, refTimecode: SourceTimecode,
        targetTrimStartFrame: Int, targetTimecode: SourceTimecode, fps: Double
    ) -> Int {
        let refClock = refTimecode.seconds + Double(refTrimStartFrame) / fps
        let targetClock = targetTimecode.seconds + Double(targetTrimStartFrame) / fps
        let lagFrames = (targetClock - refClock) * fps / max(refSpeed, SyncDefaults.minSpeed)
        return Int((Double(refStartFrame) + lagFrames).rounded())
    }

    @discardableResult
    func syncClips(
        referenceClipId: String,
        targetClipIds: [String],
        mode: SyncMode = .auto,
        searchWindowSeconds: Double = SyncDefaults.searchWindowSeconds,
        minConfidence: Double = SyncDefaults.minConfidence
    ) async -> SyncBatchReport {
        let fps = Double(timeline.fps)
        let targets = targetClipIds.filter { $0 != referenceClipId }
        var report = SyncBatchReport()

        guard fps > 0, let refLoc = findClip(id: referenceClipId) else {
            return SyncBatchReport(failures: targets.map { ($0, "Reference clip unavailable.") })
        }
        let refClip = timeline.tracks[refLoc.trackIndex].clips[refLoc.clipIndex]
        let refUnitKey = refClip.linkGroupId ?? refClip.id

        func unit(of clip: Clip) -> [Clip] {
            guard let group = clip.linkGroupId else { return [clip] }
            return timeline.tracks.flatMap(\.clips).filter { $0.linkGroupId == group }
        }

        var refs = Set(unit(of: refClip).map(\.mediaRef))
        for id in targets {
            guard let loc = findClip(id: id) else { continue }
            refs.formUnion(unit(of: timeline.tracks[loc.trackIndex].clips[loc.clipIndex]).map(\.mediaRef))
        }
        var urls: [String: URL] = [:]
        for ref in refs { urls[ref] = mediaResolver.resolveURL(for: ref) }
        let timingCache = await SourceTimingReader.cache(mediaRefs: refs, urls: urls)

        func tcCarrier(in clips: [Clip]) -> (clip: Clip, tc: SourceTimecode)? {
            let hits = clips.compactMap { c in timingCache[c.mediaRef]?.timecode.map { (c, $0) } }
            return hits.first { $0.0.mediaType.isVisual } ?? hits.first
        }
        let refTCCarrier = mode == .audio ? nil : tcCarrier(in: unit(of: refClip))

        let hop = AudioEnvelopeExtractor.hopSeconds
        let maxLag = max(1, Int((searchWindowSeconds / hop).rounded()))
        let seedWindow = max(1, Int((SyncDefaults.dateSeedWindowSeconds / hop).rounded()))
        let minOverlap = max(AudioSyncCorrelator.minOverlap, Int((SyncDefaults.minOverlapSeconds / hop).rounded()))
        var refSamples: [Float] = []
        var refEnvLoaded = false

        struct Placement {
            let clipId: String
            let rawStart: Int
            let confidence: Double
            let method: SyncMethod
        }
        var placements: [Placement] = []

        // A clip other clips can audio-align against: the reference first, then each synced target.
        struct AudioAnchor {
            let rawStart: Int
            let samples: [Float]
            let speed: Double
            let mediaRef: String
            let trimStartFrame: Int
        }
        var anchors: [AudioAnchor] = []

        struct Candidate {
            let clipId: String
            let samples: [Float]
            let speed: Double
            let mediaRef: String
            let trimStartFrame: Int
            var direct: (rawStart: Int, confidence: Double)?
        }
        var candidates: [Candidate] = []

        func dateSeedHops(anchor: AudioAnchor, targetRef: String, targetTrim: Int) -> Int? {
            guard let anchorDate = timingCache[anchor.mediaRef]?.captureDate,
                  let targetDate = timingCache[targetRef]?.captureDate else { return nil }
            let lagSeconds = targetDate.timeIntervalSince(anchorDate)
                + Double(targetTrim - anchor.trimStartFrame) / fps
            return Int((lagSeconds / hop).rounded())
        }

        // Use capture dates to narrow the search window if clocks are trusted.
        func matchAgainst(_ anchor: AudioAnchor, samples: [Float], seedHops: Int?) async -> (rawStart: Int, confidence: Double)? {
            let reference = anchor.samples
            let match = await Task.detached(priority: .userInitiated) { () -> AudioSyncCorrelator.Result? in
                if let seedHops {
                    let seeded = AudioSyncCorrelator.correlate(
                        reference: reference, target: samples,
                        maxLagHops: seedWindow, centerLagHops: seedHops, minOverlapHops: minOverlap)
                    if let seeded, seeded.confidence >= minConfidence { return seeded }
                }
                return AudioSyncCorrelator.correlate(
                    reference: reference, target: samples, maxLagHops: maxLag, minOverlapHops: minOverlap)
            }.value
            guard let match, match.confidence >= minConfidence else { return nil }
            let lagFrames = Double(match.lagHops) * hop * fps / max(anchor.speed, SyncDefaults.minSpeed)
            return (Int((Double(anchor.rawStart) + lagFrames).rounded()), match.confidence)
        }

        var seenUnits = Set<String>()
        for targetId in targets {
            guard let loc = findClip(id: targetId) else { report.failures.append((targetId, "Clip not found.")); continue }
            let targetClip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            let unitKey = targetClip.linkGroupId ?? targetClip.id
            if unitKey == refUnitKey {
                report.failures.append((targetId, "Clip is linked to the reference — they already move together."))
                continue
            }
            guard seenUnits.insert(unitKey).inserted else { continue }
            let unitClips = unit(of: targetClip)

            if let (refCarrier, refTC) = refTCCarrier, let (carrier, targetTC) = tcCarrier(in: unitClips) {
                guard let rLoc = findClip(id: refCarrier.id), let cLoc = findClip(id: carrier.id) else {
                    report.failures.append((targetId, "Clip not found.")); continue
                }
                let liveRef = timeline.tracks[rLoc.trackIndex].clips[rLoc.clipIndex]
                let liveCarrier = timeline.tracks[cLoc.trackIndex].clips[cLoc.clipIndex]
                let rawStart = Self.timecodeAlignedStart(
                    refStartFrame: liveRef.startFrame, refTrimStartFrame: liveRef.trimStartFrame,
                    refSpeed: liveRef.speed, refTimecode: refTC,
                    targetTrimStartFrame: liveCarrier.trimStartFrame, targetTimecode: targetTC, fps: fps
                )
                placements.append(Placement(clipId: carrier.id, rawStart: rawStart, confidence: 1.0, method: .timecode))
                continue
            }
            if mode == .timecode {
                report.failures.append((targetId, refTCCarrier == nil
                    ? "Reference has no source timecode." : "Clip has no source timecode."))
                continue
            }

            guard let bearer = unitClips.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? unitClips.first(where: { captionCanTranscribe($0) }) else {
                report.failures.append((targetId, mode == .auto
                    ? "No source timecode, and clip has no audio." : "Clip has no audio."))
                continue
            }
            guard let env = await envelope(of: bearer, fps: fps), !env.samples.isEmpty else {
                report.failures.append((bearer.id, "Clip has no audio.")); continue
            }
            if !refEnvLoaded {
                refEnvLoaded = true
                if let rLoc = findClip(id: referenceClipId) {
                    let liveRef = timeline.tracks[rLoc.trackIndex].clips[rLoc.clipIndex]
                    if let refEnv = await envelope(of: liveRef, fps: fps), !refEnv.samples.isEmpty {
                        refSamples = refEnv.samples
                        anchors.append(AudioAnchor(
                            rawStart: liveRef.startFrame, samples: refEnv.samples, speed: liveRef.speed,
                            mediaRef: liveRef.mediaRef, trimStartFrame: liveRef.trimStartFrame))
                    }
                }
            }
            guard !refSamples.isEmpty else {
                report.failures.append((bearer.id, mode == .auto && refTCCarrier == nil
                    ? "Reference has no source timecode or audio." : "Reference clip has no audio."))
                continue
            }
            guard let bLoc = findClip(id: bearer.id) else {
                report.failures.append((bearer.id, "Clip not found.")); continue
            }
            let liveBearer = timeline.tracks[bLoc.trackIndex].clips[bLoc.clipIndex]
            var candidate = Candidate(
                clipId: bearer.id, samples: env.samples, speed: liveBearer.speed,
                mediaRef: liveBearer.mediaRef, trimStartFrame: liveBearer.trimStartFrame)
            if let ref = anchors.first {
                let seed = dateSeedHops(anchor: ref, targetRef: candidate.mediaRef, targetTrim: candidate.trimStartFrame)
                candidate.direct = await matchAgainst(ref, samples: candidate.samples, seedHops: seed)
            }
            candidates.append(candidate)
        }

        // Place top reference match first; weaker clips may match an already-aligned sibling.
        candidates.sort { ($0.direct?.confidence ?? 0) > ($1.direct?.confidence ?? 0) }
        for candidate in candidates {
            var best = candidate.direct
            for anchor in anchors.dropFirst() {
                let seed = dateSeedHops(anchor: anchor, targetRef: candidate.mediaRef, targetTrim: candidate.trimStartFrame)
                if let hit = await matchAgainst(anchor, samples: candidate.samples, seedHops: seed),
                   hit.confidence > (best?.confidence ?? 0) { best = hit }
            }
            guard let best else {
                report.failures.append((candidate.clipId, "No confident alignment — clips may not overlap.")); continue
            }
            placements.append(Placement(clipId: candidate.clipId, rawStart: best.rawStart, confidence: best.confidence, method: .audio))
            anchors.append(AudioAnchor(
                rawStart: best.rawStart, samples: candidate.samples, speed: candidate.speed,
                mediaRef: candidate.mediaRef, trimStartFrame: candidate.trimStartFrame))
        }

        // Nothing may land before frame 0: shift the whole group (reference included) right instead.
        let shift = max(0, -(placements.map(\.rawStart).min() ?? 0))
        report.shiftedFrames = shift

        var allMoves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
        var movedIds = Set<String>()

        func queueMove(of clipId: String, toFrame rawStart: Int) -> String? {
            guard let loc = findClip(id: clipId) else { return "Clip not found." }
            var moves = [(clipId: clipId, toTrack: loc.trackIndex, toFrame: rawStart)]
            for pm in partnerMoves(forMoveOf: clipId, toFrame: rawStart) where pm.clipId != referenceClipId {
                if let pLoc = findClip(id: pm.clipId) {
                    moves.append((clipId: pm.clipId, toTrack: pLoc.trackIndex, toFrame: pm.toFrame))
                }
            }
            if shift == 0, moveWouldClobberReference(moves, referenceClipId: referenceClipId) {
                return "Shares the reference's track — move it to its own track first."
            }
            if movesOverlapQueued(moves, allMoves) {
                return "Overlaps another clip being synced on the same track."
            }
            for move in moves where movedIds.insert(move.clipId).inserted { allMoves.append(move) }
            return nil
        }

        if shift > 0, let rLoc = findClip(id: referenceClipId) {
            let liveRef = timeline.tracks[rLoc.trackIndex].clips[rLoc.clipIndex]
            _ = queueMove(of: referenceClipId, toFrame: liveRef.startFrame + shift)
        }
        for placement in placements {
            guard let loc = findClip(id: placement.clipId) else {
                report.failures.append((placement.clipId, "Clip not found.")); continue
            }
            let current = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame
            let final = placement.rawStart + shift
            if final != current, let failure = queueMove(of: placement.clipId, toFrame: final) {
                report.failures.append((placement.clipId, failure)); continue
            }
            report.synced.append((placement.clipId, final - current, placement.confidence, placement.method))
        }

        if !allMoves.isEmpty {
            undoManager?.beginUndoGrouping()
            moveClips(allMoves)
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Synchronize")
        }
        return report
    }

    func syncSelection() -> (referenceClipId: String, targetClipIds: [String])? {
        let selected = timeline.tracks.flatMap(\.clips).filter { selectedClipIds.contains($0.id) }
        var units: [String: [Clip]] = [:]
        for clip in selected { units[clip.linkGroupId ?? clip.id, default: []].append(clip) }

        // Prefer the audio bearer; a video clip with no audio can still sync by timecode.
        var bearers: [(unit: [Clip], clip: Clip)] = []
        for unit in units.values {
            guard let clip = unit.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? unit.first(where: { captionCanTranscribe($0) })
                ?? unit.first(where: { $0.mediaType == .video }) else { continue }
            bearers.append((unit, clip))
        }
        guard bearers.count >= 2 else { return nil }

        func rank(_ b: (unit: [Clip], clip: Clip)) -> (Int, Int, Int) {
            (b.unit.contains { $0.linkGroupId != nil } ? 0 : 1,
             b.unit.contains { $0.mediaType.isVisual } ? 0 : 1,
             b.unit.map(\.startFrame).min() ?? 0)
        }
        let ordered = bearers.sorted { rank($0) < rank($1) }
        let targets = ordered.dropFirst().sorted { $0.clip.startFrame < $1.clip.startFrame }.map(\.clip.id)
        return (ordered[0].clip.id, targets)
    }

    private func moveWouldClobberReference(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)], referenceClipId: String
    ) -> Bool {
        guard let refLoc = findClip(id: referenceClipId) else { return false }
        let ref = timeline.tracks[refLoc.trackIndex].clips[refLoc.clipIndex]
        for move in moves where move.toTrack == refLoc.trackIndex {
            guard let loc = findClip(id: move.clipId) else { continue }
            let duration = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames
            if move.toFrame < ref.endFrame && ref.startFrame < move.toFrame + duration { return true }
        }
        return false
    }

    private func movesOverlapQueued(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)],
        _ queued: [(clipId: String, toTrack: Int, toFrame: Int)]
    ) -> Bool {
        func duration(_ clipId: String) -> Int {
            guard let loc = findClip(id: clipId) else { return 0 }
            return timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames
        }
        for move in moves {
            let end = move.toFrame + duration(move.clipId)
            for other in queued where other.toTrack == move.toTrack {
                if move.toFrame < other.toFrame + duration(other.clipId) && other.toFrame < end { return true }
            }
        }
        return false
    }

    private func envelope(of clip: Clip, fps: Double) async -> AudioEnvelope? {
        guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else { return nil }
        let start = Double(clip.trimStartFrame) / fps
        let end = start + Double(clip.durationFrames) * max(clip.speed, SyncDefaults.minSpeed) / fps
        return try? await AudioEnvelopeExtractor.extract(from: url, range: start...max(start + AudioEnvelopeExtractor.hopSeconds, end))
    }
}
