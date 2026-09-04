import FluidAudio
import Foundation
import Observation
import UIKit
import os.log

/// **The English dictation backend**: Parakeet Unified 0.6B (English only).
///
/// ## What this is
///
/// A different model from the bundled `parakeet-tdt-0.6b-v2` — FluidAudio's
/// `FluidInference/parakeet-unified-en-0.6b-coreml`. On FluidAudio's own
/// LibriSpeech test-clean run (`Unified/benchmark.md`) it measures:
///
/// | model                  | avg WER | overall RTFx | punctuation | languages |
/// |------------------------|---------|--------------|-------------|-----------|
/// | Parakeet TDT v3        | 2.6%    | 110          | no          | 25 + ja   |
/// | **Unified (batch)**    | 2.15%   | 123          | yes         | English   |
/// | Unified (streaming)    | 2.21%   | 29           | yes         | English   |
///
/// We use the **STREAMING** variant (`StreamingUnifiedAsrManager`).
///
/// ## Why streaming, despite batch's better WER
///
/// Batch was the first choice — 2.15% vs 2.21% — but the model decodes natively
/// as audio arrives, and that changes two things the WER column doesn't show:
///
/// 1. **No stop-pass.** `finish()` flushes the tail and returns a transcript
///    that is already built, so stopping is instant regardless of recording
///    length. The batch path re-transcribes the entire recording at stop.
/// 2. **Token timings come back.** `consumeTokenTimings()` restores BOTH
///    timing-dependent features the batch API silently loses: paragraph
///    segmentation (pause-based) and the acoustic vocabulary merge (needs word
///    spans).
///
/// The 0.06-point WER cost is ~1 extra error per 1600 words. Paragraphs, the
/// acoustic vocab boost, and an instant stop are worth more than that.
///
/// ## Cost, and why it is gated
///
/// The int8 streaming set is ~582 MB on disk (encoder 564.1 + decoder 13.8 +
/// joint 3.3 + preprocessor 0.6 + vocab/metadata), and the encoder is resident
/// while loaded. Note the decoder/joint/preprocessor/vocab are SHARED with the
/// offline set, so a user who already fetched the batch variant only pays for
/// the streaming encoder.
///
/// Latency: FluidAudio 0.15.4 exposes only the `70_13_13` window, so live
/// partials trail speech by ~2.08 s (see `UnifiedStreamingSession`).
///
/// int8 rather than fp16 on FluidAudio's own measurement: identical WER
/// (1.83% vs 1.82% offline), identical ANE latency, half the download.
///
/// ## Default since build 297 — and what that changed
///
/// Owner call: this IS the English engine now, not a switch to find. Three
/// consequences, all of them deliberate:
///
/// 1. **No toggle.** The Settings→About test switch is gone. English routing is
///    decided the way every other engine choice is — by Jot, from the language
///    and the device (`features.md` §6.1: no engine selector in normal use).
///    The escape hatch is the existing "Use Apple speech engine" preference,
///    which `isOfferedForCurrentLanguage` honours.
/// 2. **The download starts by itself** (`syncWithRouting()`), discretionary and
///    Wi-Fi-only — see `UnifiedModelFetcher`.
/// 3. **Nothing changes until the model is on disk AND loaded.** `isActive` is
///    still fully conjunctive, so between install and first-successful-load
///    English silently runs the bundled v2 path exactly as before. That is the
///    whole migration: there is no cliff, only a quality step when it lands.
@MainActor
@Observable
final class UnifiedEnglishModel {
    static let shared = UnifiedEnglishModel()

    /// Kill switch, on the App Group for consistency with every other dictation
    /// setting (the keyboard does not read it — the keyboard never transcribes).
    ///
    /// **Opt-OUT, not opt-in**: absent (the default) means this model runs. It is
    /// inverted rather than defaulted-true so that "unset" and "the user said no"
    /// are the same bit as before — the old opt-IN key `jot.dictation.unifiedEnglish`
    /// could not tell an explicit OFF from a never-touched default anyway (the
    /// toggle wrote `false` for both), so no tester's choice is being discarded
    /// that was ever readable. That old key is now ignored; a stale value is
    /// harmless.
    ///
    /// Nothing in the UI writes this today (the toggle it replaces is gone). It
    /// exists so a bad build can be taken off this engine from a debug build or
    /// a one-line Settings row without shipping an engine rollback.
    static let optOutKey = "jot.dictation.unifiedEnglish.optOut"

    enum State: Equatable {
        case notDownloaded
        /// `fraction` is [0,1]; `phase` is FluidAudio's own label, surfaced so a
        /// stalled unpack is distinguishable from a stalled download.
        case downloading(fraction: Double, phase: String)
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded

    private let log = Logger(subsystem: "com.vineetu.jot.mobile", category: "UnifiedEnglish")
    private var manager: StreamingUnifiedAsrManager?
    private var prepareTask: Task<Void, Never>?

    private init() {
        // `state` starts at `.notDownloaded` in every case, on-disk or not: it
        // tracks THIS PROCESS's model, and a fresh process has none loaded.
        // (An "installed but not loaded" case would need its own state; nothing
        // needs to distinguish it today — `isInstalledOnDisk` answers that
        // question directly wherever it actually matters, e.g. the Settings
        // status line.)
        subscribeMemoryWarnings()
    }

    // MARK: - Availability

    /// Does English dictation route here on this device, right now?
    ///
    /// English-only is the owner's requirement and also the model's: it is an
    /// English-only checkpoint, so using it elsewhere would be a downgrade, not
    /// a choice.
    ///
    /// The second clause is deliberately `activeLanguageUsesApple` rather than a
    /// device check of its own. That one predicate already answers "does this
    /// language run on Jot's own engine here" — it is false when the user picked
    /// Apple's engine, and false on hardware where Parakeet can't run at all. So
    /// this cannot claim a dictation Apple is going to serve, and — because the
    /// auto-download hangs off the same predicate — it cannot spend 582 MB on a
    /// device or a preference that would never use the model.
    ///
    /// The third clause is not a nicety: this model has NO batch path. It only
    /// ever transcribes through `UnifiedStreamingSession`, and with live text
    /// off `RecordingService.kickOffStreamingSession` returns `.skipped` before
    /// any session is built — so the promote would never fire and every English
    /// dictation would fall to v2 anyway. Without this clause the app would
    /// download 582 MB and load an encoder it is structurally unable to use.
    /// (Ask/voice-prompt captures are exempt from the live-text gate over
    /// there, but they are not a reason to hold this model resident.)
    static var isOfferedForCurrentLanguage: Bool {
        LanguageChoice.current.isEnglish
            && !TranscriptionService.activeLanguageUsesApple
            && DeviceCapability.liveTextEnabled
    }

    /// Kill switch state — see `optOutKey`. NOT enough on its own to route
    /// traffic here; `isActive` also requires the model to be loaded.
    static var isEnabled: Bool {
        get { !AppGroup.defaults.bool(forKey: optOutKey) }
        set { AppGroup.defaults.set(!newValue, forKey: optOutKey) }
    }

    /// The single gate the transcription path checks. Deliberately conjunctive:
    /// the default being ON means most users reach this line with NO model on
    /// disk, and they must fall through to the bundled v2 engine rather than
    /// fail the dictation.
    var isActive: Bool {
        Self.isEnabled && Self.isOfferedForCurrentLanguage && state == .ready && manager != nil
    }

    /// Bring the model in line with the CURRENT routing. The one entry point:
    /// app launch, a dictation-language change, and the Apple-engine preference
    /// all call this rather than re-deriving the gate (same discipline as
    /// `TranscriptionService.warmIfNeeded()`).
    ///
    /// Eligible → re-attach the background fetch, then `prepare()`, which
    /// downloads if needed and loads. Not eligible → drop the ~568 MB encoder;
    /// it is pure resident cost for a language that won't use it. `unload()`
    /// keeps the files, so switching back is a load, not a re-download.
    static func syncWithRouting() {
        guard isEnabled, isOfferedForCurrentLanguage else {
            // Drop only a model that is actually RESIDENT. A prepare still in
            // flight is deliberately left to finish: cancelling it strands the
            // continuation waiting on the fetcher (the background session keeps
            // downloading either way), and `prepareTask` would then stay non-nil
            // and block a later re-prepare. That would leave the encoder
            // resident for a routing that no longer wants it, so `prepare()`'s
            // success tail re-checks this same gate and drops it there — this
            // branch and that one together cover both orderings.
            if shared.state == .ready { shared.unload() }
            return
        }
        // Re-attach FIRST: a fetch that finished (or is still running) while the
        // app was closed must be installed rather than stranded, so `prepare()`
        // then finds a complete tree instead of starting over.
        UnifiedModelFetcher.shared.resumeIfPending()
        shared.prepare()
    }

    // MARK: - Install location

    /// Where FluidAudio caches its repos. Mirrors `UnifiedAsrManager`'s own
    /// default so a model fetched by either path is found by both.
    private static var modelsBaseDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static var installDirectory: URL {
        modelsBaseDirectory.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    /// Is a **loadable, complete** model on disk?
    ///
    /// Delegates to `UnifiedModelFetcher`, which verifies every one of the 19
    /// manifest files at its exact byte size. Deliberately NOT `fileExists` on
    /// the `.mlmodelc`: that is a DIRECTORY, so it returns true from the first
    /// byte — which is how build 294 reported a truncated 563 MB weights file as
    /// installed and then died in CoreML with "Compile the model with Xcode".
    static var isInstalledOnDisk: Bool { UnifiedModelFetcher.shared.isInstalled }

    /// Exact download size, summed from the fetcher's pinned manifest — so the
    /// number in Settings can never drift from what is actually fetched.
    static var approximateDownloadBytes: Int64 { UnifiedModelFetcher.totalBytes }

    // MARK: - Prepare

    /// Download (if needed) and load. Idempotent and single-flight: a second
    /// call while a prepare is in flight joins the existing one rather than
    /// starting a competing ~586 MB fetch.
    func prepare() {
        guard prepareTask == nil else { return }
        if case .ready = state { return }

        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer { self.prepareTask = nil }

            let alreadyOnDisk = Self.isInstalledOnDisk
            self.state = alreadyOnDisk ? .loading : .downloading(fraction: 0, phase: "starting")

            // Mirror the fetcher's real byte counts into the row's state. Set
            // BEFORE `download()` installs its own completion observer, and
            // deliberately additive: `download()` replaces `onPhaseChange`, so
            // this closure is re-installed there via `progressObserver`.
            Self.progressObserver = { [weak self] phase in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = self.state { return }
                    if case .failed = self.state { return }
                    switch phase {
                    case .downloading(let done, let total):
                        self.state = .downloading(
                            fraction: total > 0 ? Double(done) / Double(total) : 0,
                            phase: "\(done / 1_048_576) of \(total / 1_048_576) MB"
                        )
                    case .installing:
                        self.state = .downloading(fraction: 1, phase: "installing")
                    case .idle, .done, .failed:
                        break
                    }
                }
            }
            self.log.info(
                "Unified English prepare begin — onDisk=\(alreadyOnDisk, privacy: .public)"
            )

            do {
                // DOWNLOAD via our own BACKGROUND session, not FluidAudio's
                // `loadModels(to:progressHandler:)`. That helper uses a
                // foreground `URLSession`, which iOS suspends the instant the app
                // backgrounds or the phone locks — and on a 563 MB weights file
                // that reliably produced a truncated `.mlmodelc` that CoreML
                // refused to load. See `UnifiedModelFetcher`.
                if !alreadyOnDisk {
                    try await Self.download()
                }
                // Now load from disk. `loadModels(from:)` does NO network work,
                // so by this point every byte is verified present.
                let manager = StreamingUnifiedAsrManager()
                self.state = .loading
                try await manager.loadModels(from: Self.installDirectory)
                self.manager = manager
                self.state = .ready
                self.log.info("Unified English ready")
                // TAIL RE-CHECK. This task can run for hours (582 MB on a
                // discretionary session), and `syncWithRouting()` deliberately
                // leaves an in-flight prepare alone rather than cancelling it —
                // so the language, the engine preference or the live-text
                // setting may all have moved while we were loading. Re-read the
                // gate here and drop the encoder immediately if it is no longer
                // wanted; otherwise ~568 MB would sit resident until the next
                // sync. `dropLoadedModel` (not `unload`) because cancelling
                // `prepareTask` from inside its own task would self-cancel.
                if !Self.isEnabled || !Self.isOfferedForCurrentLanguage {
                    self.dropLoadedModel(reason: "routing changed during prepare")
                }
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .modelLoad,
                    message: "Parakeet Unified (English) ready",
                    metadata: ["downloadedThisCall": "\(!alreadyOnDisk)"]
                )
            } catch is CancellationError {
                // Teardown, not a failure. Leave the state alone so the row does
                // not flash an error on a benign cancel.
                self.log.info("Unified English prepare cancelled")
            } catch {
                self.manager = nil
                // SELF-HEAL. The overwhelmingly likely failure is a truncated
                // encoder (iOS suspends a foreground download when the app
                // backgrounds or the phone locks, and this is a 563 MB file).
                // CoreML then reports "Compile the model with Xcode…". Since
                // FluidAudio's re-download gate is `fileExists` on the bundle
                // DIRECTORY, leaving the wreckage in place makes the failure
                // permanent — every retry skips the fetch and re-fails. Deleting
                // it is what makes "Try again" mean anything.
                // SELF-HEAL: clear a partial or corrupt tree so the next attempt
                // genuinely re-downloads. `UnifiedModelFetcher.reset()` wipes
                // staging AND any incomplete install — without it a truncated
                // bundle would be retried forever, which is the trap build 294
                // fell into.
                let wasIncomplete = !UnifiedModelFetcher.shared.isInstalled
                if wasIncomplete { UnifiedModelFetcher.shared.reset() }
                self.state = .failed(Self.friendlyMessage(for: error, incomplete: wasIncomplete))
                self.log.error(
                    "Unified English prepare FAILED — incompleteEncoder=\(wasIncomplete, privacy: .public) \(String(describing: error), privacy: .public)"
                )
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .modelLoad,
                    message: "Parakeet Unified (English) failed",
                    metadata: [
                        "error": "\(error)",
                        "incompleteEncoder": "\(wasIncomplete)",
                        "cleared": "\(wasIncomplete)",
                    ]
                )
            }
        }
    }

    /// Run the background fetch to completion.
    ///
    /// Bridges `UnifiedModelFetcher`'s callback phases into `async`. The download
    /// itself is owned by a background `URLSession`, so it keeps running even if
    /// this continuation's task is torn down — a resumed `prepare()` re-attaches
    /// rather than restarting.
    /// UI-facing progress mirror, installed by `prepare()` and invoked from
    /// `download()`'s own handler so a single `onPhaseChange` slot serves both.
    nonisolated(unsafe) private static var progressObserver: ((UnifiedModelFetcher.Phase) -> Void)?

    private static func download() async throws {
        let fetcher = UnifiedModelFetcher.shared
        if fetcher.isInstalled { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false
            fetcher.onPhaseChange = { phase in
                Self.progressObserver?(phase)
                guard !finished else { return }
                switch phase {
                case .done:
                    finished = true
                    fetcher.onPhaseChange = nil
                    cont.resume()
                case .failed(let message):
                    finished = true
                    fetcher.onPhaseChange = nil
                    cont.resume(throwing: FetchError.message(message))
                case .idle, .downloading, .installing:
                    // Progress is mirrored into `state` by the observer installed
                    // in `prepare()`; nothing to resume on yet.
                    break
                }
            }
            if !fetcher.start(), !finished {
                finished = true
                fetcher.onPhaseChange = nil
                cont.resume(throwing: FetchError.message("Couldn't start the download."))
            }
        }
    }

    enum FetchError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): return m }
        }
    }

    /// Release the loaded encoder WITHOUT touching `prepareTask`.
    ///
    /// Split out of `unload()` for the two callers that must NOT cancel the
    /// prepare task: `prepare()`'s own success tail (cancelling from inside the
    /// task would self-cancel) and the memory-warning hook (which must not kill
    /// an in-flight download). The on-disk files are always KEPT — coming back
    /// should be a load, not a 582 MB fetch.
    private func dropLoadedModel(reason: String) {
        guard manager != nil else { return }
        let outgoing = manager
        manager = nil
        state = .notDownloaded
        Task.detached { await outgoing?.cleanup() }
        log.info("Unified English dropped — \(reason, privacy: .public) (files kept on disk)")
    }

    /// Drop the loaded model AND abandon any prepare in flight. Called by
    /// `syncWithRouting()` when English stops routing here (another dictation
    /// language, the Apple engine, live text off), so the ~568 MB encoder does
    /// not stay resident for a model no longer in use.
    func unload() {
        prepareTask?.cancel()
        prepareTask = nil
        dropLoadedModel(reason: "unload")
        state = .notDownloaded
    }

    // MARK: - Memory pressure

    /// Exempted from observation (nothing renders it) and from isolation the
    /// same way `TranscriptionService`'s twin is: written once from `init` on
    /// the MainActor, never concurrently. (Unlike the twin there is no
    /// `deinit` reader — `shared` is a process-lifetime singleton, so the
    /// observer is deliberately never removed.)
    @ObservationIgnored
    private nonisolated(unsafe) var memoryWarningObserver: NSObjectProtocol?

    private func subscribeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    /// Is a capture (or the pipeline behind one) live right now?
    ///
    /// Deliberately NOT `TranscriptionService.isBusy` alone. That flag covers
    /// the STOP-PASS, which is exactly the window this model does not have —
    /// it decodes DURING the recording and promotes at stop, so `isBusy` is
    /// false for the entire time the encoder is actually in use.
    private static var recordingInFlight: Bool {
        let recorder = RecordingService.shared
        return recorder.isRecording
            || recorder.isStopInFlight
            || recorder.isPipelineInFlight
            || TranscriptionService.shared.isBusy
    }

    /// Evict the ~568 MB encoder under memory pressure, mirroring
    /// `TranscriptionService.handleMemoryWarning` — without this, the single
    /// largest resident graph in the app was the one thing exempt from the
    /// jetsam-avoidance path.
    ///
    /// KNOWN LIMIT: mid-recording the live `UnifiedStreamingSession` actor
    /// holds its own strong reference to the manager, so evicting here would
    /// free nothing until that session tears down — which is a second reason
    /// (besides not breaking the dictation) to skip while a capture is live.
    /// The useful window is idle-resident, which is also the long one.
    ///
    /// No automatic re-load: recovery is the next `syncWithRouting()` (launch,
    /// language change, engine toggle). Until then English falls back to the
    /// bundled v2 path exactly as it does pre-download.
    private func handleMemoryWarning() {
        let busy = Self.recordingInFlight
        DiagnosticsLog.record(
            source: "main-app",
            category: .memoryWarning,
            message: "unified English service received memory warning",
            metadata: [
                "hasManager": "\(manager != nil)",
                "recordingInFlight": "\(busy)",
            ]
        )
        guard !busy else {
            log.notice("Memory warning received mid-capture — deferring unified eviction")
            return
        }
        dropLoadedModel(reason: "memory warning")
    }

    /// CoreML's own text here is a 200-character `file:///private/var/mobile/...`
    /// path ending in "Compile the model with Xcode" — accurate, and useless to
    /// the person holding the phone. Say what actually happened and what to do.
    private static func friendlyMessage(for error: Error, incomplete: Bool) -> String {
        if incomplete {
            return "The download didn't finish, so the model couldn't load. "
                + "Tap Try again — it will pick up where it left off."
        }
        return "Couldn't load the model. \(error.localizedDescription)"
    }

    // MARK: - Inference

    /// Transcribe with the unified batch model.
    ///
    /// Returns plain text — the caller wraps it into an `ASRResult` so the
    /// existing post-pipeline (vocabulary rescore, segmentation, filler
    /// cleanup, number normalization) runs completely unmodified.
    /// Build a live session for one recording slice.
    ///
    /// Returns nil when the model isn't loaded, so the caller can fall back to
    /// the normal engine instead of failing the dictation.
    ///
    /// The manager is a single shared instance, so it MUST be reset between
    /// slices — otherwise slice two would decode on top of slice one's state and
    /// emit the previous recording's words.
    func makeSession(
        queue: StreamingBufferQueue,
        presenter: StreamingPartial,
        sessionID: UUID
    ) async -> UnifiedStreamingSession? {
        guard let manager else { return nil }
        do {
            try await manager.reset()
        } catch {
            log.error("Unified reset failed — \(String(describing: error), privacy: .public)")
            return nil
        }
        return UnifiedStreamingSession(
            manager: manager, queue: queue, presenter: presenter, sessionID: sessionID
        )
    }
}
