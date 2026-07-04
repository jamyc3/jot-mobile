import SwiftUI

/// One labeled turn shown in the result sheet — text is a proportional-by-time
/// split of the transcript, not exact at word boundaries (see
/// `DiarizationLabeling.distributeText`).
struct DiarizationRow: Identifiable {
    let id = UUID()
    let label: String
    let start: Float
    let end: Float
    let text: String
}

/// Ephemeral "Detect speakers" result — not persisted. Diarization Lab
/// prototype; if this graduates past the lab it would need a schema field
/// (`docs/speaker-diarization/design.md`'s `speakerTimeline`, ported to a new
/// `JotSchemaV9`) to survive relaunch. Renames here are session-local too —
/// they don't write back to a stored owner name (unlike the Mac design's D5).
struct DiarizationSheetData: Identifiable {
    let id = UUID()
    let isSingleSpeaker: Bool
    let rows: [DiarizationRow]
}

/// Sheet shown from `TranscriptDetailView`'s "Detect speakers" action.
struct DiarizationResultSheet: View {
    let data: DiarizationSheetData
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [DiarizationRow]
    @State private var renameTarget: RenameTarget?
    @State private var renameText: String = ""

    init(data: DiarizationSheetData) {
        self.data = data
        _rows = State(initialValue: data.rows)
    }

    /// Tapping a speaker label renames every turn sharing that ORIGINAL
    /// label (mirrors the Mac design's D5 — a rename applies to the whole
    /// recording, not just the tapped turn).
    private struct RenameTarget: Identifiable {
        let id = UUID()
        let originalLabel: String
    }

    private var exportText: String {
        rows.map { "\($0.label)  (\(timeRange($0.start, $0.end)))\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WallpaperBackground().ignoresSafeArea()
                if data.isSingleSpeaker {
                    VStack(spacing: 8) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.jotPageInkSecondary)
                        Text("Single speaker").font(JotType.rowTitle)
                            .foregroundStyle(Color.jotPageInk)
                        Text("Only one voice was detected in this recording.")
                            .font(JotType.rowSub)
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Button {
                                            renameText = row.label
                                            renameTarget = RenameTarget(originalLabel: row.label)
                                        } label: {
                                            HStack(spacing: 3) {
                                                Text(row.label)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(row.label == "You" ? Color.jotAccent : Color.jotPageInk)
                                                Image(systemName: "pencil")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(Color.jotPageInkSecondary.opacity(0.6))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Rename speaker \(row.label)")
                                        Text(timeRange(row.start, row.end))
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.jotPageInkSecondary)
                                    }
                                    if !row.text.isEmpty {
                                        Text(row.text)
                                            .font(.system(size: 15))
                                            .foregroundStyle(Color.jotPageInk)
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !data.isSingleSpeaker {
                    ToolbarItem(placement: .navigationBarLeading) {
                        ShareLink(item: exportText) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Export speaker transcript")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Rename speaker",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField("Name", text: $renameText)
                Button("Save") { applyRename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Renames every turn labeled \u{201C}\(renameTarget?.originalLabel ?? "")\u{201D} in this recording.")
            }
        }
    }

    private func applyRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rows = rows.map { row in
            guard row.label == target.originalLabel else { return row }
            return DiarizationRow(label: trimmed, start: row.start, end: row.end, text: row.text)
        }
    }

    private func timeRange(_ start: Float, _ end: Float) -> String {
        func format(_ seconds: Float) -> String {
            let s = Int(seconds)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return "\(format(start))–\(format(end))"
    }
}
