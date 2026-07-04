import SwiftUI

/// Voice picker sheet for the TTS Playground (`tts-voice-picker` mockup).
///
/// Offers, in order:
///   * The 10 English Supertonic presets — ONLY when the chosen language is
///     English (they can't speak the other five). For non-English the section is
///     hidden and the picker leans on cloned voices.
///   * The user's cloned voices (always — a clone speaks any of the six).
///   * A "Clone your voice" row presenting `VoiceCloneRecorderView`.
struct TTSVoicePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let language: TTSPlaygroundView.Language
    @Binding var selected: TTSVoice

    @State private var ttsService = TTSService.shared
    @State private var showCloneSheet = false
    @State private var voiceToDelete: TTSVoice?

    private var presets: [TTSVoice] {
        language.isEnglish ? TTSService.voices : TTSService.pocketPresetVoices(for: language.pocket)
    }
    private var clones: [TTSVoice] { language.isEnglish ? ttsService.clonedVoices : [] }

    var body: some View {
        NavigationStack {
            ZStack {
                WallpaperBackground().ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        if !presets.isEmpty {
                            section(language.isEnglish ? "BUILT-IN PRESETS" : "\(language.label.uppercased()) VOICES") {
                                ForEach(Array(presets.enumerated()), id: \.element.id) { idx, voice in
                                    if idx > 0 { divider }
                                    voiceRow(voice, subline: language.isEnglish ? "Supertonic preset" : "Built-in · downloads once")
                                }
                            }
                        }

                        // Cloning is English-only (cross-lingual cloning doesn't
                        // preserve identity), so clones + the clone row appear
                        // only for English.
                        if language.isEnglish {
                            if !clones.isEmpty {
                                section("YOUR VOICES") {
                                    ForEach(Array(clones.enumerated()), id: \.element.id) { idx, voice in
                                        if idx > 0 { divider }
                                        voiceRow(voice, subline: "Cloned · English")
                                    }
                                }
                            }
                            cloneRow
                        }
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showCloneSheet) {
                VoiceCloneRecorderView()
            }
            .confirmationDialog(
                "Delete this voice?",
                isPresented: Binding(
                    get: { voiceToDelete != nil },
                    set: { if !$0 { voiceToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: voiceToDelete
            ) { voice in
                Button("Delete", role: .destructive) {
                    deleteVoice(voice)
                }
                Button("Cancel", role: .cancel) {
                    voiceToDelete = nil
                }
            } message: { voice in
                Text("\u{201C}\(voice.label)\u{201D} will be removed from this iPhone. This can't be undone.")
            }
        }
    }

    /// Deletes the cloned voice and, if it was the active selection, falls
    /// back to the language's default — mirrors `TTSPlaygroundView`'s own
    /// `.onChange(of: language)` reset so a stale, now-missing `.bin` can
    /// never be selected.
    private func deleteVoice(_ voice: TTSVoice) {
        let wasSelected = selected.id == voice.id
        ttsService.deleteClonedVoice(voice)
        voiceToDelete = nil
        if wasSelected {
            selected = TTSPlaygroundView.defaultVoice(for: language)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Choose a voice")
                .font(JotType.displaySerif(36))
                .tracking(-1.2)
                .foregroundStyle(Color.jotPageInk)
                .accessibilityAddTraits(.isHeader)
            Text(headerSubline)
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerSubline: String {
        if language.isEnglish {
            return "Ten built-in voices, plus any you've cloned. Pick one to speak your text."
        }
        return "Built-in \(language.label) voices — the first is recorded natively. Downloads once on first use. (Voice cloning is English-only.)"
    }

    @ViewBuilder
    private func section<Content: View>(_ label: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(JotType.sectionLabel)
                .tracking(1.5)
                .foregroundStyle(Color.jotPageInkCaption)
                .padding(.leading, 6)
            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                VStack(spacing: 0) { content() }
            }
        }
    }

    private func voiceRow(_ voice: TTSVoice, subline: String) -> some View {
        HStack(spacing: 4) {
            // Only the select region is a Button — the trailing delete
            // button (cloned voices only) sits alongside it, not nested
            // inside it, since a custom VStack row has no `.swipeActions`.
            Button {
                selected = voice
                dismiss()
            } label: {
                HStack(spacing: 14) {
                    voiceAvatar(voice)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.label)
                            .font(JotType.rowTitle)
                            .tracking(-0.2)
                            .foregroundStyle(Color.jotPageInk)
                        Text(subline)
                            .font(JotType.rowSub)
                            .foregroundStyle(Color.jotPageInkSecondary)
                    }
                    Spacer(minLength: 12)
                    if voice.id == selected.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.jotAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(voice.label)\(voice.id == selected.id ? ", selected" : "")")

            if voice.isCloned {
                Button {
                    voiceToDelete = voice
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(.systemRed))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete voice \(voice.label)")
            }
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, voice.isCloned ? 0 : 13)
        .frame(minHeight: 44)
    }

    private var cloneRow: some View {
        Button {
            showCloneSheet = true
        } label: {
            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                HStack(spacing: 14) {
                    IconTile(
                        systemImage: "plus",
                        tint: JotDesign.JotSemanticIcon.speechModel,
                        shaded: JotDesign.JotSemanticIcon.speechModelShaded
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clone your voice")
                            .font(JotType.rowTitle)
                            .tracking(-0.2)
                            .foregroundStyle(Color.jotAccent)
                        Text("Record ~15s — add as many as you like")
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
        .accessibilityLabel("Clone your voice")
    }

    private var caption: some View {
        Text(language.isEnglish
            ? "Cloned voices stay on your iPhone — record one anytime."
            : "These voices download once and run entirely on-device. Cloning your own voice is available for English.")
            .font(.system(size: 12))
            .foregroundStyle(Color.jotPageInkCaption)
            .lineSpacing(2)
            .padding(.horizontal, 6)
            .padding(.top, 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.jotPageSeparator)
            .frame(height: 0.5)
            .padding(.leading, 60)
    }

    private func voiceAvatar(_ voice: TTSVoice) -> some View {
        let size = JotDesign.Spacing.tileRowSize
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        let isFemale = voice.id.hasPrefix("F")
        let top: Color
        let bottom: Color
        if voice.isCloned {
            top = JotDesign.JotSemanticIcon.privacyFullAccess
            bottom = JotDesign.JotSemanticIcon.privacyFullAccessShaded
        } else if voice.isPocketPreset {
            top = Color.jotBlueTop
            bottom = Color.jotBlueBottom
        } else {
            top = isFemale ? Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0xA8 / 255) : Color.jotBlueTop
            bottom = isFemale ? Color(red: 0xE0 / 255, green: 0x45 / 255, blue: 0x7E / 255) : Color.jotBlueBottom
        }

        return ZStack {
            shape.fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
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
