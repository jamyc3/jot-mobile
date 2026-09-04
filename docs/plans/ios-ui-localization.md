# Plan: Localize the Jot iOS UI into the languages Jot already dictates

> **Status:** Planned, not built. Research + design only as of 2026-07-16. No code, no
> translations, no infra changes have been made. This is the **master** localization plan;
> the Mac app derives from it at a higher altitude (`~/code/jot/docs/plans/mac-ui-localization.md`).
>
> **Size: XL.** Not because any single step is hard — it is a greenfield i18n bootstrap plus a
> long, repeated per-language translation-and-review loop across ~800 strings and 4 targets, with
> two genuinely hard sub-questions (a Latin-only display font over CJK/Cyrillic/Greek, and an
> English-only Ask help corpus). Stage it; do not attempt it in one pass.

---

## Problem

Jot dictates in ~26 languages today (30 `LanguageChoice` rows — see `Jot/App/Transcription/LanguageChoice.swift:31-58`), but **every word of the app's own UI is hardcoded English.** A user who picks Japanese dictation still navigates an English Settings screen, an English setup wizard, and an English keyboard. The product's headline promise — "dictate in your language" — is undercut the moment the surrounding chrome stays in a language the user may not read.

The goal is to localize the **app's interface** into the languages Jot already supports for dictation, so the whole experience (not just the transcript) speaks the user's language.

## Ground truth (verified 2026-07-16, cite `file:line`)

- **Zero localization infrastructure.** No `.xcstrings`, `.strings`, or `.stringsdict` anywhere in first-party code. No `NSLocalizedString` / `String(localized:)` usage in app code (only inside SPM dependency checkouts). `Jot/project.yml` has **no `knownRegions`**, no `CFBundleLocalizations`; the only region key is the default `CFBundleDevelopmentRegion = $(DEVELOPMENT_LANGUAGE)` → `en` (`Jot/Resources/Info.plist:9-10`). The keyboard appex explicitly declares `PrimaryLanguage: en-US` (`Jot/project.yml:446-448`). **This is a from-scratch bootstrap.** (Contrast: the Mac app already has String Catalogs scaffolded with an empty `ja` locale — see the Mac plan. iOS has nothing.)
- **~800 user-facing string literals**, all inline, no central copy store. Rough magnitude across `Jot/` (excluding tests/docs/atlas): `Text("` ×369, `Label("` ×186 (SF-Symbol-inflated, large user-facing fraction), `Button("` ×59, `.navigationTitle`/`.navigationBarTitle` ×42, `.alert(` ×11, `TextField("`/`Toggle("`/`Section("`/`Picker("` a few dozen more. Biggest concentrations: `Jot/App/Settings/AIRewriteSettingsView.swift`, `Jot/App/Ask/AskView.swift`, `Jot/App/TranscriptDetailView.swift`, `Jot/App/Settings/SettingsView.swift`, `Jot/App/SetupWizard/Steps/*`, and the keyboard strips (`Jot/Keyboard/CorrectionReviewStrip.swift`, `ActionsPopover.swift`, the nudge strips). There is **no** `Copy.swift` / `Strings.swift` / `L10n` layer to hook into — strings are literals passed straight to `Text("…")`.
- **Four localizable targets**, each with its own bundle: the main app, the **keyboard app-extension** (`JotKeyboard`, ~60 MB memory ceiling, cannot read the main app's bundle — needs its **own** catalog), **JotWatch** (~21 `Text(` literals, small), and **JotWatchWidgets**.
- **Display font is Fraunces** — a bundled **Latin-only** display serif (`UIAppFonts` in `Jot/project.yml:301-306` app + `:461-466` keyboard; TTFs in `Jot/Resources/Fonts/`; tokens in `Jot/App/Design/JotDesign.swift`). Fraunces has **no CJK, Cyrillic, or Greek glyphs.** Every Fraunces-styled surface (headers, streaming captions, "just now" markers, the wizard's display type) will silently fall back to the system serif for those scripts. This is a real design regression, not a nit — see §7.
- **The Ask product-help lane is grounded in an English corpus.** `Jot/App/Ask/HelpCorpus.swift` retrieves over `Jot/Resources/help-corpus.json`, a pre-embedded distillation of the **English** `Jot/features.md` (built by `scripts/make-help-corpus.sh`, chunked structurally per `§N.M`, EmbeddingGemma vectors). Localizing the UI without localizing this corpus means the "how do I use Jot" lane answers **in English regardless of UI language** — see §8.
- **Some error strings already route through `LocalizedStringResource`.** `Jot/App/Recording/RecordingService.swift:3451-3453` wraps `userFacingMessage` in `LocalizedStringResource(stringLiteral:)`, but the literal itself is still English (`:67-90`, incl. the owner-approved `micBusyMessage`). A partial hook exists.
- **DiagnosticsLog is a support-copy-paste artifact** (`Jot/Shared/DiagnosticsLog.swift`) — its category identifiers (`pasteSkipSessionMismatch`, etc.) are engineer-facing and **out of scope** to localize.

## Non-goals

- **Not** localizing dictation output. Transcripts are already in the user's spoken language; this plan is about the *chrome*.
- **Not** localizing the Diagnostics event stream (internal identifiers, copy-pasted to support).
- **Not** an App Store metadata rewrite in this repo — ASC metadata is a parallel, non-code workstream tracked in §9.
- **Not** committing to localize the Ask corpus in v1 — that is a flagged owner decision (§8), not an assumed deliverable.

---

## Schema impact

**None.** This feature adds/removes/renames **no `@Model` fields and no `@Model` entities.** It touches only presentation-layer string literals and build configuration (`project.yml` `knownRegions`, per-target String Catalogs). No `JotSchemaVN` bump, no `MigrationStage`. (Section included per the CLAUDE.md schema-discipline requirement, to record that it was considered and is empty.)

---

## Part A — The engineering: String Catalog migration

### A.1 Infra bootstrap (do once, before any translation)

1. **`project.yml`:** add `knownRegions` and per-target `CFBundleLocalizations`, plus set `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` and `SWIFT_EMIT_LOC_STRINGS = YES` on every localizable target so Xcode auto-extracts `Text("literal")` into the catalog at build. (This mirrors exactly how the Mac app is already configured — `knownRegions = (en, Base, ja)`, `SWIFT_EMIT_LOC_STRINGS = YES` — so copy that setup.) Re-run `xcodegen` from `Jot/`.
2. **Create one `Localizable.xcstrings` per target** (main app, `JotKeyboard`, `JotWatch`, `JotWatchWidgets`). String Catalogs hold all locales in one file — no per-`.lproj` sprawl. The keyboard's catalog is independent because the extension cannot read the app bundle.
3. **Create `InfoPlist.xcstrings`** for `CFBundleDisplayName` and the usage-description strings (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, etc.). These are legally/privacy load-bearing (§7 privacy note).
4. **Turn on pseudo-localization early** (a `-AppleLanguages` scheme with the built-in "Double-Length Pseudolanguage" / accented pseudolocale). This is the cheapest layout-bug detector and should run before a single human translation exists.

### A.2 Extraction strategy — auto vs explicit keys

- **Prefer SwiftUI auto-extraction.** `Text("Language")`, `Button("Cancel")`, `Section("Recent")`, `.navigationTitle("Settings")` all take `LocalizedStringKey` and are extracted automatically with `SWIFT_EMIT_LOC_STRINGS = YES`. **These need no code change** — the literal English string becomes the catalog key. This covers the large majority of the ~800 strings.
- **Explicit `String(localized:)` where the string is built outside a SwiftUI view initializer** — e.g. strings assembled in view models, passed as plain `String`, or used in `UIKit`/appex controller code (`JotKeyboardViewController` sets some banner text as raw `String`). These will **not** auto-extract; wrap them in `String(localized: "…")` deliberately.
- **Interpolated strings need format keys.** `"Dictation failed: \(error.localizedDescription)"` (`RecordingHeroView.swift:967`), `Use "\(term)"`, `"\(count) transcripts"` — these become format strings with `%@` / `%lld` placeholders in the catalog. Interpolation order can differ per language; rely on the catalog's positional handling (`%1$@`) and **never** concatenate sentence fragments in code (a classic i18n bug — German/Japanese word order will break it).
- **What NOT to localize (leave as raw literals, mark "Don't Localize" in the catalog):** DiagnosticsLog category identifiers and any developer-only debug strings; the Fraunces PostScript font names; App-Group keys; deep-link URL schemes; model labels that are proper nouns shown verbatim ("Parakeet 600M" is a product name, but its *descriptor* "(more accurate)" **is** localizable — split them).

### A.3 Pluralization and grammatical agreement

- Any count-driven string ("1 transcript" / "3 transcripts", "2 minutes ago") must use the String Catalog's **plural variation** (the `.xcstrings` equivalent of `.stringsdict`), with `%lld` and per-language plural categories. This matters far beyond English's two forms: **Slavic languages (Polish, Czech, Russian, Croatian, Serbian, Slovenian, Ukrainian) have 3–4 plural categories**; Japanese/Korean/Chinese have **one**. Enumerate every count-bearing string during extraction and convert it to a plural-varied entry — do not ship `"\(n) items"` as a flat format.
- Gendered/agreement strings are mostly absent in Jot's copy, but relative-time and unit strings ("hace 2 minutos") should use `Foundation`'s `RelativeDateTimeFormatter` / `MeasurementFormatter` where possible rather than hand-built strings, so the framework handles agreement.

### A.4 Surface extraction order (mechanical, within any one language)

The catalog is populated once (auto-extraction covers all targets at build), but **translation and QA proceed surface-by-surface** so a partially-translated build is always shippable and testable. Order by user-visibility and first-impression weight:

1. **Setup wizard (W1–W8, `Jot/App/SetupWizard/Steps/*`) + Settings (`SettingsView.swift` and its sub-panes).** First-run + configuration — highest first-impression weight, contained surface, no cross-process subtlety. **Start here.**
2. **Home + recording hero + transcript detail** (`HomeScreen.swift`, `Recording/RecordingHeroView.swift`, `TranscriptDetailView.swift`) — the core in-app loop.
3. **Keyboard extension** (`Jot/Keyboard/*`) — the core product surface, but its own target/catalog and its own memory ceiling; do it as a distinct chunk with device testing (the appex renders differently than the app).
4. **Errors + alerts** (`RecordingService.userFacingMessage`, alert titles across `SettingsView`, `HomeScreen`, `JotApp`, `AIRewriteSettingsView`, `RecordingHeroView`) — lower volume, but high-stakes wording (the mic-busy message is owner-tuned; translate its *intent*, not word-for-word).
5. **JotWatch + JotWatchWidgets** — small surface, last. (Note: the watch already omits CJK/LatAm-Spanish dictation rows; its UI-localization scope should track whatever the watch actually ships.)

---

## Part B — The translation loop (subagent-per-language, adversarial review)

This is the owner's requested workflow and the bulk of the effort. Machine translation of ~800 strings is the easy 20%; getting **native-quality, tone-consistent, terminology-consistent** copy is the 80%.

### B.1 The per-language glossary (build this FIRST, before translating anything)

Jot has coined product terms that must NOT be translated ad-hoc — every occurrence must resolve to the **same** deliberate target-language term, or the product reads as incoherent. Build a **glossary per language** as the source of truth for the translation loop. Terms that need a deliberate, pinned translation (or a deliberate decision to keep in English):

- **"Jot" / "Jot down"** — the product name and its verb. Likely kept as "Jot" (brand) but the *verb* ("Jot down a thought") needs a natural target-language rendering that isn't a literal calque. Decide per language whether "Jot" stays Latin in CJK contexts.
- **"Warm hold" / "warm-held mic"** — a Jot-specific concept (idle mic kept alive). Has no standard translation; needs a coined term the glossary pins.
- **"Vocabulary"** (the custom-terms feature), **"Add to Vocabulary"**, **"Sounds like"** — feature nouns that recur across keyboard + settings + transcript pane; must match everywhere.
- **"Recents" / "Recent languages"**, **"Dictation"**, **"Transcript"**, **"Rewrite"**, **"Cleanup" / "Clean up"**, **"Streaming" / "live text"**, **"Engine"** (as in "Jot's engine" vs "Apple's engine"), **"Parakeet"** (product name, keep).
- **Privacy claims** — "No accounts, no cloud, no telemetry", "on-device", "free + private" — legally/trust load-bearing; translate precisely and pin (see §7).

The glossary is a small table per language: `English term → pinned target term → note`. It seeds every translator agent and is the checklist the reviewer agent enforces.

### B.2 The loop, per language

Run this as a **dedicated subagent pass per language**, parallelizable across languages (no overlap):

1. **Translator agent** — given the surface's extracted English strings + the language's glossary + a tone brief (Jot's voice: instructional, warm, not condescending — see the repo's voice memos), produces target-language translations. It must flag any string it cannot translate without more context (idioms, UI strings whose meaning depends on the screen).
2. **Native-quality reviewer agent** (the adversary) — a *separate* agent that reviews the translation for: naturalness (does a native speaker wince?), **glossary compliance** (every pinned term used consistently), tone match, over-literal calques, register (formal vs informal "you" — e.g. German du/Sie, Japanese politeness level — **pin a register per language in the glossary**), and truncation risk (flag strings likely to overflow UI).
3. **Back-and-forth** — the reviewer's findings go back to the translator; iterate until the reviewer signs off. Per the repo's design-review discipline, the translator agent must **think critically** and not accept every reviewer note blindly (reviewers over-index on nitpicks) — the orchestrator filters.
4. **Human/owner spot-check** for at least the pilot languages and any the owner speaks.

Per CLAUDE.md's subagent guidance: **one supervisor agent per parallelized language** to validate the translator↔reviewer output before it's written to the catalog.

### B.3 Register and formality — pin per language

A single decision with product-wide impact: does Jot address the user formally or informally? German (Sie/du), French (vous/tu), Spanish (usted/tú), Japanese (keigo level), Korean (speech level) all force this. Jot's voice is warm and personal → lean **informal** where it reads as friendly-not-flippant, but this is a **per-language owner call** pinned in each glossary before translation starts. Getting it wrong is worse than a mistranslation — it's a consistent wrong-tone across the whole app.

---

## Part C — QA

### C.1 Pseudo-localization + long-string layout (do this before human translation)

Run the app under the double-length pseudolocale to surface truncation/overflow/clipping **before** paying for translations. **German is the canonical stress case** (compound words ~30–40% longer than English); Finnish and Hungarian also run long. Fix layouts to flex (line limits, `minimumScaleFactor`, wrapping, `Grid`/`ViewThatFits`) so no translated string is clipped. The keyboard strip is the tightest real estate — audit every keyboard label under pseudo-loc.

### C.2 Per-language screenshot verification via simulator

For each language × key surface, boot a simulator in that locale (`-AppleLanguages`), drive the flow, and capture screenshots (XcodeBuildMCP `screenshot` / `snapshot_ui`). Verify: no clipping, no tofu (missing glyphs — this is where the Fraunces CJK gap shows up, §7), correct plural forms, correct date/number formatting, RTL not accidentally triggered (none of the current language set is RTL — Arabic/Hebrew are *not* in the dictation set, so RTL is out of scope for now but keep the keyboard's `PrefersRightToLeft: false` honest). Automate the screenshot sweep so it re-runs each time a language's catalog changes.

### C.3 Doc/Atlas/features sync

Per the standing repo practice: if localization changes any user-facing behavior described in `features.md`, update it; check whether any Atlas screen (`atlas/gen/frag/*.html`) shows English copy that should now be noted as localized. Localization itself likely warrants a short `features.md` note ("the app UI localizes to your dictation language where available").

---

## Part D — The Ask-corpus question (OPEN — owner decision, §8 detail)

Localizing the UI without addressing the Ask help lane produces **mixed-language help**: a Japanese UI whose "how do I use Jot" answers come back in English. Three options, in ascending cost:

- **(D1) Keep Ask English, label it.** Cheapest. EmbeddingGemma is multilingual so a translated query still retrieves the right English chunks; the *answer text stays English*. Add a one-line "help answers are shown in English" note. Ships now; revisit if users complain.
- **(D2) Localize the corpus per language.** Re-author `features.md` per locale (or machine-translate + review), regenerate `help-corpus.json` per locale, bundle per locale (or download-on-demand to avoid bloating the app). Heaviest: it's a second ~700-line translation-and-review workstream *per language*, plus re-embedding, plus bundle-size management. Highest quality.
- **(D3) Translate at answer time.** Retrieve over the English corpus, then translate the generated answer into the UI language on-device (Apple Translation, already used elsewhere in Jot). Middle cost; adds latency and a translation-quality layer over already-generated text. Risk: translating an answer that quotes English UI labels ("tap **Add to Vocabulary**") must keep those labels matching the *localized* UI, not the English source.

**Recommendation:** ship UI localization with **D1** (labeled English Ask), and scope **D3** as the follow-up middle ground; reserve **D2** for the top 2–3 markets only if usage justifies it. **This is the #1 open question for the owner.**

---

## Recommended staging + sizing

Two axes: **languages** and **surfaces**. Stage both.

- **Stage 0 — Infra bootstrap + pseudo-loc (Part A.1, C.1). Size: M.** `project.yml` regions, per-target catalogs, extraction build, pseudolocale layout pass. No translations yet. De-risks the whole effort and finds the layout bugs for free.
- **Stage 1 — Pilot TWO languages end-to-end. Size: L.** Recommend **German** (layout stress — longest strings) **and Japanese** (script + font stress — exercises the Fraunces CJK gap and no-word-space rendering early). Localize only Stage-A.4 surface #1 (wizard + Settings) for both. Build the glossary, run the translator↔reviewer loop, do the screenshot QA, resolve the font-fallback decision (§7) on real CJK text. This pilot validates the entire pipeline before scaling.
- **Stage 2 — Extend the pilot two languages to all surfaces (#2–#5). Size: L.** Home/hero/detail, keyboard (separate catalog + device test), errors, watch. Locks the per-surface playbook.
- **Stage 3 — Tier-1 languages. Size: L (parallelized).** The high-value European set: Spanish, French, Portuguese, Italian (+ German already done). All surfaces, subagent-per-language.
- **Stage 4 — CJK completion. Size: M.** Korean, Chinese Simplified (zh-Hans), Chinese Traditional (zh-Hant) (+ Japanese already done). Note the **UI locale collapse**: the two Cantonese dictation rows + Mandarin + Traditional map to only **two** UI script locales — `zh-Hans` and `zh-Hant` — *not* four. Cantonese speakers read Traditional (HK) or Simplified (mainland); there is no separate "Cantonese UI."
- **Stage 5 — Long-tail European. Size: M–L (parallelized), owner-gated on demand.** Dutch, Danish, Swedish, Finnish, Greek, Polish, Czech, Slovak, Slovenian, Croatian, Serbian, Bosnian, Bulgarian, Romanian, Hungarian, Russian, Ukrainian, Belarusian. **The UI-locale set need not match the dictation set 1:1** — dictation is an *input* capability; UI localization is a *market* investment. Several of these (Belarusian; Bosnian, which as a UI overlaps Serbo-Croatian; Slovenian) may not warrant a full 800-string translation initially. This is an owner prioritization call (see open questions).
- **Stage 6 — Ask corpus (Part D) + App Store metadata (§9). Size: per option — D1 XS, D3 M, D2 L per language.**

---

## §7 — The Fraunces font gap (design decision, must resolve in Stage 1)

Fraunces is Latin-only. For Cyrillic, Greek, and CJK, every Fraunces-styled element falls back to whatever the system substitutes. Options:

- **(a) Accept system-serif fallback.** For Cyrillic/Greek, iOS substitutes New York (which covers both) — acceptable. For **CJK there is no system serif in the display role**; it substitutes a non-serif CJK face, so the display-serif brand identity is lost for Japanese/Chinese. Zero cost, cosmetic loss.
- **(b) Bundle a CJK serif.** A CJK serif is 10–40 MB — **violates the keyboard's ~60 MB ceiling** and bloats the app. Not viable for the keyboard target; marginal even for the app. Reject for the keyboard; reconsider only for the app if CJK becomes a flagship market.
- **(c) Script-aware font token.** Make `JotDesign` resolve the display face by the *string's* script: Fraunces for Latin, New York for Cyrillic/Greek, a chosen system CJK face for CJK. Modest engineering; preserves quality where possible; the honest default.

**Recommendation: (c) — a script-aware display-font token — with (a) as the CJK behavior.** Verify on real CJK text in Stage 1 so the decision is grounded, not theoretical.

## §7b — Privacy copy (load-bearing)

Per the repo's standing rule, privacy claims stay synced everywhere. The privacy strings — the "No accounts, no cloud, no telemetry" block (`SettingsView.swift:356`), the on-device/free/private wizard copy, and the Info.plist usage descriptions (`InfoPlist.xcstrings`) — are trust- and legally-load-bearing. Translate them precisely, pin them in every glossary, and keep them consistent with the localized App Store metadata and the website. A sloppy privacy translation is a trust bug, not a copy nit.

## §9 — App Store metadata (parallel, non-code workstream)

Separate from in-app strings: App Store Connect localizes the listing (app name, subtitle, promotional text, description, keywords, and ideally **localized screenshots**) per locale. This lives in ASC, not the repo, and should track the in-app language rollout (don't advertise a localized listing before the app UI is localized for that language). Localized screenshots can reuse the Stage-C.2 simulator screenshot pipeline. Size: XS–S per language for text; M if localized screenshots are produced.

---

## Open questions for the owner

1. **Ask corpus (the big one):** D1 (English, labeled) / D2 (per-locale corpus) / D3 (translate-at-answer-time)? Recommendation: ship D1, follow up with D3. (§8/Part D.)
2. **Which languages actually get a UI?** The UI-locale set need not equal the 26-language dictation set. Recommend a tiered rollout (pilot → tier-1 European → CJK → long-tail) and explicitly deciding whether the low-population/overlapping locales (Belarusian, Bosnian, Slovenian, …) are worth full translation. Also: one Spanish (`es`) or split `es`/`es-419` for Latin America (dictation already splits es-ES/es-MX)? And confirm the CJK collapse: 4 Chinese/Cantonese dictation rows → 2 UI script locales (`zh-Hans`, `zh-Hant`).
3. **Formality/register per language** (Sie/du, vous/tu, keigo level). Lean informal-but-warm, but this is a per-language pin that must be set before translation — getting it wrong is a whole-app tone error.

Secondary: font strategy sign-off (§7 recommends script-aware token + CJK system fallback); whether to localize App Store screenshots or ship text-only localized listings first (§9).
