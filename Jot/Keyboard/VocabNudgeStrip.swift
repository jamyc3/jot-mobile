import SwiftUI

/// Keyboard-side Vocabulary-adoption nudge.
///
/// The app owns the eligibility math: Vocabulary Boost OFF and the user is
/// either high-intent (added custom terms that are going unused) or engaged
/// (≥5 dictations) — with the warm-hold nudge not armed and the cross-nudge
/// quiet period clear — it sets `AppGroup.vocabNudgeShouldShow` + posts
/// `vocabNudgeChanged`. The keyboard can't run that math (no vocabulary
/// store, no dictation history), so it renders this strip purely off the
/// boolean and writes the two terminal actions back via the controller
/// (deep-link to the app's Vocabulary screen / `AppGroup.vocabNudgeDeclined`).
///
/// This is the keyboard twin of `ParakeetUpgradeNudgeStrip` — same Liquid
/// Glass chrome, same one-shot behavior, same "app sets the boolean,
/// keyboard just renders" split. Render precedence is warm-hold › vocab ›
/// Parakeet (see `KeyboardView.topStrip`'s branch order), so it never shows
/// at the same time as either sibling.
struct VocabNudgeStrip: View {
    let reduceMotion: Bool
    let onSetUp: () -> Void
    let onDismiss: () -> Void
    let feedback: KeyboardFeedback

    /// Matches the recents / streaming / warm-hold / Parakeet-nudge card
    /// height so toggling this nudge in and out of the strip slot doesn't
    /// jump the keyboard layout.
    private static let stripHeight: CGFloat = 129

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get names & jargon spelled right.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.jotKeyboardActionsInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Text("Turn on Vocabulary so Jot learns your words.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.jotKeyboardStreamText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    feedback.systemClick()
                    feedback.selectionTick()
                    onSetUp()
                } label: {
                    Text("Set up")
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
                .accessibilityLabel("Set up Vocabulary")
                .accessibilityHint("Opens Jot's Vocabulary screen to turn on custom words")

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
        // Spring-in (matches the sibling nudges). Reduce Motion → plain fade.
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

    // Hardcoded brand blue top stop — identical to the sibling nudges'
    // accept buttons so this reads as the same primary surface.
    private static let pillTopBlue = Color(red: 0/255, green: 122/255, blue: 255/255)

    /// Same Liquid Glass recipe as the recents / streaming / sibling-nudge
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
