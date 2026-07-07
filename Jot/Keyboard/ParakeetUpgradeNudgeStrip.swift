import SwiftUI

/// Keyboard-side Parakeet-upgrade nudge (deferred-engineering follow-up to
/// the Apple Dictation A/B spike).
///
/// The app owns the dictation-count math: after each completed English
/// dictation on Apple's engine it increments `DictationStats
/// .appleDictationCount`, and — once that crosses 5 on an eligible device,
/// with the nudge not already declined and warm hold not already showing its
/// own nudge — sets `AppGroup.showParakeetUpgradeNudge` + posts
/// `parakeetUpgradeNudgeChanged`. The keyboard can't run that math (no
/// dictation history, no device-capability check it needs to duplicate), so
/// it renders this strip purely off the boolean and writes the two terminal
/// actions back via the controller (deep-link to the app's upgrade screen /
/// `AppGroup.parakeetNudgeDeclined`).
///
/// This is the keyboard twin of `WarmHoldNudgeStrip` — same Liquid Glass
/// chrome, same one-shot (no rotation) behavior, same "app sets the boolean,
/// keyboard just renders" split. It never shows at the same time as the
/// warm-hold nudge (see `KeyboardView.topStrip`'s branch order — warm hold
/// wins if both are somehow armed).
struct ParakeetUpgradeNudgeStrip: View {
    let reduceMotion: Bool
    let onSwitch: () -> Void
    let onDismiss: () -> Void
    let feedback: KeyboardFeedback

    /// Matches the recents / streaming / warm-hold-nudge card height so
    /// toggling this nudge in and out of the strip slot doesn't jump the
    /// keyboard layout.
    private static let stripHeight: CGFloat = 129

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More accurate dictation available.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.jotKeyboardActionsInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Text("Switch to Jot's own on-device engine.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.jotKeyboardStreamText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    feedback.systemClick()
                    feedback.selectionTick()
                    onSwitch()
                } label: {
                    Text("Switch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Self.pillTopBlue,
                                            Color.jotKeyboardAccentDeep,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch to Jot's engine")
                .accessibilityHint("Opens Jot to switch English dictation to its own on-device engine")

                Button {
                    feedback.systemClick()
                    feedback.selectionTick()
                    onDismiss()
                } label: {
                    Text("Not now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.jotKeyboardStreamText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.stripHeight)
        .background(glassSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.jotKeyboardGlassHighlight, lineWidth: 0.5)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 4)
        // Spring-in (matches WarmHoldNudgeStrip). Reduce Motion → plain fade, no scale.
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.96))
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.42, dampingFraction: 0.8)
            ) {
                appeared = true
            }
        }
        .accessibilityElement(children: .contain)
    }

    // Hardcoded brand blue top stop — identical to the keyboard's Dictate
    // pill and the warm-hold nudge's accept button, so this accept button
    // reads as the same primary surface across modes.
    private static let pillTopBlue = Color(red: 0/255, green: 122/255, blue: 255/255)

    /// Same Liquid Glass recipe as the recents / streaming / warm-hold-nudge
    /// cards so this nudge reads as the same surface, just a different payload.
    @ViewBuilder
    private var glassSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.jotKeyboardGlassFill1,
                            Color.jotKeyboardGlassFill2,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}
