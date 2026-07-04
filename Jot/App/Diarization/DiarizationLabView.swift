import SwiftUI

/// Settings → About → "Diarization Lab" — the experimental speaker-diarization
/// hub. Revealed by the same 5-tap-on-Version gesture as the TTS Lab (see
/// `SettingsView.handleVersionTap`). Explains the feature, shows the model
/// download state, and shows/rebuilds the owner voice profile used to
/// auto-label "You" in a diarized recording.
///
/// The actual diarize action lives in `TranscriptDetailView` ("Detect
/// speakers", next to Re-transcribe) — this screen is configuration/status,
/// not where you run it, mirroring the Mac design's "no toggle, just an
/// explainer + status" philosophy for an on-demand, no-background-cost feature.
struct DiarizationLabView: View {
    @State private var modelState: DiarizerHolder.ModelState = .notLoaded
    @State private var isBuildingVoiceprint = false
    @State private var voiceprintProgress: (done: Int, total: Int)?
    @State private var builtFromCount = OwnerVoiceprintStore.builtFromCount
    @State private var builtAt: Date? = OwnerVoiceprintStore.builtAt

    var body: some View {
        ZStack(alignment: .top) {
            WallpaperBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    LiquidGlassCard(paddingH: 0, paddingV: 0) { modelRow }
                    LiquidGlassCard(paddingH: 0, paddingV: 0) { voiceprintRow }
                    attribution
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .task {
            async let prepare: Void = DiarizerHolder.shared.prepareIfNeeded()
            // The actor has no observation hook, so poll its state while a
            // download/load is in flight — otherwise the progress bar never
            // animates and the row just silently jumps from "Not downloaded
            // yet" straight to "Ready" once `prepareIfNeeded()` returns.
            while true {
                modelState = await DiarizerHolder.shared.modelState
                if case .ready = modelState { break }
                if case .failed = modelState { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            await prepare
            modelState = await DiarizerHolder.shared.modelState
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diarization Lab")
                .font(JotType.rowTitle).tracking(-0.2)
                .foregroundStyle(Color.jotPageInk)
            Text("Experimental. Figures out who said what in a recording, entirely on-device. Open any recording and tap \u{201C}Detect speakers.\u{201D}")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemImage: "person.wave.2",
                tint: JotDesign.JotSemanticIcon.version,
                shaded: JotDesign.JotSemanticIcon.versionShaded
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Diarization model").font(JotType.rowTitle).tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)
                Text(modelSubline).font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
            Spacer(minLength: 12)
            if case .downloading(let fraction) = modelState {
                ProgressView(value: fraction).frame(width: 40)
            } else if case .loading = modelState {
                ProgressView()
            } else if case .ready = modelState {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if case .failed = modelState {
                Button("Retry") { Task { await retryModel() } }
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var modelSubline: String {
        switch modelState {
        case .notLoaded: return "Not downloaded yet"
        case .downloading(let f): return "Downloading… \(Int(f * 100))%"
        case .loading: return "Preparing…"
        case .ready: return "Ready — ~22 MB, on-device"
        case .failed(let message): return "Couldn't download: \(message)"
        }
    }

    private func retryModel() async {
        async let prepare: Void = DiarizerHolder.shared.prepareIfNeeded()
        while true {
            modelState = await DiarizerHolder.shared.modelState
            if case .ready = modelState { break }
            if case .failed = modelState { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await prepare
    }

    @ViewBuilder
    private var voiceprintRow: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemImage: "person.fill.checkmark",
                tint: JotDesign.JotSemanticIcon.version,
                shaded: JotDesign.JotSemanticIcon.versionShaded
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Your voice profile").font(JotType.rowTitle).tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)
                Text(voiceprintSubline).font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
            }
            Spacer(minLength: 12)
            if isBuildingVoiceprint {
                ProgressView()
            } else {
                Button("Rebuild") { rebuildVoiceprint() }
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var voiceprintSubline: String {
        if isBuildingVoiceprint, let p = voiceprintProgress {
            return "Building from your recent recordings… (\(p.done)/\(p.total))"
        }
        if builtFromCount > 0 {
            return "Built from \(builtFromCount) of your recent solo recordings. Everyone else in a recording renders as \u{201C}Speaker 2\u{201D}, \u{201C}Speaker 3\u{201D}, etc."
        }
        return "Not built yet — needs a few solo recordings from the last 3 days (source audio is only kept that long). Until then every speaker renders anonymously."
    }

    private func rebuildVoiceprint() {
        guard !isBuildingVoiceprint else { return }
        isBuildingVoiceprint = true
        voiceprintProgress = nil
        Task {
            await OwnerVoiceprintStore.build { done, total in
                voiceprintProgress = (done, total)
            }
            isBuildingVoiceprint = false
            builtFromCount = OwnerVoiceprintStore.builtFromCount
            builtAt = OwnerVoiceprintStore.builtAt
        }
    }

    private var attribution: some View {
        Text("Speaker diarization model: pyannote community-1 (CC-BY-4.0), via FluidAudio. Runs fully on-device — nothing is ever uploaded.")
            .font(.system(size: 11.5))
            .foregroundStyle(Color.jotPageInkSecondary.opacity(0.8))
            .padding(.horizontal, 4)
    }
}
