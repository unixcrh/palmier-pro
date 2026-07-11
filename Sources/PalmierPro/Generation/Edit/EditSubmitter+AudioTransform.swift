import Foundation

extension EditSubmitter {
    static func audioTransformSeed(
        for asset: MediaAsset,
        kind: AudioTransformEditKind,
        durationOverride: Double? = nil,
        targetLanguage: String? = nil
    ) -> GenerationInput? {
        guard let model = kind.model else { return nil }
        let duration = max(1, Int((durationOverride ?? asset.duration).rounded()))
        var stored = GenerationInput(
            prompt: "",
            model: model.id,
            duration: duration,
            aspectRatio: "",
            resolution: nil,
            targetLanguage: kind == .dubbing
                ? (targetLanguage ?? model.defaultTargetLanguage)
                : nil
        )
        guard stored.setAudioSourceAsset(asset) else { return nil }
        return stored
    }

    @discardableResult
    static func submitAudioTransform(
        asset: MediaAsset,
        kind: AudioTransformEditKind,
        targetLanguage: String? = nil,
        editor: EditorViewModel,
        trimmedSource: TrimmedSource? = nil,
        placement: PendingAudioPlacement? = nil
    ) -> String? {
        guard AccountService.shared.isSignedIn, let model = kind.model else { return nil }

        let duration = effectiveDuration(for: asset, trimmedSource: trimmedSource)
        let language = kind == .dubbing
            ? (targetLanguage ?? model.defaultTargetLanguage) : nil
        let params = AudioGenerationParams(
            prompt: "",
            voice: nil,
            lyrics: nil,
            styleInstructions: nil,
            instrumental: false,
            durationSeconds: duration,
            sourceURL: nil,
            targetLanguage: language
        )
        guard model.validate(spanSeconds: Double(duration)) == nil,
              model.validate(params: params) == nil else { return nil }

        guard let genInput = audioTransformSeed(
            for: asset,
            kind: kind,
            durationOverride: Double(duration),
            targetLanguage: language
        ) else { return nil }

        let completion: (@MainActor (MediaAsset) -> Void)?
        if placement != nil {
            completion = { [weak editor] generated in
                editor?.finalizeGeneratingClip(placeholderId: generated.id, asset: generated)
            }
        } else {
            completion = nil
        }
        let placeholderId = AudioGenerationSubmission.make(
            genInput: genInput,
            model: model,
            params: params,
            name: "\(asset.name) \(kind.outputSuffix)",
            folderId: asset.folderId,
            references: [asset],
            trimmedSourceOverride: trimmedSource
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: completion
        )

        if let placement {
            editor.placeGeneratingAudioClip(
                placeholderId: placeholderId,
                startFrame: placement.startFrame,
                spanSeconds: placement.spanSeconds,
                actionName: placement.actionName
            )
        }
        return placeholderId
    }
}
