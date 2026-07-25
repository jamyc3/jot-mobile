import SwiftUI

/// Shown when the user's rewrite engine is Apple Intelligence (features.md §7.10).
/// Instead of running the rewrite for them, Jot enters a read-only **selection
/// mode** that pre-selects the whole transcript, then this sheet teaches the free
/// **system Writing Tools** path: tap the selection → Writing Tools → choose Key
/// Points / Summary / Rewrite → Copy. The full-transcript selection is applied on
/// this sheet's DISMISS (see `TranscriptDetailView.applyFullRangeSelection`).
///
/// Pure guidance — no engine, no model, no network.
///
/// The sheet used to end with a secondary "Download Jot's AI · 2.5 GB" link.
/// Removed 2026-07-25 per owner direction ("remove the Jot AI thing — I don't
/// think we're gonna use that anymore"): Apple Intelligence is the path we
/// teach, and a 2.5 GB upsell under a "no download needed" headline worked
/// against it. Jot's own model is still reachable from Settings → AI Rewrite.
@MainActor
struct AppleIntelligenceRewriteGuide: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotMute)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .frame(minHeight: 28)

            sparkle.padding(.top, 2)

            Text("Rewrite with Apple Intelligence")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.jotInk)
                .multilineTextAlignment(.center)
                .padding(.top, 14)

            Text("Built into your iPhone — no download needed.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotMute)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.bottom, 22)

            step(1, "We've **selected the whole transcript** for you.")
            step(2, "**Tap the selection** to bring up the menu.")
            step(3, "Tap **Writing Tools** and choose **Key Points**, **Summary**, **Rewrite**, and more.")
            step(4, "**Copy** the result to use it anywhere.")

            Spacer(minLength: 16)
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WallpaperBackground())
        .presentationDetents([.fraction(0.7), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
    }

    // MARK: - Pieces

    private var sparkle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.37, blue: 0.60),
                            Color(red: 0.64, green: 0.36, blue: 1.00),
                            Color(red: 0.23, green: 0.61, blue: 1.00),
                            Color(red: 0.23, green: 0.84, blue: 0.78),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .shadow(color: Color(red: 0.47, green: 0.31, blue: 1.0).opacity(0.4), radius: 12, x: 0, y: 6)
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [Color.jotBlueTop, Color.jotBlueBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                )
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.jotInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 16)
    }
}
