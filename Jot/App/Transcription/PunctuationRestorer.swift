import CoreML
import Foundation
import os.log

/// Restores punctuation, capitalization and sentence boundaries on a finished
/// transcript, using the downloaded `punct_cap_seg_en` CoreML model.
///
/// ## Why this exists
///
/// Parakeet's own punctuation is weak. Measured on 420 real Jot recordings with
/// the WORDS HELD CONSTANT (same transcript, only the punctuation swapped), three
/// independent blind LLM judges preferred this model's punctuation over
/// Parakeet's **31–16** (pooled 101 vs 44, z = +4.7, p ≈ 1.2e-06). Full method
/// and numbers: `docs/research/granite-turboctc/PUNCTUATION.md`.
///
/// ## How it is applied
///
/// The model wants lower-cased, unpunctuated text. So the transcript is stripped
/// of case and sentence punctuation and then re-punctuated wholesale — we do NOT
/// layer it on top of existing punctuation. Doing that doubles every mark
/// ("there??", "Yeah,,", "log. File..") because the existing punctuation is
/// tokenized as text and the model adds its own on top. Measured: 6.8 → 27.1
/// marks per 100 words.
///
/// ## What it cannot do
///
/// Its label set is `.` `,` `?` plus `<ACRONYM>` — there is no apostrophe, so it
/// can never CREATE a contraction. `stripForModel` therefore preserves the
/// source's contractions rather than flattening them, which is why this is safe
/// to bolt onto Parakeet (282 contractions across the corpus survive the round
/// trip) and would be lossy on a source that emits none.
actor PunctuationRestorer {

    static let shared = PunctuationRestorer()

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot", category: "punctuation"
    )

    /// Fixed input width of the compiled model.
    private static let sequenceLength = 256

    /// Label tables, mirroring the reference implementation.
    private static let postLabels = ["", "<ACRONYM>", ".", ",", "?"]
    private static let bosID = 1
    private static let eosID = 2
    private static let padID = 3
    private static let unkID = 0

    private var model: MLModel?
    private var vocab: [String: Int]?
    private var longestPiece = 1
    private var loadFailed = false

    // MARK: - Availability

    /// Cheap, synchronous check for callers that must not await.
    @MainActor
    static var isDownloaded: Bool { PunctuationModelFetcher.shared.isInstalled }

    // MARK: - Loading

    private func loadIfNeeded() -> Bool {
        if model != nil, vocab != nil { return true }
        if loadFailed { return false }

        guard let vocabURL = Bundle.main.url(
            forResource: "punct_cap_seg_vocab", withExtension: "json"
        ) else {
            Self.log.error("punctuation — vocab resource missing from the bundle")
            loadFailed = true
            return false
        }
        let compiledURL = PunctuationModelFetcher.compiledModelURL
        guard FileManager.default.fileExists(atPath: compiledURL.path) else { return false }

        do {
            let data = try Data(contentsOf: vocabURL)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let table = root?["vocab"] as? [String: Int] else {
                throw NSError(domain: "punctuation", code: 1)
            }
            let config = MLModelConfiguration()
            // CPU+GPU: the graph is a small BERT-style classifier and the ANE
            // gains nothing here, while ANE specialization costs a slow first load.
            config.computeUnits = .cpuAndGPU
            model = try MLModel(contentsOf: compiledURL, configuration: config)
            vocab = table
            longestPiece = table.keys.reduce(1) { max($0, $1.count) }
            Self.log.info("punctuation — loaded (vocab \(table.count, privacy: .public))")
            // One-time, so it can't flood: this record is the definitive
            // "dictations from here on ARE using the punctuation model" line
            // in Help → Diagnostics.
            DiagnosticsLog.record(
                source: "main-app", category: .punctuationModel,
                message: "Punctuation model loaded — active for English dictations",
                metadata: ["vocab": "\(table.count)"]
            )
            return true
        } catch {
            Self.log.error("punctuation — load failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticsLog.record(
                source: "main-app", category: .punctuationModel,
                message: "Punctuation model FAILED to load — dictations fall back to engine punctuation",
                metadata: ["error": error.localizedDescription]
            )
            loadFailed = true
            return false
        }
    }

    // MARK: - Public entry point

    /// Re-punctuate `text`. Returns the input unchanged if the model is not
    /// downloaded yet, fails to load, or anything goes wrong — this is a polish
    /// pass and must never cost the user a dictation.
    func restore(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard loadIfNeeded(), let model, let vocab else { return text }

        let stripped = Self.stripForModel(trimmed)
        guard !stripped.isEmpty else { return text }

        let (ids, pieces) = Self.tokenize(stripped, vocab: vocab, longestPiece: longestPiece)
        // Content tokens only; BOS/EOS are added per window.
        guard !ids.isEmpty else { return text }

        var out: [String] = []
        let budget = Self.sequenceLength - 2
        var index = 0
        while index < ids.count {
            let upper = min(index + budget, ids.count)
            let windowIDs = [Self.bosID] + Array(ids[index..<upper]) + [Self.eosID]
            let windowPieces = [""] + Array(pieces[index..<upper]) + [""]
            guard let decoded = decodeWindow(ids: windowIDs, pieces: windowPieces, model: model)
            else { return text }
            if !decoded.isEmpty { out.append(decoded) }
            index = upper
        }
        let joined = out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? text : joined
    }

    // MARK: - Inference

    private func decodeWindow(ids: [Int], pieces: [String], model: MLModel) -> String? {
        let n = ids.count
        guard let input = try? MLMultiArray(
            shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32
        ) else { return nil }
        for i in 0..<Self.sequenceLength {
            input[i] = NSNumber(value: i < n ? ids[i] : Self.padID)
        }
        guard
            let provider = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": input]),
            let result = try? model.prediction(from: provider),
            let pre = result.featureValue(for: "pre_preds")?.multiArrayValue,
            let post = result.featureValue(for: "post_preds")?.multiArrayValue,
            let cap = result.featureValue(for: "cap_preds")?.multiArrayValue,
            let seg = result.featureValue(for: "seg_preds")?.multiArrayValue
        else { return nil }

        var sentences: [String] = []
        var current = ""
        for i in 0..<(n - 2) {
            let token = pieces[i + 1]
            let outputIndex = i + 1
            if token.hasPrefix("▁"), !current.isEmpty { current.append(" ") }

            let chars = Array(token)
            let start = token.hasPrefix("▁") ? 1 : 0
            guard start < chars.count else { continue }

            let postLabel = post[outputIndex].intValue
            for j in start..<chars.count {
                var ch = String(chars[j])
                if j == start, pre[outputIndex].intValue == 1 { current.append("¿") }
                // cap_preds is [1, seq, 16] — per character within the token.
                if j < 16 {
                    let capIndex = outputIndex * 16 + j
                    if capIndex < cap.count, cap[capIndex].intValue != 0 {
                        ch = ch.uppercased()
                    }
                }
                current.append(ch)
                if postLabel == 1 {
                    current.append(".")                       // <ACRONYM>: dot every char
                } else if j == chars.count - 1, postLabel > 1 {
                    current.append(Self.postLabels[min(postLabel, Self.postLabels.count - 1)])
                }
            }
            if seg[outputIndex].intValue != 0 {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences.joined(separator: " ")
    }

    // MARK: - Tokenizer

    /// Greedy longest-match over the unigram vocabulary — what the reference
    /// implementation does. Measured against true SentencePiece Viterbi on 150
    /// real transcripts: identical token ids 87% of the time and identical FINAL
    /// TEXT 94%, the rest being single-capital differences. Not worth carrying a
    /// SentencePiece implementation on device for that.
    ///
    /// Returns ids alongside the SOURCE text each token consumed.
    ///
    /// **The `pieces` array is the bug fix.** The reference decodes each token by
    /// looking its id back up in the vocab, so an out-of-vocabulary character
    /// (which resolves to UNK) emits the literal string `"<unk>"` into
    /// user-visible text — and the per-character capitalizer may upper-case it,
    /// producing `"the front<Unk>end design skill"` for "front-end". That hit
    /// 19/420 (4.5%) of real transcripts. Emitting the consumed source instead
    /// passes unknown characters through untouched.
    private static func tokenize(
        _ text: String, vocab: [String: Int], longestPiece: Int
    ) -> (ids: [Int], pieces: [String]) {
        var remaining = Array("▁" + text.lowercased().replacingOccurrences(of: " ", with: "▁"))
        var ids: [Int] = []
        var pieces: [String] = []
        var cursor = 0
        while cursor < remaining.count {
            var matched = false
            let maxLen = min(longestPiece, remaining.count - cursor)
            if maxLen > 0 {
                for length in stride(from: maxLen, through: 1, by: -1) {
                    let candidate = String(remaining[cursor..<(cursor + length)])
                    if let id = vocab[candidate] {
                        ids.append(id)
                        pieces.append(candidate)
                        cursor += length
                        matched = true
                        break
                    }
                }
            }
            if !matched {
                ids.append(unkID)
                pieces.append(String(remaining[cursor]))   // pass the raw character through
                cursor += 1
            }
        }
        remaining = []
        return (ids, pieces)
    }

    // MARK: - Strip

    /// Lower-case and remove sentence punctuation so the model sees the shape it
    /// was trained on.
    ///
    /// Two things are deliberately preserved:
    ///
    /// - **Contractions.** The model has no apostrophe label and can never
    ///   re-create them; stripping would permanently flatten "I'm" to "I am".
    /// - **Digit-internal separators.** "5,000" and "3.1" are numbers, not
    ///   sentence punctuation. Stripping them yields "5 000" / "3 1", which the
    ///   model then re-punctuates as prose. That corrupted 17/420 real
    ///   transcripts before this guard.
    static func stripForModel(_ text: String) -> String {
        var scalars = Array(text.lowercased())
        var out = String()
        out.reserveCapacity(scalars.count)
        for (i, ch) in scalars.enumerated() {
            if ch == "." || ch == "," {
                let prevIsDigit = i > 0 && scalars[i - 1].isNumber
                let nextIsDigit = i + 1 < scalars.count && scalars[i + 1].isNumber
                if prevIsDigit && nextIsDigit {
                    out.append(ch)          // keep: it is part of a number
                    continue
                }
                out.append(" ")
                continue
            }
            if "?!;:\"()[]".contains(ch) {
                out.append(" ")
                continue
            }
            out.append(ch)
        }
        scalars = []
        return out.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
