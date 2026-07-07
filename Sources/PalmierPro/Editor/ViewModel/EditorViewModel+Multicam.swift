import Foundation

/// Multicam: group creation, sync, angle switching, and child timeline boundary.
extension EditorViewModel {

    struct MulticamMemberSpec {
        var mediaRef: String
        var kind: MulticamSource.MemberKind
        var angleLabel: String?
        var pinnedOffsetSeconds: Double?
    }

    struct MulticamSyncOutcome {
        var maps: [String: MulticamSource.SyncMap] = [:]
        var failures: [(mediaRef: String, reason: String)] = []
    }

    struct AngleSwitchRequest {
        var range: Range<Int>
        var layout: VideoLayout
        var slots: [(slot: String, angle: String)]
        var fit: LayoutFit
    }

    struct AngleSwitchReport {
        var applied: [[Int]] = []
        var clamped: [(requested: [Int], applied: [Int], culprit: String)] = []
        var skipped: [(range: [Int], reason: String)] = []
        var switched = 0
        var filled = 0
        var merged = 0
    }

    // MARK: - Lookup

    func multicamChild(id: String) -> (child: Timeline, source: MulticamSource)? {
        timeline(for: id).flatMap { t in t.multicam.map { (t, $0) } }
    }

    /// Visual carriers of `childId` on the active timeline, in timeline order.
    func multicamCarriers(of childId: String) -> [Clip] {
        timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaRef == childId && $0.sourceClipType == .sequence && $0.mediaType != .audio }
            .sorted { $0.startFrame < $1.startFrame }
    }

    /// Returns child timeline and multicam source if clip is a multicam carrier.
    func multicamContext(clip: Clip) -> (child: Timeline, source: MulticamSource)? {
        clip.sourceClipType == .sequence ? multicamChild(id: clip.mediaRef) : nil
    }

    private func multicamSourceDurations(_ source: MulticamSource) -> [String: Double] {
        source.members.reduce(into: [:]) { out, member in
            out[member.mediaRef] = mediaAssets.first { $0.id == member.mediaRef }?.duration
        }
    }

    // MARK: - Structure lock

    /// Moving content in a multicam group is locked to keep everything in sync
    func refusesMulticamStructureEdit() -> Bool {
        guard timeline.isMulticam else { return false }
        mediaPanelToast = "Timing is locked inside a multicam group — split, trim, delete, and switch angles freely; moving or rippling would break sync."
        return true
    }

    // MARK: - Child undo

    /// Atomically mutate a child timeline with undo, never activating the child.
    private func withMulticamChildSwap(childId: String, actionName: String, _ work: (inout Timeline) -> Void) {
        guard let i = timelines.firstIndex(where: { $0.id == childId }) else { return }
        let before = timelines[i]
        var copy = before
        work(&copy)
        guard copy != before else { return }
        timelines[i] = copy
        registerMulticamChildSwap(childId: childId, undoState: before, redoState: copy, actionName: actionName)
        undoManager?.setActionName(actionName)
        refreshMulticamChild(childId)
    }

    private func registerMulticamChildSwap(childId: String, undoState: Timeline, redoState: Timeline, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { vm in
            if let i = vm.timelines.firstIndex(where: { $0.id == childId }) {
                vm.timelines[i] = undoState
            }
            vm.registerMulticamChildSwap(childId: childId, undoState: redoState, redoState: undoState, actionName: actionName)
            vm.undoManager?.setActionName(actionName)
            vm.refreshMulticamChild(childId)
        }
    }

    private func refreshMulticamChild(_ childId: String) {
        videoEngine?.evictComposition(for: childId)
        if isVisibleFromActive(childId) {
            notifyTimelineChanged()
        }
    }

    // MARK: - Source sync (runs before any undo group opens)

    /// Syncs members to the master by audio; falls back to timecode if audio fails. Offsets are rebased to start at zero.
    func syncMulticamMembers(
        specs: [MulticamMemberSpec],
        masterRef: String,
        searchWindowSeconds: Double = SyncDefaults.memberSearchWindowSeconds
    ) async -> MulticamSyncOutcome {
        var outcome = MulticamSyncOutcome()

        var pending: [MulticamMemberSpec] = []
        for spec in specs {
            if let pinned = spec.pinnedOffsetSeconds {
                outcome.maps[spec.mediaRef] = MulticamSource.SyncMap(offsetSeconds: pinned, confidence: 1, locked: true)
            } else if spec.mediaRef == masterRef {
                outcome.maps[spec.mediaRef] = MulticamSource.SyncMap(offsetSeconds: 0, confidence: 1)
            } else {
                pending.append(spec)
            }
        }
        guard !pending.isEmpty else { return rebased(outcome) }

        let refs = Set([masterRef] + pending.map(\.mediaRef))
        let urls = refs.reduce(into: [String: URL]()) { $0[$1] = mediaResolver.resolveURL(for: $1) }
        let timing = await SourceTimingReader.cache(mediaRefs: refs, urls: urls)
        let masterOffset = outcome.maps[masterRef]?.offsetSeconds ?? 0

        // Use audio first; timecode only if audio fails.
        func resolveWithoutAudio(_ ref: String, reason: String) {
            if let master = timing[masterRef]?.timecode, let tc = timing[ref]?.timecode {
                outcome.maps[ref] = MulticamSource.SyncMap(offsetSeconds: masterOffset + tc.seconds - master.seconds, confidence: 1)
            } else {
                outcome.maps[ref] = MulticamSource.SyncMap()
                outcome.failures.append((ref, reason))
            }
        }

        // Offsets only need the overlap head; capping the envelope bounds hour-long decode cost.
        let envelopeSpan = 0...(searchWindowSeconds + 300)
        guard let masterURL = urls[masterRef],
              let masterEnv = try? await AudioEnvelopeExtractor.extract(from: masterURL, range: envelopeSpan),
              !masterEnv.samples.isEmpty else {
            outcome.failures.append((masterRef, "Master has no readable audio."))
            for spec in pending { resolveWithoutAudio(spec.mediaRef, reason: "No audio to sync with and no shared timecode.") }
            return rebased(outcome)
        }

        let extracted = await withTaskGroup(of: (String, [Float]?).self) { group in
            for spec in pending {
                let url = urls[spec.mediaRef]
                group.addTask {
                    guard let url, let env = try? await AudioEnvelopeExtractor.extract(from: url, range: envelopeSpan) else {
                        return (spec.mediaRef, nil)
                    }
                    return (spec.mediaRef, env.samples.isEmpty ? nil : env.samples)
                }
            }
            var out: [String: [Float]] = [:]
            for await (ref, samples) in group { out[ref] = samples }
            return out
        }

        let hop = AudioEnvelopeExtractor.hopSeconds
        let seedWindow = max(1, Int((SyncDefaults.dateSeedWindowSeconds / hop).rounded()))
        let minOverlapHops = max(AudioSyncCorrelator.minOverlap, Int((SyncDefaults.minOverlapSeconds / hop).rounded()))

        struct Anchor {
            let offsetSeconds: Double
            let mediaRef: String
            let samples: [Float]
        }
        var anchors = [Anchor(offsetSeconds: masterOffset, mediaRef: masterRef, samples: masterEnv.samples)]

        func match(_ anchor: Anchor, ref: String, samples: [Float]) async -> (offset: Double, confidence: Double)? {
            // Use capture dates if possible, otherwise fall back to blind search.
            var seed: Int?
            if let anchorDate = timing[anchor.mediaRef]?.captureDate, let date = timing[ref]?.captureDate {
                seed = Int((date.timeIntervalSince(anchorDate) / hop).rounded())
            }
            let maxLag = MulticamEngine.maxLagHops(
                windowSeconds: searchWindowSeconds, hopSeconds: hop,
                referenceCount: anchor.samples.count, targetCount: samples.count
            )
            guard let result = await AudioSyncCorrelator.seededCorrelate(
                reference: anchor.samples, target: samples, seedHops: seed, seedWindowHops: seedWindow,
                maxLagHops: maxLag, minOverlapHops: minOverlapHops, minConfidence: SyncDefaults.minConfidence
            ) else { return nil }
            return (anchor.offsetSeconds + Double(result.lagHops) * hop, result.confidence)
        }

        var candidates: [(ref: String, samples: [Float], direct: (offset: Double, confidence: Double)?)] = []
        for spec in pending {
            guard let samples = extracted[spec.mediaRef] else {
                resolveWithoutAudio(spec.mediaRef, reason: "No readable audio to sync with.")
                continue
            }
            candidates.append((spec.mediaRef, samples, await match(anchors[0], ref: spec.mediaRef, samples: samples)))
        }

        // Strongest placements first; each becomes an anchor the weaker ones can beat.
        candidates.sort { ($0.direct?.confidence ?? 0) > ($1.direct?.confidence ?? 0) }
        for candidate in candidates {
            var best = candidate.direct
            for anchor in anchors.dropFirst() {
                if let hit = await match(anchor, ref: candidate.ref, samples: candidate.samples),
                   hit.confidence > (best?.confidence ?? 0) {
                    best = hit
                }
            }
            guard let best else {
                resolveWithoutAudio(candidate.ref, reason: "No confident alignment — pin an offset or re-sync with a wider window.")
                continue
            }
            outcome.maps[candidate.ref] = MulticamSource.SyncMap(
                offsetSeconds: best.offset, confidence: (best.confidence * 1000).rounded() / 1000
            )
            anchors.append(Anchor(offsetSeconds: best.offset, mediaRef: candidate.ref, samples: candidate.samples))
        }
        return rebased(outcome)
    }

    private func rebased(_ outcome: MulticamSyncOutcome) -> MulticamSyncOutcome {
        var outcome = outcome
        let base = outcome.maps.values.filter { $0.confidence > 0 || $0.locked }.map(\.offsetSeconds).min() ?? 0
        if base != 0 {
            for (ref, var map) in outcome.maps where map.confidence > 0 || map.locked {
                map.offsetSeconds -= base
                outcome.maps[ref] = map
            }
        }
        return outcome
    }

    // MARK: - Creation (synchronous, undoable)

    /// Creates a multicam child and places carriers on the timeline using sync maps.
    @discardableResult
    func createMulticamGroup(
        specs: [MulticamMemberSpec],
        syncMaps: [String: MulticamSource.SyncMap],
        masterRef: String,
        name: String?,
        place: Bool = true,
        startFrame: Int? = nil
    ) throws -> (childId: String, carrierIds: [String]) {
        var members: [MulticamSource.Member] = []
        var usedLabels = Set<String>()
        for spec in specs {
            let asset = mediaAssets.first { $0.id == spec.mediaRef }
            let label = uniqueAngleLabel(spec.angleLabel ?? asset?.name ?? spec.mediaRef, used: &usedLabels)
            members.append(MulticamSource.Member(
                mediaRef: spec.mediaRef,
                kind: spec.kind,
                angleLabel: label,
                sync: syncMaps[spec.mediaRef] ?? MulticamSource.SyncMap()
            ))
        }
        guard let master = members.first(where: { $0.mediaRef == masterRef }) else {
            throw ToolError("Master member not found among members.")
        }
        guard members.contains(where: \.usable) else {
            throw ToolError("No member synced successfully — nothing to place.")
        }

        var source = MulticamSource(members: members, masterMemberId: master.id)
        var child = newTimelineMatchingActive(named: name ?? uniqueName({ "Multicam \($0)" }, startingAt: 1))

        let durations = multicamSourceDurations(source)
        var programTrack = Track(type: .video)
        if let angle = source.angles.first(where: { durations[$0.mediaRef] != nil }), let duration = durations[angle.mediaRef] {
            programTrack.clips.append(memberClip(angle, mediaType: .video, duration: duration, fps: child.fps, canvas: child))
        }
        source.programTrackId = programTrack.id
        child.tracks = [programTrack]

        for mic in source.mics where mic.usable {
            guard let duration = durations[mic.mediaRef] else { continue }
            var track = Track(type: .audio)
            track.clips.append(memberClip(mic, mediaType: .audio, duration: duration, fps: child.fps, canvas: child))
            child.tracks.append(track)
        }

        child.multicam = source
        timelines.append(child)
        registerRemoveUndo(for: child.id, actionName: "Create Multicam")

        guard place else { return (child.id, []) }

        // The clip covers the picture; audio-only extends inside the group.
        let angleRanges = source.angles.compactMap { angle in
            durations[angle.mediaRef].map { angle.coverage(sourceDuration: $0, fps: child.fps) }
        }
        let videoWindow: Range<Int>? = angleRanges.isEmpty ? nil
            : angleRanges.map(\.lowerBound).min()!..<angleRanges.map(\.upperBound).max()!
        let at = startFrame ?? timeline.totalFrames
        guard nestTimeline(child.id, cursor: .newTrackAt(0), atFrame: at, window: videoWindow) else {
            timelines.removeAll { $0.id == child.id }
            throw ToolError("Could not place the multicam on the timeline — switch to an edit timeline first.")
        }
        let carrierIds = timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaRef == child.id && $0.sourceClipType == .sequence }
            .map(\.id)
        return (child.id, carrierIds)
    }

    private func memberClip(_ member: MulticamSource.Member, mediaType: ClipType, duration: Double, fps: Int, canvas: Timeline) -> Clip {
        let coverage = member.coverage(sourceDuration: duration, fps: fps)
        let asset = mediaAssets.first { $0.id == member.mediaRef }
        var clip = Clip(mediaRef: member.mediaRef, startFrame: coverage.lowerBound, durationFrames: max(1, coverage.count))
        clip.mediaType = mediaType
        clip.sourceClipType = asset?.type ?? mediaType
        if mediaType == .video, let asset {
            clip.transform = fitTransform(for: asset, canvasWidth: canvas.width, canvasHeight: canvas.height)
        }
        return clip
    }

    private func uniqueAngleLabel(_ raw: String, used: inout Set<String>) -> String {
        var base = raw.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { if !($0.hasSuffix("-") && $1 == "-") { $0.append($1) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "angle" }
        var label = base
        var n = 2
        while !used.insert(label).inserted {
            label = "\(base)-\(n)"
            n += 1
        }
        return label
    }

    // MARK: - Angle switching

    /// Batch-switches camera angles over validated ranges — parent frames from an
    /// edit timeline, child frames when the group itself is active.
    func switchMulticamAngles(childId: String, requests: [AngleSwitchRequest]) throws -> AngleSwitchReport {
        guard let (child, source) = multicamChild(id: childId) else {
            throw ToolError("Not a multicam group: \(childId)")
        }
        let carriers = activeTimelineId == childId
            ? [Self.identityCarrier(child)] : multicamCarriers(of: childId)
        guard !carriers.isEmpty else {
            throw ToolError("The multicam has no clip on the active timeline.")
        }
        let durations = multicamSourceDurations(source)
        let fps = child.fps

        var report = AngleSwitchReport()
        var entries: [MulticamEngine.Entry] = []

        for request in requests {
            let assignments = try resolveAssignments(request, source: source)
            for carrier in carriers {
                let overlap = request.range.clamped(to: carrier.startFrame..<carrier.endFrame)
                guard !overlap.isEmpty else { continue }
                let childRange = carrier.childRange(fromParent: overlap)

                var clamped = childRange
                var culprit: String?
                for assignment in assignments {
                    guard let duration = durations[assignment.member.mediaRef] else { continue }
                    let next = clamped.clamped(to: assignment.member.coverage(sourceDuration: duration, fps: fps))
                    if next != clamped { culprit = assignment.member.angleLabel }
                    clamped = next
                    if clamped.isEmpty { break }
                }
                let parentPair = { (r: Range<Int>) -> [Int] in
                    let p = carrier.parentRange(fromChild: r)
                    return [p.lowerBound, p.upperBound]
                }
                if clamped.isEmpty {
                    report.skipped.append((parentPair(childRange), "\(culprit ?? "an angle") wasn't recording in this range"))
                    continue
                }
                if let culprit {
                    report.clamped.append((parentPair(childRange), parentPair(clamped), culprit))
                }
                report.applied.append(parentPair(clamped))
                entries.append(MulticamEngine.Entry(
                    childRange: clamped, layout: request.layout, assignments: assignments, fit: request.fit
                ))
            }
        }
        guard !entries.isEmpty else { return report }

        let outcome = applyEntries(entries, childId: childId)
        report.switched = outcome.switched
        report.filled = outcome.filled
        report.merged = outcome.merged
        return report
    }

    /// The single write path into the engine, shared by agent and manual switching.
    @discardableResult
    private func applyEntries(_ entries: [MulticamEngine.Entry], childId: String) -> MulticamEngine.Outcome {
        var outcome = MulticamEngine.Outcome()
        withMulticamChildSwap(childId: childId, actionName: "Switch Angle") { child in
            guard var source = child.multicam else { return }
            outcome = MulticamEngine.apply(
                entries: entries,
                to: &child,
                source: &source,
                sourceDurations: multicamSourceDurations(source),
                placement: { [self] clip, rect, fit in layoutPlacement(for: clip, in: rect, fit: fit) },
                fitTransform: { [self] clip in fitTransform(for: clip) }
            )
            child.multicam = source
        }
        return outcome
    }

    private func resolveAssignments(_ request: AngleSwitchRequest, source: MulticamSource) throws -> [MulticamEngine.SlotAssignment] {
        let slots = request.layout.slots
        guard request.slots.count == slots.count else {
            throw ToolError("Layout \(request.layout.rawValue) needs \(slots.count) slot(s): \(slots.map(\.id).joined(separator: ", ")).")
        }
        return try slots.map { slot in
            guard let pick = request.slots.first(where: { $0.slot == slot.id }) else {
                throw ToolError("Missing slot '\(slot.id)' for layout \(request.layout.rawValue).")
            }
            guard let member = source.member(labeled: pick.angle), member.providesVideo else {
                throw ToolError("Unknown angle '\(pick.angle)'. Angles: \(source.angles.map(\.angleLabel).joined(separator: ", ")).")
            }
            guard member.usable else {
                throw ToolError("Angle '\(pick.angle)' isn't synced — pin an offset or re-sync first.")
            }
            return MulticamEngine.SlotAssignment(slot: slot, member: member)
        }
    }

    // MARK: - Projection (child ↔ parent)

    /// Carrier-projected angle segments for drawing, labels, and program rows.
    func multicamRenderSegments(for carrier: Clip) -> [ClipRenderer.MulticamSegment]? {
        guard carrier.mediaType != .audio, let (child, source) = multicamContext(clip: carrier),
              let programIdx = child.tracks.firstIndex(where: { $0.id == source.programTrackId }) else { return nil }
        let window = carrier.childWindow

        var segments: [ClipRenderer.MulticamSegment] = []
        for clip in child.tracks[programIdx].clips {
            let overlap = (clip.startFrame..<clip.endFrame).clamped(to: window)
            guard !overlap.isEmpty else { continue }
            var segment = Clip(mediaRef: clip.mediaRef,
                               startFrame: carrier.parentRange(fromChild: overlap).lowerBound,
                               durationFrames: overlap.count)
            segment.speed = clip.speed
            segment.trimStartFrame = clip.trimStartFrame + Int((Double(overlap.lowerBound - clip.startFrame) * clip.speed).rounded())
            segments.append(.init(clip: segment, label: source.members.first { $0.mediaRef == clip.mediaRef }?.angleLabel ?? ""))
        }
        return segments.isEmpty ? nil : segments
    }

    /// Inside the open group, ranges are child frames — an identity carrier maps them 1:1.
    private static func identityCarrier(_ child: Timeline) -> Clip {
        var c = Clip(mediaRef: child.id, startFrame: 0, durationFrames: max(1, child.totalFrames))
        c.sourceClipType = .sequence
        return c
    }

    /// Program EDL as [angleLabel, start, end) rows, run-length across carriers —
    /// parent frames from an edit timeline, child frames inside the open group.
    func multicamProgramRows(childId: String, window: Range<Int>? = nil) -> [[Any]] {
        let carriers = activeTimelineId == childId
            ? multicamChild(id: childId).map { [Self.identityCarrier($0.child)] } ?? []
            : multicamCarriers(of: childId)
        var rows: [[Any]] = []
        for carrier in carriers {
            for segment in multicamRenderSegments(for: carrier) ?? [] {
                var r = segment.clip.startFrame..<segment.clip.endFrame
                if let window { r = r.clamped(to: window) }
                guard !r.isEmpty else { continue }
                if var last = rows.last, last[0] as? String == segment.label, last[2] as? Int == r.lowerBound {
                    last[2] = r.upperBound
                    rows[rows.count - 1] = last
                } else {
                    rows.append([segment.label, r.lowerBound, r.upperBound])
                }
            }
        }
        return rows
    }

    // MARK: - Manual switching (right-click path)

    /// Switch the segment under `frame` to `angle`.
    func switchChildSegment(atFrame frame: Int, to angle: String) {
        guard let source = timeline.multicam,
              let member = source.member(labeled: angle), member.providesVideo, member.usable,
              let programIdx = timeline.tracks.firstIndex(where: { $0.id == source.programTrackId }) else { return }
        applyChildSegment(atFrame: frame, layout: .full, members: [member], source: source, programIdx: programIdx)
    }

    /// Lays out the multicam segment at `frame` with the current angle in slot 1; others fill remaining slots. `.full` exits layout.
    func applyChildLayout(atFrame frame: Int, layout: VideoLayout) {
        guard let source = timeline.multicam,
              let programIdx = timeline.tracks.firstIndex(where: { $0.id == source.programTrackId }) else { return }
        var ordered = source.angles
        let needed = layout == .full ? 1 : 2
        guard ordered.count >= needed else {
            mediaPanelToast = "\(layout.displayName) needs at least two synced cameras."
            return
        }
        let showing = timeline.tracks[programIdx].clips.first { frame >= $0.startFrame && frame < $0.endFrame }?.mediaRef
        if let idx = ordered.firstIndex(where: { $0.mediaRef == showing }) {
            ordered.swapAt(0, idx)
        }
        applyChildSegment(atFrame: frame, layout: layout, members: Array(ordered.prefix(layout.slots.count)),
                          source: source, programIdx: programIdx)
    }

    private func applyChildSegment(atFrame frame: Int, layout: VideoLayout, members: [MulticamSource.Member], source: MulticamSource, programIdx: Int) {
        var range = 0..<max(timeline.totalFrames, frame + 1)
        for c in timeline.tracks[programIdx].clips {
            if frame >= c.startFrame && frame < c.endFrame {
                range = c.startFrame..<c.endFrame
                break
            }
            if c.endFrame <= frame, c.endFrame > range.lowerBound { range = c.endFrame..<range.upperBound }
            if c.startFrame > frame, c.startFrame < range.upperBound { range = range.lowerBound..<c.startFrame }
        }
        let durations = multicamSourceDurations(source)
        for member in members {
            if let duration = durations[member.mediaRef] {
                range = range.clamped(to: member.coverage(sourceDuration: duration, fps: timeline.fps))
            }
        }
        guard !range.isEmpty else {
            mediaPanelToast = members.count == 1
                ? "\(members[0].angleLabel) wasn't recording in this segment."
                : "Not every camera was recording in this segment."
            return
        }
        let assignments = zip(layout.slots, members).map { MulticamEngine.SlotAssignment(slot: $0, member: $1) }
        applyEntries([.init(childRange: range, layout: layout, assignments: assignments, fit: .fill)],
                     childId: timeline.id)
    }

    // MARK: - Mic mute (inspector)

    /// Mute by setting child clip volumes to zero.
    func multicamMemberMuted(child: Timeline, member: MulticamSource.Member) -> Bool {
        child.tracks.lazy.filter { $0.type == .audio }
            .flatMap(\.clips)
            .contains { $0.mediaRef == member.mediaRef && $0.volume == 0 }
    }

    func setMulticamMemberMuted(childId: String, memberId: String, muted: Bool) {
        guard let member = multicamChild(id: childId)?.source.members.first(where: { $0.id == memberId }),
              member.providesAudio else { return }
        withMulticamChildSwap(childId: childId, actionName: muted ? "Mute Mic" : "Unmute Mic") { child in
            for ti in child.tracks.indices where child.tracks[ti].type == .audio {
                for ci in child.tracks[ti].clips.indices where child.tracks[ti].clips[ci].mediaRef == member.mediaRef {
                    child.tracks[ti].clips[ci].volume = muted ? 0 : 1
                }
            }
        }
    }

    // MARK: - Audio bearer

    // Multicam carrier mirrors master mic: swaps mediaRef, shifts trims by offset.
    func audioBearer(for clip: Clip) -> Clip {
        guard clip.mediaType == .audio, let (child, source) = multicamContext(clip: clip),
              let master = source.master, master.providesAudio else { return clip }
        var bearer = clip
        let asset = mediaAssets.first { $0.id == master.mediaRef }
        bearer.mediaRef = master.mediaRef
        bearer.sourceClipType = asset?.type ?? .audio
        bearer.trimStartFrame -= Int((master.sync.offsetSeconds * Double(child.fps)).rounded())
        // Tail trim completes the source extent so fraction-based consumers (waveforms) map correctly.
        if let duration = asset?.duration {
            let totalFrames = Int((duration * Double(child.fps)).rounded())
            bearer.trimEndFrame = max(0, totalFrames - bearer.trimStartFrame - bearer.sourceFramesConsumed)
        }
        return bearer
    }

    /// Returns the intersection of all analyzed, offset-shifted mic dead air masks, or nil if any mic is missing analysis.
    func multicamDeadAirMask(for clip: Clip) -> [Bool]? {
        guard clip.mediaType == .audio, let (_, source) = multicamContext(clip: clip) else { return nil }
        let mics = source.mics.filter(\.usable)
        guard !mics.isEmpty else { return nil }
        let cellSeconds = VoiceActivity.chunkDuration
        var masks: [[Bool]] = []
        for mic in mics {
            guard let mask = mediaVisualCache.deadAirMask(for: mic.mediaRef), !mask.isEmpty else { return nil }
            let shift = Int((mic.sync.offsetSeconds / cellSeconds).rounded())
            var shifted = [Bool](repeating: true, count: max(0, mask.count + shift))
            for (i, dead) in mask.enumerated() where i + shift >= 0 && i + shift < shifted.count {
                shifted[i + shift] = dead
            }
            masks.append(shifted)
        }
        // Cells outside a mic's coverage can't testify, so they don't veto.
        return (0..<(masks.map(\.count).max() ?? 0)).map { i in masks.allSatisfy { i >= $0.count || $0[i] } }
    }
}

private extension Clip {
    /// The child-frame window a `.sequence` carrier shows.
    var childWindow: Range<Int> { trimStartFrame..<(trimStartFrame + durationFrames) }

    func childRange(fromParent r: Range<Int>) -> Range<Int> {
        (r.lowerBound - startFrame + trimStartFrame)..<(r.upperBound - startFrame + trimStartFrame)
    }

    func parentRange(fromChild r: Range<Int>) -> Range<Int> {
        (r.lowerBound - trimStartFrame + startFrame)..<(r.upperBound - trimStartFrame + startFrame)
    }
}
