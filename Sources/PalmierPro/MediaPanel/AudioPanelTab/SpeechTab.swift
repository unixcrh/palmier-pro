import SwiftUI

struct SpeechTab: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                InspectorSection("Speech") {
                    InspectorRow(
                        icon: "waveform.badge.mic",
                        label: "Mark Dead Air",
                        labelHelp: "Speech is detected on-device in the background. Dims quiet, speech-free spans on timeline waveforms."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { editor.markDeadAir },
                            set: { editor.markDeadAir = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    if editor.speechAnalyzingCount > 0 {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ProgressView()
                                .controlSize(.small)
                            Text(editor.speechAnalyzingCount == 1
                                ? "Detecting speech…"
                                : "Detecting speech in \(editor.speechAnalyzingCount) files…")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                    }
                    removeDeadAirRow
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .padding(.top, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var removeDeadAirRow: some View {
        let deadAir = editor.allDeadAir()
        let count = deadAir?.ranges.count ?? 0
        return HStack(spacing: AppTheme.Spacing.sm) {
            Button("Remove Dead Air") { editor.removeAllDeadAir() }
                .controlSize(.small)
                .disabled(count == 0)
                .help("Ripple-deletes every dead-air section; downstream clips close the gaps.")
            if count > 0 {
                Text(count == 1 ? "1 section" : "\(count) sections")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }
}
