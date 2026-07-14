# Plan: number-normalization improvements (decimals, years, dates)

**Status: IMPLEMENTED + VALIDATED (2026-07-11) — all three rules ported to `Jot/App/Transcription/NumberNormalizer.swift`; app build SUCCEEDED; awaiting TestFlight ship.** Working harness: session scratchpad `number-test/` (extracts the real `NumberNormalizer` + a JSON test set with false-positive/miss metrics).

## Final result (2026-07-11)
- **303/303 curated + adversarial cases: 0 false-positives, 0 misses, 0 wrong.**
- **Real-data audit: 2,711 recordings, 114 changed, 0 false-positives from the new rules** (every change eyeballed; imperfect outputs were all pre-existing cardinal/ordinal behavior, out of scope).
- All 47 app-test input/output pairs pass through the ported code; standalone typecheck + full app build clean.
- Adversarial round 2 (two blind agents): dates 44/44 perfect; decimals/years surfaced only pre-existing splits + one contrived, empirically-safe hyphenated-shape residual (accepted, matches round-1 stance).
- **Implemented:** Decimals (integer-cardinal + "point" + digit-run, leading-decimals dropped, unit fold-in); Years (century-lead 14–20 paired halves — hyphenated low-half fires on shape alone, non-hyphenated needs immediate temporal context + never bare 1-9; "two thousand" stays context-gated); Dates (MONTH + day-ordinal → "Month Nth", month-specific day maxima, may/march/august require capitalization, runs before the tens-ordinal combiner; trailing year folds in via the year rule).
- **Deliberately NOT converted (precision over recall):** leading decimals ("point five"), bare ordinals with no month ("meeting on the fifth").
- **Round-3 fixes (2026-07-11, build 268) — three pre-existing quirks the owner asked to clean up, all validated to 0 FP on the 325-case suite + real data:**
  - **Seasonal year cues:** added summer/winter/spring/fall/autumn to the year-context words → "summer twenty twenty-five" → "summer 2025" (guarded by the same low-half band check, so "fall 20 feet" stays non-year).
  - **"thirty second timeout" → "30 second timeout":** homograph guard in `parseTensOrdinal` — when "<tens> second" is followed by a duration noun (timeout/delay/video/…), "second" is the time unit, not the ordinal. Keeps "thirty second avenue" → "32nd avenue".
  - **"one by one" idiom:** the sub-10 time override no longer fires when it's "cardinal by cardinal" (word before "by" is a cardinal), so "one by one"/"two by two" stay words while "by five" → "by 5" and "at four" → "at 4" are preserved.
- **Test-target note:** `JotTests` has a pre-existing dependency-resolution issue (`FastClusterWrapper`/`yyjson` invisible through `@testable import Jot`); validated via harness + extracted app-test pairs instead of the XCTest runner.

## Goal & principles
Improve `NumberNormalizer` (`Jot/App/Transcription/NumberNormalizer.swift`) to handle **decimals**, fix **bare years**, and add **month-day dates** — WITHOUT regressing correct text.
- **Precision over recall.** A wrong `3.5` in a note is worse than a missed one (Microsoft on-device ITN + Deepgram both deliberately under-convert). Ship gate = **0 false positives on the idiom/hard-negative set**.
- **Structure is the guard** (NeMo): fire a conversion only when the surrounding tokens form a *complete* numeric structure — not via idiom stoplists.
- **Harness-first:** every change is proven in the scratchpad harness (curated cases + real-data diff audit) before touching the app file; then the app's `NumberNormalizerTests.swift` must stay green.

## Baseline (current behavior, measured)
50/67 curated cases, **0 false positives**, 12 misses. Point-idiom traps 29/29 safe (no decimal rule today). Decimals 0/10 (some partial-mangle: "ninety nine point nine percent" → "99 point 9%"). Bare years broken ("nineteen ninety-eight" → "19 98"). Dates/versions missed. Real "point" sentences: 1/39 touched, and that one ("Oracle Linux ten point one") *should* become 10.1.

## Rule 1 — Decimals  (highest value + risk)
Model: NeMo `DecimalFst` = `integer? "point" fractional+ [scale]?`, fractional read **digit-by-digit**.
**Fire only when a spelled number word IMMEDIATELY follows `point`** (this single condition is the entire idiom guard — every idiom has a non-number after "point").
- **Integer part (optional):** the maximal cardinal run ending right before `point` → its value (e.g. "three"→3, "ninety nine"→99). If absent/non-number → **leading decimal → render `0.x`** (safer than `.x`).
- **Fractional part:** consume the maximal run of digit-class words after `point` (`zero, oh→0, one…nine`); concatenate as literal digits. "three point one four" → `3.14`; "zero point zero five" → `0.05`.
- **Stop conditions / guards:** `point` must have NO trailing sentence punctuation (blocks "…missed the point. Five…"); fractional run must be ≥1 digit word; do NOT run post-point words through the cardinal grouper (spoken decimals are digit-by-digit).
- **Unit/scale integration:** trailing `percent`→`%`, `dollars`→`$` prefix, `million/billion`→keep as word ("two point five million" → "2.5 million"). Matches existing money/percent/large-scale handling.
- Covers "version one point oh" → `1.0` (integer "one"=1, frac "oh"=0).

## Rule 2 — Bare years (fix the "19 98" bug)
Model: NeMo `date.py` paired-halves.
- Recognize the **two-2-digit-halves** shape `[nineteen|twenty|…teen] [oh-N | N-N | ties(-ones)]` and **concatenate into 4 digits** instead of emitting two cardinals. "nineteen ninety-eight" → `1998`; "twenty twenty-four" → `2024`; "nineteen oh five" → `1905`.
- **Gate on a plausible year band** (~1500–2099) so "forty fifty" etc. don't collapse.
- Fire this **without** requiring a year-context word (the current bug is that context-less halves fall through to the cardinal splitter). Keep the existing context-word path for "two thousand [and] N".
- **Residual risk (flagged):** "twenty twenty" / "twenty twenty-four" can be scores/vision, not a year — but in dictation the year reading dominates, so accept it by default. Highest-residual-risk conversion; call it out in review.

## Rule 3 — Dates (month + day)
Model: NeMo `graph_mdy` / `graph_dmy`. **An ordinal becomes a day number ONLY when a month name is adjacent.**
- `MONTH ORDINAL` → "Month Nth": "May fourth" → `May 4th`, "December thirty first" → `December 31st`.
- `[the] ORDINAL "of" MONTH` → "the fourth of July" → `4th of July` / `July 4th` (pick one; prefer keeping the suffix for notes readability).
- **Cap day ≤ 31** (else not a date: "May hundredth" stays text). A bare ordinal with no adjacent month stays on the existing ordinal path ("finished fourth" → 4th, "fourth quarter" unchanged intent).

## Implementation hooks (in `NumberNormalizer.swift`)
- Decimals: a pre-pass (or an in-loop branch at the point token) that consumes `[int-cardinal]? point digit+ [unit]` before the cardinal branch splits it. Reuse `tokenize`/`reassemble`/`computeValue`.
- Years: extend `parseYearShape` to also match paired-halves and to run **without** a year-context gate when the band check passes; ensure the main loop calls it before the cardinal branch so "19 98" can't happen.
- Dates: a month-adjacency check that upgrades an ordinal token to `N`+suffix.

## Test / eval plan (precision-weighted)
- Harness metrics: pass, **false-positives** (changed a hard-negative), **misses**. Gate: **idiom/hard-negative preservation = 100%**.
- Grow the hard-negative set (adversarial review will add more): point idioms, ordinal-not-date ("fourth quarter", "third party", "first aid"), year-not-year ("twenty twenty vision", "room twenty twelve"), leading-decimal sentence boundaries.
- **Real-data diff audit:** run over the ~2,900-row recordings CSV, diff input↔output, eyeball every changed span for false positives.
- App-side: `Jot/Tests/NumberNormalizerTests.swift` must stay green after the port.

## Rollout
Iterate each rule in the harness → adversarial review (multiple rounds, try to break it) → real-data audit → port to `NumberNormalizer.swift` → app tests green + build → ship. Order: **decimals → year fix → dates** (independent; can ship incrementally). "Anything better than now" — but only after 0-FP is proven.

## Residual risks
"twenty twenty"→year (accepted, highest risk); leading decimals at sentence boundaries; decimal+unit edge combos ("$2.5 million"); non-homophone number mis-hearings out of scope. No LM available, so ambiguous cases are resolved structurally/conservatively, not contextually.

Sources: NeMo ITN (arXiv:2104.05055) + grammars (Apache-2.0); Microsoft on-device ITN (arXiv:2211.03721); Deepgram numerals.

## Adversarial review round 1 (Codex ultra + breaking-case agent, 2026-07-11) — REQUIRED refinements
The review found real bugs + an inadequate harness. Refinements before any implementation:

**Decimals:**
- **DROP generic leading decimals** ("point five" → stays text). Both reviewers: "at this point three of us…" → "0.3", "point two of the agenda" → "0.2" are natural dictation. Require an integer cardinal immediately BEFORE "point" AND a digit word immediately after.
- **Parse FORWARD from the integer-cardinal start**, not backward from "point" (by then "ninety nine" is already "99" in the output; backtracking + whitespace remapping is fragile).
- **Reject any newline/sentence-punctuation crossing** in/around the span. "three point five. Percent…" must not become "3.5%…"; "twenty\n\ntwenty" must never merge.
- Keep the fractional part as a **String** (preserve "1.05", trailing zeros; never round-trip through Double).
- **Repeated "point" / IP addresses / "version 3 point five" (digit `.other` integer)** are undefined today → need a dedicated version/IP grammar or explicit skip; don't half-convert.
- `$2.5 million` is NOT free reuse — the existing large-scale pass-through leaves million/billion sequences unchanged (locked by app tests). Needs an explicit, narrow decimal→scale→currency pipeline or leave as "2.5 million".

**Years — the big correction:**
- **Do NOT ungate `parseYearShape` wholesale.** It owns "two thousand" forms and `readTwoDigitWord` accepts bare 1-9 → catastrophic: "room twenty one"→"2001", "twenty four seven"→"2004 seven", "Twenty One Pilots"→"2001 Pilots", "two thousand people"→"2000" (loses comma).
- A numeric band ALONE is not safe. **Retain positive temporal evidence** (context word / month / decade "'s") for most cases; a narrow bare-year rule may fire ONLY when the low half is a genuine two-digit form (teen, tens, tens+ones, or explicit "oh"+digit) — NEVER a bare one-through-nine. Keep "two thousand" context-gated.

**Dates — most hazardous, lowest priority:**
- Parse a COMPLETE date span BEFORE the generic ordinal combiner (else "May thirty-second"→"32nd" slips through).
- Validate **month-specific day maxima** (no "April 31st", "February 30th").
- Require **stronger evidence for homographic months** (May/March/August as verb/adjective/name). Casing won't save sentence-initial "May".
- Define ONE output order; parse an adjacent year as part of the same date span ("July fourth twenty twenty-six").
- Do NOT add a general bare-ordinal feature just to satisfy "meeting on the fifth" — that's out of scope and risky.

**Harness fixes (the tests couldn't prove safety):**
- Run ALL categories incl. the 144 adversarial cases (year_traps/date_traps were being silently skipped).
- Strengthen the FP metric to catch a destructive conversion inside an otherwise-correct sentence (not just whole-string equality).
- Give the real-data "point" audit per-row expected outputs (some rows ARE real decimals that SHOULD convert).
- Add a drift check between the harness copy and the app source.

**Verdict:** the plan needs another loop — fix the harness, apply these refinements, re-run against the full adversarial + real-data set, and only implement once 0-FP is *proven*, not asserted. Ship decimals first (clearest), years second (narrowed), dates last (or defer).
