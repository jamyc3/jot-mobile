import SwiftUI

/// Presented via the `jot://upgrade-engine` deep link — the destination of the
/// keyboard's Parakeet-upgrade nudge. Lets the user switch English dictation from
/// Apple's on-device engine to Jot's own (Parakeet), or explicitly keep Apple.
/// Tone mirrors `DonationCard` — plain, no dark patterns, no re-asking pressure.
///
/// Equivalent, always-available path: Settings → "Apple Dictation (English)"
/// toggle flips the same `AppGroup.useAppleDictationForEnglish` flag this screen's
/// primary button does — this screen is the nudge's one-tap shortcut into that
/// decision plus the copy explaining why.
///
/// The switch is instant when the Parakeet weights are already on device (bundled
/// build, carried-forward, or previously downloaded). On a stripped build where
/// the model isn't on disk, the switch queues a background, Wi-Fi + charging
/// download (`ParakeetModelFetcher`) and Jot auto-switches the engine when it
/// lands (`ParakeetModelArrival`) — so the tap is never a silent dead-end. See
/// docs/plans/parakeet-upgrade-nudge-download.md.
struct UpgradeEngineView: View {
    @Environment(\.dismiss) private var dismiss

    /// What to show, resolved from device/model/flag state on appear and whenever
    /// the background switch activates while this sheet is open.
    private enum Screen {
        case offerInstant       // weights on device → one-tap instant switch
        case offerDownload      // eligible, weights absent → queue background fetch
        case downloading        // a background fetch is in flight
        case switched           // already on Jot's engine (just switched, or auto)
        case ineligibleDevice   // device can't run Parakeet → keep Apple, honestly
        case lowDisk            // eligible device, not enough free space to download
        case failed             // download hit a terminal error → retriable
    }

    @State private var screen: Screen = .offerInstant
    @State private var activationObserver: CrossProcessNotification.Observer?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Color.jotInk)

                if screen == .downloading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(message)
                            .font(.system(.body))
                            .foregroundStyle(Color.jotMute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(message)
                        .font(.system(.body))
                        .foregroundStyle(Color.jotMute)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                primaryButton

                secondaryButton
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
        .onAppear {
            resolveScreen()
            if activationObserver == nil {
                activationObserver = CrossProcessNotification.addObserver(
                    name: CrossProcessNotification.parakeetEngineActivated
                ) {
                    resolveScreen()
                }
            }
        }
    }

    // MARK: - Copy (owner reviews these strings)

    private var title: String {
        switch screen {
        case .offerInstant, .offerDownload: return "More accurate dictation"
        case .downloading: return "Downloading the better engine"
        case .switched: return "You're on Jot's engine"
        case .ineligibleDevice: return "Staying on Apple's engine"
        case .lowDisk: return "Not enough free space"
        case .failed: return "Download didn't finish"
        }
    }

    private var message: String {
        switch screen {
        case .offerInstant:
            return "Jot's own on-device engine is more precise for English. Switch to it — it runs fully on-device, and Apple's engine stays as a fallback."
        case .offerDownload:
            return "Jot's own on-device engine is more precise for English. It's a one-time ~450 MB download — Jot grabs it in the background over Wi-Fi, usually while your phone charges, then switches you over automatically. Apple's engine keeps working until then."
        case .downloading:
            return "Downloading in the background over Wi-Fi, usually while your phone charges. Jot switches you over automatically when it's ready — Apple's engine keeps working until then."
        case .switched:
            return "English dictation now uses Jot's own on-device engine. You can switch back to Apple anytime in Settings."
        case .ineligibleDevice:
            return "Jot's own engine needs a newer iPhone or iPad to run well, so English dictation stays on Apple's on-device engine here — it's the best option on this device."
        case .lowDisk:
            return "Jot's own engine is a ~450 MB download and there isn't enough free space right now. Free up some space and try again — Apple's engine keeps working in the meantime."
        case .failed:
            return "Something interrupted the download of Jot's engine. You can try again — Apple's engine keeps working in the meantime."
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var primaryButton: some View {
        switch screen {
        case .offerInstant:
            filledButton("Use Jot's engine", action: switchInstant)
                .accessibilityHint("Switches English dictation to Jot's own on-device engine")
        case .offerDownload:
            filledButton("Download & switch automatically", action: startDownload)
                .accessibilityHint("Downloads Jot's engine over Wi-Fi and switches automatically")
        case .failed:
            filledButton("Try again", action: startDownload)
                .accessibilityHint("Retries the download of Jot's engine")
        case .lowDisk:
            // Re-check eligibility — if space was freed, this advances to the
            // download offer instead of dead-ending on "Done" (mirrors .failed).
            filledButton("Try again", action: retryResolve)
                .accessibilityHint("Re-checks free space and offers the download if there's now room")
        case .downloading, .switched, .ineligibleDevice:
            EmptyView()
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch screen {
        case .offerInstant, .offerDownload:
            // Explicit decline — permanent, mirrors the keyboard nudge's "Not now".
            plainButton("Keep Apple", action: keepApple)
                .accessibilityHint("Keeps Apple's dictation engine and dismisses this")
        case .downloading:
            // User-recoverable exit: cancel the fetch + keep Apple. (The toolbar
            // "Close" instead LEAVES the download running in the background.)
            plainButton("Stop download", action: stopDownload)
                .accessibilityHint("Cancels the download and keeps Apple's engine")
        case .failed:
            plainButton("Keep Apple", action: keepApple)
                .accessibilityHint("Keeps Apple's dictation engine and dismisses this")
        case .switched, .ineligibleDevice, .lowDisk:
            plainButton("Done") { dismiss() }
        }
    }

    private func filledButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule(style: .continuous).fill(Color.jotBlueTop))
        }
        .buttonStyle(.plain)
    }

    private func plainButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.body))
                .foregroundStyle(Color.jotMute)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - State resolution

    private func resolveScreen() {
        // Already on Jot's engine (switched here, or auto-switched after a
        // background download) → confirmation, whatever else is true.
        if !AppGroup.useAppleDictationForEnglish {
            screen = .switched
            return
        }
        if AppGroup.parakeetDownloadFailed {
            screen = .failed
            return
        }
        if AppGroup.parakeetDownloadPending {
            screen = .downloading
            return
        }
        if TranscriptionService.parakeetV2ReadyOnDevice() {
            screen = .offerInstant
            return
        }
        if !TranscriptionService.parakeetUsable {
            screen = .ineligibleDevice
            return
        }
        if !ParakeetModelFetcher.shared.hasEnoughFreeDisk {
            screen = .lowDisk
            return
        }
        screen = .offerDownload
    }

    // MARK: - Actions

    /// Weights already on device → flip instantly and show the confirmation in
    /// place (no silent dismiss / no-op). Clears the nudge and resets the Apple
    /// count so a later Apple re-enable doesn't instantly re-nudge.
    private func switchInstant() {
        AppGroup.useAppleDictationForEnglish = false
        AppGroup.showParakeetUpgradeNudge = false
        DictationStats.resetAppleDictationCount()
        CrossProcessNotification.post(name: CrossProcessNotification.parakeetUpgradeNudgeChanged)
        withAnimation { screen = .switched }
    }

    /// Weights absent → queue the background, Wi-Fi download and move to the
    /// "downloading" state. Only flips to `.downloading` if the fetch actually
    /// started (Fix 7 — a filesystem/staging failure surfaces `.failed` instead of
    /// a fake "downloading"). `ParakeetModelArrival` applies the switch + posts the
    /// confirmation when it lands.
    private func startDownload() {
        AppGroup.parakeetDownloadFailed = false
        if ParakeetModelFetcher.shared.requestBackgroundDownload() {
            withAnimation { screen = .downloading }
        } else {
            withAnimation { screen = .failed }
        }
    }

    /// "Stop download" — cancel the in-flight fetch, drop staged files, keep
    /// Apple, and re-resolve so the sheet offers a fresh download (recoverable).
    private func stopDownload() {
        ParakeetModelFetcher.shared.stopDownload()
        withAnimation { resolveScreen() }
    }

    /// "Try again" from `.lowDisk` — re-evaluate eligibility (disk may have been
    /// freed); advances to `.offerDownload` when there's now room.
    private func retryResolve() {
        withAnimation { resolveScreen() }
    }

    /// Explicitly keep Apple's engine — permanent decline, mirrors the keyboard
    /// nudge's "Not now" dismissal.
    private func keepApple() {
        AppGroup.parakeetNudgeDeclined = true
        CrossProcessNotification.post(name: CrossProcessNotification.parakeetUpgradeNudgeChanged)
        dismiss()
    }
}

#Preview {
    UpgradeEngineView()
}
