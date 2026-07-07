import SwiftUI

/// One-time "Jot is on your Mac too" prompt content, presented as a
/// centered modal popup on the home screen (`HomeScreen.macAppPromoPopup`)
/// once cumulative dictation time crosses `DictationStats
/// .macAppPromoThresholdSeconds` (see `DictationStats.shouldShowMacAppPromo`).
/// Unlike the donation card, this never re-fires — one crossing, one
/// prompt, forever. Visually it's the same "quiet reminder" card as
/// `DonationCard`, just with a different pitch and destination.
struct MacAppPromoCard: View {
    /// User tapped "Not now" — bubble up so the parent flips its
    /// visibility @State and marks the prompt seen.
    var onDismiss: () -> Void
    /// User tapped the primary action — same reason as `onDismiss`, plus
    /// the parent opens the Jot for Mac screen.
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jot is on your Mac too.")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Text("Same on-device dictation, on a bigger screen. Send yourself the download link to try it there.")
                .font(.system(.subheadline))
                .foregroundStyle(Color.jotMute)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                // Same soft tinted-blue capsule as the donation card's CTA —
                // a gentle pointer, not a competing primary action.
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Text("Get Jot for Mac")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Color.jotBlueBottom)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.jotBlueTop.opacity(0.15))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Get Jot for Mac")
                .accessibilityHint("Opens the Jot for Mac screen")

                Button("Not now", action: onDismiss)
                    .font(.system(.callout))
                    .foregroundStyle(Color.jotMute)
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismisses this reminder for good")

                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.jotInk.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.jotInk.opacity(0.10), lineWidth: 0.5)
        )
    }
}

#Preview {
    MacAppPromoCard(onDismiss: {}, onOpen: {})
        .padding()
        .background(JotDesign.background)
}
