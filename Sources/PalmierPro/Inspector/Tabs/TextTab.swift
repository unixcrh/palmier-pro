import SwiftUI

struct TextTab: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor
    @State private var outlineExpanded = true
    @State private var shadowExpanded = true
    @State private var backgroundExpanded = true

    private static let defaults = TextStyle()

    private var clip: Clip { clips[0] }
    private var clipIds: [String] { clips.map(\.id) }
    private var isBatch: Bool { clips.count > 1 }
    private var style: TextStyle { clip.textStyle ?? Self.defaults }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            contentField
            EditorPanelGroup("Style") {
                fontRow
                styleRow
                sizeSlider
                trackingRow
                alignmentRow
                positionSection
                colorRow
                opacitySlider
            }
            outlineGroup
            shadowGroup
            backgroundGroup
        }
    }

    // MARK: - Controls

    private var contentField: some View {
        EditorPanelGroup("Text") {
            TextContentField(
                text: Binding(
                    get: { clip.textContent ?? "" },
                    set: { new in
                        guard !isBatch else { return }
                        editor.applyClipProperty(clipId: clip.id, rebuild: true) { $0.textContent = new }
                        editor.fitTextClipToContent(clipId: clip.id)
                    }
                ),
                onCommit: { new in
                    guard !isBatch else { return }
                    editor.commitClipProperty(clipId: clip.id) { $0.textContent = new }
                    editor.fitTextClipToContent(clipId: clip.id)
                }
            )
            .disabled(isBatch)
            .opacity(isBatch ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
            .frame(minHeight: AppTheme.EditorPanel.textEditorMinHeight)
            .padding(AppTheme.Spacing.smMd)
            .editorValueField()
        }
    }

    private var fontRow: some View {
        InspectorRow(
            label: "Font",
            onReset: {
                editor.commitTextStyles(clipIds: clipIds, fitToContent: true) {
                    $0.fontName = Self.defaults.fontName
                }
            }
        ) {
            FontPickerField(
                current: sharedTextStyleValue { $0.fontName },
                onPreview: { name in
                    editor.applyTextStyles(clipIds: clipIds, fitToContent: true) { $0.fontName = name }
                },
                onChange: { newName in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: true) { $0.fontName = newName }
                },
                onCancel: {
                    for id in clipIds { editor.revertClipProperty(clipId: id) }
                }
            )
        }
    }

    private var styleRow: some View {
        InspectorRow(
            label: "Style",
            onReset: {
                editor.commitTextStyles(clipIds: clipIds, fitToContent: true) {
                    $0.isBold = Self.defaults.isBold
                    $0.isItalic = Self.defaults.isItalic
                }
            }
        ) {
            TextStyleTraitButtons(
                isBold: sharedTextStyleValue { $0.isBold },
                isItalic: sharedTextStyleValue { $0.isItalic },
                onBold: { new in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: true) { $0.isBold = new }
                },
                onItalic: { new in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: true) { $0.isItalic = new }
                }
            )
        }
    }

    private var sizeSlider: some View {
        styleNumberRow(
            label: "Size",
            value: sharedTextStyleValue { $0.fontSize },
            range: 12...300,
            format: "%.0f",
            suffix: " pt",
            fitToContent: true,
            resetValue: Self.defaults.fontSize,
            keyPath: \.fontSize
        )
    }

    private var trackingRow: some View {
        styleNumberRow(
            label: "Tracking",
            value: sharedTextStyleValue { $0.tracking },
            range: -20...100,
            format: "%.1f",
            suffix: " pt",
            fitToContent: true,
            resetValue: Self.defaults.tracking,
            keyPath: \.tracking
        )
    }

    private var opacitySlider: some View {
        InspectorRow(
            label: "Opacity",
            onReset: {
                editor.commitClipProperties(clipIds: clipIds) { $0.opacity = 1 }
            }
        ) {
            ScrubbableNumberField(
                value: sharedClipValue(clips) { $0.opacity },
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newVal in
                    editor.applyClipProperties(clipIds: clipIds) { $0.opacity = newVal }
                }
            ) { newVal in
                editor.commitClipProperties(clipIds: clipIds) { $0.opacity = newVal }
            }
        }
    }

    private var colorRow: some View {
        styleColorRow(
            label: "Color",
            color: style.color,
            debounceKey: "textColor",
            resetColor: Self.defaults.color,
            keyPath: \.color
        )
    }

    private var alignmentRow: some View {
        InspectorRow(
            label: "Alignment",
            onReset: {
                editor.commitTextStyles(clipIds: clipIds) { $0.alignment = Self.defaults.alignment }
            }
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { style.alignment },
                    set: { new in
                        editor.commitTextStyles(clipIds: clipIds) { $0.alignment = new }
                    }
                )
            ) {
                Image(systemName: "text.alignleft").tag(TextStyle.Alignment.left)
                Image(systemName: "text.aligncenter").tag(TextStyle.Alignment.center)
                Image(systemName: "text.alignright").tag(TextStyle.Alignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.white.opacity(AppTheme.Opacity.strong))
            .fixedSize()
        }
    }

    private var outlineGroup: some View {
        let enabled = sharedTextStyleValue { $0.border.enabled }
        return decorationGroup(
            "Outline",
            isExpanded: $outlineExpanded,
            enabled: enabled,
            enabledKeyPath: \.border.enabled,
            debounceKeys: ["outlineColor"],
            onReset: { $0.border = Self.defaults.border }
        ) {
            styleColorRow(
                label: "Color",
                color: style.border.color,
                debounceKey: "outlineColor",
                resetColor: Self.defaults.border.color,
                keyPath: \.border.color
            )
            styleNumberRow(
                label: "Width",
                value: sharedTextStyleValue { $0.border.width },
                range: 0...40,
                format: "%.1f",
                suffix: " pt",
                resetValue: Self.defaults.border.width,
                keyPath: \.border.width
            )
        }
    }

    private var shadowGroup: some View {
        let enabled = sharedTextStyleValue { $0.shadow.enabled }
        return decorationGroup(
            "Shadow",
            isExpanded: $shadowExpanded,
            enabled: enabled,
            enabledKeyPath: \.shadow.enabled,
            debounceKeys: ["shadowColor"],
            onReset: { $0.shadow = Self.defaults.shadow }
        ) {
            styleColorRow(
                label: "Color",
                color: style.shadow.color,
                debounceKey: "shadowColor",
                resetColor: Self.defaults.shadow.color,
                preservesOpacity: true,
                keyPath: \.shadow.color
            )
            styleNumberRow(
                label: "Opacity",
                value: sharedTextStyleValue { $0.shadow.color.a },
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                suffix: "%",
                resetValue: Self.defaults.shadow.color.a,
                keyPath: \.shadow.color.a
            )
            stylePairRow(
                label: "Offset",
                x: sharedTextStyleValue { $0.shadow.offsetX },
                y: sharedTextStyleValue { $0.shadow.offsetY },
                range: -200...200,
                resetX: Self.defaults.shadow.offsetX,
                resetY: Self.defaults.shadow.offsetY,
                xKeyPath: \.shadow.offsetX,
                yKeyPath: \.shadow.offsetY
            )
            styleNumberRow(
                label: "Blur",
                value: sharedTextStyleValue { $0.shadow.blur },
                range: 0...100,
                format: "%.1f",
                suffix: " pt",
                resetValue: Self.defaults.shadow.blur,
                keyPath: \.shadow.blur
            )
        }
    }

    private var backgroundGroup: some View {
        let enabled = sharedTextStyleValue { $0.background.enabled }
        return decorationGroup(
            "Background",
            isExpanded: $backgroundExpanded,
            enabled: enabled,
            fitToContent: true,
            enabledKeyPath: \.background.enabled,
            debounceKeys: ["backgroundColor", "backgroundOutlineColor"],
            onReset: { $0.background = Self.defaults.background }
        ) {
            styleColorRow(
                label: "Color",
                color: style.background.color,
                debounceKey: "backgroundColor",
                resetColor: Self.defaults.background.color,
                preservesOpacity: true,
                keyPath: \.background.color
            )
            styleNumberRow(
                label: "Opacity",
                value: sharedTextStyleValue { $0.background.color.a },
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                suffix: "%",
                resetValue: Self.defaults.background.color.a,
                keyPath: \.background.color.a
            )
            stylePairRow(
                label: "Padding",
                x: sharedTextStyleValue { $0.background.paddingX },
                y: sharedTextStyleValue { $0.background.paddingY },
                range: 0...300,
                fitToContent: true,
                resetX: Self.defaults.background.paddingX,
                resetY: Self.defaults.background.paddingY,
                xKeyPath: \.background.paddingX,
                yKeyPath: \.background.paddingY
            )
            stylePairRow(
                label: "Center",
                x: sharedTextStyleValue { $0.background.offsetX },
                y: sharedTextStyleValue { $0.background.offsetY },
                range: -500...500,
                resetX: Self.defaults.background.offsetX,
                resetY: Self.defaults.background.offsetY,
                xKeyPath: \.background.offsetX,
                yKeyPath: \.background.offsetY
            )
            styleNumberRow(
                label: "Corner Radius",
                value: sharedTextStyleValue { $0.background.cornerRadius },
                range: 0...300,
                format: "%.1f",
                suffix: " pt",
                resetValue: Self.defaults.background.cornerRadius,
                keyPath: \.background.cornerRadius
            )
            styleColorRow(
                label: "Outline Color",
                color: style.background.outlineColor,
                debounceKey: "backgroundOutlineColor",
                resetColor: Self.defaults.background.outlineColor,
                keyPath: \.background.outlineColor
            )
            styleNumberRow(
                label: "Outline Width",
                value: sharedTextStyleValue { $0.background.outlineWidth },
                range: 0...40,
                format: "%.1f",
                suffix: " pt",
                resetValue: Self.defaults.background.outlineWidth,
                keyPath: \.background.outlineWidth
            )
        }
    }

    private func decorationGroup<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        enabled: Bool?,
        fitToContent: Bool = false,
        enabledKeyPath: WritableKeyPath<TextStyle, Bool>,
        debounceKeys: [String],
        onReset: @escaping (inout TextStyle) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        EditorPanelGroup(
            title,
            isExpanded: isExpanded,
            onReset: {
                debounceKeys.forEach { editor.cancelDebouncedCommit(key: $0) }
                editor.commitTextStyles(clipIds: clipIds, fitToContent: fitToContent, onReset)
            },
            headerAccessory: {
                decorationToggle(
                    label: title,
                    isOn: Binding(
                        get: { enabled ?? false },
                        set: { newValue in
                            editor.commitTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                                $0[keyPath: enabledKeyPath] = newValue
                            }
                        }
                    )
                )
            }
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                content()
            }
            .disabled(enabled != true)
            .opacity(enabled == true ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
        }
    }

    private func decorationToggle(
        label: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle("", isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
        .accessibilityLabel(label)
    }

    private func styleColorRow(
        label: String,
        color: TextStyle.RGBA,
        debounceKey: String,
        resetColor: TextStyle.RGBA,
        preservesOpacity: Bool = false,
        keyPath: WritableKeyPath<TextStyle, TextStyle.RGBA>
    ) -> some View {
        InspectorRow(
            label: label,
            onReset: {
                editor.cancelDebouncedCommit(key: debounceKey)
                editor.commitTextStyles(clipIds: clipIds) {
                    if preservesOpacity {
                        $0[keyPath: keyPath].setRGB(from: resetColor)
                    } else {
                        $0[keyPath: keyPath] = resetColor
                    }
                }
            }
        ) {
            ColorField(
                displayColor: color.swiftUIColor,
                onUserChange: { new in
                    editor.debouncedCommitTextStyles(clipIds: clipIds, key: debounceKey) {
                        let newColor = TextStyle.RGBA(new)
                        if preservesOpacity {
                            $0[keyPath: keyPath].setRGB(from: newColor)
                        } else {
                            $0[keyPath: keyPath] = newColor
                        }
                    }
                },
                supportsOpacity: !preservesOpacity
            )
        }
    }

    private func styleNumberRow(
        label: String,
        value: Double?,
        range: ClosedRange<Double>,
        displayMultiplier: Double = 1,
        format: String,
        suffix: String,
        fitToContent: Bool = false,
        resetValue: Double,
        keyPath: WritableKeyPath<TextStyle, Double>
    ) -> some View {
        InspectorRow(
            label: label,
            onReset: {
                editor.commitTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                    $0[keyPath: keyPath] = resetValue
                }
            }
        ) {
            ScrubbableNumberField(
                value: value,
                range: range,
                displayMultiplier: displayMultiplier,
                format: format,
                valueSuffix: suffix,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { new in
                    editor.applyTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                        $0[keyPath: keyPath] = new
                    }
                }
            ) { new in
                editor.commitTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                    $0[keyPath: keyPath] = new
                }
            }
        }
    }

    private func stylePairRow(
        label: String,
        x: Double?,
        y: Double?,
        range: ClosedRange<Double>,
        fitToContent: Bool = false,
        resetX: Double,
        resetY: Double,
        xKeyPath: WritableKeyPath<TextStyle, Double>,
        yKeyPath: WritableKeyPath<TextStyle, Double>
    ) -> some View {
        InspectorRow(
            label: label,
            onReset: {
                editor.commitTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                    $0[keyPath: xKeyPath] = resetX
                    $0[keyPath: yKeyPath] = resetY
                }
            }
        ) {
            HStack(spacing: AppTheme.Spacing.sm) {
                ScrubbableNumberField(
                    value: x,
                    range: range,
                    format: "%.1f",
                    fieldWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
                    trailingLabel: "X",
                    onChanged: { new in
                        editor.applyTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                            $0[keyPath: xKeyPath] = new
                        }
                    }
                ) { new in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                        $0[keyPath: xKeyPath] = new
                    }
                }
                ScrubbableNumberField(
                    value: y,
                    range: range,
                    format: "%.1f",
                    fieldWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
                    trailingLabel: "Y",
                    onChanged: { new in
                        editor.applyTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                            $0[keyPath: yKeyPath] = new
                        }
                    }
                ) { new in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: fitToContent) {
                        $0[keyPath: yKeyPath] = new
                    }
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var positionSection: some View {
        InspectorRow(
            label: "Position",
            onReset: {
                editor.commitClipProperties(clipIds: clipIds) {
                    $0.transform.centerX = Transform().centerX
                    $0.transform.centerY = Transform().centerY
                    $0.positionTrack = nil
                }
            }
        ) {
            InspectorPositionFields(clips: clips)
        }
    }

    private func sharedTextStyleValue<T: Equatable>(_ extract: (TextStyle) -> T) -> T? {
        sharedClipValue(clips) { extract($0.textStyle ?? Self.defaults) }
    }
}

struct TextAnimateTab: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    private var clip: Clip { clips[0] }
    private var targetIds: [String] {
        var seen = Set<String>()
        return clips.flatMap { editor.captionGroupTextClipIds(for: $0.id) }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        let anim = clip.textAnimation ?? TextAnimation()
        EditorPanelGroup("Animation") {
            CaptionPresetGallery(
                selection: Binding(
                    get: { anim.preset },
                    set: { new in setAnim { $0.preset = new } }
                ),
                highlight: anim.highlight
            )
            if anim.preset.usesHighlight { highlightRow(anim) }
        }
    }

    private func setAnim(_ modify: (inout TextAnimation) -> Void) {
        var a = clip.textAnimation ?? TextAnimation()
        modify(&a)
        let value: TextAnimation? = a.preset == .none ? nil : a
        editor.cancelDebouncedCommit(key: "textHighlight")
        editor.commitClipProperties(clipIds: targetIds) { $0.textAnimation = value }
    }

    private func highlightRow(_ anim: TextAnimation) -> some View {
        InspectorRow(
            label: "Highlight",
            onReset: {
                editor.cancelDebouncedCommit(key: "textHighlight")
                editor.commitClipProperties(clipIds: targetIds) {
                    guard var animation = $0.textAnimation else { return }
                    animation.highlight = TextAnimation.defaultHighlight
                    $0.textAnimation = animation
                }
            }
        ) {
            ColorField(
                displayColor: (anim.highlight ?? TextAnimation.defaultHighlight).swiftUIColor,
                onUserChange: { new in
                    editor.debouncedCommitClipProperties(clipIds: targetIds, key: "textHighlight") {
                        guard var a = $0.textAnimation, a.preset.usesHighlight else { return }
                        a.highlight = TextStyle.RGBA(new)
                        $0.textAnimation = a
                    }
                }
            )
        }
    }
}
