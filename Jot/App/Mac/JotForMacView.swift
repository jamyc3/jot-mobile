import SwiftUI

/// Reached from Settings → About → "Jot for Mac" (a permanent row, not
/// gated on the one-time home prompt — see `DictationStats
/// .shouldShowMacAppPromo` for that separate nudge). Pitches the Mac app
/// and gives the easiest possible phone→laptop handoff: share the
/// download link to AirDrop, Messages, or Mail it to yourself, since Jot
/// has no accounts to sign into on the other device. Tone mirrors
/// `DonationsView` — plain, no dark patterns.
struct JotForMacView: View {
    private static let macSiteURL = URL(string: "https://jot-transcribe.com")!

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            WallpaperBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topToolbar
                    heroTitle
                    pitchBlock
                    actionsCard
                    footnote
                }
                .padding(.horizontal, JotDesign.Spacing.pageGutter)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
        }
        .jotPushedPage()
    }

    private var topToolbar: some View {
        HStack {
            glassCircleButton(
                systemImage: "chevron.backward",
                accessibilityLabel: "Back"
            ) {
                dismiss()
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
    }

    private var heroTitle: some View {
        Text("Jot for Mac")
            .font(JotType.displaySerif(44))
            .tracking(-1.6)
            .foregroundStyle(Color.jotPageInk)
            .accessibilityAddTraits(.isHeader)
    }

    private var pitchBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Same dictation, on a bigger screen.")
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundStyle(Color.jotPageInk)

            Text("Jot for Mac transcribes on-device, the same way it does here — no accounts, no cloud. Handy when you're writing at a desk and want to speak instead of type.")
                .font(.system(size: 15, weight: .regular, design: .default))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private var actionsCard: some View {
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(Self.macSiteURL.absoluteString.replacingOccurrences(of: "https://", with: ""))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.jotPageInkSecondary)

                // The key handoff affordance: share the link to AirDrop it
                // straight to the Mac, or send it to yourself via Messages
                // or Mail — whatever's fastest to open on the other device.
                ShareLink(item: Self.macSiteURL) {
                    Text("Send to your Mac")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule(style: .continuous).fill(Color.jotBlueTop))
                }
                .accessibilityHint("Share the Jot for Mac download link — AirDrop it to your Mac, or message or email it to yourself")

                Button {
                    openURL(Self.macSiteURL)
                } label: {
                    Text("Open jot-transcribe.com")
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Color.jotPageInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Jot for Mac site in Safari")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footnote: some View {
        Text("Downloads directly on jot-transcribe.com — no App Store account needed.")
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(Color.jotMute)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func glassCircleButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .frame(width: 44, height: 44)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    NavigationStack {
        JotForMacView()
    }
}
