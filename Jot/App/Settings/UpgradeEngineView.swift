import SwiftUI

/// Presented via the `jot://upgrade-engine` deep link — the destination of
/// the keyboard's Parakeet-upgrade nudge (deferred-engineering follow-up to
/// the Apple Dictation A/B spike; see `ParakeetUpgradeNudgeStrip`). Lets the
/// user switch English dictation from Apple's on-device engine to Jot's own
/// (Parakeet), or explicitly keep Apple. Tone mirrors `DonationCard` — plain,
/// no dark patterns, no re-asking pressure.
///
/// Equivalent, always-available path: Settings → "Apple Dictation (English)"
/// toggle already flips the same `AppGroup.useAppleDictationForEnglish` flag
/// this screen's primary button does — this screen is just the nudge's
/// one-tap shortcut into that same decision, plus the copy explaining why.
///
/// NOTE: Parakeet 600M is currently BUNDLED (already on device), so the
/// switch below is INSTANT — there is no download step. When the bundle is
/// stripped later (deferred-engineering), this screen will need a
/// download-progress state before flipping the toggle.
struct UpgradeEngineView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("More accurate dictation")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Color.jotInk)

                Text("Jot's own on-device engine is more precise for English. Switch to it — it runs fully on-device, and Apple's engine stays as a fallback.")
                    .font(.system(.body))
                    .foregroundStyle(Color.jotMute)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(action: useJotsEngine) {
                    Text("Use Jot's engine")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule(style: .continuous).fill(Color.jotBlueTop))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Switches English dictation to Jot's own on-device engine")

                Button(action: keepApple) {
                    Text("Keep Apple")
                        .font(.system(.body))
                        .foregroundStyle(Color.jotMute)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Keeps Apple's dictation engine and dismisses this permanently")
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Switch English dictation to Jot's own Parakeet engine. Instant — no
    /// download (Parakeet 600M is bundled; see the file-level NOTE). Clears
    /// the nudge terminally, the same App-Group flag the keyboard's own
    /// "Switch" tap already cleared before deep-linking here.
    private func useJotsEngine() {
        AppGroup.useAppleDictationForEnglish = false
        AppGroup.showParakeetUpgradeNudge = false
        // Reset the Apple-dictation count so re-enabling Apple later doesn't
        // instantly re-nudge (Opus nudge review E2).
        DictationStats.resetAppleDictationCount()
        CrossProcessNotification.post(name: CrossProcessNotification.parakeetUpgradeNudgeChanged)
        dismiss()
    }

    /// Explicitly keep Apple's engine — permanent decline, mirrors the
    /// keyboard nudge's "Not now" dismissal.
    private func keepApple() {
        AppGroup.parakeetNudgeDeclined = true
        CrossProcessNotification.post(name: CrossProcessNotification.parakeetUpgradeNudgeChanged)
        dismiss()
    }
}

#Preview {
    UpgradeEngineView()
}
