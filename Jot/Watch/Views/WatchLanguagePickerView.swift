import SwiftUI
import WatchKit

/// Digital-Crown dictation-language picker.
///
/// Reached from a quiet row under the Dictate hero on `RootView`. The user
/// spins the Crown to scroll `WatchLanguage.presentationOrder`; the centered
/// language name updates live (native endonym big, English name small). The
/// choice persists to `WatchLanguageStore` and is broadcast to the phone over
/// WCSession so the next watch-originated transcription uses it.
///
/// ## Crown mechanics
/// `.focusable()` + `.digitalCrownRotation` bound to a `Double` index over the
/// list. `from: 0 ... last, by: 1, sensitivity: .low, isContinuous: false`
/// gives one detent per language with the system's idiomatic crown haptic. We
/// round the live `Double` to the nearest index for display and commit, so a
/// partial spin still reads the closest language.
///
/// Styling matches the rest of the watch surface (`JotDesignWatchSafe` inks,
/// `WatchPillButton` for the confirm CTA). Light theme is the system default
/// on this surface — no forced dark.
struct WatchLanguagePickerView: View {
    @Environment(\.dismiss) private var dismiss

    private let languages = WatchLanguage.presentationOrder

    /// Crown-driven cursor over `languages`. A `Double` so the crown can move
    /// it smoothly; the displayed/committed language is `rounded`.
    @State private var crownValue: Double = 0
    @FocusState private var focused: Bool

    /// Nearest in-range language index for the current crown value.
    private var selectedIndex: Int {
        let i = Int(crownValue.rounded())
        return min(max(i, 0), languages.count - 1)
    }

    private var selected: WatchLanguage { languages[selectedIndex] }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            // Big centered language name — the crown's live read-out.
            VStack(spacing: 4) {
                Text(selected.nativeName)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: selectedIndex)

                if selected.nativeName != selected.englishName {
                    Text(selected.englishName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity)

            // Crown affordance: the brand-blue progress hint + a small position
            // read-out ("3 of 24") so the user knows the crown drives this.
            VStack(spacing: 6) {
                Image(systemName: "digitalcrown.arrow.clockwise.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JotDesignWatchSafe.jotBlueTop)
                Text("\(selectedIndex + 1) of \(languages.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            WatchPillButton(title: "Use this language") {
                commit(selected)
                WKInterfaceDevice.current().play(.success)
                dismiss()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Crown drives the index. `.focusable()` + focus on appear so the crown
        // is captured by this view without a tap.
        .focusable(true)
        .focused($focused)
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(languages.count - 1),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Start the crown at the currently-chosen language.
            let current = WatchLanguageStore.current
            if let idx = languages.firstIndex(of: current) {
                crownValue = Double(idx)
            }
            focused = true
        }
    }

    /// Persist locally + tell the phone. Called on confirm.
    private func commit(_ language: WatchLanguage) {
        WatchLanguageStore.current = language
        WatchConnectivityClient.shared.sendLanguageSelection(language)
    }
}
