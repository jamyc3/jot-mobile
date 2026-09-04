# Teach Vocabulary by Voice — Design

## Feature overview

The sheet asks the user to say the term they want Jot to write. Each take records
the selected recognizer's uncorrected transcript and shows it unchanged. If that
transcript is the term, Jot says so. Otherwise the transcript is the useful
mishearing and becomes a provisional “Sounds like” alias.

This design deliberately has no convergence rule and no attempt cap. One useful
take answers the question; additional takes are optional examples. Save merges
the remaining provisional aliases into the term, while Cancel changes nothing.

## Background and investigation findings

The shared pipeline already owns correction policy. `VocabularyGate` may ask
about a common-word mapping per occurrence, explicitly granted mappings can
auto-apply, and multi-word terms already have their own apply path. Voice
teaching therefore records what the recognizer produced; it does not predict or
duplicate the gate's later ask-versus-apply decision.

The shared `CorrectionKey.normalize` is the appropriate identity comparison:
NFC precomposition, case folding, whitespace collapse, and surrounding
punctuation removal while preserving internal punctuation and word boundaries.
This makes `Claude code.` the same utterance as typed `claude code`, while
`Cloud code` remains a mishearing. The user's typed `VocabTerm.text` is never
derived from the transcript.

Learned aliases belong in `VocabTerm.aliases`, the same slot as typed aliases.
`VocabularyRescorerHolder.enrichedAliases` remains the sole feed-time casing and
dedup enrichment; teaching must not reorder or reproduce it.

Apple's Speech guidance likewise treats short custom phrases as recognition
context and notes that specialized terms may need explicit spelling or
pronunciation data. That supports capturing the recognizer's actual short
output as data rather than asking the user to prove repeated convergence.

## Assumptions

- There is no separate `requirements.md`; the owner's supplied framing and
  acceptance traces are the source of truth.
- A useful take is a non-empty transcript that survives the vocabulary file's
  alias sanitization, whether it matches the term or is a mishearing.
- Existing and concurrently added typed aliases must survive Save.
- Deleting a take removes any alias derived from it and recomputes the visible
  state from the remaining immutable takes.

## Options explored and tradeoffs

- **Convergence plus a cap:** rejected. Repeating a stable mishearing adds no
  information, and a cap can end with nothing learned from exactly the useful
  common-word case.
- **Automatically finish after one take:** rejected. It would remove the liked
  review/delete interaction and prevent collecting a second genuine rendering.
- **User-controlled finish after one useful take:** selected. Save is enabled
  once at least one take produced usable evidence; Record stays available for
  optional examples. Failed or empty takes do not enable Save, but never block a
  retry. The flow ends only on Save or Cancel.

## Take outcomes and visible copy

For every completed take, keep the raw recognizer text for display and derive
one of these outcomes:

- **Term:** shared-normalized transcript equals shared-normalized typed term.
  Show `Heard: <raw transcript>` and `That's your term. Nothing new to learn.`
  Store no alias.
- **New mishearing:** the values differ and the file-safe alias is new. Show
  `Heard: <raw transcript>` and `Will learn “<alias>” as a sounds-like.` Add the
  alias provisionally.
- **Known mishearing:** the file-safe alias shared-normalizes equal to an
  existing or earlier provisional alias. Show the raw transcript and
  `Already in Sounds like.` Store no duplicate.
- **Empty:** show `Heard: Nothing` and `Jot didn't hear anything. Try again.`
- **Unusable after file sanitization:** show the raw transcript and
  `That take can't be saved as a sounds-like. Try again.`
- **Becomes the term after file formatting:** show the raw transcript and
  `That take becomes your term after formatting, so there's no sounds-like to save.`
  This is a truthful, non-success no-op and does not enable Save by itself.
- **Capture/transcription failure:** show `Take failed` and the concrete retry
  message from the failed operation.

Only the Term row uses the success checkmark/green treatment. A mishearing is
shown as something Jot will learn, never as text Jot “got right.”

The attempts line becomes an uncapped `Takes: N` count. The introductory copy
explains that one take is enough and more are optional.

## Selected implementation plan

1. Keep the existing recognizer-only transcription seam, which returns the
   selected recognizer's text before vocabulary correction and cleanup.
2. Replace the reducer's convergence/common-word/corrector machinery with a
   replay over immutable takes:

   ```text
   for each take:
     failure -> failed row
     empty transcript -> empty row
     shared-normalized transcript == shared-normalized term -> term row
     file-safe alias is empty -> unusable row
     shared-normalized alias == shared-normalized term -> formatting no-op row
     shared-normalized alias already belongs to existing/new aliases -> known row
     otherwise -> provisional alias + new-mishearing row

   maySave = at least one term, new-mishearing, or known-mishearing row remains
   ```

3. Keep the sheet's title, `Say <term>` prompt, attempts line, large
   Record/Stop control, deletable per-take list, and Cancel/Save actions. Remove
   terminal-state-driven recording and status copy; Record remains available
   whenever audio work is idle.
4. On Save, read the latest stored term, case/normalization-deduplicate and
   append provisional aliases, then update aliases only. Never overwrite the
   term or typed aliases.
5. Preserve the `hasDismissed` latch before every gentle-teardown guard. Await
   an in-flight start, use only `stop()`/`cancel()`-style gentle cleanup, and
   release `ownsActiveRecording` on every owned terminal. After a successful
   `save()`, call `stopGently()` synchronously before `dismiss()`; Cancel does
   the same, and `onDisappear` remains an idempotent backstop. A failed Save
   leaves the sheet active and must not latch dismissal. Never force-stop.
6. Replace reducer tests with the owner-required classifications, normalized
   term matching, no common-word rejection, alias merging/dedup behavior,
   failure/empty handling, deletion replay, and absence of a take cap.
