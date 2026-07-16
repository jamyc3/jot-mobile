import SwiftUI

/// One-time "you're now on Jot's engine" confirmation, presented as a centered
/// modal popup on the home screen (`HomeScreen.engineSwitchedPopup`) after a
/// background Parakeet-upgrade download lands and the engine auto-switches at a
/// safe boundary (see `ParakeetModelArrival`). The download almost always
/// completes while the app is backgrounded, so the switch would otherwise be
/// invisible — this makes it an honest, dismissible note. Same quiet "reminder"
/// card treatment as `MacAppPromoCard`. Gated on `AppGroup.parakeetSwitchedNotice`.
struct EngineSwitchedCard: View {
    /// User acknowledged — bubble up so the parent flips its visibility @State
    /// and clears the one-shot notice flag.
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're on Jot's engine.")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Text("The download finished, so English dictation now uses Jot's own on-device engine — more precise, still fully on-device. You can switch back to Apple anytime in Settings.")
                .font(.system(.subheadline))
                .foregroundStyle(Color.jotMute)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Button(action: onDismiss) {
                    Text("Got it")
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
                .accessibilityHint("Dismisses this note")

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
    EngineSwitchedCard(onDismiss: {})
        .padding()
        .background(JotDesign.background)
}
