import Foundation

// Multicam angles are cut in a child timeline; parent changes are normally empty.
extension ToolExecutor {

    func manageMulticam(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["create", "bake"], path: "manage_multicam")
        guard args["create"] != nil || args["bake"] != nil else {
            throw ToolError("Pass create or bake. To delete a group, remove its clips and delete the timeline via organize_media.")
        }
        let snapshot = timelineSnapshot(editor)
        var extra: [String: Any] = [:]
        var notes: [String] = []

        if let raw = args["create"] as? [String: Any] {
            let created = try await createSection(editor, raw)
            extra["created"] = created.payload
            notes += created.notes
        }
        if let raw = args["bake"] as? [String: Any] {
            extra["baked"] = try bakeSection(editor, raw)
            notes.append("Baked clips are plain clips: sync is positional from here and change_cam no longer applies to them.")
        }
        return mutationResult(editor, since: snapshot, extra: extra, notes: notes)
    }

    private func createSection(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> (payload: [String: Any], notes: [String]) {
        try validateUnknownKeys(args, allowed: ["name", "members", "master", "place", "startFrame", "searchWindowSeconds"], path: "manage_multicam.create")
        if editor.timeline.isMulticam, args.bool("place") ?? true {
            throw ToolError("The active timeline is a multicam group — switch to an edit timeline (set_active_timeline) to place a new group, or pass place: false.")
        }
        guard let rawMembers = args["members"] as? [[String: Any]], rawMembers.count >= 2 else {
            throw ToolError("create.members requires at least two entries (cameras and mics).")
        }

        var specs: [EditorViewModel.MulticamMemberSpec] = []
        var seenRefs = Set<String>()
        for (i, raw) in rawMembers.enumerated() {
            let path = "create.members[\(i)]"
            try validateUnknownKeys(raw, allowed: ["mediaRef", "kind", "angleLabel", "offsetSeconds"], path: path)
            let expanded = try expandingIdPrefixes(in: raw, editor: editor)
            let ref = try expanded.requireString("mediaRef")
            guard seenRefs.insert(ref).inserted else { throw ToolError("\(path): duplicate mediaRef \(ref)") }
            guard let kind = MulticamSource.MemberKind(rawValue: try expanded.requireString("kind")) else {
                throw ToolError("\(path): kind must be angle, mic, or both.")
            }
            let asset = try asset(ref, editor: editor, label: "\(path) member")
            switch kind {
            case .angle:
                guard asset.type == .video else { throw ToolError("\(path): angle members must be video.") }
            case .mic:
                guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else {
                    throw ToolError("\(path): mic members need audio.")
                }
            case .both:
                guard asset.type == .video && asset.hasAudio else {
                    throw ToolError("\(path): 'both' members must be video with audio.")
                }
            }
            specs.append(.init(
                mediaRef: ref, kind: kind,
                angleLabel: expanded.string("angleLabel"),
                pinnedOffsetSeconds: expanded.double("offsetSeconds")
            ))
        }

        let masterRef = try resolveMasterRef(args.string("master"), specs: specs, editor: editor)
        let sync = await editor.syncMulticamMembers(
            specs: specs, masterRef: masterRef,
            searchWindowSeconds: args.double("searchWindowSeconds") ?? EditorViewModel.SyncDefaults.memberSearchWindowSeconds
        )

        let (childId, carrierIds) = try withUndoGroup(editor, actionName: "Create Multicam (Agent)") {
            try editor.createMulticamGroup(
                specs: specs, syncMaps: sync.maps, masterRef: masterRef,
                name: args.string("name"), place: args.bool("place") ?? true, startFrame: args.int("startFrame")
            )
        }

        var payload: [String: Any] = [
            "groupId": childId,
            "members": memberRows(editor, childId: childId),
            "carrierClipIds": carrierIds,
        ]
        if !sync.failures.isEmpty {
            payload["needsAttention"] = sync.failures.map { ["mediaRef": $0.mediaRef, "reason": $0.reason] }
        }
        var notes = ["Angle cuts live inside the group — use change_cam; the timeline clip stays put. remove_words/remove_silence treat it as one clip.",
                     "The placed clip spans where cameras have picture; audio-only head/tail stays in the group — extend the clip's edges (set_clip_properties trims) to include it."]
        if !specs.contains(where: { $0.kind == .mic }), specs.filter({ $0.kind == .both }).count >= 2 {
            notes.append("All members are 'both', so every camera's audio plays. If the cameras share the room's sound, mute all but the master (open the group, mute the other beds) to avoid comb filtering; if each file is one speaker's isolated mic, keep them all audible.")
        }
        if !sync.failures.isEmpty {
            notes.append("Unsynced members can't be used as angles until re-created with a pinned offsetSeconds.")
        }
        return (payload, notes)
    }

    private func bakeSection(_ editor: EditorViewModel, _ raw: [String: Any]) throws -> [String: Any] {
        try validateUnknownKeys(raw, allowed: ["groupId", "clipId"], path: "manage_multicam.bake")
        let childId = try resolveGroupId(editor, raw)
        let carriers: [Clip]
        if let clipId = raw.string("clipId") {
            guard let clip = editor.clipFor(id: clipId), editor.multicamContext(clip: clip)?.child.id == childId else {
                throw ToolError("clipId doesn't name a clip of this group on the active timeline.")
            }
            carriers = [clip]
        } else {
            carriers = editor.multicamCarriers(of: childId)
        }
        guard !carriers.isEmpty else {
            throw ToolError("No clips of this group on the active timeline to bake.")
        }
        withUndoGroup(editor, actionName: "Bake Multicam (Agent)") {
            for carrier in carriers where editor.findClip(id: carrier.id) != nil {
                editor.decomposeNest(clipId: carrier.id)
            }
        }
        return ["groupId": childId, "bakedClips": carriers.count]
    }


    func changeCam(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["groupId", "clipId", "entries"], path: "change_cam")
        let childId = try resolveGroupId(editor, args)
        guard let rawEntries = args["entries"] as? [[String: Any]], !rawEntries.isEmpty else {
            throw ToolError("entries requires at least one {range, angle|layout} entry.")
        }

        var requests: [EditorViewModel.AngleSwitchRequest] = []
        for (i, raw) in rawEntries.enumerated() {
            let path = "entries[\(i)]"
            try validateUnknownKeys(raw, allowed: ["range", "angle", "layout", "slots", "fit"], path: path)
            guard let range = raw["range"] as? [Any], range.count == 2,
                  let a = (range[0] as? NSNumber)?.intValue, let b = (range[1] as? NSNumber)?.intValue, a < b else {
                throw ToolError("\(path): range must be [startFrame, endFrame) with start < end.")
            }
            let fit = try raw.string("fit").map {
                try LayoutFit(rawValue: $0) ?? { throw ToolError("\(path): fit must be fill or fit.") }()
            } ?? .fill

            switch (raw.string("angle"), raw.string("layout")) {
            case (let angle?, nil):
                requests.append(.init(range: a..<b, layout: .full, slots: [("main", angle)], fit: fit))
            case (nil, let layoutRaw?):
                guard let layout = VideoLayout(rawValue: layoutRaw), layout != .full else {
                    throw ToolError("\(path): unknown layout '\(layoutRaw)'. Use angle for full-frame.")
                }
                guard let slots = raw["slots"] as? [[String: Any]] else {
                    throw ToolError("\(path): layout entries need slots: [{slot, angle}].")
                }
                let parsed = try slots.enumerated().map { j, s -> (String, String) in
                    try validateUnknownKeys(s, allowed: ["slot", "angle"], path: "\(path).slots[\(j)]")
                    return (try s.requireString("slot"), try s.requireString("angle"))
                }
                requests.append(.init(range: a..<b, layout: layout, slots: parsed, fit: fit))
            default:
                throw ToolError("\(path): pass exactly one of angle (full-frame) or layout+slots.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let report = try withUndoGroup(editor, actionName: "Switch Angle (Agent)") {
            try editor.switchMulticamAngles(childId: childId, requests: requests)
        }

        var extra: [String: Any] = [
            "groupId": childId,
            "switched": report.switched, "gapsFilled": report.filled, "cutsMerged": report.merged,
        ]
        if let lo = report.applied.compactMap({ $0.first }).min(),
           let hi = report.applied.compactMap({ $0.last }).max() {
            extra["program"] = editor.multicamProgramRows(childId: childId, window: lo..<hi)
        }
        if !report.clamped.isEmpty {
            extra["clamped"] = report.clamped.map {
                ["requested": $0.requested, "applied": $0.applied, "culprit": $0.culprit]
            }
        }
        if !report.skipped.isEmpty {
            extra["skipped"] = report.skipped.map { ["range": $0.range, "reason": $0.reason] }
        }
        return mutationResult(editor, since: snapshot, extra: extra)
    }

    func getMulticam(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["groupId", "clipId", "startFrame", "endFrame"], path: "get_multicam")
        let childId = try resolveGroupId(editor, args)
        guard let (child, _) = editor.multicamChild(id: childId) else {
            throw ToolError("Not a multicam group: \(childId)")
        }
        let window = try Self.frameWindow(args)
        var payload: [String: Any] = [
            "groupId": childId,
            "name": child.name,
            "members": memberRows(editor, childId: childId),
            "program": editor.multicamProgramRows(childId: childId, window: window),
            "carriers": editor.multicamCarriers(of: childId).map {
                ["clipId": $0.id, "frames": [$0.startFrame, $0.endFrame]]
            },
        ]
        if editor.activeTimelineId == childId {
            payload["note"] = "Read from inside the group: program rows are in the group's own frames (matching get_timeline here); the group's placement (carriers) lives on the edit timelines."
        }
        return .ok(Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) ?? "{}")
    }

    // MARK: - Helpers

    private func resolveGroupId(_ editor: EditorViewModel, _ args: [String: Any]) throws -> String {
        if let groupId = args.string("groupId") {
            guard editor.multicamChild(id: groupId) != nil else {
                throw ToolError("No multicam group '\(groupId)'. get_media lists groups under timelines.")
            }
            return groupId
        }
        if let clipId = args.string("clipId") {
            guard let clip = editor.clipFor(id: clipId), let context = editor.multicamContext(clip: clip) else {
                throw ToolError("Clip '\(clipId)' is not a multicam clip.")
            }
            return context.child.id
        }
        throw ToolError("Pass groupId or clipId.")
    }

    private func resolveMasterRef(_ master: String?, specs: [EditorViewModel.MulticamMemberSpec], editor: EditorViewModel) throws -> String {
        if let master {
            let expanded = (try? expandingIdPrefixes(in: ["mediaRef": master], editor: editor))?.string("mediaRef") ?? master
            guard let spec = specs.first(where: {
                $0.mediaRef == expanded || $0.angleLabel?.caseInsensitiveCompare(master) == .orderedSame
            }) else {
                throw ToolError("master '\(master)' doesn't match a member's angleLabel or mediaRef.")
            }
            return spec.mediaRef
        }
        let pick = specs.first { $0.kind == .mic } ?? specs.first { $0.kind == .both } ?? specs[0]
        guard pick.kind != .angle else {
            throw ToolError("No mic member to sync against — mark one member as mic/both, or pin offsets explicitly.")
        }
        return pick.mediaRef
    }

    private func memberRows(_ editor: EditorViewModel, childId: String) -> [[String: Any]] {
        guard let source = editor.multicamChild(id: childId)?.source else { return [] }
        return source.members.map { m in
            var row: [String: Any] = [
                "angleLabel": m.angleLabel, "kind": m.kind.rawValue, "mediaRef": m.mediaRef,
                "offsetSeconds": m.sync.offsetSeconds, "confidence": m.sync.confidence,
            ]
            if m.id == source.masterMemberId { row["master"] = true }
            if m.sync.locked { row["pinned"] = true }
            if !m.usable { row["unsynced"] = true }
            return row
        }
    }
}
