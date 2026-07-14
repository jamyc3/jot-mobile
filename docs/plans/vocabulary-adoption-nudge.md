# Plan: Vocabulary-adoption keyboard nudge

**Status: IMPLEMENTED (2026-07-13, build 274) — owner approved with priority warm-hold › vocab › Parakeet and CTA routing to the Vocabulary screen ("Go go go").** Goal: gently invite users who haven't enabled **Vocabulary Boost** to turn it on, modeled on the existing Parakeet-upgrade nudge, opt-in only, coordinated so it never collides with the other keyboard nudges. Framed as a **retention** lever (a custom dictionary is a sticky personalization feature).

## As built (deltas from the design below)
- **Priority (owner-set): warm-hold › vocab › Parakeet** — vocab arms before Parakeet in `DictationPipeline` and outranks it in `KeyboardView.topStrip`'s chain; both defer to warm-hold.
- **Both tiers shipped in one nudge:** Tier A (terms exist + toggle off) or Tier B (≥5 total dictations, no terms) — same card, tier logged to Diagnostics (`vocab nudge armed`, tier metadata).
- **CTA routes to the Vocabulary screen** (`jot://vocabulary` → `Router.showVocabularySettings` → sheet-wrapped `VocabularySettingsView`); nothing auto-enables.
- **Cross-nudge quiet period implemented as 24h time-based** (not sessions — simpler + robust): `AppGroup.lastNudgeResolvedAt` stamped by ALL three nudges' terminal resolvers; `AppGroup.nudgeQuietPeriodActive` consulted by the vocab + Parakeet arm sites. One-shot like the siblings (shown until acted on; no impression counter — matches the existing nudge UX).
- Files: `AppGroup` (3 keys + quiet-period helpers), `CrossProcessNotification.vocabNudgeChanged`, `DictationPipeline.maybeArmVocabNudge`, `VocabNudgeStrip.swift`, `KeyboardStreamingHub` (observer/refresh/clear), `KeyboardViewInputs`/`KeyboardView` (prop + chain branch + callbacks), `JotKeyboardViewController` (handlers + quiet-period stamps in all three resolvers), `JotApp`/`Router`/`ContentView` (deep link + sheet). features.md §5.2c + cross-links (§5.2a/§5.2b/§8.6). Atlas `kb-vocab-nudge` deployed.

## Why (grounded)
- **Vocabulary Boost is OFF by default** (`VocabularyStore.isEnabled` → `UserDefaults` bool, key `jot.vocabulary.enabled`, defaults false; `VocabularySettingsView` toggle flips it, ON triggers `VocabularyRescorerHolder.prepare`). So many users never turn it on — a real adoption gap.
- **Retention evidence:** adopting 3+ features ≈ **70% higher 12-month retention** (MIT Sloan/Amplitude); early feature engagement ≈ **3.2–3.7× higher 90-day retention** (Amplitude/Reforge). A custom dictionary is exactly the "deeper habit, harder to peel away" personalization these cite. Sources below.

## Current nudge system (the template to extend — verified in code)
Two nudges already share the keyboard top-strip slot and **never stack**, via two coordination layers:
1. **Per-nudge App-Group flags:** `…ShouldShow` + `…Declined` — `warmHoldNudgeShouldShow` (armed in `RecordingService` after a few app-bounces) and `showParakeetUpgradeNudge`/`parakeetNudgeDeclined` (armed in `DictationPipeline` after ≥5 Apple dictations on a Parakeet-capable, non-Apple-only language — see the LatAm-Spanish nudge gate).
2. **Arm-time mutual exclusion:** the Parakeet nudge refuses to arm while `warmHoldNudgeShouldShow` is set (`DictationPipeline` guard).
3. **Render-time precedence:** the keyboard renders via a strict if/else-if chain (`KeyboardView`: warm-hold › Parakeet › normal) mirrored from the App-Group flags into `KeyboardStreamingHub` (`refresh…FromProjection`). "The two nudges never stack."

A third nudge slots straight into this pattern. The owner's "don't collide / give leeway" is the arbiter below.

## Design — the Vocabulary nudge

### Trigger (contextual > time-based, per research)
- **Tier A (primary, high-intent):** the user has **≥1 custom term** but the **master toggle is OFF** → "You've added words but Vocabulary is off — turn it on so Jot uses them." Behavior-triggered, high relevance. *(Verify in build: does adding a term via Find&Replace / selection auto-enable the toggle? If yes, this state is only reachable when the user explicitly turned it off — still valid, rarer.)*
- **Tier B (soft, broader):** an engaged user (≈ the Parakeet nudge's ≥5 dictations) with vocab OFF and **no terms yet** → "Jot can learn the names & jargon you use — set up Vocabulary." Lower priority, tighter cap.
- Never mid-dictation; only in the idle top strip (like the others).

### Copy + CTA (value-first, one action + honest dismiss)
- Title (benefit, not mechanism): **"Get names & jargon spelled right."**
- Sub: **"Turn on Vocabulary so Jot learns your words."**
- Actions: **Turn on** (one tap → deep-link to the Vocabulary screen; see "needs terms" note) · **Not now** (honest dismiss — NOT "maybe later" only).
- Match `ParakeetUpgradeNudgeStrip` styling (Liquid-Glass card).

### Frequency / decay (per research — fatigue is a cliff)
- **Lifetime cap ≈ 2–3 impressions**, spaced across sessions.
- **Permanent stop** on ANY of: explicit "Not now"/"Don't show again" (`vocabNudgeDeclined`), cap reached, or the **competing action** — user enables Vocabulary OR opens the Vocabulary screen by any path.

### Coordination arbiter (the owner's main concern — formalize it)
Extend the current ad-hoc gates into one small **slot arbiter** shared by all three nudges:
- **(a) One nudge per session** across all three (global cap).
- **(b) Fixed priority** so two can never both pass the gate. Proposed order — tunable: **Vocab (Tier A) › Warm-hold › Parakeet-upgrade › Vocab (Tier B)**. (Owner wants vocab surfaced for retention; Tier A is high-intent so it leads, Tier B trails since it's the softest.)
- **(c) Cross-nudge cooldown / quiet period:** after ANY nudge fires (shown or dismissed), no *other* nudge may fire for **K sessions** (start K≈3), so a user who just dismissed one isn't hit by the next next-session.
- **(d) Exit condition** per nudge so a satisfied one leaves the pool (warm-hold enabled → drop; engine switched → drop; vocab enabled → drop).
- Implement as a tiny predicate the arm sites all consult (or a shared `KeyboardNudgeArbiter` reading the App-Group flags + a `lastNudgeShownSession` stamp), rather than three independent `!otherFlag` checks that don't scale to N.

### "Needs terms" nuance (recommendation)
Enabling the toggle does nothing until terms exist (the toggle gates rescoring, not the term list). So **the CTA should lead into the Vocabulary screen** (enable + show how to add a name/term / the existing add-term affordances), not silently flip a bool the user then sees no effect from. Tier A already implies terms exist → for it, "Turn on" can enable directly + confirm; Tier B → route to the screen to add the first term.

## Implementation hooks (mirror the Parakeet nudge exactly)
- `AppGroup`: `showVocabNudgeShouldShow` + `vocabNudgeDeclined` keys (+ `lastNudgeShownSession` for the cooldown).
- Arm in `DictationPipeline` (post-dictation) behind the arbiter predicate + the Tier A/B condition.
- Mirror into `KeyboardStreamingHub` (`refreshVocabNudgeFromProjection`) + a render flag; add to `KeyboardView`'s if/else-if chain at the arbiter-decided precedence.
- `VocabNudgeStrip.swift` (twin of `ParakeetUpgradeNudgeStrip`); accept → `jot://vocabulary` deep link (add if absent, parallel to `jot://upgrade-engine`); the terminal actions write the App-Group flags + post the change notification.
- features.md: new §5.2c + cross-links (§8 Vocabulary, §2.15). Atlas: new `kb-vocab-nudge` fragment, deploy.

## Ship gate / rollout
Behavior-only, opt-in, no model. Verify on device: fires only when eligible, never mid-dictation, never co-shows with the other two, honors decline + cap. Roll into the current TestFlight train.

## Open questions for owner
1. **Priority** — is "Vocab-A › warm-hold › Parakeet › Vocab-B" the right ranking, or should vocab always lead (retention emphasis)?
2. **Tier B** — ship both tiers, or start with only the high-intent Tier A (terms-added-but-off) and add the broad one later?
3. **CTA target** — enable-directly (Tier A) vs always route to the Vocabulary screen?
4. Cooldown K (sessions) + lifetime cap (2 vs 3) — start values, tune on data.

## Sources (external research 2026-07-13)
- Frequency capping / multi-nudge coordination: [Plotline](https://www.plotline.so/blog/frequency-capping-in-app-messaging), [Braze](https://www.braze.com/resources/articles/whats-frequency-capping)
- Adoption-nudge effectiveness + copy: [Appcues](https://www.appcues.com/blog/improve-feature-adoption-in-app-messaging), [Plotline in-app nudges](https://www.plotline.so/blog/in-app-nudges-ultimate-guide)
- Retention/adoption link: [Amplitude](https://amplitude.com/blog/product-stickiness-guide), [Statsig](https://www.statsig.com/perspectives/feature-adoption-vs-retention)
- Anti-patterns: [NNGroup mobile onboarding](https://www.nngroup.com/articles/mobile-app-onboarding/)
