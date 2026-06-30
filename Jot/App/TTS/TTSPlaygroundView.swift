import AVFoundation
import SwiftUI
import UIKit
import FluidAudio

/// Settings → About → "Text to Speech" — the on-device TTS Playground.
///
/// Type text, pick a synthesis language + voice, generate speech entirely on
/// this iPhone, play it back, and export a shareable audio file. Replaces the
/// hidden "TTS Lab" toggle and the transcript read-aloud entry points.
///
/// Engine routing (see `TTSService`):
///   * English presets → Supertonic-3 (the 10 bundled high-quality voices).
///   * Cloned voices → PocketTTS in the SELECTED language (a clone speaks any of
///     the six — its conditioning is language-agnostic).
///   * Non-English languages currently rely on cloned voices (PocketTTS pack
///     preset voices are a documented follow-up).
///
/// All synthesis + playback is on-device; nothing is uploaded. Export writes an
/// AAC `.m4a` (WAV fallback) and hands it to the system share sheet.
struct TTSPlaygroundView: View {

    /// The six user-facing synthesis languages, mapped to `PocketTtsLanguage`.
    /// French ships only a 24-layer pack (no base), so it maps to `.french24L`.
    enum Language: String, CaseIterable, Identifiable {
        case english, french, german, italian, portuguese, spanish

        var id: String { rawValue }

        var label: String {
            switch self {
            case .english: return "English"
            case .french: return "French"
            case .german: return "German"
            case .italian: return "Italian"
            case .portuguese: return "Portuguese"
            case .spanish: return "Spanish"
            }
        }

        var pocket: PocketTtsLanguage {
            switch self {
            case .english: return .english
            case .french: return .french24L   // French is 24-layer only.
            case .german: return .german
            case .italian: return .italian
            case .portuguese: return .portuguese
            case .spanish: return .spanish
            }
        }

        var isEnglish: Bool { self == .english }
    }

    /// The voice to select for a given language: English defaults to the first
    /// Supertonic preset; every other language defaults to its native built-in
    /// PocketTTS voice (cloning is English-only).
    static func defaultVoice(for language: Language) -> TTSVoice {
        language.isEnglish
            ? TTSService.defaultVoice
            : (TTSService.pocketPresetVoices(for: language.pocket).first ?? TTSService.defaultVoice)
    }

    @State private var ttsService = TTSService.shared

    @State private var text: String = ""
    @State private var language: Language = .english
    @State private var selectedVoice: TTSVoice = TTSService.defaultVoice
    @State private var showVoicePicker = false

    /// Generation / playback lifecycle.
    @State private var generateTask: Task<Void, Never>?
    @State private var hasGenerated = false
    @State private var generateError: String?

    /// Export lifecycle.
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false

    @FocusState private var textFocused: Bool

    private static let placeholder =
        "The northern lights spilled green across the sky while we waited, breath fogging, for the tide to turn."

    var body: some View {
        ZStack {
            WallpaperBackground().ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    textSection
                    languageSection
                    voiceSection
                    generateButton
                    if ttsService.isDownloadingPack {
                        downloadCard
                    }
                    if (hasGenerated || ttsService.isSpeaking) && !ttsService.isDownloadingPack {
                        previewSection
                    }
                    if let generateError {
                        errorCard(generateError)
                    }
                    exportButton
                    caption
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 8)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.liquidGlassShadowScale, 0.5)
        .sheet(isPresented: $showVoicePicker) {
            TTSVoicePickerView(language: language, selected: $selectedVoice)
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .onChange(of: language) { _, newValue in
            // The voice set differs by language: English = Supertonic presets +
            // your clones; other languages = that pack's built-in voices (cloning
            // is English-only). On a language switch, reset to that language's
            // first voice so the selection is always valid.
            selectedVoice = Self.defaultVoice(for: newValue)
            resetPlayback()
        }
        .onChange(of: selectedVoice) { _, _ in resetPlayback() }
        .onDisappear {
            generateTask?.cancel()
            ttsService.stop()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Text to Speech")
                .font(JotType.displaySerif(40))
                .tracking(-1.4)
                .foregroundStyle(Color.jotPageInk)
                .accessibilityAddTraits(.isHeader)
            Text("Type anything, choose a voice, and Jot speaks it — entirely on this iPhone. Then export the audio.")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("YOUR TEXT")
            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.placeholder)
                            .font(.system(size: 15.5, design: .serif))
                            .foregroundStyle(Color.jotPageInkSecondary.opacity(0.6))
                            .lineSpacing(4)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 15.5, design: .serif))
                        .foregroundStyle(Color.jotPageInk)
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 92)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .focused($textFocused)
                }
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("LANGUAGE")
            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                HStack(spacing: 14) {
                    IconTile(
                        systemImage: "globe",
                        tint: JotDesign.JotSemanticIcon.speechModel,
                        shaded: JotDesign.JotSemanticIcon.speechModelShaded
                    )
                    Text("Spoken language")
                        .font(JotType.rowTitle)
                        .tracking(-0.2)
                        .foregroundStyle(Color.jotPageInk)
                    Spacer(minLength: 12)
                    Picker("Language", selection: $language) {
                        ForEach(Language.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.jotAccent)
                    .accessibilityLabel("Spoken language")
                }
                .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
                .padding(.vertical, 13)
                .frame(minHeight: 44)
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("VOICE")
            Button {
                textFocused = false
                showVoicePicker = true
            } label: {
                LiquidGlassCard(paddingH: 0, paddingV: 0) {
                    HStack(spacing: 14) {
                        VoiceAvatar(voice: selectedVoice)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedVoice.label)
                                .font(JotType.rowTitle)
                                .tracking(-0.2)
                                .foregroundStyle(Color.jotPageInk)
                            Text(voiceSubline)
                                .font(JotType.rowSub)
                                .foregroundStyle(Color.jotPageInkSecondary)
                        }
                        Spacer(minLength: 12)
                        RowChevron()
                    }
                    .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
                    .padding(.vertical, 13)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice: \(selectedVoice.label). Tap to change.")
        }
    }

    private var voiceSubline: String {
        if selectedVoice.isCloned { return "Your cloned voice · tap to change" }
        if selectedVoice.isPocketPreset { return "Built-in \(language.label) voice · tap to change" }
        return "Bundled preset · tap to change"
    }

    /// One-time language-pack download progress, shown on the first Generate in
    /// a not-yet-downloaded language (FR/DE/IT/PT/ES). The pack downloads once,
    /// then runs entirely on-device.
    @ViewBuilder
    private var downloadCard: some View {
        let pct = Int((ttsService.packDownloadFraction * 100).rounded())
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).tint(Color.jotAccent)
                    Text("Downloading \(language.label) voices… \(pct)%")
                        .font(JotType.rowTitle)
                        .tracking(-0.2)
                        .foregroundStyle(Color.jotPageInk)
                }
                ProgressView(value: ttsService.packDownloadFraction)
                    .tint(Color.jotAccent)
                Text("One-time download, then \(language.label) runs entirely on your iPhone.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.jotPageInkCaption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloading \(language.label) voices, \(pct) percent")
    }

    @ViewBuilder
    private var generateButton: some View {
        let busy = ttsService.isSpeaking
        Button {
            generate()
        } label: {
            HStack(spacing: 9) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(busy ? "Generating…" : "Generate")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.jotBlueTop, Color.jotBlueBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate || busy)
        .opacity(canGenerate ? 1.0 : 0.5)
        .accessibilityLabel("Generate speech")
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("PREVIEW")
            LiquidGlassCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 10) {
                        VoiceAvatar(voice: selectedVoice, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedVoice.label)
                                .font(JotType.rowTitle)
                                .foregroundStyle(Color.jotPageInk)
                            Text("Generated on device")
                                .font(JotType.rowSub)
                                .foregroundStyle(Color.jotPageInkSecondary)
                        }
                        Spacer()
                        statusPill
                    }

                    // Transport. A scrubbable progress bar isn't possible against
                    // the streaming engine playback (no seekable file is held), so
                    // we surface a live play/pause/stop transport that mirrors the
                    // engine's `isSpeaking` state.
                    HStack(spacing: 32) {
                        Button {
                            ttsService.stop()
                            resetPlayback()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.jotPageInkSecondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop")

                        Button {
                            if ttsService.isSpeaking {
                                ttsService.stop()
                            } else {
                                generate()
                            }
                        } label: {
                            Image(systemName: ttsService.isSpeaking ? "pause.fill" : "play.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.white)
                                .frame(width: 56, height: 56)
                                .background(
                                    Circle().fill(
                                        LinearGradient(
                                            colors: [Color.jotBlueTop, Color.jotBlueBottom],
                                            startPoint: .top, endPoint: .bottom
                                        )
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ttsService.isSpeaking ? "Pause" : "Play again")

                        // Symmetry spacer mirroring the stop button.
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statusPill: some View {
        let speaking = ttsService.isSpeaking
        return HStack(spacing: 5) {
            Circle()
                .fill(speaking ? Color.jotAccent : Color.jotSuccess)
                .frame(width: 6, height: 6)
            Text(speaking ? "PLAYING" : "READY")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(speaking ? Color.jotAccent : Color.jotSuccessInk)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill((speaking ? Color.jotAccent : Color.jotSuccess).opacity(0.12))
        )
    }

    @ViewBuilder
    private var exportButton: some View {
        Button {
            exportAudio()
        } label: {
            HStack(spacing: 8) {
                if isExporting {
                    ProgressView().controlSize(.small).tint(Color.jotAccent)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(isExporting ? "Preparing…" : "Export audio")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color.jotAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.jotPageSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate || isExporting || ttsService.isSpeaking)
        .opacity(canGenerate ? 1.0 : 0.5)
        .accessibilityLabel("Export audio")
    }

    private var caption: some View {
        Text("Generated on-device with the bundled voices — nothing is uploaded. Export saves a shareable audio file (Files, AirDrop, Messages…).")
            .font(.system(size: 12))
            .foregroundStyle(Color.jotPageInkCaption)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.jotWarning)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.jotPageInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.jotWarning.opacity(0.10))
        )
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label)
            .font(JotType.sectionLabel)
            .tracking(1.5)
            .foregroundStyle(Color.jotPageInkCaption)
            .padding(.leading, 6)
    }

    // MARK: - State

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canGenerate: Bool {
        !trimmedText.isEmpty
    }

    private func resetPlayback() {
        hasGenerated = false
        generateError = nil
    }

    // MARK: - Actions

    private func generate() {
        guard canGenerate else { return }
        textFocused = false
        generateError = nil
        generateTask?.cancel()
        let body = trimmedText
        let voice = selectedVoice
        let pocket = language.pocket
        generateTask = Task {
            do {
                hasGenerated = true
                try await ttsService.speak(text: body, voice: voice, language: pocket)
            } catch is CancellationError {
                // superseded — ignore
            } catch {
                generateError = friendlyError(error)
            }
        }
    }

    private func exportAudio() {
        guard canGenerate, !isExporting else { return }
        textFocused = false
        generateError = nil
        isExporting = true
        let body = trimmedText
        let voice = selectedVoice
        let pocket = language.pocket
        Task {
            defer { isExporting = false }
            do {
                let url = try await ttsService.synthesizeToFile(
                    text: body, voice: voice, language: pocket)
                exportURL = url
                showShareSheet = true
            } catch {
                generateError = friendlyError(error)
            }
        }
    }

    private func friendlyError(_ error: Error) -> String {
        error.localizedDescription
    }
}

// MARK: - Voice avatar

/// Small gradient tile for a voice — initials for a Supertonic preset
/// (`F1`…`M5`), a person-waveform glyph for a cloned voice.
private struct VoiceAvatar: View {
    let voice: TTSVoice
    var size: CGFloat = JotDesign.Spacing.tileRowSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        let colors: (top: Color, bottom: Color) = {
            if voice.isCloned {
                return (JotDesign.JotSemanticIcon.privacyFullAccess, JotDesign.JotSemanticIcon.privacyFullAccessShaded)
            }
            if voice.isPocketPreset {
                return (Color.jotBlueTop, Color.jotBlueBottom)
            }
            let isFemale = voice.id.hasPrefix("F")
            return isFemale
                ? (Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0xA8 / 255), Color(red: 0xE0 / 255, green: 0x45 / 255, blue: 0x7E / 255))
                : (Color.jotBlueTop, Color.jotBlueBottom)
        }()

        ZStack {
            shape.fill(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom))
            shape.inset(by: 0.5).stroke(Color.white.opacity(0.35), lineWidth: 0.5).blendMode(.plusLighter)
            if voice.isCloned {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.white)
            } else if voice.isPocketPreset {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Color.white)
            } else {
                Text(voice.id)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
    }
}

// MARK: - Share sheet

/// Thin `UIActivityViewController` wrapper for exporting the generated audio.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        TTSPlaygroundView()
    }
}
