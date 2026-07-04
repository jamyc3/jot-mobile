import SwiftUI

/// Settings → About → "Voice Clone Consent" — a plain, read-only list of
/// every consent acceptance recorded by `VoiceCloneConsentStore`. Purely a
/// transparency/legal record for the user's own reference; nothing here is
/// ever transmitted off the device.
struct VoiceCloneConsentView: View {
    @State private var records = VoiceCloneConsentStore.records

    var body: some View {
        ZStack(alignment: .top) {
            WallpaperBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if records.isEmpty {
                        emptyState
                    } else {
                        LiquidGlassCard(paddingH: 0, paddingV: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(records.enumerated()), id: \.element.id) { idx, record in
                                    if idx > 0 { divider }
                                    recordRow(record)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .onAppear { records = VoiceCloneConsentStore.records }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voice Clone Consent")
                .font(JotType.rowTitle).tracking(-0.2)
                .foregroundStyle(Color.jotPageInk)
            Text("A record of every voice-clone disclaimer you've accepted, kept only on this iPhone. Never uploaded or shared anywhere.")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
        }
    }

    private var emptyState: some View {
        Text("No voice clones created yet.")
            .font(JotType.rowSub)
            .foregroundStyle(Color.jotPageInkSecondary)
    }

    private func recordRow(_ record: VoiceCloneConsentStore.Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.voiceName)
                .font(JotType.rowTitle).tracking(-0.2)
                .foregroundStyle(Color.jotPageInk)
            Text(record.acceptedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(Color.jotPageInkSecondary)
            Text(record.disclaimerText)
                .font(.system(size: 12))
                .foregroundStyle(Color.jotPageInkSecondary.opacity(0.8))
                .lineSpacing(2)
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.jotPageSeparator)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
