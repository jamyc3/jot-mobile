# Plan: Dictation in languages Apple supports but FluidAudio doesn't

> **Status:** Planned, not built. Depends on the dictation-engine-rework's peer-engine
> architecture ([design.md](design.md), [implementation-plan.md](implementation-plan.md)),
> which is implemented + harness-verified but **awaiting the owner's on-device checkpoints**
> as of this writing. Do not start implementation here before that lands and is verified —
> this plan reuses `AppleStreamingSession`, `AppleDictationEngine`, `stopPassTranscribe`, and
> `makeStreamingSession` verbatim; if those change shape before this is picked up, re-read
> them first.
>
> **Size: L.** Language-set + locale-plumbing + UI work across a well-understood seam, no new
> subsystem — but touches `LanguageChoice` (shared, high-fan-in), both Apple engine files, the
> engine-selection policy, and two picker UIs, plus real product judgment calls (script
> handling, vocab eligibility) that need owner sign-off before code.

---

## Problem

Today Jot cannot dictate at all in several major world languages — Chinese, Japanese, Korean,
Arabic, and others — because Jot's only two engines are FluidAudio's Parakeet (which doesn't
support them) and, since the dictation-engine rework, Apple's `SpeechTranscriber` gated to
English only. Apple's engine, however, *does* support these languages on-device today. The
rework that just shipped made Apple's engine a real peer to FluidAudio for both the live
preview and the saved transcript — that architecture is what makes closing this gap tractable:
it's a language-routing extension, not a new transcription subsystem.

## Goal

Let the user pick a dictation language that only Apple supports, and have dictation actually
work in it — live preview, saved transcript, and (where sensible) the existing vocabulary/
paragraph pipeline — using the exact two-engine machinery already built. No FluidAudio
involvement for these languages at any point, because none is possible.

## Non-goals

- **Not the 10-language Apple/FluidAudio overlap rollout** (Spanish, French, German, Italian,
  Portuguese, Russian, Danish, Dutch, Finnish, Swedish) — design.md's §Language coverage and
  §Rollout already cover making Apple the *default* engine for those, with FluidAudio as an
  opt-in upgrade. That is a different, already-scoped piece of work with its own owner
  decisions pending (D1 proactive-offer lines, bundle removal, min-iOS-26 bump). This plan's
  11 new languages have **no FluidAudio to upgrade to** — there is no "default vs upgrade"
  question for them, which is exactly why they're simpler and don't need to wait for that
  rollout to land.
- **Not min-iOS-26, not bundle removal, not the carry-forward migration.** Independent of all
  of that; this plan works whether or not those ship.
- **Not fixing CJK/Thai search tokenization.** Found during research (see §Downstream text
  pipeline) — real, but scoped out as a follow-up, not a blocker for dictation itself.
- **Not general RTL UI layout work.** Arabic/Hebrew transcript *display* already goes through
  standard SwiftUI `Text`, which handles RTL shaping natively; no bidi-specific UI work is
  identified as required. Flagged as an open question in case device testing shows otherwise.

## The net-new language list

> ### ⛔ CORRECTED 2026-07-06 — the web-research list below was WRONG; here's the DEVICE TRUTH.
> A live probe of Apple's real APIs (macOS 26; `SpeechTranscriber.supportedLocales` /
> `DictationTranscriber.supportedLocales`) showed the web research overstated the modern
> engine's coverage badly. The ground truth:
>
> - **`SpeechTranscriber`** (the modern, streaming, high-quality engine we benchmarked) covers
>   only **10 base languages**: de, en, es, fr, it, **ja, ko, pt, yue, zh**. It does NOT do
>   Arabic, Hebrew, Turkish, Vietnamese, Thai, Malay, Norwegian, Danish, Dutch, Finnish,
>   Russian, Swedish — those were fiction in the research.
> - **`DictationTranscriber`** (Apple's OLDER SFSpeechRecognizer-successor — lower quality, no
>   live streaming) covers **33 base languages** (54 locales), including ar, he, hi, id, ms, nb,
>   th, tr, vi, ca and the modern set.
>
> **Net-new vs FluidAudio, via the GOOD engine: only 4 — Japanese (ja-JP), Korean (ko-KR),
> Mandarin Chinese (zh-CN), Cantonese (yue-CN).** These are being IMPLEMENTED now (all use
> `SpeechTranscriber`, same quality bar as English). Traditional Chinese (zh-TW) and HK
> (zh-HK) are trivially addable later.
>
> **The ~10 extra languages** (Arabic, Hebrew, Hindi, Indonesian, Malay, Norwegian, Thai,
> Turkish, Vietnamese, Catalan) are only on the OLDER `DictationTranscriber` — under a separate
> quality-research decision (owner asked: research how good/bad the old engine is, then decide).
> Adding them would require wiring `DictationTranscriber` (a different, older API) — NOT part of
> the 4-language implementation.
>
> Everything below this banner is the SUPERSEDED web-research version — kept for history only.

---

_(SUPERSEDED — see banner above)_ Apple's `SpeechTranscriber.supportedLocales` (iOS 26)
reportedly returns 42 locales... [the list below was sourced from a third-party write-up and is
inaccurate; the real modern-engine list is the 10 languages in the banner].

| Language | Locale(s) | New `LanguageChoice` case | Notes |
|---|---|---|---|
| Chinese (Simplified, Mainland) | `zh_CN` | `.chineseMandarin` | ✅ real (SpeechTranscriber) |
| Cantonese | `yue_CN` | `.cantonese` | ✅ real (SpeechTranscriber; device shows `yue-CN`) |
| Japanese | `ja_JP` | `.japanese` | ✅ real (SpeechTranscriber) |
| Korean | `ko_KR` | `.korean` | ✅ real (SpeechTranscriber) |
| Arabic / Hebrew / Turkish / Vietnamese / Thai / Malay / Norwegian / Hindi / Indonesian / Catalan | various | — | ❌ NOT on the modern engine — older `DictationTranscriber` only; separate decision |

**FluidAudio-only, unconditionally, no change (13, unchanged from design.md):** Romanian,
Polish, Czech, Slovak, Slovenian, Croatian, Bosnian, Ukrainian, Belarusian, Bulgarian, Serbian,
Greek, Hungarian.

## DECISION (2026-07-06): ship the 4 modern-engine languages; HOLD the older-engine ~10

**Shipping now (SpeechTranscriber, same quality bar + streaming as English):** Japanese, Korean,
Mandarin (zh-CN), Cantonese (yue-CN). Being implemented.

**HELD — the ~10 `DictationTranscriber`-only languages** (Arabic, Hebrew, Hindi, Indonesian,
Malay, Norwegian, Thai, Turkish, Vietnamese, Catalan). Rationale (from a quality-research pass):
- Apple's `DictationTranscriber` is the **frozen iOS-10-era on-device model**, documented and
  corroborated as consistently BEHIND the server dictation users get from the iOS keyboard mic.
  That expectation gap applies to ALL 10 — users WILL compare against the keyboard.
- **Arabic** = real red flag: Apple's whole Arabic stack (old AND new engine) is weak outside
  Modern Standard Arabic; most speech is dialectal → high risk of embarrassing output. Don't ship
  without explicit "best with formal Arabic" framing.
- **Hindi / Thai / Vietnamese** = moderate risk (Hinglish code-switching; tonal-language variance).
- **Indonesian / Malay / Norwegian / Catalan / Turkish** = no red flags, Latin-script, likely
  "functional but plainer."
- No published per-language WER exists for this engine — the risk calls are strong circumstantial
  inference, not a benchmark.
- Adding them = wiring `DictationTranscriber` (a DIFFERENT, older API, NO live streaming) — a
  separate engine integration, not a locale-list extension. Real work for uncertain payoff.

**If revisited:** add ONLY the low-risk Latin-script subset (Indonesian, Malay, Norwegian,
Catalan, maybe Turkish) first, AFTER an empirical spot-check (record real clips → run through
`DictationTranscriber` in the harness). Never Arabic without expectation-setting copy. Owner may
override toward breadth-over-polish; default recommendation is the 4, done well.

**Apple/FluidAudio overlap, unconditionally FluidAudio-routed today, unchanged by this plan
(10, design.md's later-phase rollout territory):** Spanish, French, German, Italian,
Portuguese, Russian, Danish, Dutch, Finnish, Swedish.

## Engine routing

`TranscriptionService.useAppleEngine` (`TranscriptionService.swift:997-1000`) is today:

```swift
var useAppleEngine: Bool {
    LanguageChoice.current.isEnglish
        && AppGroup.defaults.bool(forKey: AppGroup.Keys.useAppleDictationForEnglish)
}
```

It must generalize to: *"is this language Apple-only (no FluidAudio possible, so route
unconditionally), OR is it English with the A/B toggle on"*:

```swift
var useAppleEngine: Bool {
    LanguageChoice.current.isAppleOnly
        || (LanguageChoice.current.isEnglish
            && AppGroup.defaults.bool(forKey: AppGroup.Keys.useAppleDictationForEnglish))
}
```

New `LanguageChoice.isAppleOnly: Bool` — `true` for exactly the 12 new cases, `false` for
everything else (including the 10 overlap languages — they stay FluidAudio-routed until the
separate rollout plan changes that). This single flag is the whole routing change; nothing
else in `makeStreamingSession` or `appleStopPass` needs to change — they already dispatch
purely off `useAppleEngine`.

**The no-fallback case.** `stopPassTranscribe`'s existing resilience path
(`TranscriptionService.swift:720-751`) falls back to `fluidAudioStopPass` on ANY Apple failure.
For an Apple-only language that fallback would silently run FluidAudio's currently-loaded
model (whatever English/European variant happens to be resident) against, say, Japanese audio
— producing confidently-wrong garbage text, not an honest failure. Two changes close this:

1. **Root-cause guard in `fluidAudioStopPass` itself** (belt-and-suspenders, so no future call
   site can hit this silently): first line of the method,
   ```swift
   guard !LanguageChoice.current.isAppleOnly else {
       throw TranscriptionError.loadFailed(
           "\(LanguageChoice.current.englishName) dictation runs only on Apple's on-device engine, which just failed. No fallback is available for this language."
       )
   }
   ```
2. **`stopPassTranscribe`'s catch branch** checks `isAppleOnly` before attempting the fallback
   at all, so the log/DiagnosticsLog messaging is accurate (today's copy says "falling back to
   FluidAudio," which would be a lie here) and the user sees a real, actionable error instead
   of nothing or garbage. Same shape for the live-preview side: `makeStreamingSession`'s
   existing catch already falls back to `PreviewScheduler` on Apple construction failure — for
   an Apple-only language this means the live *preview* would silently show FluidAudio-garbled
   text for a few seconds, then the *stop-pass* honestly errors. That mismatch needs an
   explicit product decision — see §Open questions — but leans toward: keep the preview
   fallback (a wrong preview that self-corrects at stop is much better than no preview during
   an outage), and prominently error only at stop, where it saves/publishes.

The existing `CancellationError` passthrough is unaffected either way.

## Locale threading (the debt this plan is forced to pay)

Both Apple entry points are hardcoded to English today:
- `AppleStreamingSession.makeConfiguredTranscriber()` (`AppleStreamingSession.swift:89-107`):
  `let locale = Locale(identifier: "en-US")`.
- `AppleDictationEngine.transcribe(samples:)` (`AppleDictationEngine.swift:69`): `let locale =
  Locale(identifier: "en-US")`.

This was flagged as a known, deliberately-deferred debt in implementation-plan.md's §Rollout
("Scheduled debts" — `Locale("en-US")` → `LanguageChoice` threading in both Apple paths). This
plan is what forces it to be paid, because a Japanese dictation running Apple's engine
configured for `en-US` will not work — this isn't an accuracy nuance, it's a hard functional
requirement.

**New `LanguageChoice.appleLocaleIdentifier: String?`** — `nil` for the 13 FluidAudio-only
languages (Apple has no coverage there so the property is meaningless), a locale identifier
string for everything else:
- `.english` → `"en-US"` (unchanged behavior, now just parameterized instead of hardcoded).
- The 12 new Apple-only cases → per the table above (`"zh-CN"`, `"zh-TW"`, the Cantonese
  identifier pending the open question, `"ja-JP"`, `"ko-KR"`, `"ar-SA"`, `"he-IL"`, `"tr-TR"`,
  `"vi-VN"`, `"th-TH"`, `"ms-MY"`, `"nb-NO"`).
- The 10 overlap languages → also non-nil (e.g. `"es-ES"`, `"fr-FR"`, `"de-DE"`, `"it-IT"`,
  `"pt-BR"`, `"ru-RU"`, `"da-DK"`, `"nl-NL"`, `"fi-FI"`, `"sv-SE"`) even though nothing routes
  them to Apple yet — cheap to add now, and the later rollout plan won't have to touch
  `LanguageChoice` again for this. **Flag for that later plan:** Apple offers multiple regional
  variants for several of these (`es_CL/es_ES/es_MX/es_US`, `fr_BE/fr_CA/fr_CH/fr_FR`,
  `de_AT/de_CH/de_DE`, `it_CH/it_IT`) — picking one default region per language (proposed above:
  the "main" European variant) is a product call for that plan, not this one, mirroring the
  existing `pt_BR`-only precedent design.md already set.

**Both engine files change from a hardcoded `Locale` to an injected one:**
- `AppleStreamingSession.makeConfiguredTranscriber(locale:)` gains a required `locale: Locale`
  parameter (no default — forces every call site to pass explicitly rather than silently
  defaulting to English). `make()` calls it with
  `Locale(identifier: LanguageChoice.current.appleLocaleIdentifier ?? "en-US")` (the `?? "en-
  US"` is unreachable in practice since `make()` is only ever invoked when `useAppleEngine` is
  true, which requires a non-nil identifier — kept as a defensive fallback, not a silent
  language mismatch).
- `AppleDictationEngine.transcribe(samples:locale:)` gains the same required parameter; its one
  call site (`TranscriptionService.appleStopPass`) passes the same resolved locale.
- `TranscriptionService.preinstallAppleAssets()` (Step 7 of the implementation plan) also needs
  the locale threaded through, since asset pre-installation is per-locale — see §Asset download.

**pt-BR-style single-variant gotcha, generalized:** Apple has no `pt_PT` (design.md already
flags this for Portuguese); this plan's set has the analogous single-variant case for Arabic
(`ar_SA` only — no Egyptian/Levantine/Gulf variants offered) and Norwegian (`nb_NO` — Bokmål
only, no Nynorsk, which Apple doesn't support at all). Not a blocker, just worth stating
explicitly in the picker copy if a user's own dialect isn't the offered one — same treatment as
the existing Portuguese caveat.

## Vocabulary / CTC — needs a real skip decision, not a blanket "no change"

Design.md §E states the CTC vocabulary-boost mechanism is engine-agnostic (Apple vs FluidAudio)
and needs no change — **that claim is about the engine, not the language/script**, and I want to
be precise about what is and isn't verified here:

- **Confirmed by reading the actual merge/gate code** (`VocabularyRescorerHolder.swift:271`,
  `VocabularyGate.swift:206`): both split transcript text on the literal space character
  (`text.split(separator: " ")`) to find word boundaries for matching/anchoring proposed
  corrections. Chinese, Japanese, and Thai do not use spaces between words at all — this
  splitting would treat an entire clause as one "word," which breaks the whole word-level
  matching model the gate depends on.
- **Also confirmed:** `AppleDictationEngine.words(from:)` (`AppleDictationEngine.swift:37-56`,
  shared by both the one-shot engine and the streaming session's `stopArtifact()`) synthesizes
  per-word timings the same way — `runText.split(separator: " ")`. For CJK/Thai this collapses
  to one "word" per Apple result-run instead of one per actual word, which degrades
  `tokenTimings` granularity for anything downstream that consumes them (paragraph
  segmentation still works — it only needs *some* timing span per pause-adjacent unit — but
  vocab merge, which needs real word-level spans, does not).
- **NOT verified, and I want to flag the uncertainty rather than assert a conclusion:** whether
  the CTC acoustic scorer itself (the `parakeet-ctc-110m` model + its tokenizer) meaningfully
  degrades on non-Latin-script *audio*. The existing 5 Cyrillic languages (Russian, Ukrainian,
  Belarusian, Bulgarian, Serbian) already ship in production running this exact pipeline with
  no reported breakage — that's real evidence AGAINST a blanket "non-Latin breaks it" claim,
  since Cyrillic is non-Latin. But Cyrillic is still alphabetic and space-delimited; CJK/Thai
  are a bigger structural leap (no spaces at all; Chinese/Japanese are logographic, not
  alphabetic). I could not find or run evidence one way or the other on CJK/Thai specifically —
  this needs an on-device test, not a guess.

**Recommendation (Likely-confidence, not asserted as fact): gate vocab CTC off for the
no-word-space script languages only** — `.chineseSimplified`, `.chineseTraditional`,
`.cantonese`, `.japanese`, `.thai` — where the space-splitting bugs above are *confirmed*, not
hypothetical. For the space-delimited Apple-only languages (`.korean`, `.arabic`, `.hebrew`,
`.turkish`, `.vietnamese`, `.malay`, `.norwegianBokmal`), the word-splitting code paths are
structurally fine (spaces exist); whether the CTC model itself performs usefully on Korean/
Arabic/Hebrew audio is unverified but has no confirmed bug forcing a skip — ship vocab ON for
those, and treat any quality issue as a normal correctness bug to investigate later, not a
known gap to design around now.

Implementation: new `LanguageChoice.isVocabEligible: Bool`, `false` only for the 5 no-word-
space cases above, `true` for every other case (all 24 existing + the other 7 new). Gate at
`TranscriptionService.swift`'s vocab `async let` spot block (~line 691-733 per the
implementation plan's step numbering) with `LanguageChoice.current.isVocabEligible &&` prepended
to whatever condition currently starts that block. When skipped, the stop-pass simply returns
the raw Apple transcript with `tokenTimings` still attached (paragraph segmentation still runs)
— never a broken/garbled merge.

> **AS-BUILT (2026-07-14): Korean vocab stays OFF, not ON.** The plan above
> recommended Korean = eligible (spaces exist, so the merge's word-split doesn't
> break). Review found that reasoning incomplete: the merge IS reachable on the
> Apple path (Apple emits synthetic `tokenTimings`), and the CTC scorer
> (`parakeet-ctc-110m`) is English/Latin-trained — so over Korean audio it can
> false-positive-inject a Latin term into otherwise-correct Korean text. "Safe
> no-op" was an unverified assumption, so `isVocabEligible` is `false` for
> Korean (alongside the no-word-space CJK). **Follow-up trigger to reconsider:**
> run an on-device Korean + Latin-seeded-term test and confirm no false-positive
> injection before flipping Korean back on. Latin-American Spanish is likewise
> kept off here to preserve shipped behavior (European Spanish keeps vocab on via
> Parakeet); enabling LatAm-Spanish parity is a separate deliberate call. Net:
> `isVocabEligible` is currently equivalent to `!isAppleOnly`, but written as an
> explicit case list so a future no-word-space FluidAudio language (e.g. Thai)
> is also skipped rather than wrongly treated as eligible.

## Downstream text pipeline

- **`FillerWordCleaner` / `NumberNormalizer`** — already gated by `LanguageChoice.current.
  isEnglish` at both call sites (`TranscriptionService.swift:928` batch path, `:1120` preview
  path) — confirmed by reading the code, not assumed. **No change needed**; all 12 new
  languages already skip these English-only passes automatically, same as every non-English
  language today.
- **`ParagraphSegmenter`** — confirmed language-agnostic by reading it: it operates on
  `tokenTimings`' audio pause gaps, never splits the display string itself. No change needed.
  Its only dependency on word-level granularity is the drift check at
  `ParagraphSegmenter.swift:199` (`rescoredTokens.count` vs `words.count`), which compares
  token-array counts, not string splits — safe even with the coarser CJK/Thai timing spans
  from §Vocabulary above.
- **Search — confirmed real gap, scoped OUT of this plan.** `BM25Index.tokenize`
  (`BM25Index.swift:184-188`) splits on `!$0.isLetter && !$0.isNumber` — CJK characters ARE
  Unicode letters, so a whole contiguous Chinese/Japanese sentence with no spaces becomes ONE
  token instead of one per word, which would make Ask's BM25 half of hybrid retrieval nearly
  useless on CJK transcripts (term-frequency scoring needs real word tokens). Thai has the same
  problem. **This is a genuine, code-confirmed limitation of Jot's existing Ask/search
  feature**, not something this plan introduces — it simply becomes visible the first time a
  CJK/Thai transcript exists. Recommended real fix (not implemented here):
  `String.enumerateSubstrings(in:options:[.byWords, .localized])`, which uses ICU's
  dictionary-based word-breaking and correctly segments CJK/Thai (unlike a naive character-class
  split) — a self-contained, low-risk swap inside `BM25Index.tokenize` whenever it's picked up.
  Flagged in known-bugs-and-plans.md (§Registry below) rather than bundled into this plan, since
  it's orthogonal to dictation working at all and shouldn't block shipping these languages.
- **RTL display (Arabic, Hebrew)** — SwiftUI `Text` shapes bidi text correctly out of the box;
  no code path found that manually reverses, slices by fixed left-to-right offsets, or assumes
  LTR order for transcript body text. Not asserting this is bug-free — genuinely untested for
  Jot's specific layouts (transcript detail, keyboard recents strip, search snippet
  highlighting) — flagged as a device-verification item, not a code change.

## Schema

**No `@Model` change.** Per the standing schema-impact requirement (`Jot/CLAUDE.md`): `Transcript.
language` already exists as an unconstrained `String?` (added in schema V8,
`JotSchemaV8.swift:95`, confirmed by reading the file — not inferred). It stores
`LanguageChoice.rawValue`, and `LanguageChoice.fromStored(_:)` already treats any unrecognized
raw value as `.english` (`LanguageChoice.swift:156-159`) — so this is forward-and-backward safe
by construction: a build with the new cases writes new raw strings that an older build reading
them would just fall back to English on, and there is nothing to migrate. Adding 12 new
`enum` cases to a `String`-backed `RawRepresentable` enum is a Swift source change, not a
persistence change.

## Device support

Inherits the same best-effort story design.md already established (§Compatibility matrix, §The
one real unknown): iOS 26 minimum for `SpeechTranscriber` at all; whether a given device
actually runs `SpeechTranscriber` or silently degrades to Apple's older `DictationTranscriber`
fallback is not knowable from Jot's side and isn't gated on here, consistent with the existing
policy. Nothing about *language choice* changes that story — the RAM/device-tier question is
orthogonal to which locale is loaded. No new device-capability code needed.

## Asset download (UX for picking a new Apple-only language)

Apple's assets download per-locale via `AssetInventory`, exactly like English's does today via
`preinstallAppleAssets()` (Step 7 of the implementation plan) and exactly like FluidAudio's v3
download-on-pick pattern the European language picker already uses
(`LanguageStep.swift:269-276`'s `select(_:)` → `handleLanguageChange()`).

Proposed flow, reusing existing shapes rather than inventing new ones:
1. User picks an Apple-only language in the wizard or Settings picker.
2. `select(_:)` persists the choice (unchanged) and, instead of only calling
   `handleLanguageChange()` (which is FluidAudio-model-oriented — download+warm the v2/v3
   model), branches: for `LanguageChoice.current.isAppleOnly`, call a new
   `TranscriptionService.preinstallAppleAssets(locale:)` (the existing method,
   generalized to take the resolved locale instead of always building the English one) and
   surface its progress the same way `modelState` already drives the existing
   downloading/loading/ready status line (`LanguageStep.statusContent`,
   `SettingsView.languageStatusRow`) — reusing the UI shape, not the FluidAudio-specific state
   machine underneath it 1:1 (Apple's `AssetInstallationRequest.progress` publishes a
   fraction the same shape as FluidAudio's download progress, so the existing `.downloading(let
   f)` rendering branch is directly reusable if `modelState` grows an Apple-asset variant, or a
   small parallel `appleAssetState` property mirrors it — pick whichever keeps `modelState`'s
   existing FluidAudio-only callers simplest; recommend the parallel property to avoid
   conflating two different download systems in one enum).
3. No explicit "Download" button needed the way FluidAudio's does — Apple's asset install is
   typically fast and unobtrusive (it already runs invisibly today for English toggle-flips);
   match that expectation rather than adding new UI weight for these 11 languages.

## UI

- **Not an "upgrade" — no FluidAudio affordance at all** for these 12 cases, unlike the 10
  overlap languages' future "Download the more accurate model" row (design.md §B). The picker
  row and status line should say something like *"Runs on Apple's on-device speech engine"*
  rather than any language implying a FluidAudio option exists, since none does.
  `LanguagePickerSheet`'s existing "Built in" badge (English-only today,
  `LanguageStep.swift:367-377`) should NOT be reused verbatim for these — English's badge means
  "bundled in the app binary, zero download"; these 12 still have a (small, fast) asset
  download. A distinct badge/subline (e.g. "Apple on-device") avoids implying no-download.
- **Wizard + Settings both need the 12 new cases to appear** in `LanguagePickerSheet.ordered`
  and `SettingsView`'s language `Picker` — both already iterate `LanguageChoice.
  presentationOrder` / `allCases`, so they pick up new enum cases automatically once added; no
  separate UI wiring needed beyond the status-line/badge distinction above and the download-
  trigger branch in §Asset download.
- **MRU recents** (`LanguageChoice.recentLanguages`) already works generically off any
  `LanguageChoice` — no change needed.

## Verification

Per the standing "verify locally before shipping" rule: the SPM standalone harness that already
runs `AppleStreamingSession`/`AppleDictationEngine` verbatim against real recordings
(`~/Desktop/jot-recordings.csv`, per the implementation plan's V1-V8 harness suite) can be
pointed at non-English audio the same way — it doesn't care what language the audio is in, only
that the locale passed to `makeConfiguredTranscriber`/`transcribe` matches. Concretely:
1. Record (or source) a handful of real Chinese/Japanese/Korean/Arabic samples per §Staging.
2. Run them through the harness with the corresponding `appleLocaleIdentifier`, confirming (a)
   the analyzer doesn't crash/hang the same way the original English work found and fixed real
   bugs (format mismatch, converter hang, missing finalize — all found by running real audio
   locally, not by code review, per `AppleDictationEngine.swift`'s own doc comments), (b) the
   streaming session's assembled text and the one-shot's text are sane, (c) `words(from:)`'s
   space-split behavior on CJK/Thai actually looks like the coarse-granularity degradation
   predicted in §Vocabulary, confirming or correcting that prediction before shipping the skip
   gate.
3. On-device per-language spot checks: pick each language in Settings, dictate a short note,
   confirm live preview streams, stop saves correctly, and (for the 7 vocab-eligible ones) a
   seeded vocab term still corrects; for the 5 no-word-space languages confirm the vocab skip
   doesn't regress the plain transcript.
4. Confirm the honest-error path: force an Apple failure (airplane mode before asset install,
   e.g.) on an Apple-only language and confirm the user sees a real error, not silence or
   garbled FluidAudio output.

## Sizing and staging

**L overall.** Suggested staged rollout by likely population/impact, matching the task's own
framing:
1. **Wave 1 — biggest population:** Chinese (Simplified), Japanese, Korean, Arabic. Also the
   highest-risk wave (CJK script issues, Arabic RTL) — good to front-load so the harder
   verification work happens once, not four separate times later.
2. **Wave 2 — remaining CJK/RTL family:** Chinese (Traditional), Cantonese (once the locale
   ambiguity is resolved), Hebrew, Thai.
3. **Wave 3 — Latin/space-delimited, lower risk:** Turkish, Vietnamese, Malay, Norwegian Bokmål
   — these share the least-risky shape with the already-shipped European languages (spaces,
   alphabetic script), so they can likely ride the same vocab-eligible path with minimal
   surprises and are a good place to validate the locale-threading plumbing cheaply before
   Wave 1's harder cases, if the team prefers to sequence easy-first instead.

## Open questions for the owner

1. **Cantonese locale:** `zh_HK` vs `yue_CN` — which does Jot offer (or both, as if they were
   two separate `LanguageChoice` cases)? Needs a real iOS 26 device check of what each actually
   transcribes and how `SpeechTranscriber.supportedLocales` frames the distinction. Blocks
   finalizing the `LanguageChoice.appleLocaleIdentifier` for `.cantonese`.
2. **Vocab CTC on CJK/Thai:** confirmed code-level word-splitting bugs justify skipping the
   *merge*, but is skipping the *entire* CTC boost pass (not just the merge) the right call, or
   should the merge logic instead be fixed to use script-aware word segmentation (the same ICU
   `.byWords` fix recommended for BM25 search) so vocab terms CAN still be boosted for these
   languages? The skip is the safe/cheap v1; the segmentation fix is more work but keeps
   feature parity. Recommend v1 = skip, follow-up = investigate the segmentation fix once these
   languages have real usage data.
3. **Live-preview-vs-stop-pass error mismatch** (§Engine routing): is a self-correcting wrong
   preview (garbled FluidAudio text shown briefly, replaced by an honest error at stop when
   Apple fails) acceptable, or should the live preview also go blank/show an explicit "engine
   unavailable" state for Apple-only languages rather than showing any FluidAudio-attempted
   text at all?
4. **CJK/Thai search (BM25 tokenization)** — fix now as part of this plan (small, self-
   contained, but touches a shared retrieval component with its own test surface), or file as a
   separate follow-up so this plan stays scoped to dictation itself? Leaning follow-up (see
   §Non-goals) but flagging for an explicit call rather than silently deferring.
5. **Badge/copy wording** for "Apple on-device, no FluidAudio option" in the picker — does
   product want that surfaced at all, or should it look identical to every other non-English
   row and only the *absence* of a download-upgrade affordance communicate the difference?
6. **Should picking a language mid-recording-history change how OLDER transcripts in a
   FluidAudio-only or different-Apple-locale language are searched/displayed?** Not expected to
   be affected (each transcript stores its own `language`, independent of the currently-active
   picker selection), but worth an explicit "no" from the owner given how much of this plan
   touches shared, per-transcript state.

## Cross-links

- [design.md](design.md) — the peer-engine architecture, the 10-language overlap table this
  plan's net-new set is the complement of, and the `Locale("en-US")` debt this plan pays off.
- [implementation-plan.md](implementation-plan.md) — the exact shipped/in-review shape of
  `AppleStreamingSession`, `AppleDictationEngine`, `stopPassTranscribe`, `makeStreamingSession`,
  and the harness (V1-V8) this plan's verification step extends.
- `Jot/App/Transcription/LanguageChoice.swift` — where every new case, `isAppleOnly`,
  `appleLocaleIdentifier`, and `isVocabEligible` land.
- `Jot/App/SetupWizard/Steps/LanguageStep.swift` / `Jot/App/Settings/SettingsView.swift` — the
  two picker surfaces that pick up the new cases automatically, plus the download-trigger
  branch this plan adds.
- `docs/multilingual-dictation/design.md` — the original European-language rollout this
  mirrors structurally (language → model/engine resolution, MRU recents, wizard + Settings
  parity).
